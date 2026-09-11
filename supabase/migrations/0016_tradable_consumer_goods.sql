-- =============================================================================
-- UrbanHills · 0016 · Los bienes de consumo vuelven al mercado
-- -----------------------------------------------------------------------------
-- Corrige un fallo de diseño detectado al arrancar el primer mundo real.
--
-- El problema: `groceries`, `meals` y `leisure` estaban marcados como NO
-- almacenables, pensando que se consumen en el acto. Pero `rpc_place_order`
-- rechaza cualquier recurso no almacenable (`NOT_TRADABLE`), y la demanda de la
-- población se emite precisamente como órdenes de compra sobre esos tres. El
-- resultado era que la mayor demanda del juego —más de mil cestas por tick—
-- quedaba en el libro sin que ningún jugador pudiera servirla jamás.
--
-- La regla correcta es más estrecha: lo único que no pasa por el almacén es lo
-- que va por RED, es decir la luz y el agua. Todo lo demás se compra y se vende
-- en el mercado, que es donde el juego quiere que se decidan los precios.
-- =============================================================================

-- Volumen 0: ocupan sitio en la tienda, no en el almacén. Se pueden guardar
-- entre ticks sin que eso obligue a construir naves.
update resources
   set is_storable = true, volume = 0
 where code in ('groceries', 'meals', 'leisure');

-- La red sólo tiene dos contadores. Los tres que sobraban se creaban porque
-- bootstrap_world los elegía por `is_storable = false`, que era el criterio
-- equivocado.
delete from utility_meters
 where resource_code not in ('power', 'water');

-- Un único sitio donde se dice qué va por red.
create or replace function game.grid_resources()
returns text[] language sql immutable as $$
  select array['power', 'water']::text[];
$$;

comment on function game.grid_resources is
  'Recursos que se distribuyen por red y no pasan por el almacén ni por el '
  'libro de órdenes. Todo lo demás se negocia en el mercado.';

create or replace function game.bootstrap_world(p_world uuid)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
begin
  insert into city_treasury (world_id, balance)
  values (p_world, 2000000)
  on conflict (world_id) do nothing;

  -- Precio de arranque de la red, igual al precio ancla del recurso.
  insert into utility_meters (world_id, resource_code, price)
  select p_world, r.code, r.base_price
  from resources r
  where r.code = any (game.grid_resources())
  on conflict (world_id, resource_code) do nothing;

  insert into district_stats (district_id, world_id)
  select d.id, d.world_id from districts d where d.world_id = p_world
  on conflict (district_id) do nothing;

  -- Población semilla: la ciudad no arranca vacía, arranca pequeña. Se reparte
  -- con más gente cuanto más céntrico es el distrito.
  insert into population_cohorts (district_id, class, count, income)
  select d.id, c.class,
         greatest(0, round(c.base * (0.35 + avg(p.centrality) / 140.0)))::int,
         c.income
  from districts d
  join plots p on p.district_id = d.id
  cross join (values
      ('low'::social_class,  120, 22.0),
      ('mid'::social_class,   70, 55.0),
      ('high'::social_class,  14, 140.0)
  ) as c(class, base, income)
  where d.world_id = p_world
  group by d.id, c.class, c.base, c.income
  on conflict (district_id, class) do nothing;

  -- La ciudad heredada da alojamiento a su población con un 12 % de holgura,
  -- y empleo al 92 % de quien puede trabajar.
  update districts d
     set legacy_housing = round(sub.total * 1.12)::int,
         legacy_jobs    = round(sub.total * 0.55 * 0.92)::int
    from (
      select pc.district_id, sum(pc.count)::int as total
      from population_cohorts pc
      join districts dd on dd.id = pc.district_id
      where dd.world_id = p_world
      group by pc.district_id
    ) sub
   where d.id = sub.district_id;

  update district_stats ds
     set population = sub.total,
         households = greatest(1, round(sub.total / 2.5))::int
    from (
      select pc.district_id, sum(pc.count)::int as total
      from population_cohorts pc
      join districts d on d.id = pc.district_id
      where d.world_id = p_world
      group by pc.district_id
    ) sub
   where ds.district_id = sub.district_id;
end $$;

-- `rpc_place_order` rechazaba por `is_storable`; ahora rechaza por lo que de
-- verdad importa: si va por red, no se negocia.
create or replace function rpc_place_order(
  p_world_id uuid,
  p_resource text,
  p_side     text,
  p_qty      numeric,
  p_price    numeric
) returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_co    companies;
  v_res   resources;
  v_side  order_side;
  v_id    uuid;
  v_escrow numeric := 0;
begin
  v_co := game.my_company(p_world_id);
  perform game.rate_limit(v_co.id, 'order', 60, interval '1 minute');

  v_side := p_side::order_side;

  select * into v_res from resources where code = p_resource;
  if not found then
    raise exception 'UNKNOWN_RESOURCE' using errcode = 'P0002';
  end if;
  if v_res.code = any (game.grid_resources()) then
    raise exception 'NOT_TRADABLE' using errcode = 'P0001';  -- luz y agua van por red
  end if;
  if p_qty <= 0 or p_price <= 0 then
    raise exception 'INVALID_ORDER' using errcode = 'P0001';
  end if;

  if v_side = 'buy' then
    v_escrow := round(p_qty * p_price, 2);
    if v_co.cash < v_escrow then
      raise exception 'INSUFFICIENT_FUNDS' using errcode = 'P0001';
    end if;
    -- El dinero sale de caja ya: no se puede comprometer dos veces.
    perform game.post_ledger(v_co.id, 'market_buy', -v_escrow,
      'Retención por orden de compra de ' || p_resource);
  else
    -- La mercancía sale del almacén al poner la orden, por el mismo motivo.
    perform game.inventory_take(v_co.id, p_resource, p_qty);
  end if;

  insert into market_orders
    (world_id, company_id, resource_code, side, qty, unit_price, escrow, expires_at)
  values
    (p_world_id, v_co.id, p_resource, v_side, p_qty, round(p_price, 4), v_escrow,
     now() + interval '7 days')
  returning id into v_id;

  -- Se intenta casar en el acto: una orden que cruza no debería esperar al tick.
  perform game.match_market(p_world_id, p_resource);

  return jsonb_build_object('order_id', v_id);
end $$;

revoke all on function rpc_place_order(uuid,text,text,numeric,numeric) from public, anon;
grant execute on function rpc_place_order(uuid,text,text,numeric,numeric) to authenticated;

-- El tick sigue el mismo criterio: sólo la luz y el agua se vierten a la red.
create or replace function game.tick_production(p_world uuid, p_tick bigint)
returns integer
language plpgsql security definer set search_path = public, game as $$
declare
  b        record;
  v_qty    numeric;
  v_bill   numeric;
  v_inputs numeric;
  v_unit   numeric;
  v_pw     numeric := game.utility_price(p_world, 'power');
  v_wt     numeric := game.utility_price(p_world, 'water');
  v_grid   boolean;
  v_n      integer := 0;
  v_in     record;
  v_ok     boolean;
begin
  for b in
    select bl.*, r.output_code, r.output_qty, r.minutes,
           r.power_use, r.water_use, bt.name as type_name
      from buildings bl
      join recipes r         on r.id = bl.recipe_id
      join building_types bt on bt.code = bl.type_code
     where bl.world_id = p_world
       and bl.status = 'producing'
       and bl.run_ends_at <= now()
       for update of bl
  loop
    -- Rinde lo que permita la plantilla y el estado de conservación.
    v_qty := round(b.output_qty * b.run_batches * b.staffed_ratio
                   * (0.5 + b.condition / 200.0), 4);

    v_bill := round(b.power_use * b.run_batches * v_pw
                  + b.water_use * b.run_batches * v_wt, 2);

    select coalesce(sum(ri.qty * b.run_batches * coalesce(i.avg_cost, res.base_price)), 0)
      into v_inputs
      from recipe_inputs ri
      join resources res on res.code = ri.resource_code
      left join inventories i
        on i.company_id = b.company_id and i.resource_code = ri.resource_code
     where ri.recipe_id = b.recipe_id;

    update utility_meters
       set demand = demand + b.power_use * b.run_batches
     where world_id = p_world and resource_code = 'power';
    update utility_meters
       set demand = demand + b.water_use * b.run_batches
     where world_id = p_world and resource_code = 'water';

    if v_bill > 0 and b.company_id is not null then
      perform game.post_ledger(b.company_id, 'upkeep', -v_bill,
        'Suministros: ' || b.type_name, 'buildings', b.id);
    end if;

    v_grid := b.output_code = any (game.grid_resources());

    if v_qty > 0 and b.company_id is not null then
      if v_grid then
        -- Luz y agua no se almacenan: la red las compra al precio vigente.
        perform game.post_ledger(
          b.company_id, 'market_sale',
          round(v_qty * game.utility_price(p_world, b.output_code), 2),
          'Vertido a red: ' || b.output_code, 'buildings', b.id);
        update utility_meters set supply = supply + v_qty
         where world_id = p_world and resource_code = b.output_code;
      else
        v_unit := case when v_qty > 0 then (v_inputs + v_bill) / v_qty else 0 end;
        perform game.inventory_add(b.company_id, b.output_code, v_qty, v_unit);
      end if;
    end if;

    insert into production_runs
      (building_id, company_id, recipe_id, batches, output_code, output_qty,
       input_cost, wage_cost, tick)
    values (b.id, b.company_id, b.recipe_id, b.run_batches, b.output_code, v_qty,
            v_inputs, v_bill, p_tick);

    -- Encadenar el siguiente lote si el jugador lo dejó en automático y hay
    -- material para ello. Si falta algo, el edificio queda parado y esperando.
    v_ok := false;
    if b.auto_repeat then
      begin
        for v_in in select resource_code, qty from recipe_inputs where recipe_id = b.recipe_id
        loop
          perform game.inventory_take(b.company_id, v_in.resource_code, v_in.qty * b.run_batches);
        end loop;
        v_ok := true;
      exception when others then
        v_ok := false;
      end;
    end if;

    if v_ok then
      update buildings
         set run_ends_at = now() + make_interval(mins => b.minutes * b.run_batches),
             condition   = greatest(0, condition - 0.25)
       where id = b.id;
    else
      update buildings
         set status      = 'idle',
             run_ends_at = null,
             run_batches = 0,
             auto_repeat = false,
             condition   = greatest(0, condition - 0.25)
       where id = b.id;
    end if;

    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

-- El tick casaba sólo los recursos almacenables, que antes excluía los de
-- consumo. Ahora casa todo lo que no va por red.
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
