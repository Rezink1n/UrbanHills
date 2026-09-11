-- =============================================================================
-- UrbanHills · 0004 · Jugadores: perfiles, empresas, libro mayor e inventario
-- =============================================================================

create table if not exists profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  username      text not null,
  display_name  text,
  avatar_url    text,
  bio           text,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  constraint username_format check (username ~ '^[A-Za-z0-9_]{3,20}$')
);

create unique index if not exists idx_profiles_username_lower
  on profiles (lower(username));

comment on table profiles is 'Datos públicos de la cuenta. 1:1 con auth.users.';

-- El perfil se crea solo en cuanto alguien se registra: el cliente nunca tiene
-- que acordarse de hacerlo, y no puede elegir el id.
create or replace function game.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, game, auth
as $$
declare
  v_username text;
begin
  v_username := coalesce(
    nullif(regexp_replace(new.raw_user_meta_data ->> 'username', '[^A-Za-z0-9_]', '', 'g'), ''),
    'player_' || substr(replace(new.id::text, '-', ''), 1, 8)
  );
  v_username := substr(v_username, 1, 20);

  -- Si el nombre está pillado, se desempata con un sufijo corto.
  if exists (select 1 from public.profiles where lower(username) = lower(v_username)) then
    v_username := substr(v_username, 1, 14) || '_' || substr(md5(new.id::text), 1, 5);
  end if;

  insert into public.profiles (id, username, display_name)
  values (new.id, v_username, coalesce(new.raw_user_meta_data ->> 'display_name', v_username))
  on conflict (id) do nothing;

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function game.handle_new_user();

-- -----------------------------------------------------------------------------

create table if not exists companies (
  id              uuid primary key default gen_random_uuid(),
  world_id        uuid not null references worlds(id) on delete cascade,
  owner_id        uuid not null references profiles(id) on delete cascade,
  name            text not null,
  slug            text not null,
  motto           text,
  logo            text,

  cash            numeric(16,2) not null default 0,
  -- 0..100. Sube construyendo ciudad, baja contaminando y especulando.
  reputation      numeric(6,2)  not null default 50
                    check (reputation between 0 and 100),
  credit_limit    numeric(16,2) not null default 0,
  hq_plot_id      uuid references plots(id) on delete set null,

  founded_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  is_active       boolean not null default true,

  -- Un jugador, una empresa por mundo.
  unique (world_id, owner_id),
  unique (world_id, slug)
);

comment on table companies is 'El avatar económico del jugador dentro de un mundo.';

drop trigger if exists trg_companies_touch on companies;
create trigger trg_companies_touch before update on companies
  for each row execute function game.touch_updated_at();

create index if not exists idx_companies_owner on companies(owner_id);

-- Ahora que existe `companies`, se cierra la referencia circular con `plots`.
do $$ begin
  alter table plots
    add constraint plots_owner_company_fk
    foreign key (owner_company_id) references companies(id) on delete set null;
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- Libro mayor: toda variación de caja deja rastro. Sin excepciones.
-- -----------------------------------------------------------------------------

create table if not exists ledger_entries (
  id              bigserial primary key,
  world_id        uuid not null references worlds(id) on delete cascade,
  company_id      uuid not null references companies(id) on delete cascade,
  tick            bigint not null default 0,
  kind            ledger_kind not null,
  amount          numeric(16,2) not null,   -- con signo: negativo = salida de caja
  balance_after   numeric(16,2) not null,
  memo            text,
  ref_table       text,
  ref_id          uuid,
  created_at      timestamptz not null default now()
);

create index if not exists idx_ledger_company
  on ledger_entries(company_id, created_at desc);
create index if not exists idx_ledger_world_tick
  on ledger_entries(world_id, tick);

comment on table ledger_entries is
  'Libro mayor inmutable. Permite auditar la economía y detectar exploits.';

-- Único punto por el que puede moverse la caja de una empresa.
create or replace function game.post_ledger(
  p_company_id uuid,
  p_kind       ledger_kind,
  p_amount     numeric,
  p_memo       text default null,
  p_ref_table  text default null,
  p_ref_id     uuid default null
) returns numeric
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_world uuid;
  v_tick  bigint;
  v_new   numeric;
begin
  update companies c
     set cash = c.cash + p_amount
   where c.id = p_company_id
  returning c.cash, c.world_id into v_new, v_world;

  if not found then
    raise exception 'COMPANY_NOT_FOUND' using errcode = 'P0002';
  end if;

  select w.current_tick into v_tick from worlds w where w.id = v_world;

  insert into ledger_entries
    (world_id, company_id, tick, kind, amount, balance_after, memo, ref_table, ref_id)
  values
    (v_world, p_company_id, coalesce(v_tick, 0), p_kind, p_amount, v_new,
     p_memo, p_ref_table, p_ref_id);

  return v_new;
end $$;

-- -----------------------------------------------------------------------------
-- Inventario por empresa
-- -----------------------------------------------------------------------------

create table if not exists inventories (
  company_id      uuid not null references companies(id) on delete cascade,
  resource_code   text not null references resources(code),
  qty             numeric(16,4) not null default 0 check (qty >= 0),
  -- Coste medio ponderado: permite calcular el margen real de cada venta.
  avg_cost        numeric(14,4) not null default 0,
  updated_at      timestamptz not null default now(),
  primary key (company_id, resource_code)
);

comment on column inventories.avg_cost is
  'Coste medio ponderado de adquisición, para el cálculo de márgenes.';

-- Añade stock recalculando el coste medio ponderado.
create or replace function game.inventory_add(
  p_company_id uuid, p_resource text, p_qty numeric, p_unit_cost numeric
) returns void
language plpgsql
security definer
set search_path = public, game
as $$
begin
  if p_qty <= 0 then return; end if;

  insert into inventories (company_id, resource_code, qty, avg_cost)
  values (p_company_id, p_resource, p_qty, greatest(p_unit_cost, 0))
  on conflict (company_id, resource_code) do update
    set avg_cost = case
          when inventories.qty + excluded.qty = 0 then 0
          else (inventories.qty * inventories.avg_cost + excluded.qty * excluded.avg_cost)
               / (inventories.qty + excluded.qty)
        end,
        qty        = inventories.qty + excluded.qty,
        updated_at = now();
end $$;

-- Retira stock. Devuelve el coste medio de lo retirado; falla si no hay bastante.
create or replace function game.inventory_take(
  p_company_id uuid, p_resource text, p_qty numeric
) returns numeric
language plpgsql
security definer
set search_path = public, game
as $$
declare v_cost numeric;
begin
  if p_qty <= 0 then return 0; end if;

  update inventories
     set qty = qty - p_qty, updated_at = now()
   where company_id = p_company_id
     and resource_code = p_resource
     and qty >= p_qty
  returning avg_cost into v_cost;

  if not found then
    raise exception 'INSUFFICIENT_STOCK:%', p_resource using errcode = 'P0001';
  end if;

  return v_cost;
end $$;

-- -----------------------------------------------------------------------------
-- Avisos al jugador
-- -----------------------------------------------------------------------------

create table if not exists notifications (
  id            bigserial primary key,
  company_id    uuid not null references companies(id) on delete cascade,
  kind          text not null,
  title         text not null,
  body          text,
  payload       jsonb not null default '{}'::jsonb,
  read_at       timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists idx_notifications_company
  on notifications(company_id, created_at desc);

-- Freno básico contra scripts: cuenta acciones por empresa y ventana temporal.
create table if not exists action_log (
  id          bigserial primary key,
  company_id  uuid not null references companies(id) on delete cascade,
  action      text not null,
  created_at  timestamptz not null default now()
);

create index if not exists idx_action_log_recent
  on action_log(company_id, action, created_at desc);
