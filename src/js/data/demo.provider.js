/* ============================================================================
 * Proveedor de datos: MODO DEMO.
 *
 * Genera un mundo en memoria y lo simula en el propio navegador, para poder
 * abrir el juego y jugar sin haber tocado Supabase. Expone exactamente la misma
 * interfaz que supabase.provider.js, así que las vistas no saben cuál de los
 * dos tienen detrás.
 *
 * Qué NO es: la simulación real. Aquí el tick va a 20 s (no a 5 min), no hay
 * libro de órdenes entre jugadores (compra y vende la "red" a precio de
 * referencia) y el modelo social está recortado. El mundo de verdad vive en
 * supabase/migrations/0013_tick.sql. Esto es un banco de pruebas jugable.
 * ========================================================================== */

import { generateWorld } from '../game/worldgen.js';

export const kind = 'demo';

/** La interfaz lo anuncia en la cinta de aviso. */
export function demoSpeed() { return DEMO_SPEED; }

const STORE_KEY = 'urbanhills.demo.v2';
const TICK_MS = 20_000;
/** Aceleración del reloj en demo: una obra de 20 min tarda 1 min de verdad. */
const DEMO_SPEED = 20;

let db = null;
let catalog = null;
let tickTimer = null;
const tickListeners = new Set();

// --- Persistencia ------------------------------------------------------------

function save() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(db));
  } catch {
    // Cuota llena o almacenamiento bloqueado: la partida sigue en memoria.
  }
}

function load() {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

export function resetDemo() {
  try { localStorage.removeItem(STORE_KEY); } catch { /* ignorado */ }
  db = null;
}

// --- Arranque ----------------------------------------------------------------

async function ensureCatalog() {
  if (catalog) return catalog;

  const res = await fetch(new URL('../../data/catalog.json', import.meta.url));
  if (!res.ok) throw new Error('No se pudo cargar el catálogo del juego.');

  const raw = await res.json();
  catalog = {
    resources: raw.resources,
    buildingTypes: raw.buildingTypes,
    recipes: raw.recipes,
    byResource: Object.fromEntries(raw.resources.map((r) => [r.code, r])),
    byBuilding: Object.fromEntries(raw.buildingTypes.map((b) => [b.code, b])),
    byRecipe: Object.fromEntries(raw.recipes.map((r) => [r.id, r])),
  };
  return catalog;
}

async function ensureWorld() {
  if (db) return db;
  await ensureCatalog();

  db = load();
  if (!db?.world) {
    const seed = Math.floor(Math.random() * 1e9);
    const generated = generateWorld({ seed, width: 48, height: 48 });

    db = {
      ...generated,
      company: null,
      buildings: [],
      inventory: {},
      orders: [],
      ledger: [],
      stats: {},
      prices: {},
      treasury: 2_000_000,
    };

    // Población de partida y base heredada, igual que game.bootstrap_world().
    for (const d of db.districts) {
      const centrality = avgCentrality(d);
      const pop = Math.round(204 * (0.35 + centrality / 140));
      d.legacy_housing = Math.round(pop * 1.12);
      d.legacy_jobs = Math.round(pop * 0.55 * 0.92);
      db.stats[d.id] = {
        district_id: d.id, population: pop,
        households: Math.max(1, Math.round(pop / 2.5)),
        housing_capacity: d.legacy_housing,
        jobs: d.legacy_jobs, jobs_filled: d.legacy_jobs,
        employment_rate: 0.92, happiness: 50, pollution: 0, noise: 0,
        crime: 10, prestige: 0, supply_index: 55,
        health_cov: 0, education_cov: 0, safety_cov: 0,
        transport_cov: 0, leisure_cov: 0,
        land_value_index: 55, avg_rent: 0, migration_pressure: 0,
      };
    }

    for (const r of catalog.resources) db.prices[r.code] = r.base_price;
    save();
  }

  startTicking();
  return db;
}

function avgCentrality(district) {
  const own = db.plots.filter((p) => p.district_id === district.id);
  return own.reduce((a, p) => a + p.centrality, 0) / Math.max(own.length, 1);
}

// --- Sesión simulada ---------------------------------------------------------

export async function getSession() {
  await ensureWorld();
  return db.company
    ? { user: { id: 'demo-user', email: 'demo@urbanhills.local' } }
    : null;
}

export async function onAuthChange() { return () => {}; }
export async function signUp() { throw new Error('En modo demo no hace falta cuenta.'); }
export async function signIn() { throw new Error('En modo demo no hace falta cuenta.'); }
export async function signOut() { resetDemo(); }

// --- Lecturas ----------------------------------------------------------------

export async function getWorld() { return (await ensureWorld()).world; }

export async function getCatalog() {
  await ensureCatalog();
  return {
    resources: catalog.resources,
    buildingTypes: catalog.buildingTypes,
    recipes: catalog.recipes,
  };
}

export async function getPlots() { return (await ensureWorld()).plots; }

export async function getDistricts() {
  const d = await ensureWorld();
  return { districts: d.districts, stats: d.stats };
}

export async function getBuildings() { return (await ensureWorld()).buildings; }

export async function getMyState() {
  const d = await ensureWorld();
  if (!d.company) return { authenticated: true, company: null };

  return {
    authenticated: true,
    company: d.company,
    inventory: Object.entries(d.inventory)
      .filter(([, v]) => v.qty > 0)
      .map(([resource_code, v]) => ({ resource_code, ...v })),
    plots: d.plots.filter((p) => p.owner_company_id === d.company.id),
    buildings: d.buildings,
    orders: d.orders.filter((o) => o.status === 'open' || o.status === 'partial'),
    unread: 0,
  };
}

export async function getPrices() {
  const d = await ensureWorld();
  return catalog.resources.map((r) => ({
    resource_code: r.code, name: r.name, category: r.category, tier: r.tier,
    base_price: r.base_price,
    last_price: d.prices[r.code] ?? r.base_price,
    volume_24h: 0,
    best_bid: r.is_storable ? round2((d.prices[r.code] ?? r.base_price) * 0.95) : null,
    best_ask: r.is_storable ? round2((d.prices[r.code] ?? r.base_price) * 1.05) : null,
  }));
}

export async function getOrderBook(_worldId, resourceCode) {
  const d = await ensureWorld();
  return d.orders.filter(
    (o) => o.resource_code === resourceCode && ['open', 'partial'].includes(o.status),
  );
}

// --- Acciones ----------------------------------------------------------------

function fail(code) { throw new Error(code); }

function post(kindOfEntry, amount, memo) {
  db.company.cash = round2(db.company.cash + amount);
  db.ledger.unshift({
    id: db.ledger.length + 1, kind: kindOfEntry, amount: round2(amount),
    balance_after: db.company.cash, memo, created_at: new Date().toISOString(),
  });
  if (db.ledger.length > 300) db.ledger.length = 300;
}

export async function foundCompany(name) {
  const d = await ensureWorld();
  if (d.company) fail('NAME_TAKEN_OR_ALREADY_PLAYING');
  if (!name || name.trim().length < 3) fail('INVALID_NAME');

  d.company = {
    id: 'c-demo', name: name.trim(),
    slug: name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-'),
    cash: d.world.starting_cash, reputation: 50,
    founded_at: new Date().toISOString(),
  };
  d.ledger.unshift({
    id: 1, kind: 'founding', amount: d.world.starting_cash,
    balance_after: d.world.starting_cash, memo: 'Capital fundacional',
    created_at: new Date().toISOString(),
  });
  save();
  return { company_id: d.company.id, cash: d.company.cash };
}

export async function buyPlot(plotId) {
  const d = await ensureWorld();
  if (!d.company) fail('NO_COMPANY_IN_WORLD');

  const plot = d.plots.find((p) => p.id === plotId);
  if (!plot) fail('PLOT_NOT_FOUND');
  if (plot.owner_company_id === d.company.id) fail('ALREADY_OWNED');
  if (!plot.for_sale || plot.zoning === 'protected') fail('PLOT_NOT_FOR_SALE');

  const price = plot.owner_company_id ? (plot.ask_price ?? plot.land_value) : plot.land_value;
  if (d.company.cash < price) fail('INSUFFICIENT_FUNDS');

  post('land_purchase', -price, `Parcela ${plot.x},${plot.y}`);
  d.treasury += price;
  plot.owner_company_id = d.company.id;
  plot.for_sale = false;
  plot.ask_price = null;
  plot.acquired_at = new Date().toISOString();

  save();
  return { plot_id: plot.id, paid: price };
}

export async function setPlotSale(plotId, price) {
  const d = await ensureWorld();
  const plot = d.plots.find((p) => p.id === plotId);
  if (!plot) fail('PLOT_NOT_FOUND');
  if (plot.owner_company_id !== d.company?.id) fail('PLOT_NOT_OWNED');

  plot.for_sale = price != null;
  plot.ask_price = price != null ? round2(price) : null;
  save();
  return { for_sale: plot.for_sale, ask_price: plot.ask_price };
}

export async function build(plotId, buildingCode) {
  const d = await ensureWorld();
  const plot = d.plots.find((p) => p.id === plotId);
  if (!plot) fail('PLOT_NOT_FOUND');
  if (plot.owner_company_id !== d.company?.id) fail('PLOT_NOT_OWNED');
  if (d.buildings.some((b) => b.plot_id === plotId)) fail('PLOT_OCCUPIED');

  const bt = catalog.byBuilding[buildingCode];
  if (!bt) fail('UNKNOWN_BUILDING');
  if (bt.municipal_only) fail('MUNICIPAL_ONLY');
  if (!bt.allowed_terrain.includes(plot.terrain)) fail('TERRAIN_NOT_ALLOWED');
  if (!bt.allowed_zoning.includes(plot.zoning)) fail('ZONING_NOT_ALLOWED');
  if (plot.slope > bt.max_slope) fail('SLOPE_TOO_STEEP');
  if (d.company.reputation < bt.min_reputation) fail('REPUTATION_TOO_LOW');

  const cost = round2(bt.build_cost * (1 + plot.slope * 0.0075));
  if (d.company.cash < cost) fail('INSUFFICIENT_FUNDS');

  for (const [code, need] of Object.entries(bt.build_materials || {})) {
    if ((d.inventory[code]?.qty ?? 0) < need) fail(`INSUFFICIENT_STOCK:${code}`);
  }
  for (const [code, need] of Object.entries(bt.build_materials || {})) {
    d.inventory[code].qty = round4(d.inventory[code].qty - need);
  }

  post('construction', -cost, `Obra: ${bt.name}`);

  const building = {
    id: `b-${Date.now().toString(36)}`,
    plot_id: plot.id, company_id: d.company.id, type_code: bt.code,
    level: 1, status: 'construction', condition: 100,
    ready_at: new Date(Date.now() + bt.build_minutes * 60_000 / DEMO_SPEED).toISOString(),
    recipe_id: null, run_ends_at: null, run_batches: 0, auto_repeat: false,
    wage_level: 1, staffed_ratio: 1, occupancy: 0,
    rent_per_tick: bt.base_rent,
  };
  d.buildings.push(building);
  plot.for_sale = false;

  save();
  return { building_id: building.id, cost, ready_at: building.ready_at };
}

export async function produce(buildingId, recipeId, batches = 1) {
  const d = await ensureWorld();
  const b = d.buildings.find((x) => x.id === buildingId);
  if (!b) fail('BUILDING_NOT_OWNED');
  if (b.status === 'construction') fail('STILL_UNDER_CONSTRUCTION');
  if (b.status === 'producing') fail('ALREADY_PRODUCING');

  const recipe = catalog.byRecipe[recipeId];
  if (!recipe || recipe.building_code !== b.type_code) fail('RECIPE_NOT_AVAILABLE');
  if (batches < 1 || batches > 100) fail('INVALID_BATCHES');

  for (const inp of recipe.inputs) {
    if ((d.inventory[inp.resource_code]?.qty ?? 0) < inp.qty * batches) {
      fail(`INSUFFICIENT_STOCK:${inp.resource_code}`);
    }
  }
  for (const inp of recipe.inputs) {
    d.inventory[inp.resource_code].qty =
      round4(d.inventory[inp.resource_code].qty - inp.qty * batches);
  }

  b.status = 'producing';
  b.recipe_id = recipeId;
  b.run_batches = batches;
  // El reloj va acelerado para que se vea pasar algo en una sesión corta.
  b.run_ends_at = new Date(
    Date.now() + recipe.minutes * batches * 60_000 / DEMO_SPEED).toISOString();

  save();
  return { building_id: b.id, ends_at: b.run_ends_at };
}

export async function setWage(buildingId, wage) {
  const d = await ensureWorld();
  const b = d.buildings.find((x) => x.id === buildingId);
  if (!b) fail('BUILDING_NOT_OWNED');
  if (wage < 0.5 || wage > 2) fail('INVALID_WAGE');
  b.wage_level = wage;
  save();
  return { wage_level: wage };
}

export async function demolish(buildingId) {
  const d = await ensureWorld();
  const i = d.buildings.findIndex((x) => x.id === buildingId);
  if (i < 0) fail('BUILDING_NOT_OWNED');

  const bt = catalog.byBuilding[d.buildings[i].type_code];
  const cost = round2(bt.build_cost * 0.08);
  post('construction', -cost, `Derribo: ${bt.name}`);
  d.buildings.splice(i, 1);

  save();
  return { demolished: true, cost };
}

/**
 * En demo no hay contraparte humana: la orden se ejecuta contra la red al
 * precio de referencia si cruza, y si no se queda en el libro esperando a que
 * el precio se mueva.
 */
export async function placeOrder(_worldId, resource, side, quantity, price) {
  const d = await ensureWorld();
  if (!d.company) fail('NO_COMPANY_IN_WORLD');

  const res = catalog.byResource[resource];
  if (!res) fail('UNKNOWN_RESOURCE');
  if (!res.is_storable) fail('NOT_TRADABLE');
  if (quantity <= 0 || price <= 0) fail('INVALID_ORDER');

  if (side === 'sell') {
    if ((d.inventory[resource]?.qty ?? 0) < quantity) fail(`INSUFFICIENT_STOCK:${resource}`);
    d.inventory[resource].qty = round4(d.inventory[resource].qty - quantity);
  } else {
    const hold = round2(quantity * price);
    if (d.company.cash < hold) fail('INSUFFICIENT_FUNDS');
    post('market_buy', -hold, `Retención por compra de ${resource}`);
  }

  const order = {
    id: `o-${Date.now().toString(36)}`,
    company_id: d.company.id, resource_code: resource, side,
    qty: quantity, qty_filled: 0, unit_price: round2(price),
    escrow: side === 'buy' ? round2(quantity * price) : 0,
    status: 'open', is_npc: false, created_at: new Date().toISOString(),
  };
  d.orders.unshift(order);

  settleOrder(order);
  save();
  return { order_id: order.id };
}

export async function cancelOrder(orderId) {
  const d = await ensureWorld();
  const o = d.orders.find((x) => x.id === orderId);
  if (!o || !['open', 'partial'].includes(o.status)) fail('ORDER_NOT_FOUND');

  const left = o.qty - o.qty_filled;
  if (o.side === 'buy') post('market_buy', o.escrow, 'Liberación de retención');
  else addInventory(o.resource_code, left, o.unit_price);

  o.status = 'cancelled';
  o.escrow = 0;
  save();
  return { cancelled: true };
}

export async function onTick(_worldId, fn) {
  tickListeners.add(fn);
  return () => tickListeners.delete(fn);
}

// --- Simulación local --------------------------------------------------------

function startTicking() {
  if (tickTimer) return;
  tickTimer = setInterval(() => {
    try { runTick(); } catch (err) { console.error('[demo tick]', err); }
  }, TICK_MS);
}

function runTick() {
  if (!db) return;
  const now = Date.now();
  db.world.current_tick += 1;
  db.world.last_tick_at = new Date().toISOString();

  // 1 · Obras terminadas
  for (const b of db.buildings) {
    if (b.status === 'construction' && new Date(b.ready_at) <= now) {
      b.status = 'idle';
      b.ready_at = null;
      b.built_at = new Date().toISOString();
    }
  }

  // 2 · Producción cerrada
  for (const b of db.buildings) {
    if (b.status !== 'producing' || new Date(b.run_ends_at) > now) continue;

    const recipe = catalog.byRecipe[b.recipe_id];
    const out = recipe.output_qty * b.run_batches * b.staffed_ratio;
    const res = catalog.byResource[recipe.output_code];

    if (res.is_storable) {
      addInventory(recipe.output_code, out, db.prices[recipe.output_code] * 0.6);
    } else {
      post('market_sale', round2(out * db.prices[recipe.output_code]),
           `Vertido a red: ${res.name}`);
    }

    b.status = 'idle';
    b.run_ends_at = null;
    b.run_batches = 0;
    b.condition = Math.max(0, b.condition - 0.25);
  }

  if (db.company) {
    // 3 · Nóminas, mantenimiento y alquileres
    let wages = 0, upkeep = 0, rent = 0;
    for (const b of db.buildings) {
      if (b.status === 'construction') continue;
      const bt = catalog.byBuilding[b.type_code];
      wages += bt.jobs * bt.base_wage * b.wage_level * b.staffed_ratio;
      upkeep += bt.upkeep_per_tick
              + bt.power_use * db.prices.power
              + bt.water_use * db.prices.water;
      rent += b.occupancy * b.rent_per_tick;
    }
    if (wages) post('wages', -round2(wages), 'Nóminas');
    if (upkeep) post('upkeep', -round2(upkeep), 'Mantenimiento y suministros');
    if (rent) post('rent', round2(rent), 'Alquileres');

    // 4 · Órdenes vivas contra el precio de referencia
    for (const o of db.orders) {
      if (['open', 'partial'].includes(o.status)) settleOrder(o);
    }
  }

  driftPrices();
  updateDistricts();
  save();

  for (const fn of tickListeners) fn({ tick: db.world.current_tick });
}

/**
 * Materiales que en la partida real importa el puerto, con su sobreprecio.
 * Ver game.imported_resources() en supabase/migrations/0017_imports.sql.
 */
const IMPORTED = ['cement', 'brick', 'glass', 'steel', 'lumber', 'concrete'];
const IMPORT_MARKUP = 1.35;

/**
 * En demo no hay contraparte humana, así que la orden se ejecuta contra un
 * mercado abstracto. Comprar siempre encuentra vendedor: hace de puerto, igual
 * que en la partida real, y por eso los materiales de obra se cobran con el
 * mismo sobreprecio de importación. Sin ese vendedor de último recurso, aquí
 * también habría bloqueo: el acero, el hormigón y el ladrillo se necesitan
 * entre sí en círculo.
 */
function settleOrder(order) {
  const ref = db.prices[order.resource_code];
  const anchor = catalog.byResource[order.resource_code].base_price;
  const importPrice = IMPORTED.includes(order.resource_code)
    ? anchor * IMPORT_MARKUP
    : ref;

  const ask = order.side === 'buy' ? Math.min(ref, importPrice) : ref;
  const crosses = order.side === 'buy'
    ? order.unit_price >= importPrice * 0.98
    : order.unit_price <= ref * 1.02;
  if (!crosses) return;

  const left = order.qty - order.qty_filled;
  const price = order.side === 'buy' ? Math.min(order.unit_price, ask) : Math.max(order.unit_price, ref);
  const gross = round2(left * price);
  const fee = round2(gross * 0.01);

  if (order.side === 'buy') {
    addInventory(order.resource_code, left, price);
    const refund = round2(order.escrow - gross);
    if (refund > 0) post('market_buy', refund, 'Devolución por mejor precio');
    order.escrow = 0;
  } else {
    post('market_sale', gross - fee, `${round4(left)} × ${order.resource_code}`);
  }

  db.treasury += fee;
  order.qty_filled = order.qty;
  order.status = 'filled';
}

/** Deriva suave del precio de referencia, acotada al ±35 % del precio ancla. */
function driftPrices() {
  for (const r of catalog.resources) {
    const anchor = r.base_price;
    const cur = db.prices[r.code] ?? anchor;
    const drift = (Math.random() - 0.5) * 0.03;
    const pull = (anchor - cur) / anchor * 0.05;   // siempre tira hacia el ancla
    db.prices[r.code] = round4(
      Math.min(anchor * 1.35, Math.max(anchor * 0.65, cur * (1 + drift + pull))),
    );
  }
}

function updateDistricts() {
  for (const d of db.districts) {
    const st = db.stats[d.id];
    const inside = db.buildings.filter((b) => {
      const p = db.plots.find((pp) => pp.id === b.plot_id);
      return p && p.district_id === d.id && b.status !== 'construction';
    });

    let pollution = 0, prestige = 0, jobs = d.legacy_jobs, housing = d.legacy_housing;
    for (const b of inside) {
      const bt = catalog.byBuilding[b.type_code];
      pollution += bt.pollution * b.level;
      prestige += bt.prestige * b.level;
      jobs += bt.jobs * b.level;
      housing += bt.housing_capacity * b.level;
    }

    st.pollution = clamp(pollution, 0, 100);
    st.prestige = clamp(prestige, -100, 100);
    st.jobs = jobs;
    st.housing_capacity = housing;
    st.jobs_filled = Math.min(jobs, Math.round(st.population * 0.55));
    st.employment_rate = st.jobs_filled / Math.max(st.population * 0.55, 1);

    const overcrowding = clamp((st.population - housing) * 100 / Math.max(housing, 1), 0, 100);
    st.crime = clamp(8 + st.population / 150 + st.pollution * 0.1, 0, 100);
    st.happiness = clamp(
      46 - st.pollution * 0.30 - overcrowding * 0.30
      + (st.employment_rate * 100 - 50) * 0.22
      + (st.supply_index - 70) * 0.20 - st.crime * 0.25,
      0, 100,
    );

    // Migración: la gente entra si el barrio tira y hay dónde meterla.
    const pressure = (st.happiness - 52) / 50;
    st.population = Math.max(0, Math.round(
      st.population * (1 + pressure * 0.035) + (st.population < housing ? 1.5 : -2),
    ));
    st.households = Math.max(1, Math.round(st.population / 2.5));
    st.migration_pressure = round2((st.happiness - 52) * 2 + (housing - st.population) * 0.05);

    // Valor del suelo: consecuencia de todo lo anterior, igual que en el tick real.
    const mult = clamp(
      0.55 + clamp(st.prestige, 0, 100) / 100 * 0.55
           - st.pollution / 100 * 0.45 - st.crime / 100 * 0.20,
      0.25, 4,
    );
    st.land_value_index = round2(mult * 100);

    for (const p of db.plots) {
      if (p.district_id === d.id) p.land_value = round2(p.base_land_value * mult);
    }

    // Ocupación de la vivienda del jugador, que es de donde sale su renta.
    const fill = clamp(st.population / Math.max(housing, 1), 0, 1);
    for (const b of inside) {
      const bt = catalog.byBuilding[b.type_code];
      if (bt.housing_capacity > 0) {
        b.occupancy = Math.floor(bt.housing_capacity * b.level * fill);
        const p = db.plots.find((pp) => pp.id === b.plot_id);
        b.rent_per_tick = round2(bt.base_rent * clamp(p.land_value / 25000, 0.5, 3));
      }
    }
  }
}

// --- Utilidades --------------------------------------------------------------

function addInventory(code, quantity, unitCost) {
  const slot = db.inventory[code] ?? (db.inventory[code] = { qty: 0, avg_cost: 0 });
  const total = slot.qty + quantity;
  slot.avg_cost = total > 0
    ? round4((slot.qty * slot.avg_cost + quantity * unitCost) / total)
    : 0;
  slot.qty = round4(total);
}

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const round2 = (v) => Math.round(v * 100) / 100;
const round4 = (v) => Math.round(v * 10000) / 10000;

/** El libro mayor del jugador, para la vista de empresa. */
export async function getLedger() {
  const d = await ensureWorld();
  return d.ledger;
}
