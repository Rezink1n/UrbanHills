-- =============================================================================
-- UrbanHills · 0007 · Simulación urbana: población, distritos y municipio
-- =============================================================================

-- Estado social vigente de cada distrito. Una fila por distrito, reescrita cada
-- tick. El histórico vive en district_stats_history.
create table if not exists district_stats (
  district_id       uuid primary key references districts(id) on delete cascade,
  world_id          uuid not null references worlds(id) on delete cascade,

  population        integer not null default 0,
  households        integer not null default 0,
  housing_capacity  integer not null default 0,

  jobs              integer not null default 0,
  jobs_filled       integer not null default 0,
  employment_rate   numeric(6,4) not null default 0,

  -- Índices 0..100
  happiness         numeric(6,2) not null default 50,
  pollution         numeric(6,2) not null default 0,
  noise             numeric(6,2) not null default 0,
  crime             numeric(6,2) not null default 10,
  health_cov        numeric(6,2) not null default 0,
  education_cov     numeric(6,2) not null default 0,
  safety_cov        numeric(6,2) not null default 0,
  transport_cov     numeric(6,2) not null default 0,
  leisure_cov       numeric(6,2) not null default 0,

  -- Prestigio acumulado por los edificios del entorno: parques y buena
  -- arquitectura suman, chimeneas restan.
  prestige          numeric(10,2) not null default 0,
  -- Hasta qué punto el mercado cubre lo que la población quiere comprar (0..100).
  supply_index      numeric(6,2) not null default 100,

  avg_rent          numeric(12,2) not null default 0,
  land_value_index  numeric(10,2) not null default 100,
  -- Cuánta gente quiere entrar (o salir) ahora mismo. Positivo = atrae.
  migration_pressure numeric(8,2) not null default 0,

  updated_tick      bigint not null default 0,
  updated_at        timestamptz not null default now()
);

comment on table district_stats is
  'Fotografía social del distrito. Se recalcula entera en cada tick del mundo.';

create index if not exists idx_dstats_world on district_stats(world_id);

create table if not exists district_stats_history (
  district_id   uuid not null references districts(id) on delete cascade,
  tick          bigint not null,
  population    integer not null,
  happiness     numeric(6,2) not null,
  pollution     numeric(6,2) not null,
  employment_rate numeric(6,4) not null,
  land_value_index numeric(10,2) not null,
  recorded_at   timestamptz not null default now(),
  primary key (district_id, tick)
);

-- Cohortes sociales. La demanda de bienes y la mano de obra salen de aquí.
create table if not exists population_cohorts (
  district_id   uuid not null references districts(id) on delete cascade,
  class         social_class not null,
  count         integer not null default 0 check (count >= 0),
  employed      integer not null default 0 check (employed >= 0),
  -- Ingreso medio por hogar y tick; fija el precio de reserva al comprar.
  income        numeric(12,2) not null default 0,
  happiness     numeric(6,2) not null default 50,
  primary key (district_id, class)
);

comment on table population_cohorts is
  'Tres clases sociales por distrito: distinto ingreso, consumo y exigencia.';

-- Qué consume cada clase por hogar y tick. Es el sumidero de la economía.
create table if not exists consumption_profile (
  class           social_class not null,
  resource_code   text not null references resources(code),
  qty_per_household numeric(12,6) not null check (qty_per_household >= 0),
  -- Multiplicador sobre el precio base que esta clase está dispuesta a pagar.
  price_tolerance numeric(6,3) not null default 1.0,
  -- 0 = capricho, 1 = necesidad. Si no lo consigue, la felicidad cae.
  necessity       numeric(4,3) not null default 0.5,
  primary key (class, resource_code)
);

-- -----------------------------------------------------------------------------
-- Municipio
-- -----------------------------------------------------------------------------

create table if not exists city_treasury (
  world_id          uuid primary key references worlds(id) on delete cascade,
  balance           numeric(16,2) not null default 0,

  -- Tipos impositivos (fracción)
  tax_property      numeric(6,4) not null default 0.0050
                      check (tax_property between 0 and 0.05),
  tax_corporate     numeric(6,4) not null default 0.1500
                      check (tax_corporate between 0 and 0.60),
  tax_payroll       numeric(6,4) not null default 0.0800
                      check (tax_payroll between 0 and 0.40),

  -- Reparto del gasto (fracciones que deben sumar <= 1)
  budget_health     numeric(6,4) not null default 0.25,
  budget_education  numeric(6,4) not null default 0.25,
  budget_safety     numeric(6,4) not null default 0.20,
  budget_transport  numeric(6,4) not null default 0.20,
  budget_leisure    numeric(6,4) not null default 0.10,

  mayor_company_id  uuid references companies(id) on delete set null,
  term_ends_at      timestamptz,
  updated_at        timestamptz not null default now(),
  constraint budget_sums_to_one check (
    budget_health + budget_education + budget_safety
    + budget_transport + budget_leisure <= 1.0001
  )
);

comment on table city_treasury is
  'Hacienda municipal: recauda impuestos y paga los servicios públicos.';

create table if not exists city_ledger (
  id          bigserial primary key,
  world_id    uuid not null references worlds(id) on delete cascade,
  tick        bigint not null,
  kind        text not null,
  amount      numeric(16,2) not null,
  balance_after numeric(16,2) not null,
  memo        text,
  created_at  timestamptz not null default now()
);

create index if not exists idx_city_ledger on city_ledger(world_id, tick desc);

-- -----------------------------------------------------------------------------
-- Elecciones
-- -----------------------------------------------------------------------------

create table if not exists elections (
  id            uuid primary key default gen_random_uuid(),
  world_id      uuid not null references worlds(id) on delete cascade,
  opens_at      timestamptz not null,
  closes_at     timestamptz not null,
  status        text not null default 'open'
                  check (status in ('open','closed','cancelled')),
  winner_company_id uuid references companies(id) on delete set null,
  created_at    timestamptz not null default now()
);

create table if not exists election_candidates (
  election_id   uuid not null references elections(id) on delete cascade,
  company_id    uuid not null references companies(id) on delete cascade,
  manifesto     text,
  -- Lo que promete aplicar si gana; se valida contra city_treasury al tomar posesión.
  proposed      jsonb not null default '{}'::jsonb,
  votes         integer not null default 0,
  primary key (election_id, company_id)
);

create table if not exists election_votes (
  election_id   uuid not null references elections(id) on delete cascade,
  voter_id      uuid not null references profiles(id) on delete cascade,
  company_id    uuid not null references companies(id) on delete cascade,
  cast_at       timestamptz not null default now(),
  primary key (election_id, voter_id)
);

-- -----------------------------------------------------------------------------
-- Eventos del mundo y registro de ticks
-- -----------------------------------------------------------------------------

create table if not exists world_events (
  id            uuid primary key default gen_random_uuid(),
  world_id      uuid not null references worlds(id) on delete cascade,
  code          text not null,
  title         text not null,
  description   text,
  starts_tick   bigint not null,
  ends_tick     bigint not null,
  magnitude     numeric(6,3) not null default 1,
  payload       jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists idx_events_active
  on world_events(world_id, ends_tick desc);

create table if not exists tick_log (
  world_id      uuid not null references worlds(id) on delete cascade,
  tick          bigint not null,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  duration_ms   integer,
  stats         jsonb not null default '{}'::jsonb,
  primary key (world_id, tick)
);

comment on table tick_log is
  'Un tick, una fila. Es lo que hace idempotente a fn_world_tick().';
