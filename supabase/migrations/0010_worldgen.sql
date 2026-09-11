-- =============================================================================
-- UrbanHills · 0010 · Generación del mundo
-- -----------------------------------------------------------------------------
-- Crea una partida entera: relieve, distritos, parcelas, hacienda y red.
-- Determinista: la misma semilla produce siempre el mismo mapa.
-- =============================================================================

create or replace function game.generate_world(
  p_code          text,
  p_name          text,
  p_seed          integer default 20260911,
  p_width         integer default 64,
  p_height        integer default 64,
  p_district_size integer default 8,
  p_starting_cash numeric default 250000
) returns uuid
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_world uuid;
  v_cx    numeric := p_width  / 2.0;
  v_cy    numeric := p_height / 2.0;
  v_maxd  numeric := sqrt(power(p_width / 2.0, 2) + power(p_height / 2.0, 2));
begin
  insert into worlds (code, name, seed, width, height, district_size, starting_cash)
  values (p_code, p_name, p_seed, p_width, p_height, p_district_size, p_starting_cash)
  returning id into v_world;

  -- ── Distritos ──────────────────────────────────────────────────────────────
  -- Se nombran con una letra por columna y un número por fila: A1, A2, B1…
  insert into districts (world_id, code, name, gx, gy, center_x, center_y)
  select
    v_world,
    chr(65 + gx) || (gy + 1)::text,
    chr(65 + gx) || (gy + 1)::text,
    gx, gy,
    (gx * p_district_size + p_district_size / 2)::int,
    (gy * p_district_size + p_district_size / 2)::int
  from generate_series(0, (p_width  / p_district_size) - 1) gx,
       generate_series(0, (p_height / p_district_size) - 1) gy;

  -- ── Parcelas ───────────────────────────────────────────────────────────────
  with grid as (
    select x, y,
           -- El ruido crudo se agolpa en torno a 0,5; sin expandirlo el mapa
           -- sale plano y nunca aparecen ni crestas ni roca. El factor 2,2
           -- abre el histograma hasta usar el rango entero.
           game.clamp(0.5 + (game.smooth_noise(p_seed, x, y, 16) - 0.5) * 2.2, 0, 1)
             as relief,
           game.hash_noise(p_seed + 404, x, y) as biome_roll,
           game.clamp(
             round((1 - game.grid_distance(x, y, v_cx::int, v_cy::int) / v_maxd) * 100),
             0, 100)::numeric as centrality
    from generate_series(0, p_width - 1) x,
         generate_series(0, p_height - 1) y
  ),
  shaped as (
    select g.*,
           -- La ciudad nace en un valle: el centro se hunde y las colinas
           -- quedan alrededor. De ahí el nombre del juego.
           game.clamp(round(g.relief * 100 - g.centrality * 0.30), 0, 100)::int
             as elevation
      from grid g
  ),
  ranked as (
    -- Las bandas de terreno se reparten por percentil, no por umbrales fijos.
    -- Así cualquier semilla produce un mapa jugable: siempre habrá roca para
    -- minar, vega para industria y ladera para vivienda cara, pase lo que pase
    -- con la media del ruido.
    select s.*,
           percent_rank() over (order by s.relief)    as relief_rank,
           percent_rank() over (order by s.elevation) as elev_rank
      from shaped s
  ),
  typed as (
    select r.*,
      case
        when r.relief_rank < 0.10                          then 'water'
        when r.elev_rank   < 0.38 and r.biome_roll > 0.72  then 'forest'
        when r.elev_rank   < 0.38                          then 'lowland'
        when r.elev_rank   < 0.76 and r.biome_roll > 0.82  then 'forest'
        when r.elev_rank   < 0.76                          then 'hill'
        when r.elev_rank   < 0.93                          then 'ridge'
        else 'rock'
      end::terrain_type as terrain
    from ranked r
  )
  insert into plots (
    world_id, district_id, x, y, elevation, terrain, centrality,
    base_land_value, land_value, zoning, for_sale
  )
  select
    v_world,
    d.id,
    t.x, t.y, t.elevation, t.terrain, t.centrality,
    0, 0,
    -- Calificación inicial: anillos concéntricos, con la periferia rocosa
    -- dejada sin calificar para que haya dónde abrir canteras y minas.
    -- El municipio puede recalificar después.
    case
      when t.terrain = 'water'                              then 'protected'
      when t.terrain = 'rock' and t.elevation > 92           then 'protected'
      when t.terrain in ('rock','ridge') and t.centrality < 45 then 'unzoned'
      when t.centrality >= 80                                then 'commercial'
      when t.centrality >= 55                                then 'mixed'
      when t.centrality >= 28                                then 'residential'
      when t.centrality >= 10                                then 'industrial'
      else 'unzoned'
    end::zoning_type,
    t.terrain <> 'water'
  from typed t
  join districts d
    on d.world_id = v_world
   and d.gx = t.x / p_district_size
   and d.gy = t.y / p_district_size;

  -- ── Pendiente y vistas ─────────────────────────────────────────────────────
  -- Dos derivadas del relieve que se calculan una vez y ya no cambian:
  --   slope      = mayor desnivel contra las 8 parcelas contiguas
  --   view_score = cuánto se levanta esta parcela sobre su entorno de 5×5,
  --                que es exactamente lo que se paga en una ciudad con colinas.
  with neigh as (
    select p.id,
           max(abs(p.elevation - n.elevation))
             filter (where abs(n.x - p.x) <= 1 and abs(n.y - p.y) <= 1) as max_drop,
           avg(n.elevation)                                             as around
    from plots p
    join plots n
      on n.world_id = p.world_id
     and n.id <> p.id
     and abs(n.x - p.x) <= 2
     and abs(n.y - p.y) <= 2
    where p.world_id = v_world
    group by p.id
  )
  update plots p
     set slope      = game.clamp(coalesce(neigh.max_drop, 0), 0, 100)::smallint,
         view_score = game.clamp(round(50 + (p.elevation - neigh.around) * 3.2), 0, 100)
    from neigh
   where p.id = neigh.id;

  -- ── Valor base del suelo ───────────────────────────────────────────────────
  update plots p
     set base_land_value = round(
           ( 6000
             + p.centrality * 260          -- estar cerca del centro
             + p.view_score * 150          -- tener vistas
           )
           * case p.terrain
               when 'water'   then 0.15
               when 'rock'    then 0.55
               when 'ridge'   then 0.90
               when 'forest'  then 1.10
               when 'hill'    then 1.05
               else 1.00
             end
           * (1 - least(p.slope, 60) * 0.006)   -- construir en cuesta cuesta
         , 2),
         ask_price = null
   where p.world_id = v_world;

  -- Sin servicios de ningún tipo, tick_districts deja el suelo en el 55 % de su
  -- valor potencial. Se arranca ya ahí para que el primer tick no provoque un
  -- desplome del 45 % a quien haya comprado en el primer minuto.
  update plots set land_value = round(base_land_value * 0.55, 2)
   where world_id = v_world;

  -- ── Arranque de la simulación ──────────────────────────────────────────────
  perform game.bootstrap_world(v_world);

  return v_world;
end $$;

comment on function game.generate_world is
  'Crea una partida completa a partir de una semilla. Determinista.';

-- -----------------------------------------------------------------------------
-- Inicializa las tablas dependientes de un mundo ya generado.
-- -----------------------------------------------------------------------------
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
  where r.is_storable = false
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
  -- y empleo al 92 % de quien puede trabajar. Es el punto de equilibrio del
  -- que parte la partida.
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
