#!/usr/bin/env node
/* ============================================================================
 * Exporta el catálogo del juego (recursos, edificios y recetas) desde Postgres
 * a src/data/catalog.json.
 *
 * El catálogo vive en las migraciones SQL: ésa es la fuente de verdad. Este
 * fichero JSON es un derivado que se compromete al repositorio para que el
 * MODO DEMO funcione en GitHub Pages sin ningún backend detrás. Reexpórtalo
 * cada vez que toques 0008 o 0009.
 *
 *   node tools/export-catalog.mjs                    # base local de pruebas
 *   PGDATABASE=urbanhills node tools/export-catalog.mjs
 * ========================================================================== */

import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = resolve(root, 'src/data/catalog.json');

const args = process.env.PGURL
  ? ['-d', process.env.PGURL]
  : ['-d', process.env.PGDATABASE || 'urbanhills_test'];

function query(sql) {
  const raw = execFileSync('psql', [...args, '-tAc', sql], { encoding: 'utf8' });
  return JSON.parse(raw.trim() || 'null') ?? [];
}

const resources = query(`
  select coalesce(json_agg(r order by r.tier, r.sort_order), '[]')
  from (select code, name, category, tier, unit, base_price, is_storable, volume,
               icon, sort_order
          from resources) r`);

const buildingTypes = query(`
  select coalesce(json_agg(b order by b.category, b.sort_order), '[]')
  from (select code, name, category, tier, description, build_cost, build_minutes,
               build_materials, upkeep_per_tick, jobs, job_class, base_wage,
               power_use, water_use, pollution, noise, prestige, effect_radius,
               service, service_strength, housing_capacity, housing_class,
               retail_capacity, base_rent, storage_capacity,
               allowed_terrain, allowed_zoning, max_slope, municipal_only,
               min_reputation, icon, sort_order
          from building_types) b`);

const recipes = query(`
  select coalesce(json_agg(x order by x.building_code, x.sort_order), '[]')
  from (
    select r.id, r.building_code, r.name, r.output_code, r.output_qty, r.minutes,
           r.labor_factor, r.power_use, r.water_use, r.min_level, r.sort_order,
           coalesce((
             select json_agg(json_build_object('resource_code', ri.resource_code,
                                               'qty', ri.qty))
               from recipe_inputs ri where ri.recipe_id = r.id
           ), '[]'::json) as inputs
      from recipes r
  ) x`);

if (!resources.length || !buildingTypes.length || !recipes.length) {
  console.error('El catálogo ha salido vacío. ¿Aplicaste las migraciones 0008 y 0009?');
  process.exit(1);
}

mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify({
  generatedAt: new Date().toISOString().slice(0, 10),
  note: 'Generado por tools/export-catalog.mjs desde supabase/migrations. No editar a mano.',
  resources, buildingTypes, recipes,
}, null, 1) + '\n');

console.log(`${out}: ${resources.length} recursos, ${buildingTypes.length} edificios, ${recipes.length} recetas`);
