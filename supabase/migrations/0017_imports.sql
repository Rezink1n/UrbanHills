-- =============================================================================
-- UrbanHills · 0017 · Importaciones municipales
-- -----------------------------------------------------------------------------
-- Corrige un bloqueo detectado al poner en marcha el primer mundo real.
--
-- El problema: los materiales de construcción se necesitan entre sí en círculo.
--   acero    ← hormigón + ladrillo   (acería)
--   hormigón ← acero                 (hormigonera)
--   ladrillo ← acero                 (ladrillería)
-- En un mundo recién creado no existe ninguno de los tres, así que ninguna de
-- las tres fábricas se puede levantar, y la economía se queda congelada en la
-- extracción: piedra, arcilla, madera y cultivo, y nada más, para siempre.
--
-- La salida, que además es la que cuenta bien la historia: una ciudad joven
-- IMPORTA lo que todavía no sabe fabricar. Cada tick, el puerto pone a la venta
-- una cantidad limitada de materiales a precio de importación (35 % sobre el
-- precio ancla).
--
-- Tiene tres efectos, los tres buenos:
--   1. Se puede empezar a construir desde el primer minuto.
--   2. Pone un techo al precio: nadie puede estrangular el mercado del acero,
--      porque siempre existe la alternativa de importar.
--   3. Producir en la ciudad es más barato que importar, así que la industria
--      local gana en cuanto aparece. La importación se apaga sola.
-- =============================================================================

-- Sobreprecio de lo importado frente al precio ancla.
create or replace function game.import_markup() returns numeric
language sql immutable as $$ select 1.35::numeric $$;

-- Qué importa la ciudad. Deliberadamente sólo materiales de obra: las materias
-- primas y los bienes de consumo se los dejamos enteros a los jugadores, que es
-- donde está el juego.
create or replace function game.imported_resources() returns text[]
language sql immutable as $$
  select array['cement', 'brick', 'glass', 'steel', 'lumber', 'concrete']::text[];
$$;

comment on function game.imported_resources is
  'Materiales que el puerto pone a la venta cada tick para que una ciudad nueva '
  'pueda arrancar. No incluye materias primas ni bienes de consumo.';

-- -----------------------------------------------------------------------------
-- Oferta de importación del tick
-- -----------------------------------------------------------------------------
create or replace function game.tick_imports(p_world uuid)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare v_secs integer;
begin
  select tick_seconds into v_secs from worlds where id = p_world;

  -- Lo que no se vendió caduca: el cupo es por tick, no se acumula. Si no, un
  -- mundo tranquilo amasaría un almacén infinito de acero barato.
  update market_orders
     set status = 'expired'
   where world_id = p_world and is_npc and side = 'sell'
     and status in ('open','partial');

  insert into market_orders
    (world_id, company_id, resource_code, side, qty, unit_price, is_npc, expires_at)
  select p_world, null, r.code, 'sell',
         -- Cupo inversamente proporcional al precio: del material barato entra
         -- mucho, del caro poco. Suficiente para un par de obras por tick.
         greatest(15, round(5000 / r.base_price)),
         round(r.base_price * game.import_markup(), 4),
         true,
         now() + make_interval(secs => v_secs)
    from resources r
   where r.code = any (game.imported_resources());
end $$;

-- La satisfacción del consumo sólo mira la demanda de los hogares. Con las
-- importaciones, `is_npc` ya no basta para identificarla.
create or replace function game.demand_satisfaction(p_world uuid)
returns numeric
language sql stable security definer set search_path = public, game as $$
  select game.clamp(
    55 + 45 * coalesce(
      sum(o.qty_filled * cp.necessity) / nullif(sum(o.qty * cp.necessity), 0),
      0),
    0, 100)
  from market_orders o
  join (select resource_code, max(necessity) as necessity
          from consumption_profile group by resource_code) cp
    on cp.resource_code = o.resource_code
  where o.world_id = p_world and o.is_npc and o.side = 'buy'
    and o.created_at > now() - interval '1 hour';
$$;

-- La demanda de la población sólo debe caducar sus propias órdenes de compra,
-- no la oferta de importación.
create or replace function game.tick_demand(p_world uuid)
returns void
language plpgsql security definer set search_path = public, game as $$
declare v_secs integer;
begin
  select tick_seconds into v_secs from worlds where id = p_world;

  -- Lo que no se compró en el tick anterior caduca: la población no acumula
  -- la compra del martes para el miércoles.
  update market_orders
     set status = 'expired'
   where world_id = p_world and is_npc and side = 'buy'
     and status in ('open','partial');

  with hh as (
    select pc.class, sum(pc.count) / game.household_size() as households
      from population_cohorts pc
      join districts d on d.id = pc.district_id
     where d.world_id = p_world
     group by pc.class
  ),
  need as (
    select cp.resource_code,
           sum(hh.households * cp.qty_per_household) as qty,
           sum(hh.households * cp.qty_per_household * r.base_price * cp.price_tolerance)
             / nullif(sum(hh.households * cp.qty_per_household), 0) as price
      from hh
      join consumption_profile cp on cp.class = hh.class
      join resources r on r.code = cp.resource_code
     group by cp.resource_code
  )
  insert into market_orders
    (world_id, company_id, resource_code, side, qty, unit_price, is_npc, expires_at)
  select p_world, null, n.resource_code, 'buy',
         round(n.qty, 4), round(n.price, 4), true,
         now() + make_interval(secs => v_secs)
    from need n
   where n.qty > 0.01 and n.price > 0;
end $$;

-- -----------------------------------------------------------------------------
-- El tick, con la fase de importación antes de casar el mercado
-- -----------------------------------------------------------------------------
create or replace function fn_world_tick(p_world_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  w          worlds;
  v_tick     bigint;
  v_t0       timestamptz := clock_timestamp();
  v_built    integer;
  v_produced integer;
  v_matched  integer := 0;
  r          record;
  v_result   jsonb := '[]'::jsonb;
begin
  for w in
    select * from worlds
     where status = 'active'
       and (p_world_code is null or code = p_world_code)
     for update skip locked
  loop
    v_tick := w.current_tick + 1;

    -- Candado de idempotencia: si este tick ya se registró, no se repite.
    begin
      insert into tick_log (world_id, tick) values (w.id, v_tick);
    exception when unique_violation then
      continue;
    end;

    -- Las órdenes de jugador caducadas devuelven dinero o mercancía.
    for r in
      select id from market_orders
       where world_id = w.id and status in ('open','partial')
         and expires_at is not null and expires_at < now() and not is_npc
    loop
      perform game.release_order(r.id, 'expired');
    end loop;

    -- El contador de la red se pone a cero: mide un tick, no la historia.
    update utility_meters set supply = 0, demand = 0, updated_tick = v_tick
     where world_id = w.id;

    v_built    := game.tick_construction(w.id);
    perform      game.tick_staffing(w.id);
    v_produced := game.tick_production(w.id, v_tick);
    perform      game.tick_overheads(w.id, v_tick);
    perform      game.tick_rents(w.id, v_tick);
    perform      game.tick_demand(w.id);
    perform      game.tick_imports(w.id);

    for r in
      select code from resources where not (code = any (game.grid_resources()))
    loop
      v_matched := v_matched + game.match_market(w.id, r.code);
    end loop;

    perform game.tick_districts(w.id, v_tick);
    perform game.tick_migration(w.id);
    perform game.tick_treasury(w.id, v_tick);
    perform game.utility_reprice(w.id);
    perform game.tick_prices(w.id);

    update worlds
       set current_tick = v_tick, last_tick_at = now(), updated_at = now()
     where id = w.id;

    update tick_log
       set finished_at = now(),
           duration_ms = extract(milliseconds from clock_timestamp() - v_t0)::int,
           stats = jsonb_build_object(
             'built', v_built, 'produced', v_produced, 'trades', v_matched)
     where world_id = w.id and tick = v_tick;

    v_result := v_result || jsonb_build_object(
      'world', w.code, 'tick', v_tick,
      'built', v_built, 'produced', v_produced, 'trades', v_matched);
  end loop;

  return jsonb_build_object('ok', true, 'worlds', v_result);
end $$;

revoke all on function fn_world_tick(text) from public, anon, authenticated;
grant execute on function fn_world_tick(text) to service_role;
revoke all on all functions in schema game from public, anon, authenticated;
