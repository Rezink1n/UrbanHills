/* ============================================================================
 * Capa de datos.
 *
 * Una sola interfaz, dos implementaciones. Si config.js tiene credenciales, se
 * habla con Supabase; si no, con el mundo local en memoria. Las vistas importan
 * `db` y no se enteran de cuál está detrás.
 * ========================================================================== */

import { isConfigured } from '../config.js';

/** Métodos que ambos proveedores deben implementar. */
const CONTRACT = [
  'getSession', 'onAuthChange', 'signUp', 'signIn', 'signOut',
  'getWorld', 'getCatalog', 'getPlots', 'getDistricts', 'getBuildings',
  'getMyState', 'getPrices', 'getOrderBook', 'getLedger',
  'foundCompany', 'buyPlot', 'setPlotSale', 'build', 'produce',
  'setWage', 'demolish', 'placeOrder', 'cancelOrder', 'onTick',
];

export let db = null;

export async function initData() {
  db = isConfigured()
    ? await import('./supabase.provider.js')
    : await import('./demo.provider.js');

  // Si un proveedor se queda corto, es mejor enterarse al arrancar que en
  // mitad de una partida.
  const missing = CONTRACT.filter((m) => typeof db[m] !== 'function');
  if (missing.length) {
    throw new Error(`El proveedor "${db.kind}" no implementa: ${missing.join(', ')}`);
  }

  return db;
}
