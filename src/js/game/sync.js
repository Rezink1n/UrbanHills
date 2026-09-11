/* ============================================================================
 * Sincronización con el servidor.
 *
 * Tres funciones y ninguna más: cargar todo al arrancar, refrescar el mundo
 * (lo que cambia con cada tick) y refrescar lo mío (lo que cambia con cada
 * acción). Las vistas llaman a éstas y nunca al proveedor de datos.
 * ========================================================================== */

import { db } from '../data/index.js';
import { state, setState, reindexPlots } from '../core/store.js';

/** Carga inicial. Todo lo que no cambia (catálogo) se pide una sola vez. */
export async function bootstrap() {
  const world = await db.getWorld();
  const [catalog, plots, districts, buildings] = await Promise.all([
    db.getCatalog(),
    db.getPlots(world.id),
    db.getDistricts(world.id),
    db.getBuildings(world.id),
  ]);

  setState({
    world,
    plots,
    districts: districts.districts,
    districtStats: districts.stats,
    worldBuildings: buildings,
    resources: catalog.resources,
    buildingTypes: catalog.buildingTypes,
    recipes: catalog.recipes,
  });
  reindexPlots();

  await refreshMine();
  setState({ ready: true });
}

/** Lo que se mueve con el tick: parcelas, edificios y estado de los distritos. */
export async function refreshWorld() {
  if (!state.world) return;

  const [world, plots, districts, buildings] = await Promise.all([
    db.getWorld(),
    db.getPlots(state.world.id),
    db.getDistricts(state.world.id),
    db.getBuildings(state.world.id),
  ]);

  setState({
    world,
    plots,
    districts: districts.districts,
    districtStats: districts.stats,
    worldBuildings: buildings,
  });
  reindexPlots();
}

/** Lo que se mueve con mis acciones: caja, almacén, edificios y órdenes. */
export async function refreshMine() {
  if (!state.world) return;

  const mine = await db.getMyState(state.world.id);

  setState({
    session: mine.authenticated ? (state.session ?? true) : null,
    company: mine.company ?? null,
    inventory: Object.fromEntries(
      (mine.inventory ?? []).map((i) => [i.resource_code, i]),
    ),
    buildings: mine.buildings ?? [],
    orders: mine.orders ?? [],
  });
}

/** Precio de referencia de un recurso, con el precio ancla como respaldo. */
export function priceOf(code) {
  const p = state.prices?.[code];
  if (p?.last_price != null) return Number(p.last_price);
  return Number(state.resources.find((r) => r.code === code)?.base_price ?? 0);
}

export async function refreshPrices() {
  if (!state.world) return;
  const rows = await db.getPrices(state.world.id);
  setState({ prices: Object.fromEntries(rows.map((r) => [r.resource_code, r])) });
}
