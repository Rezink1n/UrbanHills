/* ============================================================================
 * Mapa: render en canvas con desplazamiento y zoom.
 *
 * Por qué canvas y no DOM: un mundo de 64×64 son 4.096 parcelas. En DOM eso son
 * 4.096 nodos que hay que crear, estilar y recomponer en cada cambio de capa;
 * en canvas es un bucle de dibujo de 4.096 rectángulos, que el navegador
 * despacha en un par de milisegundos.
 * ========================================================================== */

const TERRAIN_COLORS = {
  water:   [28,  58,  94],
  lowland: [71,  96,  58],
  forest:  [47,  81,  52],
  hill:    [122, 106, 60],
  ridge:   [138, 106, 74],
  rock:    [110, 106, 104],
};

const ZONING_COLORS = {
  unzoned:     [45,  52,  66],
  residential: [87,  167, 115],
  commercial:  [74,  144, 196],
  industrial:  [192, 138, 74],
  civic:       [155, 123, 196],
  mixed:       [138, 181, 160],
  protected:   [63,  107, 90],
};

export const LAYERS = [
  { id: 'terrain',   label: 'Relieve' },
  { id: 'value',     label: 'Valor del suelo' },
  { id: 'zoning',    label: 'Calificación' },
  { id: 'pollution', label: 'Contaminación' },
  { id: 'happiness', label: 'Felicidad' },
];

const rgb = ([r, g, b], a = 1) =>
  a === 1 ? `rgb(${r},${g},${b})` : `rgba(${r},${g},${b},${a})`;

/**
 * Sombreado de relieve, como en un mapa topográfico: se ilumina desde el
 * noroeste y se compara cada parcela con la que tiene arriba a la izquierda.
 * Sin esto el mapa es un mosaico de colores planos y no se lee dónde están las
 * colinas, que es justo de lo que va el juego.
 */
function computeShade(plots) {
  const elev = new Map(plots.map((p) => [`${p.x},${p.y}`, p.elevation]));
  for (const p of plots) {
    const nw = elev.get(`${p.x - 1},${p.y - 1}`) ?? p.elevation;
    const dz = p.elevation - nw;
    // ±12 m de desnivel saturan el sombreado; más allá no aporta legibilidad.
    p._shade = 1 + Math.max(-1, Math.min(1, dz / 12)) * 0.30;
  }
}

/** Rampa fría→cálida para las capas de calor. t en [0,1]. */
function heat(t) {
  const stops = [
    [0.0, [40, 62, 110]],
    [0.35, [58, 132, 138]],
    [0.6, [214, 180, 84]],
    [1.0, [206, 90, 78]],
  ];
  for (let i = 1; i < stops.length; i++) {
    if (t <= stops[i][0]) {
      const [t0, c0] = stops[i - 1];
      const [t1, c1] = stops[i];
      const k = (t - t0) / (t1 - t0);
      return c0.map((v, j) => Math.round(v + (c1[j] - v) * k));
    }
  }
  return stops.at(-1)[1];
}

/** Aplica el sombreado de relieve atenuado, para las capas temáticas. */
function shaded(color, plot) {
  const k = 1 + ((plot._shade ?? 1) - 1) * 0.45;
  return rgb(color.map((c) => Math.min(255, Math.round(c * k))));
}

export function createMap(stage, options = {}) {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  stage.appendChild(canvas);

  const view = {
    plots: [],
    buildings: new Map(),   // plot_id → edificio
    stats: {},              // district_id → estadísticas
    buildingIcons: {},      // type_code → emoji
    layer: 'terrain',
    companyId: null,
    selectedId: null,
    cell: 14,
    offsetX: 0,
    offsetY: 0,
    world: { width: 64, height: 64 },
    hover: null,
  };

  // Mientras el jugador no mueva el mapa, cada cambio de tamaño lo reencuadra.
  // Al montar la vista, el contenedor flexible todavía no tiene su altura
  // definitiva: sin esto el mundo se calcula contra una caja equivocada y
  // aparece cortado por abajo.
  let userAdjusted = false;
  let frame = null;
  const schedule = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => { frame = null; draw(); });
  };

  // --- Tamaño y densidad de píxel ------------------------------------------
  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const { width, height } = stage.getBoundingClientRect();
    canvas.width = Math.max(1, Math.round(width * dpr));
    canvas.height = Math.max(1, Math.round(height * dpr));
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    schedule();
  }

  const ro = new ResizeObserver(() => {
    resize();
    if (!userAdjusted) fit();
  });
  ro.observe(stage);

  /** Encaja el mundo entero en la ventana. */
  function fit() {
    const { width, height } = stage.getBoundingClientRect();
    view.cell = Math.max(
      2,
      Math.min(width / view.world.width, height / view.world.height) * 0.92,
    );
    view.offsetX = (width - view.world.width * view.cell) / 2;
    view.offsetY = (height - view.world.height * view.cell) / 2;
    schedule();
  }

  // --- Color por capa -------------------------------------------------------
  function colorFor(plot) {
    switch (view.layer) {
      case 'zoning':
        return rgb(ZONING_COLORS[plot.zoning] ?? ZONING_COLORS.unzoned);

      case 'value': {
        const max = view.maxValue || 1;
        return shaded(heat(Math.min(plot.land_value / max, 1)), plot);
      }
      case 'pollution': {
        const st = view.stats[plot.district_id];
        return shaded(heat(Math.min((st?.pollution ?? 0) / 100, 1)), plot);
      }
      case 'happiness': {
        const st = view.stats[plot.district_id];
        // Se invierte: rojo es infeliz, azul-verde es feliz.
        return shaded(heat(1 - Math.min((st?.happiness ?? 50) / 100, 1)), plot);
      }
      default: {
        // Altitud (tono general) × sombreado (dirección de la ladera).
        const base = TERRAIN_COLORS[plot.terrain] ?? TERRAIN_COLORS.lowland;
        const k = (0.66 + (plot.elevation / 100) * 0.58) * (plot._shade ?? 1);
        return rgb(base.map((c) => Math.min(255, Math.round(c * k))));
      }
    }
  }

  // --- Dibujo ---------------------------------------------------------------
  function draw() {
    const { width, height } = stage.getBoundingClientRect();
    ctx.clearRect(0, 0, width, height);
    if (!view.plots.length) return;

    const c = view.cell;
    const gap = c > 7 ? 1 : 0;

    // Sólo se pinta lo que se ve: con zoom alto, la mayor parte del mundo cae
    // fuera de la ventana y recorrerlo entero sería tirar frames.
    const x0 = Math.max(0, Math.floor(-view.offsetX / c) - 1);
    const y0 = Math.max(0, Math.floor(-view.offsetY / c) - 1);
    const x1 = Math.min(view.world.width, Math.ceil((width - view.offsetX) / c) + 1);
    const y1 = Math.min(view.world.height, Math.ceil((height - view.offsetY) / c) + 1);

    for (const plot of view.plots) {
      if (plot.x < x0 || plot.x >= x1 || plot.y < y0 || plot.y >= y1) continue;

      const px = view.offsetX + plot.x * c;
      const py = view.offsetY + plot.y * c;

      ctx.fillStyle = colorFor(plot);
      ctx.fillRect(px, py, c - gap, c - gap);

      // Parcelas propias: marco de acento. Es la información que más se mira.
      if (view.companyId && plot.owner_company_id === view.companyId) {
        ctx.strokeStyle = '#4cc2a0';
        ctx.lineWidth = Math.max(1, c * 0.09);
        ctx.strokeRect(px + 0.5, py + 0.5, c - gap - 1, c - gap - 1);
      } else if (plot.owner_company_id) {
        ctx.strokeStyle = 'rgba(224,179,86,.55)';
        ctx.lineWidth = 1;
        ctx.strokeRect(px + 0.5, py + 0.5, c - gap - 1, c - gap - 1);
      }

      // Con celdas pequeñas el emoji es una mancha ilegible: se omite.
      const b = view.buildings.get(plot.id);
      if (b && c >= 13) {
        const icon = view.buildingIcons[b.type_code];
        if (icon) {
          ctx.font = `${Math.round(c * 0.62)}px system-ui, "Apple Color Emoji", "Segoe UI Emoji"`;
          ctx.textAlign = 'center';
          ctx.textBaseline = 'middle';
          ctx.globalAlpha = b.status === 'construction' ? 0.45 : 1;
          ctx.fillText(icon, px + c / 2, py + c / 2 + 1);
          ctx.globalAlpha = 1;
        }
      } else if (b && c >= 5) {
        ctx.fillStyle = 'rgba(255,255,255,.75)';
        ctx.fillRect(px + c * 0.35, py + c * 0.35, c * 0.3, c * 0.3);
      }
    }

    // Selección y cursor, siempre por encima.
    if (view.hover) outline(view.hover, 'rgba(255,255,255,.45)', 1.5);
    const sel = view.plots.find((p) => p.id === view.selectedId);
    if (sel) outline(sel, '#e6edf7', 2.5);
  }

  function outline(plot, color, lw) {
    const c = view.cell;
    ctx.strokeStyle = color;
    ctx.lineWidth = lw;
    ctx.strokeRect(
      view.offsetX + plot.x * c - 1,
      view.offsetY + plot.y * c - 1,
      c + 1, c + 1,
    );
  }

  // --- Interacción ----------------------------------------------------------
  // Los gestos van sobre el canvas, no sobre el contenedor: los botones de capa
  // y de zoom son hermanos suyos y quedan por encima. Si escuchara en el
  // contenedor, setPointerCapture() se tragaría sus clics y ningún control
  // respondería.
  function plotAtClient(clientX, clientY) {
    const rect = canvas.getBoundingClientRect();
    const x = Math.floor((clientX - rect.left - view.offsetX) / view.cell);
    const y = Math.floor((clientY - rect.top - view.offsetY) / view.cell);
    return view.plots.find((p) => p.x === x && p.y === y) || null;
  }

  let dragging = false;
  let moved = 0;
  let last = { x: 0, y: 0 };

  canvas.addEventListener('pointerdown', (e) => {
    dragging = true;
    moved = 0;
    last = { x: e.clientX, y: e.clientY };
    canvas.setPointerCapture(e.pointerId);
  });

  canvas.addEventListener('pointermove', (e) => {
    if (dragging) {
      userAdjusted = true;
      const dx = e.clientX - last.x;
      const dy = e.clientY - last.y;
      moved += Math.abs(dx) + Math.abs(dy);
      view.offsetX += dx;
      view.offsetY += dy;
      last = { x: e.clientX, y: e.clientY };
      schedule();
      return;
    }

    const hit = plotAtClient(e.clientX, e.clientY);
    if (hit !== view.hover) {
      view.hover = hit;
      options.onHover?.(hit);
      schedule();
    }
  });

  canvas.addEventListener('pointerup', (e) => {
    dragging = false;
    // Un arrastre no es un clic: 4 px de margen para el pulso de la mano.
    if (moved < 4) {
      const hit = plotAtClient(e.clientX, e.clientY);
      if (hit) {
        view.selectedId = hit.id;
        options.onSelect?.(hit);
        schedule();
      }
    }
  });

  canvas.addEventListener('pointerleave', () => {
    dragging = false;
    if (view.hover) { view.hover = null; options.onHover?.(null); schedule(); }
  });

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    userAdjusted = true;
    const rect = canvas.getBoundingClientRect();
    const mx = e.clientX - rect.left;
    const my = e.clientY - rect.top;

    const prev = view.cell;
    const next = Math.max(3, Math.min(48, prev * (e.deltaY < 0 ? 1.12 : 0.89)));
    if (next === prev) return;

    // El zoom se ancla al puntero: el punto bajo el cursor no se mueve.
    view.offsetX = mx - (mx - view.offsetX) * (next / prev);
    view.offsetY = my - (my - view.offsetY) * (next / prev);
    view.cell = next;
    schedule();
  }, { passive: false });

  // --- API ------------------------------------------------------------------
  return {
    setData({ plots, buildings, stats, world, buildingIcons, companyId }) {
      if (plots) {
        view.plots = plots;
        view.maxValue = plots.reduce((m, p) => Math.max(m, p.land_value), 1);
        computeShade(plots);
      }
      if (buildings) view.buildings = new Map(buildings.map((b) => [b.plot_id, b]));
      if (stats) view.stats = stats;
      if (world) view.world = world;
      if (buildingIcons) view.buildingIcons = buildingIcons;
      if (companyId !== undefined) view.companyId = companyId;
      schedule();
    },
    setLayer(layer) { view.layer = layer; schedule(); },
    getLayer() { return view.layer; },
    select(plotId) { view.selectedId = plotId; schedule(); },
    centerOn(x, y) {
      userAdjusted = true;
      const { width, height } = stage.getBoundingClientRect();
      view.offsetX = width / 2 - (x + 0.5) * view.cell;
      view.offsetY = height / 2 - (y + 0.5) * view.cell;
      schedule();
    },
    zoom(factor) {
      userAdjusted = true;
      const { width, height } = stage.getBoundingClientRect();
      const prev = view.cell;
      view.cell = Math.max(3, Math.min(48, prev * factor));
      view.offsetX = width / 2 - (width / 2 - view.offsetX) * (view.cell / prev);
      view.offsetY = height / 2 - (height / 2 - view.offsetY) * (view.cell / prev);
      schedule();
    },
    fit() { userAdjusted = false; fit(); },
    redraw: schedule,
    destroy() { ro.disconnect(); canvas.remove(); },
  };
}

export { TERRAIN_COLORS, ZONING_COLORS, rgb };
