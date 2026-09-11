-- =============================================================================
-- UrbanHills · 0001 · Fundamentos: esquema de utilidades, tipos y ayudantes
-- =============================================================================

create schema if not exists game;

comment on schema game is
  'Funciones internas del motor de juego. No se expone vía PostgREST.';

-- -----------------------------------------------------------------------------
-- Tipos enumerados
-- -----------------------------------------------------------------------------

do $$ begin
  create type terrain_type as enum ('water','lowland','hill','ridge','forest','rock');
exception when duplicate_object then null; end $$;

do $$ begin
  create type zoning_type as enum
    ('unzoned','residential','commercial','industrial','civic','mixed','protected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type resource_category as enum
    ('raw','material','component','good','service','utility');
exception when duplicate_object then null; end $$;

do $$ begin
  create type building_category as enum
    ('extraction','energy','processing','manufacturing',
     'residential','commercial','civic','logistics');
exception when duplicate_object then null; end $$;

do $$ begin
  create type building_status as enum
    ('construction','idle','producing','paused','derelict');
exception when duplicate_object then null; end $$;

do $$ begin
  create type service_kind as enum
    ('none','health','education','safety','transport','leisure','utility');
exception when duplicate_object then null; end $$;

do $$ begin
  create type social_class as enum ('low','mid','high');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_side as enum ('buy','sell');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_status as enum ('open','partial','filled','cancelled','expired');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ledger_kind as enum
    ('founding','land_purchase','land_sale','construction','upgrade','upkeep',
     'wages','market_buy','market_sale','rent','tax','grant','penalty','adjustment');
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- Ayudantes numéricos usados por la simulación
-- -----------------------------------------------------------------------------

-- Acota un valor a un rango. Se usa constantemente para índices 0..100.
create or replace function game.clamp(v numeric, lo numeric, hi numeric)
returns numeric language sql immutable parallel safe as $$
  select greatest(lo, least(hi, v));
$$;

-- Ruido determinista 2D basado en hash. No es Perlin, pero es estable, barato y
-- suficiente para generar relieve creíble sin extensiones externas.
create or replace function game.hash_noise(seed int, x int, y int)
returns numeric language sql immutable parallel safe as $$
  select (abs(hashtextextended(seed::text || ':' || x::text || ':' || y::text, 0)) % 100000)::numeric
         / 100000.0;
$$;

-- Ruido de valor con interpolación bilineal y suavizado de Hermite. Es el
-- ingrediente que convierte el hash anterior (que es estática pura) en un
-- relieve continuo: sin interpolar, cada celda salta respecto a su vecina y el
-- mapa sale con pendientes imposibles en todas partes.
create or replace function game.value_noise(seed int, x int, y int, scale numeric)
returns numeric language sql immutable parallel safe as $$
  with f as (
    select x / scale as fx, y / scale as fy
  ),
  c as (
    select floor(fx)::int as x0, floor(fy)::int as y0,
           fx - floor(fx)  as tx, fy - floor(fy)  as ty
    from f
  ),
  s as (
    -- smoothstep: derivada nula en los nodos, así no se ven las costuras.
    select x0, y0,
           tx * tx * (3 - 2 * tx) as sx,
           ty * ty * (3 - 2 * ty) as sy
    from c
  )
  select game.hash_noise(seed, x0,     y0    ) * (1 - sx) * (1 - sy)
       + game.hash_noise(seed, x0 + 1, y0    ) *      sx  * (1 - sy)
       + game.hash_noise(seed, x0,     y0 + 1) * (1 - sx) *      sy
       + game.hash_noise(seed, x0 + 1, y0 + 1) *      sx  *      sy
  from s;
$$;

-- Ruido fractal: cuatro octavas del anterior, de la más gruesa a la más fina.
-- Las gruesas dibujan las colinas; las finas, el detalle del terreno.
create or replace function game.smooth_noise(seed int, x int, y int, scale int)
returns numeric language sql immutable parallel safe as $$
  select game.value_noise(seed,      x, y, scale)            * 0.54
       + game.value_noise(seed + 17, x, y, scale / 2.0)      * 0.27
       + game.value_noise(seed + 91, x, y, scale / 4.0)      * 0.13
       + game.value_noise(seed + 33, x, y, greatest(scale / 8.0, 1)) * 0.06;
$$;

-- Distancia euclídea entre dos puntos de la retícula.
create or replace function game.grid_distance(x1 int, y1 int, x2 int, y2 int)
returns numeric language sql immutable parallel safe as $$
  select sqrt(power(x1 - x2, 2) + power(y1 - y2, 2))::numeric;
$$;

-- Mantiene `updated_at` al día sin que cada RPC tenga que acordarse.
create or replace function game.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
