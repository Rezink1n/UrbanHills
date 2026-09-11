-- =============================================================================
-- UrbanHills · 0014 · Seguridad a nivel de fila
-- -----------------------------------------------------------------------------
-- Regla única y sin excepciones:
--   · El estado del mundo se LEE en público. Es un juego: el mapa, el mercado y
--     las cuentas del municipio están a la vista de todos, y eso es parte de la
--     gracia.
--   · NADIE escribe directamente. No existe una sola política de INSERT, UPDATE
--     o DELETE sobre las tablas económicas. Toda escritura pasa por las
--     funciones SECURITY DEFINER de 0012, que validan reglas y caja.
--   · Lo que es privado (almacén, libro mayor, avisos) sólo lo ve su dueño.
-- =============================================================================

-- Activar RLS en todo. Una tabla sin RLS en Supabase es una tabla pública y
-- escribible: no puede quedarse ninguna fuera.
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','companies','ledger_entries','inventories','notifications','action_log',
    'worlds','districts','plots','buildings','production_runs',
    'resources','building_types','recipes','recipe_inputs',
    'market_orders','market_trades','price_history','utility_meters',
    'district_stats','district_stats_history','population_cohorts','consumption_profile',
    'city_treasury','city_ledger','elections','election_candidates','election_votes',
    'world_events','tick_log'
  ] loop
    execute format('alter table %I enable row level security', t);
    -- Deliberadamente NO se usa FORCE ROW LEVEL SECURITY. Con FORCE, el RLS se
    -- aplicaría también al dueño de las tablas, que es justamente el rol bajo el
    -- que corren las funciones SECURITY DEFINER de 0012: como no hay ninguna
    -- política de escritura, cada RPC fallaría. Sin FORCE, el dueño queda exento
    -- (que es lo que hace que el patrón funcione) y anon/authenticated siguen
    -- sujetos a las políticas, que es lo único que importa: ningún cliente se
    -- conecta nunca como dueño.
    -- Defensa en profundidad: aunque alguien añadiera una política por error,
    -- el rol no tiene el privilegio de escritura.
    execute format('revoke insert, update, delete, truncate on table %I from anon, authenticated', t);
    execute format('grant select on table %I to anon, authenticated', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Lectura pública: el estado del mundo
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','companies','worlds','districts','plots','buildings',
    'resources','building_types','recipes','recipe_inputs',
    'market_orders','market_trades','price_history','utility_meters',
    'district_stats','district_stats_history','population_cohorts','consumption_profile',
    'city_treasury','city_ledger','elections','election_candidates',
    'world_events','tick_log'
  ] loop
    execute format('drop policy if exists %I on %I', t || '_public_read', t);
    execute format(
      'create policy %I on %I for select to anon, authenticated using (true)',
      t || '_public_read', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Lectura privada: sólo el dueño
-- -----------------------------------------------------------------------------
drop policy if exists inventories_own_read on inventories;
create policy inventories_own_read on inventories
  for select to authenticated
  using (exists (select 1 from companies c
                  where c.id = inventories.company_id and c.owner_id = auth.uid()));

drop policy if exists ledger_own_read on ledger_entries;
create policy ledger_own_read on ledger_entries
  for select to authenticated
  using (exists (select 1 from companies c
                  where c.id = ledger_entries.company_id and c.owner_id = auth.uid()));

drop policy if exists notifications_own_read on notifications;
create policy notifications_own_read on notifications
  for select to authenticated
  using (exists (select 1 from companies c
                  where c.id = notifications.company_id and c.owner_id = auth.uid()));

drop policy if exists runs_own_read on production_runs;
create policy runs_own_read on production_runs
  for select to authenticated
  using (exists (select 1 from companies c
                  where c.id = production_runs.company_id and c.owner_id = auth.uid()));

drop policy if exists votes_own_read on election_votes;
create policy votes_own_read on election_votes
  for select to authenticated
  using (voter_id = auth.uid());

-- action_log no lo lee nadie: es telemetría interna del antiabuso.

-- -----------------------------------------------------------------------------
-- Única escritura directa permitida en todo el esquema
-- -----------------------------------------------------------------------------
-- Un jugador puede editar su propia ficha. No afecta a la economía, así que no
-- merece una RPC. El `username` queda fuera: lo fija el alta y es identidad.
grant update (display_name, avatar_url, bio) on profiles to authenticated;

drop policy if exists profiles_own_update on profiles;
create policy profiles_own_update on profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- -----------------------------------------------------------------------------
-- El esquema `game` son las tripas del motor
-- -----------------------------------------------------------------------------
-- Sus funciones mueven caja e inventario sin comprobar quién llama, porque las
-- llaman las RPC de 0012 después de validar. Que no queden al alcance de nadie
-- más: sin USAGE sobre el esquema, no se pueden invocar aunque se adivine el
-- nombre.
revoke all on schema game from public, anon, authenticated;
revoke all on all functions in schema game from public, anon, authenticated;
grant usage on schema game to service_role;
