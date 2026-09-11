-- =============================================================================
-- UrbanHills · 0013 · El tick del mundo
-- -----------------------------------------------------------------------------
-- Una llamada = un paso de simulación. Es idempotente por número de tick: si se
-- ejecuta dos veces el mismo tick, la segunda no hace nada. Eso permite
-- dispararlo desde pg_cron y desde una Edge Function sin miedo a duplicar.
--
-- Cada fase es una función aparte para poder probarlas y perfilarlas sueltas.
-- =============================================================================

-- Valor de suelo de referencia con el que se escalan las rentas.
create or replace function game.reference_land_value() returns numeric
language sql immutable as $$ select 25000::numeric $$;

-- Fracción de la población en edad de trabajar.
create or replace function game.labor_participation() returns numeric
language sql immutable as $$ select 0.55::numeric $$;

-- Personas por hogar.
create or replace function game.household_size() returns numeric
language sql immutable as $$ select 2.5::numeric $$;

-- -----------------------------------------------------------------------------
-- 1 · Entregar las obras terminadas
-- -----------------------------------------------------------------------------
create or replace function game.tick_construction(p_world uuid)
returns integer
language plpgsql security definer set search_path = public, game as $$
declare v_n integer;
begin
  with done as (
    update buildings b
       set status   = 'idle',
           built_at = coalesce(b.built_at, now()),
           ready_at = null
     where b.world_id = p_world
       and b.status = 'construction'
       and b.ready_at <= now()
    returning b.id, b.company_id, b.type_code
  )
  insert into notifications (company_id, kind, title, body, payload)
  select d.company_id, 'build_done', 'Obra terminada',
         bt.name || ' ya está operativa.',
         jsonb_build_object('building_id', d.id)
    from done d join building_types bt on bt.code = d.type_code
   where d.company_id is not null;

  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- -----------------------------------------------------------------------------
-- 2 · Reparto de mano de obra
-- -----------------------------------------------------------------------------
-- La plantilla sale de la población del distrito. Si hay menos manos que
-- puestos, todos los edificios producen por debajo de su capacidad; pagar mejor
-- que el vecino te pone por delante en la cola.
create or replace function game.tick_staffing(p_world uuid)
returns void
language plpgsql security definer set search_path = public, game as $$
begin
  with demand as (
    select p.district_id, bt.job_class, sum(bt.jobs * b.level) as jobs
      from buildings b
      join building_types bt on bt.code = b.type_code
      join plots p on p.id = b.plot_id
     where b.world_id = p_world and b.status <> 'construction' and bt.jobs > 0
     group by p.district_id, bt.job_class
  ),
  supply as (
    select pc.district_id, pc.class,
           floor(pc.count * game.labor_participation()) as pool
      from population_cohorts pc
      join districts d on d.id = pc.district_id
     where d.world_id = p_world
  ),
  ratio as (
    select d.district_id, d.job_class,
           game.clamp(coalesce(s.pool, 0) / nullif(d.jobs, 0), 0, 1) as r
      from demand d
      left join supply s
        on s.district_id = d.district_id and s.class = d.job_class
  )
  update buildings b
     set staffed_ratio = game.clamp(r.r * b.wage_level, 0, 1)
    from plots p, building_types bt, ratio r
   where p.id = b.plot_id
     and bt.code = b.type_code
     and r.district_id = p.district_id
     and r.job_class = bt.job_class
     and b.world_id = p_world
     and b.status <> 'construction';

  -- Los edificios sin plantilla (vivienda, huerto solar) trabajan siempre al 100 %.
  update buildings b
     set staffed_ratio = 1
    from building_types bt
   where bt.code = b.type_code
     and b.world_id = p_world
     and b.status <> 'construction'
     and bt.jobs = 0;
end $$;

-- -----------------------------------------------------------------------------
-- 3 · Cerrar los lotes de producción terminados
-- -----------------------------------------------------------------------------
create or replace function game.tick_production(p_world uuid, p_tick bigint)
returns integer
language plpgsql security definer set search_path = public, game as $$
declare
  b          record;
  v_qty      numeric;
  v_bill     numeric;
  v_inputs   numeric;
  v_unit     numeric;
  v_pw       numeric := game.utility_price(p_world, 'power');
  v_wt       numeric := game.utility_price(p_world, 'water');
  v_storable boolean;
  v_n        integer := 0;
  v_in       record;
  v_ok       boolean;
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

    select is_storable into v_storable from resources where code = b.output_code;

    if v_qty > 0 and b.company_id is not null then
      if v_storable then
        v_unit := case when v_qty > 0 then (v_inputs + v_bill) / v_qty else 0 end;
        perform game.inventory_add(b.company_id, b.output_code, v_qty, v_unit);
      else
        -- Luz y agua no se almacenan: la red las compra al precio vigente.
        perform game.post_ledger(
          b.company_id, 'market_sale',
          round(v_qty * game.utility_price(p_world, b.output_code), 2),
          'Vertido a red: ' || b.output_code, 'buildings', b.id);
        update utility_meters set supply = supply + v_qty
         where world_id = p_world and resource_code = b.output_code;
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

-- -----------------------------------------------------------------------------
-- 4 · Nóminas, mantenimiento y suministros de base
-- -----------------------------------------------------------------------------
create or replace function game.tick_overheads(p_world uuid, p_tick bigint)
returns void
language plpgsql security definer set search_path = public, game as $$
declare
  v_pw numeric := game.utility_price(p_world, 'power');
  v_wt numeric := game.utility_price(p_world, 'water');
  r    record;
begin
  for r in
    select b.company_id,
           sum(bt.jobs * b.level * bt.base_wage * b.wage_level * b.staffed_ratio) as wages,
           sum(bt.upkeep_per_tick * b.level)                                       as upkeep,
           sum(bt.power_use * b.level)                                             as power,
           sum(bt.water_use * b.level)                                             as water
      from buildings b
      join building_types bt on bt.code = b.type_code
     where b.world_id = p_world
       and b.company_id is not null
       and b.status <> 'construction'
     group by b.company_id
  loop
    if coalesce(r.wages, 0) > 0 then
      perform game.post_ledger(r.company_id, 'wages', -round(r.wages, 2),
        'Nóminas del tick ' || p_tick);
    end if;

    if coalesce(r.upkeep, 0) + coalesce(r.power, 0) * v_pw + coalesce(r.water, 0) * v_wt > 0 then
      perform game.post_ledger(r.company_id, 'upkeep',
        -round(r.upkeep + r.power * v_pw + r.water * v_wt, 2),
        'Mantenimiento y suministros');
    end if;
  end loop;

  -- Lo consumido en marcha también carga en la red.
  update utility_meters um
     set demand = um.demand + coalesce(agg.total, 0)
    from (
      select 'power' as code, sum(bt.power_use * b.level) as total
        from buildings b join building_types bt on bt.code = b.type_code
       where b.world_id = p_world and b.status <> 'construction'
      union all
      select 'water', sum(bt.water_use * b.level)
        from buildings b join building_types bt on bt.code = b.type_code
       where b.world_id = p_world and b.status <> 'construction'
    ) agg
   where um.world_id = p_world and um.resource_code = agg.code;

  -- El paso del tiempo desgasta. Bajo 40 de conservación la producción se resiente.
  update buildings
     set condition = greatest(0, condition - 0.05)
   where world_id = p_world and status <> 'construction';
end $$;

-- -----------------------------------------------------------------------------
-- 5 · Alquileres
-- -----------------------------------------------------------------------------
-- El mismo bloque de pisos renta el doble en un barrio bueno. Ésa es la razón
-- de ser de toda la capa urbana: quien mejora su distrito cobra más.
create or replace function game.tick_rents(p_world uuid, p_tick bigint)
returns void
language plpgsql security definer set search_path = public, game as $$
declare r record;
begin
  -- Tarifa por ocupante, escalada con el valor del suelo de la parcela.
  update buildings b
     set rent_per_tick = round(
           bt.base_rent
           * game.clamp(p.land_value / game.reference_land_value(), 0.5, 3.0), 2)
    from building_types bt, plots p
   where bt.code = b.type_code and p.id = b.plot_id
     and b.world_id = p_world and bt.base_rent > 0;

  -- Ocupación de la vivienda: la gente del distrito se reparte entre los
  -- edificios de su clase, a prorrata de capacidad.
  with cap as (
    select p.district_id, bt.housing_class as class,
           sum(bt.housing_capacity * b.level) as capacity
      from buildings b
      join building_types bt on bt.code = b.type_code
      join plots p on p.id = b.plot_id
     where b.world_id = p_world and b.status <> 'construction'
       and bt.housing_capacity > 0
     group by p.district_id, bt.housing_class
  ),
  fill as (
    select c.district_id, c.class,
           game.clamp(coalesce(pc.count, 0) / nullif(c.capacity, 0), 0, 1) as rate
      from cap c
      left join population_cohorts pc
        on pc.district_id = c.district_id and pc.class = c.class
  )
  update buildings b
     set occupancy = floor(bt.housing_capacity * b.level * f.rate)
    from building_types bt, plots p, fill f
   where bt.code = b.type_code and p.id = b.plot_id
     and f.district_id = p.district_id and f.class = bt.housing_class
     and b.world_id = p_world and bt.housing_capacity > 0;

  -- Ocupación de oficinas: depende de que haya empleo en el distrito.
  update buildings b
     set occupancy = floor(bt.retail_capacity * b.level
                           * game.clamp(coalesce(ds.employment_rate, 0), 0, 1))
    from building_types bt, plots p, district_stats ds
   where bt.code = b.type_code and p.id = b.plot_id and ds.district_id = p.district_id
     and b.world_id = p_world and bt.base_rent > 0 and bt.retail_capacity > 0;

  for r in
    select b.company_id, sum(b.occupancy * b.rent_per_tick) as income
      from buildings b
     where b.world_id = p_world and b.company_id is not null
       and b.status <> 'construction' and b.rent_per_tick > 0 and b.occupancy > 0
     group by b.company_id
  loop
    perform game.post_ledger(r.company_id, 'rent', round(r.income, 2),
      'Alquileres del tick ' || p_tick);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 6 · Demanda de la población
-- -----------------------------------------------------------------------------
-- Los hogares emiten una orden de compra agregada por recurso y tick. Es el
-- único punto por el que entra dinero nuevo en la economía de las empresas.
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
   where world_id = p_world and is_npc and status in ('open','partial');

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

-- Cuánto de lo que quería comprar la población se ha podido servir (0..100).
-- La ciudad heredada ya se abastecía sola, mal pero se abastecía: sin ningún
-- jugador vendiendo, el índice vale 55. Lo que los jugadores sirven lo empuja
-- hacia 100. Es lo que hace que abrir una tienda mejore el barrio de verdad.
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
  where o.world_id = p_world and o.is_npc
    and o.created_at > now() - interval '1 hour';
$$;

-- -----------------------------------------------------------------------------
-- 7 · Estado social de cada distrito
-- -----------------------------------------------------------------------------
create or replace function game.tick_districts(p_world uuid, p_tick bigint)
returns void
language plpgsql security definer set search_path = public, game as $$
declare v_supply numeric := game.demand_satisfaction(p_world);
begin
  with own as (
    select p.district_id,
           sum(bt.pollution * b.level)                                          as pollution,
           sum(bt.noise * b.level)                                              as noise,
           sum(bt.prestige * b.level)                                           as prestige,
           sum(bt.jobs * b.level)                                               as jobs,
           sum(bt.jobs * b.level * b.staffed_ratio)                             as jobs_filled,
           sum(bt.housing_capacity * b.level)                                   as housing,
           sum(case when bt.service='health'    then bt.service_strength*b.level else 0 end) as health,
           sum(case when bt.service='education' then bt.service_strength*b.level else 0 end) as education,
           sum(case when bt.service='safety'    then bt.service_strength*b.level else 0 end) as safety,
           sum(case when bt.service='transport' then bt.service_strength*b.level else 0 end) as transport,
           sum(case when bt.service='leisure'   then bt.service_strength*b.level else 0 end) as leisure
      from buildings b
      join building_types bt on bt.code = b.type_code
      join plots p on p.id = b.plot_id
     where b.world_id = p_world and b.status <> 'construction'
     group by p.district_id
  ),
  -- Nada se queda dentro del distrito: el humo, el ruido y los servicios se
  -- derraman al vecindario con un peso del 35 %.
  agg as (
    select d.id as district_id,
           coalesce(sum(o.pollution  * w.f), 0) as pollution,
           coalesce(sum(o.noise      * w.f), 0) as noise,
           coalesce(sum(o.prestige   * w.f), 0) as prestige,
           coalesce(sum(o.health     * w.f), 0) as health,
           coalesce(sum(o.education  * w.f), 0) as education,
           coalesce(sum(o.safety     * w.f), 0) as safety,
           coalesce(sum(o.transport  * w.f), 0) as transport,
           coalesce(sum(o.leisure    * w.f), 0) as leisure,
           -- Empleo y vivienda no se derraman al distrito vecino: se trabaja
           -- y se vive donde está el edificio. Sobre ellos se suma lo heredado.
           max(d.legacy_jobs)
             + coalesce(sum(case when n.id = d.id then o.jobs        end), 0) as jobs,
           max(d.legacy_jobs)
             + coalesce(sum(case when n.id = d.id then o.jobs_filled end), 0) as jobs_filled,
           max(d.legacy_housing)
             + coalesce(sum(case when n.id = d.id then o.housing     end), 0) as housing
      from districts d
      join districts n
        on n.world_id = d.world_id
       and abs(n.gx - d.gx) <= 1 and abs(n.gy - d.gy) <= 1
      cross join lateral (select case when n.id = d.id then 1.0 else 0.35 end as f) w
      left join own o on o.district_id = n.id
     where d.world_id = p_world
     group by d.id
  ),
  pop as (
    select pc.district_id,
           sum(pc.count)::int as population
      from population_cohorts pc
      join districts d on d.id = pc.district_id
     where d.world_id = p_world
     group by pc.district_id
  ),
  calc as (
    select a.*,
           coalesce(p.population, 0)                     as population,
           -- Una "unidad de demanda" son 40 habitantes: los servicios se miden
           -- contra el tamaño del distrito, no en valor absoluto.
           greatest(coalesce(p.population, 0) / 40.0, 1) as demand_unit
      from agg a
      left join pop p on p.district_id = a.district_id
  ),
  final as (
    select c.district_id,
           c.population,
           greatest(1, round(c.population / game.household_size()))::int as households,
           c.housing::int                                               as housing_capacity,
           c.jobs::int                                                  as jobs,
           round(c.jobs_filled)::int                                    as jobs_filled,
           game.clamp(c.pollution, 0, 100)                              as pollution,
           game.clamp(c.noise, 0, 100)                                  as noise,
           game.clamp(c.prestige, -100, 100)                            as prestige,
           game.clamp(c.health    * 100 / c.demand_unit, 0, 100)        as health_cov,
           game.clamp(c.education * 100 / c.demand_unit, 0, 100)        as education_cov,
           game.clamp(c.safety    * 100 / c.demand_unit, 0, 100)        as safety_cov,
           game.clamp(c.transport * 100 / c.demand_unit, 0, 100)        as transport_cov,
           game.clamp(c.leisure   * 100 / c.demand_unit, 0, 100)        as leisure_cov,
           -- Hacinamiento: gente por encima de la vivienda disponible.
           game.clamp((c.population - c.housing) * 100.0
                      / greatest(c.housing, 1), 0, 100)                 as overcrowding,
           game.clamp(c.jobs_filled / nullif(c.population * game.labor_participation(), 0),
                      0, 1)                                             as employment_rate
      from calc c
  )
  update district_stats ds
     set population       = f.population,
         households       = f.households,
         housing_capacity = f.housing_capacity,
         jobs             = f.jobs,
         jobs_filled      = f.jobs_filled,
         employment_rate  = f.employment_rate,
         pollution        = f.pollution,
         noise            = f.noise,
         prestige         = f.prestige,
         health_cov       = f.health_cov,
         education_cov    = f.education_cov,
         safety_cov       = f.safety_cov,
         transport_cov    = f.transport_cov,
         leisure_cov      = f.leisure_cov,
         supply_index     = v_supply,
         crime            = game.clamp(8 + f.population / 150.0
                                        - f.safety_cov * 0.35
                                        + f.pollution * 0.10, 0, 100),
         happiness        = game.clamp(
                              46
                              + (f.health_cov + f.education_cov + f.safety_cov
                                 + f.transport_cov + f.leisure_cov) / 5.0 * 0.42
                              - f.pollution * 0.30
                              - f.noise * 0.12
                              - f.overcrowding * 0.30
                              + (f.employment_rate * 100 - 50) * 0.22
                              + (v_supply - 70) * 0.20
                              - game.clamp(8 + f.population / 150.0
                                            - f.safety_cov * 0.35
                                            + f.pollution * 0.10, 0, 100) * 0.25,
                              0, 100),
         updated_tick     = p_tick,
         updated_at       = now()
    from final f
   where ds.district_id = f.district_id;

  -- El valor del suelo es la consecuencia de todo lo anterior. Es lo que hace
  -- que mejorar el barrio sea rentable y no un gesto altruista.
  update plots p
     set land_value = round(game.clamp(
           p.base_land_value * (
             0.55
             + (ds.health_cov + ds.education_cov + ds.safety_cov
                + ds.transport_cov + ds.leisure_cov) / 500.0 * 0.80
             + game.clamp(ds.prestige, 0, 100) / 100.0 * 0.55
             - ds.pollution / 100.0 * 0.45
             - ds.noise / 100.0 * 0.15
             - ds.crime / 100.0 * 0.20
           ),
           p.base_land_value * 0.25, p.base_land_value * 4.0), 2),
         updated_at = now()
    from district_stats ds
   where ds.district_id = p.district_id and p.world_id = p_world;

  update district_stats ds
     set land_value_index = sub.idx,
         avg_rent         = sub.rent
    from (
      select p.district_id,
             round(avg(p.land_value) / nullif(avg(p.base_land_value), 0) * 100, 2) as idx,
             coalesce(round(avg(nullif(b.rent_per_tick, 0)), 2), 0)                as rent
        from plots p
        left join buildings b on b.plot_id = p.id
       where p.world_id = p_world
       group by p.district_id
    ) sub
   where ds.district_id = sub.district_id;

  insert into district_stats_history
    (district_id, tick, population, happiness, pollution, employment_rate, land_value_index)
  select ds.district_id, p_tick, ds.population, ds.happiness, ds.pollution,
         ds.employment_rate, ds.land_value_index
    from district_stats ds
   where ds.world_id = p_world
  on conflict (district_id, tick) do nothing;
end $$;

-- -----------------------------------------------------------------------------
-- 8 · Migración
-- -----------------------------------------------------------------------------
-- La gente vota con los pies. Un barrio feliz con vivienda libre crece; uno
-- infeliz se vacía, y con él se vacían los locales de quien apostó por él.
create or replace function game.tick_migration(p_world uuid)
returns void
language plpgsql security definer set search_path = public, game as $$
begin
  update population_cohorts pc
     set count = greatest(0, floor(
           pc.count
           * (1 + game.clamp((ds.happiness - 52) / 50.0, -1, 1) * 0.035)
           + case
               -- Aunque el barrio sea perfecto, sin pisos no entra nadie.
               when ds.population < ds.housing_capacity then 1.5
               else -2.0
             end
         ))::int,
         happiness = ds.happiness
    from district_stats ds
   where ds.district_id = pc.district_id
     and ds.world_id = p_world;

  -- La clase que atrae cada barrio depende de lo que valga su suelo: los
  -- distritos caros expulsan a la clase baja y atraen a la alta.
  update population_cohorts pc
     set count = greatest(0, floor(pc.count * case
           when pc.class = 'high' and ds.land_value_index > 130 then 1.020
           when pc.class = 'high' and ds.land_value_index <  85 then 0.975
           when pc.class = 'low'  and ds.land_value_index > 150 then 0.980
           when pc.class = 'low'  and ds.land_value_index <  80 then 1.015
           else 1.0 end))::int
    from district_stats ds
   where ds.district_id = pc.district_id and ds.world_id = p_world;

  update district_stats ds
     set migration_pressure = round((ds.happiness - 52) * 2
                                    + (ds.housing_capacity - ds.population) * 0.05, 2)
   where ds.world_id = p_world;
end $$;

-- -----------------------------------------------------------------------------
-- 9 · Hacienda municipal
-- -----------------------------------------------------------------------------
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

  -- Mantenimiento de lo público.
  select coalesce(sum(bt.upkeep_per_tick * b.level), 0) into v_spend
    from buildings b
    join building_types bt on bt.code = b.type_code
   where b.world_id = p_world and b.company_id is null;

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
     where b.world_id = p_world and b.company_id is null;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 10 · Velas de precio
-- -----------------------------------------------------------------------------
create or replace function game.tick_prices(p_world uuid)
returns void
language plpgsql security definer set search_path = public, game as $$
begin
  insert into price_history (world_id, resource_code, bucket, open, high, low, close, volume)
  select t.world_id, t.resource_code, date_trunc('hour', t.created_at),
         (array_agg(t.unit_price order by t.created_at asc ))[1],
         max(t.unit_price), min(t.unit_price),
         (array_agg(t.unit_price order by t.created_at desc))[1],
         sum(t.qty)
    from market_trades t
   where t.world_id = p_world
     and t.created_at >= date_trunc('hour', now())
   group by t.world_id, t.resource_code, date_trunc('hour', t.created_at)
  on conflict (world_id, resource_code, bucket) do update
     set high   = greatest(price_history.high, excluded.high),
         low    = least(price_history.low, excluded.low),
         close  = excluded.close,
         volume = excluded.volume;
end $$;

-- =============================================================================
-- Orquestador
-- =============================================================================
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

    for r in select code from resources where is_storable loop
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

comment on function fn_world_tick is
  'Avanza un paso la simulación. Idempotente por número de tick.';

-- Sólo el servidor mueve el mundo: ni anon ni los jugadores pueden invocarlo.
revoke all on function fn_world_tick(text) from public, anon, authenticated;
grant execute on function fn_world_tick(text) to service_role;
