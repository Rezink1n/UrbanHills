/* ============================================================================
 * Cliente de Supabase.
 *
 * Se carga desde CDN como módulo ES: sin npm, sin bundler, sin paso de build.
 * Es lo que permite que GitHub Pages sirva esto tal cual está en el repo.
 * ========================================================================== */

import { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_JS_VERSION, isConfigured }
  from '../config.js';

let client = null;

export async function getClient() {
  if (client) return client;
  if (!isConfigured()) {
    throw new Error('Supabase no está configurado (ver src/js/config.js).');
  }

  const { createClient } = await import(
    /* @vite-ignore */
    `https://cdn.jsdelivr.net/npm/@supabase/supabase-js@${SUPABASE_JS_VERSION}/+esm`
  );

  client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    realtime: { params: { eventsPerSecond: 4 } },
  });

  return client;
}

/**
 * PostgREST corta a 1000 filas por petición. Un mundo de 64×64 son 4096
 * parcelas, así que hay que pedirlas por tramos.
 */
export async function fetchAll(table, { select = '*', filters = {}, pageSize = 1000 } = {}) {
  const supabase = await getClient();
  const rows = [];

  for (let from = 0; ; from += pageSize) {
    let q = supabase.from(table).select(select).range(from, from + pageSize - 1);
    for (const [col, val] of Object.entries(filters)) q = q.eq(col, val);

    const { data, error } = await q;
    if (error) throw error;

    rows.push(...data);
    if (data.length < pageSize) break;
  }

  return rows;
}
