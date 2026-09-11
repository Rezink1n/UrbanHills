/* ============================================================================
 * Proveedor de datos: Supabase (producción).
 *
 * Todas las lecturas son SELECT bajo RLS; todas las escrituras son RPC. Aquí no
 * hay una sola llamada a .insert() o .update() sobre tablas económicas, y no
 * debe haberla nunca: el servidor es quien decide.
 * ========================================================================== */

import { getClient, fetchAll } from '../core/supabase.js';
import { WORLD_CODE } from '../config.js';

export const kind = 'supabase';

const PLOT_COLUMNS =
  'id,district_id,x,y,elevation,slope,terrain,zoning,view_score,centrality,' +
  'land_value,base_land_value,owner_company_id,for_sale,ask_price';

// --- Sesión ------------------------------------------------------------------

export async function getSession() {
  const supabase = await getClient();
  const { data } = await supabase.auth.getSession();
  return data.session ?? null;
}

export async function onAuthChange(fn) {
  const supabase = await getClient();
  const { data } = supabase.auth.onAuthStateChange((_event, session) => fn(session));
  return () => data.subscription.unsubscribe();
}

export async function signUp({ email, password, username }) {
  const supabase = await getClient();
  const { data, error } = await supabase.auth.signUp({
    email, password,
    options: { data: { username } },
  });
  if (error) throw error;
  return data;
}

export async function signIn({ email, password }) {
  const supabase = await getClient();
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data;
}

export async function signOut() {
  const supabase = await getClient();
  await supabase.auth.signOut();
}

// --- Lecturas ----------------------------------------------------------------

export async function getWorld(code = WORLD_CODE) {
  const supabase = await getClient();
  const { data, error } = await supabase
    .from('worlds').select('*').eq('code', code).single();
  if (error) throw error;
  return data;
}

export async function getCatalog() {
  const supabase = await getClient();
  const [resources, buildingTypes, recipes, recipeInputs] = await Promise.all([
    supabase.from('resources').select('*').order('sort_order'),
    supabase.from('building_types').select('*').order('sort_order'),
    supabase.from('recipes').select('*').order('sort_order'),
    supabase.from('recipe_inputs').select('*'),
  ]);

  for (const r of [resources, buildingTypes, recipes, recipeInputs]) {
    if (r.error) throw r.error;
  }

  // Cada receta lleva dentro sus entradas: la UI no debería tener que cruzarlas.
  const inputsByRecipe = new Map();
  for (const row of recipeInputs.data) {
    if (!inputsByRecipe.has(row.recipe_id)) inputsByRecipe.set(row.recipe_id, []);
    inputsByRecipe.get(row.recipe_id).push(row);
  }

  return {
    resources: resources.data,
    buildingTypes: buildingTypes.data,
    recipes: recipes.data.map((r) => ({ ...r, inputs: inputsByRecipe.get(r.id) ?? [] })),
  };
}

export async function getPlots(worldId) {
  return fetchAll('plots', { select: PLOT_COLUMNS, filters: { world_id: worldId } });
}

export async function getDistricts(worldId) {
  const supabase = await getClient();
  const [districts, stats] = await Promise.all([
    supabase.from('districts').select('*').eq('world_id', worldId),
    supabase.from('district_stats').select('*').eq('world_id', worldId),
  ]);
  if (districts.error) throw districts.error;
  if (stats.error) throw stats.error;

  return {
    districts: districts.data,
    stats: Object.fromEntries(stats.data.map((s) => [s.district_id, s])),
  };
}

export async function getBuildings(worldId) {
  return fetchAll('buildings', {
    select: 'id,plot_id,company_id,type_code,level,status,ready_at,run_ends_at,recipe_id,occupancy',
    filters: { world_id: worldId },
  });
}

export async function getMyState(worldId) {
  const supabase = await getClient();
  const { data, error } = await supabase.rpc('rpc_my_state', { p_world_id: worldId });
  if (error) throw error;
  return data;
}

export async function getPrices(worldId) {
  const supabase = await getClient();
  const { data, error } = await supabase
    .from('market_prices').select('*').eq('world_id', worldId);
  if (error) throw error;
  return data;
}

export async function getOrderBook(worldId, resourceCode) {
  const supabase = await getClient();
  const { data, error } = await supabase
    .from('market_orders')
    .select('id,company_id,side,qty,qty_filled,unit_price,is_npc,created_at')
    .eq('world_id', worldId)
    .eq('resource_code', resourceCode)
    .in('status', ['open', 'partial'])
    .order('unit_price', { ascending: false })
    .limit(100);
  if (error) throw error;
  return data;
}

// --- Acciones (todas vía RPC) ------------------------------------------------

async function rpc(name, args) {
  const supabase = await getClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}

export const foundCompany = (name) =>
  rpc('rpc_found_company', { p_world_code: WORLD_CODE, p_name: name });

export const buyPlot = (plotId) =>
  rpc('rpc_buy_plot', { p_plot_id: plotId });

export const setPlotSale = (plotId, price) =>
  rpc('rpc_set_plot_sale', { p_plot_id: plotId, p_price: price });

export const build = (plotId, buildingCode) =>
  rpc('rpc_build', { p_plot_id: plotId, p_building_code: buildingCode });

export const produce = (buildingId, recipeId, batches = 1, auto = false) =>
  rpc('rpc_produce', {
    p_building_id: buildingId, p_recipe_id: recipeId,
    p_batches: batches, p_auto: auto,
  });

export const setWage = (buildingId, wage) =>
  rpc('rpc_set_wage', { p_building_id: buildingId, p_wage: wage });

export const demolish = (buildingId) =>
  rpc('rpc_demolish', { p_building_id: buildingId });

export const placeOrder = (worldId, resource, side, quantity, price) =>
  rpc('rpc_place_order', {
    p_world_id: worldId, p_resource: resource, p_side: side,
    p_qty: quantity, p_price: price,
  });

export const cancelOrder = (orderId) =>
  rpc('rpc_cancel_order', { p_order_id: orderId });

// --- Tiempo real -------------------------------------------------------------

/** Avisa cuando el mundo avanza un tick, para refrescar sin hacer polling. */
export async function onTick(worldId, fn) {
  const supabase = await getClient();
  const channel = supabase
    .channel(`world:${worldId}`)
    .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'tick_log', filter: `world_id=eq.${worldId}` },
        (payload) => fn(payload.new))
    .subscribe();

  return () => supabase.removeChannel(channel);
}

/** Últimos movimientos de caja de la empresa. RLS deja ver sólo los propios. */
export async function getLedger(limit = 60) {
  const supabase = await getClient();
  const { data, error } = await supabase
    .from('ledger_entries')
    .select('id,kind,amount,balance_after,memo,created_at')
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data;
}
