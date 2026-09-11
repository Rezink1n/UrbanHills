-- =============================================================================
-- UrbanHills · 0019 · search_path fijado en los ayudantes del motor
-- -----------------------------------------------------------------------------
-- El linter de Supabase avisa de 13 funciones de `game` sin `search_path`
-- fijado. Hoy no es explotable —ni `anon` ni `authenticated` tienen CREATE en
-- ningún esquema, así que nadie puede colocar una función que suplante a
-- `sqrt()` o `floor()`— pero es defensa en profundidad y conviene dejarlo bien:
-- si mañana alguien concede CREATE en `public` por comodidad, estas funciones
-- ya no serán la puerta.
--
-- Se fija a cadena vacía, que es lo más estricto: obliga a que toda referencia
-- vaya cualificada. Las llamadas internas ya lo estaban (`game.hash_noise`,
-- `game.value_noise`), y los operadores y funciones de `pg_catalog` siguen
-- disponibles siempre.
--
-- Contrapartida, medida en el proyecto real (64×64):
--   · generar un mundo:  9,6 s → 28,6 s
--   · un tick del mundo: 165 ms → 165 ms (sin cambio)
-- Una función con cláusula SET no se puede incrustar en la consulta que la
-- llama, y las de ruido se ejecutan decenas de miles de veces al generar el
-- relieve. Pero generar un mundo es una operación única de administración,
-- mientras que el tick —que es lo que corre cada cinco minutos para siempre—
-- no se entera, porque ahí las llamadas van dentro de UPDATE por conjuntos y
-- el coste de la función es despreciable frente al de escribir la fila.
-- =============================================================================

alter function game.clamp(numeric, numeric, numeric)        set search_path = '';
alter function game.hash_noise(int, int, int)               set search_path = '';
alter function game.value_noise(int, int, int, numeric)     set search_path = '';
alter function game.smooth_noise(int, int, int, int)        set search_path = '';
alter function game.grid_distance(int, int, int, int)       set search_path = '';
alter function game.touch_updated_at()                      set search_path = '';

alter function game.market_fee_rate()        set search_path = '';
alter function game.import_markup()          set search_path = '';
alter function game.imported_resources()     set search_path = '';
alter function game.grid_resources()         set search_path = '';
alter function game.reference_land_value()   set search_path = '';
alter function game.labor_participation()    set search_path = '';
alter function game.household_size()         set search_path = '';

-- `action_log` tiene RLS activo y ninguna política a propósito: es telemetría
-- interna del antiabuso y no la debe leer nadie a través de la API. Sólo la
-- escriben las funciones SECURITY DEFINER. El aviso `rls_enabled_no_policy`
-- del linter es, en este caso, exactamente el comportamiento buscado.
comment on table action_log is
  'Telemetría del freno antiabuso. RLS activo y sin políticas a propósito: '
  'nadie la lee por la API; sólo la escribe game.rate_limit().';
