-- =============================================================================
-- UrbanHills · 0003 · El mundo: partidas, distritos y parcelas
-- =============================================================================

create table if not exists worlds (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique,
  name                  text not null,
  seed                  integer not null,
  width                 smallint not null check (width between 8 and 256),
  height                smallint not null check (height between 8 and 256),
  district_size         smallint not null default 8 check (district_size >= 4),

  tick_seconds          integer not null default 300 check (tick_seconds >= 30),
  current_tick          bigint  not null default 0,
  last_tick_at          timestamptz,

  starting_cash         numeric(14,2) not null default 250000,
  status                text not null default 'active'
                          check (status in ('active','paused','archived')),
  settings              jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table worlds is
  'Cada fila es una partida persistente independiente (un "servidor").';

drop trigger if exists trg_worlds_touch on worlds;
create trigger trg_worlds_touch before update on worlds
  for each row execute function game.touch_updated_at();

create table if not exists districts (
  id            uuid primary key default gen_random_uuid(),
  world_id      uuid not null references worlds(id) on delete cascade,
  code          text not null,
  name          text not null,
  gx            smallint not null,          -- coordenada del distrito en la rejilla
  gy            smallint not null,
  center_x      smallint not null,          -- centro en coordenadas de parcela
  center_y      smallint not null,

  -- La ciudad no nace vacía el día que entra el primer jugador: ya había casas
  -- y ya había trabajo. Sin esta base heredada, el primer tick mide a todo el
  -- mundo contra cero vivienda y cero empleo, y la felicidad se hunde sola.
  legacy_housing integer not null default 0,
  legacy_jobs    integer not null default 0,

  created_at    timestamptz not null default now(),
  unique (world_id, code),
  unique (world_id, gx, gy)
);

comment on table districts is
  'Unidad de simulación social y circunscripción electoral. Agrupa parcelas.';

create table if not exists plots (
  id                uuid primary key default gen_random_uuid(),
  world_id          uuid not null references worlds(id) on delete cascade,
  district_id       uuid not null references districts(id) on delete cascade,
  x                 smallint not null,
  y                 smallint not null,

  -- Geografía. Generada una vez por game.generate_world() y ya inmutable.
  elevation         smallint not null check (elevation between 0 and 100),
  slope             smallint not null default 0 check (slope between 0 and 100),
  terrain           terrain_type not null,
  -- 0 = borde del mapa, 100 = centro urbano. Afecta a valor y accesibilidad.
  centrality        numeric(6,2) not null default 0,
  -- Cuánto se ve desde aquí: la razón de ser de una ciudad sobre colinas.
  view_score        numeric(6,2) not null default 0,

  zoning            zoning_type not null default 'unzoned',
  base_land_value   numeric(14,2) not null default 0,
  land_value        numeric(14,2) not null default 0,

  owner_company_id  uuid,                   -- FK añadida en 0004
  acquired_at       timestamptz,
  for_sale          boolean not null default true,
  ask_price         numeric(14,2),

  updated_at        timestamptz not null default now(),
  unique (world_id, x, y)
);

comment on table plots is
  'La unidad atómica de territorio. Es el recurso escaso central del juego.';
comment on column plots.for_sale is
  'Sin dueño + for_sale = la vende el municipio al precio land_value. '
  'Con dueño + for_sale = reventa entre jugadores a ask_price.';

create index if not exists idx_plots_world_xy    on plots(world_id, x, y);
create index if not exists idx_plots_district    on plots(district_id);
create index if not exists idx_plots_owner       on plots(owner_company_id)
  where owner_company_id is not null;
create index if not exists idx_plots_for_sale    on plots(world_id, for_sale)
  where for_sale;
