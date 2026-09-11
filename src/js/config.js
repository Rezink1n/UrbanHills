/* ============================================================================
 * UrbanHills · Configuración
 *
 * Rellena estos dos valores con los de tu proyecto de Supabase
 * (Project Settings → API). Mientras estén vacíos, el juego arranca en MODO
 * DEMO: genera un mundo en memoria, en tu navegador, sin backend.
 *
 * La `anon key` es pública por diseño: va al navegador de todo el mundo y sólo
 * sirve para hablar con PostgREST bajo las políticas de RLS. Puede vivir en el
 * repositorio sin problema.
 *
 * La `service_role key` NO. Esa nunca entra aquí ni en ningún fichero del
 * cliente: da acceso total y salta la seguridad a nivel de fila.
 * ========================================================================== */

export const SUPABASE_URL      = 'https://nviwpcehgltwfhjnphas.supabase.co';
export const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im52aXdwY2VoZ2x0d2Zoam5waGFzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxMzM3NDQsImV4cCI6MjEwNDcwOTc0NH0.usXmGGr2z3R1kqU6WVW-c0mtGrWoJaCsrX-ArqOzvOE';

/** Código del mundo (partida) al que se conecta este despliegue. */
export const WORLD_CODE = 'alpha';

/** Versión de supabase-js que se carga desde CDN. */
export const SUPABASE_JS_VERSION = '2.45.4';

export function isConfigured() {
  return Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);
}
