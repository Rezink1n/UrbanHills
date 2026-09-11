-- =============================================================================
-- UrbanHills · 0005 · Edificios y producción
-- =============================================================================

create table if not exists buildings (
  id                uuid primary key default gen_random_uuid(),
  world_id          uuid not null references worlds(id) on delete cascade,
  -- Una parcela, un edificio.
  plot_id           uuid not null unique references plots(id) on delete cascade,
  company_id        uuid references companies(id) on delete set null,
  type_code         text not null references building_types(code),

  level             smallint not null default 1 check (level >= 1),
  status            building_status not null default 'construction',
  -- 0..100. Se degrada con el uso; por debajo de 40 la producción cae.
  condition         numeric(6,2) not null default 100
                      check (condition between 0 and 100),

  ready_at          timestamptz,          -- fin de obra o de mejora
  built_at          timestamptz,

  -- Producción en curso
  recipe_id         text references recipes(id) on delete set null,
  run_ends_at       timestamptz,
  run_batches       integer not null default 0 check (run_batches >= 0),
  -- Se repone la orden de producción automáticamente al terminar.
  auto_repeat       boolean not null default false,

  -- Empleo: multiplicador salarial elegido por el jugador (0.6 .. 1.6)
  wage_level        numeric(5,3) not null default 1
                      check (wage_level between 0.5 and 2),
  staffed_ratio     numeric(5,4) not null default 0
                      check (staffed_ratio between 0 and 1),

  -- Residencial / comercial
  occupancy         integer not null default 0 check (occupancy >= 0),
  rent_per_tick     numeric(12,2) not null default 0 check (rent_per_tick >= 0),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table buildings is 'Instancias construidas sobre parcelas.';
comment on column buildings.staffed_ratio is
  'Fracción de puestos cubiertos por la población cercana. Escala la producción.';

drop trigger if exists trg_buildings_touch on buildings;
create trigger trg_buildings_touch before update on buildings
  for each row execute function game.touch_updated_at();

create index if not exists idx_buildings_company on buildings(company_id);
create index if not exists idx_buildings_world    on buildings(world_id, status);
create index if not exists idx_buildings_pending
  on buildings(ready_at) where status = 'construction';
create index if not exists idx_buildings_running
  on buildings(run_ends_at) where status = 'producing';

-- Histórico de lotes producidos: alimenta las gráficas de rendimiento.
create table if not exists production_runs (
  id            bigserial primary key,
  building_id   uuid not null references buildings(id) on delete cascade,
  company_id    uuid references companies(id) on delete set null,
  recipe_id     text not null,
  batches       integer not null,
  output_code   text not null,
  output_qty    numeric(14,4) not null,
  input_cost    numeric(14,2) not null default 0,
  wage_cost     numeric(14,2) not null default 0,
  tick          bigint not null,
  created_at    timestamptz not null default now()
);

create index if not exists idx_runs_company
  on production_runs(company_id, created_at desc);
