-- =============================================================================
-- UrbanHills · 0018 · Qué pasa cuando una empresa desaparece
-- -----------------------------------------------------------------------------
-- Tercer fallo detectado al probar el mundo real. Al borrar una cuenta:
--
--   · `buildings.company_id` quedaba en NULL en vez de derribarse. Y como
--     `tick_treasury` cobraba el mantenimiento público a "los edificios sin
--     empresa", el municipio se ponía a pagar la fábrica de alguien que ya no
--     juega. Confundía "edificio municipal" con "edificio abandonado".
--
--   · `plots.owner_company_id` quedaba en NULL pero `for_sale` seguía en false,
--     así que la parcela quedaba atrapada: sin dueño y sin poder comprarse.
--     Suelo muerto para siempre en mitad de la ciudad.
-- =============================================================================

-- Una empresa disuelta se lleva sus edificios por delante. Es lo que espera
-- cualquiera: si la empresa no existe, la fábrica tampoco.
alter table buildings drop constraint if exists buildings_company_id_fkey;
alter table buildings
  add constraint buildings_company_id_fkey
  foreign key (company_id) references companies(id) on delete cascade;

-- Limpieza de lo que quedó huérfano antes de esta migración.
delete from buildings b
 where b.company_id is null
   and exists (select 1 from building_types bt
                where bt.code = b.type_code and not bt.municipal_only);

-- -----------------------------------------------------------------------------
-- El municipio paga lo suyo, y sólo lo suyo
-- -----------------------------------------------------------------------------
-- Se identifica por el TIPO de edificio, que es el dato fiable, en vez de por
-- la ausencia de empresa, que es una coincidencia.
create or replace function game.tick_treasury(p_world uuid, p_tick bigint)
returns void
language plpgsql security definer set search_path = public, game as $$
declare
  v_t      city_treasury;
  v_income numeric := 0;
  v_spend  numeric := 0;
  r        record;
begin
  select * into v_t from city_treasury where world_id = p_world for update;
  if not found then return; end if;

  -- IBI sobre el valor del suelo en propiedad.
  for r in
    select p.owner_company_id as company_id,
           round(sum(p.land_value) * v_t.tax_property, 2) as tax
      from plots p
     where p.world_id = p_world and p.owner_company_id is not null
     group by p.owner_company_id
  loop
    if r.tax > 0 then
      perform game.post_ledger(r.company_id, 'tax', -r.tax, 'IBI del tick ' || p_tick);
      v_income := v_income + r.tax;
    end if;
  end loop;

  -- Impuesto sobre nóminas.
  for r in
    select b.company_id,
           round(sum(bt.jobs * b.level * bt.base_wage * b.wage_level * b.staffed_ratio)
                 * v_t.tax_payroll, 2) as tax
      from buildings b
      join building_types bt on bt.code = b.type_code
     where b.world_id = p_world and b.company_id is not null
       and b.status <> 'construction' and bt.jobs > 0
     group by b.company_id
  loop
    if r.tax > 0 then
      perform game.post_ledger(r.company_id, 'tax', -r.tax,
        'Cuotas sociales del tick ' || p_tick);
      v_income := v_income + r.tax;
    end if;
  end loop;

  -- Mantenimiento de lo público: escuelas, hospitales, parques y transporte.
  select coalesce(sum(bt.upkeep_per_tick * b.level), 0) into v_spend
    from buildings b
    join building_types bt on bt.code = b.type_code
   where b.world_id = p_world and bt.municipal_only;

  update city_treasury
     set balance = balance + v_income - v_spend, updated_at = now()
   where world_id = p_world
  returning balance into v_t.balance;

  insert into city_ledger (world_id, tick, kind, amount, balance_after, memo)
  values (p_world, p_tick, 'taxes', v_income, v_t.balance, 'Recaudación'),
         (p_world, p_tick, 'upkeep', -v_spend, v_t.balance, 'Servicios públicos');

  -- Un municipio en números rojos no mantiene sus edificios, y se nota en la calle.
  if v_t.balance < 0 then
    update buildings b
       set condition = greatest(0, b.condition - 1.5)
      from building_types bt
     where bt.code = b.type_code
       and b.world_id = p_world and bt.municipal_only;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- El suelo sin dueño vuelve al mercado municipal
-- -----------------------------------------------------------------------------
create or replace function game.tick_reclaim_land(p_world uuid)
returns void
language plpgsql security definer set search_path = public, game as $$
begin
  update plots p
     set for_sale   = true,
         ask_price  = null,
         updated_at = now()
   where p.world_id = p_world
     and p.owner_company_id is null
     and not p.for_sale
     and p.terrain <> 'water'
     and p.zoning <> 'protected';
end $$;

comment on function game.tick_reclaim_land is
  'Devuelve al mercado el suelo que se quedó sin dueño. Sin esto, la parcela de '
  'una empresa disuelta quedaría atrapada: ni suya ni comprable.';

-- -----------------------------------------------------------------------------
-- El tick, con la recuperación de suelo
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
    perform game.tick_reclaim_land(w.id);
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
