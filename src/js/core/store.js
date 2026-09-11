/* ============================================================================
 * Store reactivo mínimo.
 *
 * No hace falta más: el estado del juego es un objeto plano y las vistas se
 * repintan enteras. Un framework aquí sería peso sin contrapartida.
 * ========================================================================== */

const listeners = new Set();

export const state = {
  /** 'demo' | 'supabase' */
  mode: 'demo',
  ready: false,

  session: null,      // sesión de Supabase Auth, o null
  profile: null,
  company: null,

  world: null,        // { id, code, name, width, height, current_tick, ... }
  plots: [],          // array plano de parcelas
  districts: [],
  districtStats: {},  // district_id → estadísticas

  buildingTypes: [],
  resources: [],
  recipes: [],

  inventory: {},      // resource_code → { qty, avg_cost }
  buildings: [],      // los míos
  worldBuildings: [], // todos los del mundo, para pintar el mapa
  orders: [],
  prices: {},         // resource_code → { last, bid, ask }

  selectedPlotId: null,
  mapLayer: 'terrain', // terrain | value | zoning | pollution | happiness
};

export function setState(patch) {
  Object.assign(state, patch);
  emit();
}

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

let queued = false;
function emit() {
  // Se agrupan los cambios del mismo frame: pintar una vez por lote y no una
  // vez por propiedad.
  if (queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    for (const fn of listeners) fn(state);
  });
}

/** Búsqueda de parcela por coordenadas sin recorrer el array entero. */
let plotIndex = new Map();

export function reindexPlots() {
  plotIndex = new Map();
  for (const p of state.plots) plotIndex.set(`${p.x},${p.y}`, p);
}

export function plotAt(x, y) {
  return plotIndex.get(`${x},${y}`) || null;
}

export function plotById(id) {
  return state.plots.find((p) => p.id === id) || null;
}
