-- =============================================================================
-- UrbanHills · 0020 · Los permisos de las vistas
-- -----------------------------------------------------------------------------
-- El bucle de 0014 recorría `pg_tables`, así que se dejó fuera la vista
-- `market_prices`, que se quedó con los permisos por defecto del esquema
-- público: SELECT, pero también INSERT, UPDATE, DELETE y TRUNCATE para anon y
-- authenticated.
--
-- No era explotable: la vista lleva cruces y agregados, no es actualizable
-- automáticamente, y un INSERT contra ella falla en el propio Postgres. Pero un
-- permiso de escritura colgando de la superficie de la API no se deja ahí
-- "porque no se puede usar": se quita.
-- =============================================================================

do $$
declare v text;
begin
  for v in
    select table_name from information_schema.views where table_schema = 'public'
  loop
    execute format('revoke insert, update, delete, truncate, references, trigger '
                   'on table %I from anon, authenticated', v);
    execute format('grant select on table %I to anon, authenticated', v);
  end loop;
end $$;

-- Mismo repaso sobre las tablas, por si alguna nació después de 0014.
do $$
declare t text;
begin
  for t in
    select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('revoke insert, update, delete, truncate on table %I '
                   'from anon, authenticated', t);
  end loop;
end $$;

-- Y se devuelve la única escritura directa legítima, que 0014 concedía y el
-- repaso de arriba acaba de quitar.
grant update (display_name, avatar_url, bio) on profiles to authenticated;
