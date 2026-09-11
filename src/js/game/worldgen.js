/* ============================================================================
 * Generador de mundo en el navegador.
 *
 * Reproduce el mismo algoritmo que game.generate_world() en SQL: ruido de valor
 * con interpolación bilineal, valle central, y bandas de terreno por percentil.
 * Se usa sólo en MODO DEMO; la partida real la genera el servidor.
 *
 * Mantener los dos en sintonía importa: si tocas las constantes de aquí, toca
 * también supabase/migrations/0010_worldgen.sql.
 * ========================================================================== */

/** Hash entero determinista → [0,1). Equivale a game.hash_noise() en SQL. */
function hash2(seed, x, y) {
  let h = (seed ^ Math.imul(x, 374761393) ^ Math.imul(y, 668265263)) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

/** Ruido de valor: hash en los nodos de la retícula, interpolado con Hermite. */
function valueNoise(seed, x, y, scale) {
  const fx = x / scale, fy = y / scale;
  const x0 = Math.floor(fx), y0 = Math.floor(fy);
  const tx = fx - x0, ty = fy - y0;
  const sx = tx * tx * (3 - 2 * tx);
  const sy = ty * ty * (3 - 2 * ty);

  return hash2(seed, x0,     y0    ) * (1 - sx) * (1 - sy)
       + hash2(seed, x0 + 1, y0    ) *      sx  * (1 - sy)
       + hash2(seed, x0,     y0 + 1) * (1 - sx) *      sy
       + hash2(seed, x0 + 1, y0 + 1) *      sx  *      sy;
}

/** Cuatro octavas: las gruesas dan las colinas, las finas el detalle. */
function fbm(seed, x, y, scale) {
  return valueNoise(seed,      x, y, scale)               * 0.54
       + valueNoise(seed + 17, x, y, scale / 2)           * 0.27
       + valueNoise(seed + 91, x, y, scale / 4)           * 0.13
       + valueNoise(seed + 33, x, y, Math.max(scale / 8, 1)) * 0.06;
}

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

const TERRAIN_MULT = {
  water: 0.15, rock: 0.55, ridge: 0.90, forest: 1.10, hill: 1.05, lowland: 1.00,
};

export function generateWorld({
  code = 'demo',
  name = 'Mundo local',
  seed = 20260911,
  width = 48,
  height = 48,
  districtSize = 8,
  startingCash = 250000,
} = {}) {
  const cx = width / 2, cy = height / 2;
  const maxDist = Math.hypot(width / 2, height / 2);

  // --- Distritos ------------------------------------------------------------
  const districts = [];
  const cols = Math.floor(width / districtSize);
  const rows = Math.floor(height / districtSize);

  for (let gx = 0; gx < cols; gx++) {
    for (let gy = 0; gy < rows; gy++) {
      const label = String.fromCharCode(65 + gx) + (gy + 1);
      districts.push({
        id: `d-${gx}-${gy}`,
        code: label,
        name: label,
        gx, gy,
        center_x: gx * districtSize + (districtSize >> 1),
        center_y: gy * districtSize + (districtSize >> 1),
        legacy_housing: 0,
        legacy_jobs: 0,
      });
    }
  }
  const districtAt = (x, y) =>
    districts[Math.floor(x / districtSize) * rows + Math.floor(y / districtSize)];

  // --- Relieve --------------------------------------------------------------
  const cells = [];
  for (let x = 0; x < width; x++) {
    for (let y = 0; y < height; y++) {
      const relief = clamp(0.5 + (fbm(seed, x, y, 16) - 0.5) * 2.2, 0, 1);
      const centrality = clamp(Math.round((1 - Math.hypot(x - cx, y - cy) / maxDist) * 100), 0, 100);
      cells.push({
        x, y, relief, centrality,
        biome: hash2(seed + 404, x, y),
        elevation: clamp(Math.round(relief * 100 - centrality * 0.30), 0, 100),
      });
    }
  }

  // Bandas por percentil, igual que en SQL: cualquier semilla da un mapa
  // jugable, con roca para minar y vega para industria.
  const byRelief = [...cells].sort((a, b) => a.relief - b.relief);
  byRelief.forEach((c, i) => { c.reliefRank = i / (cells.length - 1); });
  const byElev = [...cells].sort((a, b) => a.elevation - b.elevation);
  byElev.forEach((c, i) => { c.elevRank = i / (cells.length - 1); });

  for (const c of cells) {
    if (c.reliefRank < 0.10) c.terrain = 'water';
    else if (c.elevRank < 0.38) c.terrain = c.biome > 0.72 ? 'forest' : 'lowland';
    else if (c.elevRank < 0.76) c.terrain = c.biome > 0.82 ? 'forest' : 'hill';
    else if (c.elevRank < 0.93) c.terrain = 'ridge';
    else c.terrain = 'rock';
  }

  // --- Parcelas -------------------------------------------------------------
  const grid = new Map(cells.map((c) => [`${c.x},${c.y}`, c]));
  const plots = [];

  for (const c of cells) {
    // Pendiente contra las 8 contiguas; vistas contra el entorno de 5×5.
    let maxDrop = 0, sum = 0, n = 0;
    for (let dx = -2; dx <= 2; dx++) {
      for (let dy = -2; dy <= 2; dy++) {
        if (!dx && !dy) continue;
        const nb = grid.get(`${c.x + dx},${c.y + dy}`);
        if (!nb) continue;
        sum += nb.elevation; n++;
        if (Math.abs(dx) <= 1 && Math.abs(dy) <= 1) {
          maxDrop = Math.max(maxDrop, Math.abs(c.elevation - nb.elevation));
        }
      }
    }

    const around = n ? sum / n : c.elevation;
    const slope = clamp(maxDrop, 0, 100);
    const viewScore = clamp(Math.round(50 + (c.elevation - around) * 3.2), 0, 100);

    const base = Math.round(
      (6000 + c.centrality * 260 + viewScore * 150)
      * TERRAIN_MULT[c.terrain]
      * (1 - Math.min(slope, 60) * 0.006)
    );

    const d = districtAt(c.x, c.y);
    plots.push({
      id: `p-${c.x}-${c.y}`,
      district_id: d.id,
      x: c.x, y: c.y,
      elevation: c.elevation,
      slope,
      terrain: c.terrain,
      view_score: viewScore,
      centrality: c.centrality,
      zoning: initialZoning(c),
      base_land_value: base,
      land_value: Math.round(base * 0.55),
      owner_company_id: null,
      for_sale: c.terrain !== 'water',
      ask_price: null,
    });
  }

  return {
    world: {
      id: 'w-demo', code, name, seed, width, height,
      district_size: districtSize,
      tick_seconds: 300,
      current_tick: 0,
      last_tick_at: null,
      starting_cash: startingCash,
      status: 'active',
    },
    districts,
    plots,
  };
}

function initialZoning(c) {
  if (c.terrain === 'water') return 'protected';
  if (c.terrain === 'rock' && c.elevation > 92) return 'protected';
  if ((c.terrain === 'rock' || c.terrain === 'ridge') && c.centrality < 45) return 'unzoned';
  if (c.centrality >= 80) return 'commercial';
  if (c.centrality >= 55) return 'mixed';
  if (c.centrality >= 28) return 'residential';
  if (c.centrality >= 10) return 'industrial';
  return 'unzoned';
}
