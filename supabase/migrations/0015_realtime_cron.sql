-- =============================================================================
-- UrbanHills · 0015 · Tiempo real y programación del tick
-- -----------------------------------------------------------------------------
-- Todo lo de este fichero es opcional y tolerante a fallos: en un Postgres
-- local sin las extensiones de Supabase, la migración avisa y sigue.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Realtime: las tablas que el cliente sigue en vivo
-- -----------------------------------------------------------------------------
-- Se limita a lo que de verdad cambia mientras miras la pantalla. Suscribir
-- `plots` entero (miles de filas) sería derrochar el canal: el mapa se refresca
-- al recibir el aviso de tick.
do $$
declare t text;
begin
  foreach t in array array['market_orders','market_trades','buildings','notifications','tick_log']
  loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception
      when undefined_object then
        raise notice 'Publicación supabase_realtime no encontrada; se omite %', t;
      when duplicate_object then
        null;
    end;
  end loop;
end $$;

-- Realtime respeta RLS, así que hace falta que la fila tenga identidad completa
-- para poder filtrar por ella en el cliente.
alter table market_orders replica identity full;
alter table notifications replica identity full;

-- -----------------------------------------------------------------------------
-- pg_cron: el latido del mundo
-- -----------------------------------------------------------------------------
-- Con tick_seconds = 300 basta un cron cada minuto: fn_world_tick() es
-- idempotente y sólo avanza cuando toca. Ver la comprobación de abajo.

-- Avanza sólo los mundos a los que de verdad les toca según su tick_seconds.
-- Esto desacopla la frecuencia del cron (fija, cada minuto) de la del juego
-- (configurable por mundo).
create or replace function fn_world_tick_due()
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  w      record;
  v_out  jsonb := '[]'::jsonb;
begin
  for w in
    select code from worlds
     where status = 'active'
       and (last_tick_at is null
            or last_tick_at + make_interval(secs => tick_seconds) <= now())
  loop
    v_out := v_out || fn_world_tick(w.code);
  end loop;

  return jsonb_build_object('ok', true, 'ran', v_out);
end $$;

revoke all on function fn_world_tick_due() from public, anon, authenticated;
grant execute on function fn_world_tick_due() to service_role;

do $$
begin
  create extension if not exists pg_cron;

  perform cron.unschedule('urbanhills_tick')
    where exists (select 1 from cron.job where jobname = 'urbanhills_tick');

  perform cron.schedule(
    'urbanhills_tick',
    '* * * * *',
    $cron$ select public.fn_world_tick_due(); $cron$
  );
exception when others then
  raise notice 'pg_cron no disponible (%). Programa el tick desde la Edge Function.', sqlerrm;
end $$;
