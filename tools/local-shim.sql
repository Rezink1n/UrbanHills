-- =============================================================================
-- Emulación mínima de Supabase para probar las migraciones en un Postgres pelado.
-- NO forma parte del esquema del juego: sólo existe para poder ejecutar
-- tools/test-migrations.sh sin levantar Supabase entero.
-- =============================================================================

create schema if not exists auth;

create table if not exists auth.users (
  id                    uuid primary key default gen_random_uuid(),
  email                 text unique,
  raw_user_meta_data    jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now()
);

-- auth.uid() devuelve el usuario del JWT. En local se simula con un GUC que la
-- propia prueba fija con set_config('request.jwt.claim.sub', ...).
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

do $$ begin create role anon nologin;          exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin;  exception when duplicate_object then null; end $$;

grant usage on schema public to anon, authenticated, service_role;
