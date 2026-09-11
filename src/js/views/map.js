/* ============================================================================
 * Vista de mapa: el juego propiamente dicho.
 *
 * A la izquierda, el mundo. A la derecha, la parcela seleccionada y todo lo que
 * se puede hacer con ella: comprarla, construir, producir y ponerla en venta.
 * ========================================================================== */

import { state, setState, plotById } from '../core/store.js';
import { db } from '../data/index.js';
import { chrome } from '../ui/shell.js';
import { createMap, LAYERS, TERRAIN_COLORS, ZONING_COLORS, rgb } from '../game/mapview.js';
import { TERRAIN, ZONING, CATEGORY, BUILDING_STATUS, SERVICE } from '../game/labels.js';
import { esc, money, qty, toast, humanError, relTime, compact } from '../core/ui.js';
import { refreshWorld, refreshMine } from '../game/sync.js';

let map = null;

export default function mapView() {
  return {
    html: chrome(`
      <div class="mapview">
        <div class="mapstage" id="stage">
          <div class="maphud" id="hud">Pasa el cursor por el mapa</div>

          <div class="mapctl">
            <div class="mapctl__group" id="layers">
              ${LAYERS.map((l) => `
                <button class="btn btn--sm" data-layer="${l.id}"
                        aria-pressed="${l.id === state.mapLayer}">${l.label}</button>
              `).join('')}
            </div>
            <div class="mapctl__group">
              <button class="btn btn--sm" data-zoom="in"  title="Acercar">＋</button>
              <button class="btn btn--sm" data-zoom="out" title="Alejar">−</button>
              <button class="btn btn--sm" data-zoom="fit" title="Ver todo">⤢</button>
            </div>
          </div>

          <div class="maplegend" id="legend"></div>
        </div>

        <aside class="panel" id="panel">
          ${panelHtml()}
        </aside>
      </div>
    `),

    mount(root) {
      const stage = root.querySelector('#stage');
      const panel = root.querySelector('#panel');
      const hud = root.querySelector('#hud');

      map = createMap(stage, {
        onHover: (plot) => {
          hud.textContent = plot
            ? `${plot.x},${plot.y} · ${TERRAIN[plot.terrain]} · alt ${plot.elevation}`
              + ` · ${money(plot.land_value)}`
            : 'Pasa el cursor por el mapa';
        },
        onSelect: (plot) => {
          setState({ selectedPlotId: plot.id });
          panel.innerHTML = panelHtml();
        },
      });

      syncMap();
      map.fit();
      renderLegend(root.querySelector('#legend'));

      // --- Controles del mapa ---
      root.querySelector('#layers').addEventListener('click', (e) => {
        const btn = e.target.closest('[data-layer]');
        if (!btn) return;
        setState({ mapLayer: btn.dataset.layer });
        map.setLayer(btn.dataset.layer);
        for (const b of root.querySelectorAll('[data-layer]')) {
          b.setAttribute('aria-pressed', String(b === btn));
        }
        renderLegend(root.querySelector('#legend'));
      });

      root.querySelector('.mapctl').addEventListener('click', (e) => {
        const btn = e.target.closest('[data-zoom]');
        if (!btn) return;
        if (btn.dataset.zoom === 'in') map.zoom(1.3);
        else if (btn.dataset.zoom === 'out') map.zoom(0.77);
        else map.fit();
      });

      // --- Acciones del panel (delegadas: el panel se repinta entero) ---
      panel.addEventListener('click', (e) => {
        const btn = e.target.closest('[data-action]');
        if (btn) return handleAction(btn, panel);
      });

      panel.addEventListener('submit', (e) => {
        const form = e.target.closest('[data-action]');
        if (form) { e.preventDefault(); handleAction(form, panel); }
      });
    },
  };
}

/** Vuelca el estado actual al renderizador. */
export function syncMap() {
  if (!map) return;
  map.setData({
    plots: state.plots,
    buildings: state.worldBuildings ?? [],
    stats: state.districtStats,
    world: state.world,
    buildingIcons: Object.fromEntries(state.buildingTypes.map((b) => [b.code, b.icon])),
    companyId: state.company?.id ?? null,
  });
  map.setLayer(state.mapLayer);
}

/** Repinta el panel lateral sin volver a montar la vista entera. */
export function refreshPanel() {
  const panel = document.getElementById('panel');
  if (panel) panel.innerHTML = panelHtml();
}

// --- Panel -------------------------------------------------------------------

function panelHtml() {
  const plot = state.selectedPlotId ? plotById(state.selectedPlotId) : null;
  if (!plot) {
    return `
      <div class="panel__head"><h2>Parcela</h2></div>
      <div class="panel__body">
        <div class="empty">
          Elige una parcela en el mapa.<br>
          Arrastra para moverte, rueda para acercar.
        </div>
      </div>`;
  }

  const mine = state.company && plot.owner_company_id === state.company.id;
  const building = (state.worldBuildings ?? []).find((b) => b.plot_id === plot.id);
  const stats = state.districtStats[plot.district_id];
  const district = state.districts.find((d) => d.id === plot.district_id);

  return `
    <div class="panel__head">
      <div class="row row--sb">
        <h2>Parcela ${plot.x}, ${plot.y}</h2>
        <span class="tag">${esc(district?.code ?? '')}</span>
      </div>
      <p class="muted" style="margin:6px 0 0">
        ${TERRAIN[plot.terrain]} · ${ZONING[plot.zoning]}
        ${mine ? ' · <strong style="color:var(--accent)">tuya</strong>' : ''}
      </p>
    </div>

    <div class="panel__body">
      <dl class="deflist">
        <dt>Valor del suelo</dt><dd class="money">${money(plot.land_value)}</dd>
        <dt>Altitud</dt>        <dd>${plot.elevation} m</dd>
        <dt>Pendiente</dt>      <dd>${plot.slope}%</dd>
        <dt>Vistas</dt>         <dd>${plot.view_score}/100</dd>
        <dt>Centralidad</dt>    <dd>${plot.centrality}/100</dd>
      </dl>

      ${stats ? districtBlock(stats) : ''}
      ${building ? buildingBlock(building, mine) : plotActions(plot, mine)}
    </div>
  `;
}

function districtBlock(st) {
  const meter = (label, value, invert = false) => {
    const v = Math.round(Number(value) || 0);
    const hue = invert ? 100 - v : v;
    const color = hue > 60 ? 'var(--accent)' : hue > 35 ? 'var(--warn)' : 'var(--danger)';
    return `
      <div class="meter">
        <div class="meter__top"><span class="muted">${label}</span><span>${v}</span></div>
        <div class="meter__track">
          <div class="meter__fill" style="width:${v}%;background:${color}"></div>
        </div>
      </div>`;
  };

  return `
    <section class="card stack">
      <h3>El barrio</h3>
      ${meter('Felicidad', st.happiness)}
      ${meter('Contaminación', st.pollution, true)}
      ${meter('Empleo', (st.employment_rate ?? 0) * 100)}
      <dl class="deflist">
        <dt>Población</dt><dd>${compact(st.population)}</dd>
        <dt>Vivienda</dt> <dd>${compact(st.housing_capacity)} plazas</dd>
        <dt>Empleos</dt>  <dd>${compact(st.jobs)}</dd>
      </dl>
    </section>`;
}

function plotActions(plot, mine) {
  if (!state.company) {
    return `<div class="empty">Funda tu empresa para poder comprar suelo.
            <div style="margin-top:12px"><a class="btn btn--primary" href="#/empezar">Empezar</a></div></div>`;
  }

  if (!mine) {
    if (!plot.for_sale || plot.zoning === 'protected') {
      return `<div class="empty">${plot.zoning === 'protected'
        ? 'Suelo protegido: aquí no se construye.'
        : 'Esta parcela no está en venta.'}</div>`;
    }
    const price = plot.owner_company_id ? (plot.ask_price ?? plot.land_value) : plot.land_value;
    const canAfford = state.company.cash >= price;

    return `
      <section class="card stack">
        <h3>${plot.owner_company_id ? 'En reventa' : 'Suelo municipal'}</h3>
        <div class="row row--sb">
          <span class="muted">Precio</span>
          <strong class="money">${money(price)}</strong>
        </div>
        <button class="btn btn--primary btn--block" data-action="buy"
                data-plot="${plot.id}" ${canAfford ? '' : 'disabled'}>
          ${canAfford ? 'Comprar parcela' : 'No te llega la caja'}
        </button>
      </section>`;
  }

  return `
    ${buildMenu(plot)}
    <section class="card stack">
      <h3>Vender</h3>
      ${plot.for_sale
        ? `<p class="muted">En venta por <strong class="money">${money(plot.ask_price)}</strong>.</p>
           <button class="btn btn--block" data-action="unlist" data-plot="${plot.id}">
             Retirar del mercado
           </button>`
        : `<form class="stack" data-action="list" data-plot="${plot.id}">
             <div class="field">
               <label for="ask">Precio de venta</label>
               <input class="input" id="ask" name="price" type="number" min="1" step="1"
                      value="${Math.round(plot.land_value * 1.15)}" required>
             </div>
             <button class="btn btn--block" type="submit">Poner en venta</button>
           </form>`}
    </section>`;
}

function buildMenu(plot) {
  const options = state.buildingTypes.filter((bt) =>
    !bt.municipal_only
    && bt.allowed_terrain.includes(plot.terrain)
    && bt.allowed_zoning.includes(plot.zoning)
    && plot.slope <= bt.max_slope,
  );

  if (!options.length) {
    return `<div class="empty">
      En ${TERRAIN[plot.terrain].toLowerCase()} calificado como
      ${ZONING[plot.zoning].toLowerCase()} no se puede levantar nada de tu catálogo.
    </div>`;
  }

  const byCategory = new Map();
  for (const bt of options) {
    if (!byCategory.has(bt.category)) byCategory.set(bt.category, []);
    byCategory.get(bt.category).push(bt);
  }

  return `
    <section class="card stack">
      <h3>Construir</h3>
      <p class="muted" style="font-size:.82rem;margin:0">
        La pendiente de ${plot.slope}% encarece la obra un
        ${Math.round(plot.slope * 0.75)}%.
      </p>
      ${[...byCategory].map(([cat, list]) => `
        <div>
          <div class="muted" style="font-size:.74rem;text-transform:uppercase;
               letter-spacing:.05em;margin:10px 0 6px">${CATEGORY[cat]}</div>
          <div class="buildlist">
            ${list.map((bt) => {
              const cost = Math.round(bt.build_cost * (1 + plot.slope * 0.0075));
              const afford = (state.company?.cash ?? 0) >= cost;
              return `
                <button class="buildopt" data-action="build"
                        data-plot="${plot.id}" data-code="${esc(bt.code)}"
                        ${afford ? '' : 'disabled'} title="${esc(bt.description ?? '')}">
                  <span class="buildopt__icon">${bt.icon ?? '🏗️'}</span>
                  <span>
                    <span class="buildopt__name">${esc(bt.name)}</span><br>
                    <span class="buildopt__meta">
                      ${bt.jobs ? `${bt.jobs} empleos · ` : ''}${bt.build_minutes} min
                      ${bt.pollution > 0 ? ` · contamina ${bt.pollution}` : ''}
                      ${bt.prestige > 0 ? ` · prestigio +${bt.prestige}` : ''}
                    </span>
                  </span>
                  <span class="money">${compact(cost)} €</span>
                </button>`;
            }).join('')}
          </div>
        </div>
      `).join('')}
    </section>`;
}

function buildingBlock(building, mine) {
  const bt = state.buildingTypes.find((b) => b.code === building.type_code);
  if (!bt) return '';

  const recipes = state.recipes.filter((r) => r.building_code === bt.code);
  const busy = building.status === 'producing';
  const inObra = building.status === 'construction';

  return `
    <section class="card stack">
      <div class="row">
        <span style="font-size:1.6rem">${bt.icon ?? '🏗️'}</span>
        <div>
          <h3>${esc(bt.name)}</h3>
          <span class="tag">${BUILDING_STATUS[building.status]}</span>
        </div>
      </div>

      <dl class="deflist">
        <dt>Nivel</dt><dd>${building.level}</dd>
        ${bt.jobs ? `<dt>Empleo</dt><dd>${bt.jobs} · ${SERVICE[bt.service] !== '—' ? SERVICE[bt.service] : 'privado'}</dd>` : ''}
        ${bt.housing_capacity ? `<dt>Ocupación</dt><dd>${building.occupancy ?? 0} / ${bt.housing_capacity}</dd>` : ''}
        ${inObra && building.ready_at ? `<dt>Termina</dt><dd>${esc(relTime(building.ready_at) ?? '')}</dd>` : ''}
        ${busy && building.run_ends_at ? `<dt>Lote listo</dt><dd>${esc(relTime(building.run_ends_at) ?? '')}</dd>` : ''}
      </dl>

      ${!mine ? '' : inObra
        ? '<p class="muted" style="margin:0">Obra en marcha. Cuando termine podrás producir.</p>'
        : recipes.length ? productionForm(building, recipes, busy) : ''}
    </section>`;
}

function productionForm(building, recipes, busy) {
  return `
    <form class="stack" data-action="produce" data-building="${building.id}">
      <div class="field">
        <label for="recipe">Qué producir</label>
        <select class="input" id="recipe" name="recipe" ${busy ? 'disabled' : ''}>
          ${recipes.map((r) => {
            const out = state.resources.find((x) => x.code === r.output_code);
            const inputs = r.inputs?.length
              ? r.inputs.map((i) => `${qty(i.qty)} ${i.resource_code}`).join(' + ')
              : 'sin entradas';
            return `<option value="${esc(r.id)}"
              ${building.recipe_id === r.id ? 'selected' : ''}>
              ${esc(r.name)} → ${qty(r.output_qty)} ${esc(out?.unit ?? '')} (${esc(inputs)})
            </option>`;
          }).join('')}
        </select>
      </div>

      <div class="field">
        <label for="batches">Lotes</label>
        <input class="input" id="batches" name="batches" type="number"
               min="1" max="100" value="1" ${busy ? 'disabled' : ''}>
      </div>

      <button class="btn btn--primary btn--block" type="submit" ${busy ? 'disabled' : ''}>
        ${busy ? 'Produciendo…' : 'Poner a producir'}
      </button>
      <button class="btn btn--danger btn--block btn--sm" type="button"
              data-action="demolish" data-building="${building.id}">
        Derribar
      </button>
    </form>`;
}

// --- Acciones ----------------------------------------------------------------

async function handleAction(el, panel) {
  const action = el.dataset.action;
  const setBusy = (on) => { el.disabled = on; };

  try {
    setBusy(true);

    switch (action) {
      case 'buy': {
        const res = await db.buyPlot(el.dataset.plot);
        toast(`Parcela comprada por ${money(res.paid)}.`);
        break;
      }
      case 'list': {
        const price = Number(new FormData(el).get('price'));
        await db.setPlotSale(el.dataset.plot, price);
        toast('Parcela puesta en venta.');
        break;
      }
      case 'unlist': {
        await db.setPlotSale(el.dataset.plot, null);
        toast('Retirada del mercado.');
        break;
      }
      case 'build': {
        const res = await db.build(el.dataset.plot, el.dataset.code);
        toast(`Obra iniciada por ${money(res.cost)}.`);
        break;
      }
      case 'produce': {
        const form = new FormData(el);
        await db.produce(
          el.dataset.building,
          form.get('recipe'),
          Number(form.get('batches')) || 1,
        );
        toast('Producción en marcha.');
        break;
      }
      case 'demolish': {
        if (!confirm('¿Derribar el edificio? No se recupera la inversión.')) break;
        const res = await db.demolish(el.dataset.building);
        toast(`Derribado. Coste: ${money(res.cost)}.`);
        break;
      }
      default:
        return;
    }

    await refreshWorld();
    await refreshMine();
    syncMap();
    panel.innerHTML = panelHtml();
  } catch (err) {
    toast(humanError(err), 'error');
  } finally {
    setBusy(false);
  }
}

// --- Leyenda -----------------------------------------------------------------

function renderLegend(host) {
  if (!host) return;
  const layer = state.mapLayer;

  const rows = layer === 'zoning'
    ? Object.entries(ZONING).map(([k, label]) => [rgb(ZONING_COLORS[k]), label])
    : layer === 'terrain'
      ? Object.entries(TERRAIN).map(([k, label]) => [rgb(TERRAIN_COLORS[k]), label])
      : [
          ['rgb(40,62,110)',   layer === 'happiness' ? 'Mucha' : 'Poco'],
          ['rgb(58,132,138)',  ''],
          ['rgb(214,180,84)',  ''],
          ['rgb(206,90,78)',   layer === 'happiness' ? 'Poca' : 'Mucho'],
        ];

  host.innerHTML = rows.map(([color, label]) => `
    <div class="maplegend__row">
      <span class="maplegend__sw" style="background:${color}"></span>
      <span>${esc(label)}</span>
    </div>`).join('');
}
