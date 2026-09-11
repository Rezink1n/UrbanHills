// =============================================================================
// Edge Function: world-tick
//
// Alternativa a pg_cron para mover el mundo. Sirve para dos casos:
//   · el proyecto no tiene pg_cron disponible;
//   · quieres disparar el tick desde fuera (un cron externo, un botón de
//     administración) y quedarte con la telemetría de cada ejecución.
//
// Si usas pg_cron, esta función es redundante: fn_world_tick() es idempotente
// por número de tick, así que tenerlas las dos no duplica nada, pero tampoco
// aporta.
//
// Despliegue:
//   supabase functions deploy world-tick
//   supabase secrets set TICK_SECRET=<una cadena larga y aleatoria>
//
// Invocación:
//   curl -X POST https://<ref>.functions.supabase.co/world-tick \
//        -H "Authorization: Bearer $TICK_SECRET"
// =============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';

const TICK_SECRET = Deno.env.get('TICK_SECRET');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

/** Comparación en tiempo constante: no filtra el secreto por cuánto tarda. */
function secretMatches(provided: string, expected: string): boolean {
  if (provided.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < provided.length; i++) {
    diff |= provided.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  // Sin secreto configurado se rechaza todo: un endpoint que mueve la economía
  // del juego no puede quedarse abierto por olvido.
  if (!TICK_SECRET) {
    return Response.json(
      { error: 'TICK_SECRET no configurado en el proyecto.' },
      { status: 503 },
    );
  }

  const auth = req.headers.get('Authorization') ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!secretMatches(token, TICK_SECRET)) {
    return Response.json({ error: 'No autorizado.' }, { status: 401 });
  }

  // service_role: fn_world_tick() sólo es invocable por el servidor.
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const startedAt = performance.now();
  const body = await req.json().catch(() => ({}));

  // Sin código de mundo se avanzan todos los que les toque según su cadencia.
  const { data, error } = body.world
    ? await supabase.rpc('fn_world_tick', { p_world_code: body.world })
    : await supabase.rpc('fn_world_tick_due');

  if (error) {
    console.error('fn_world_tick:', error);
    return Response.json({ error: error.message }, { status: 500 });
  }

  const ms = Math.round(performance.now() - startedAt);
  console.log(`tick ok en ${ms} ms`, JSON.stringify(data));

  return Response.json({ ok: true, ms, result: data });
});
