/* Ficha de empresa: caja, almacén, edificios y movimientos. */

import { state } from '../core/store.js';
import { db } from '../data/index.js';
import { chrome } from '../ui/shell.js';
import { esc, money, qty, compact, relTime } from '../core/ui.js';
import { BUILDING_STATUS, LEDGER_KIND, CATEGORY } from '../game/labels.js';
import { priceOf } from '../game/sync.js';

export default async function company() {
  if (!state.company) {
    return chrome(`<div class="page"><div class="empty">
      Todavía no tienes empresa.
      <div style="margin-top:12px"><a class="btn btn--primary" href="#/empezar">Fundarla</a></div>
    </div></div>`);
  }

  const co = state.company;
  const inventory = Object.values(state.inventory ?? {});
  const stockValue = inventory.reduce((a, i) => a + i.qty * priceOf(i.resource_code), 0);
  const plotValue = state.plots
    .filter((p) => p.owner_company_id === co.id)
    .reduce((a, p) => a + Number(p.land_value), 0);

  let ledger = [];
  try { ledger = await db.getLedger(40); } catch { /* sin permisos o sin datos */ }

  return chrome(`
    <div class="page">
      <div class="page__head">
        <h1>${esc(co.name)}</h1>
        <p>Fundada ${esc(relTime(co.founded_at) ?? '')} · reputación ${Math.round(co.reputation)}/100</p>
      </div>

      <div class="stats" style="margin-bottom:var(--sp-5)">
        <div class="stat">
          <div class="stat__label">Caja</div>
          <div class="stat__value money">${compact(co.cash)} €</div>
        </div>
        <div class="stat">
          <div class="stat__label">Suelo</div>
          <div class="stat__value">${compact(plotValue)} €</div>
        </div>
        <div class="stat">
          <div class="stat__label">Almacén</div>
          <div class="stat__value">${compact(stockValue)} €</div>
        </div>
        <div class="stat">
          <div class="stat__label">Patrimonio</div>
          <div class="stat__value money">${compact(Number(co.cash) + plotValue + stockValue)} €</div>
        </div>
      </div>

      <section class="card" style="margin-bottom:var(--sp-4)">
        <h2 style="margin-bottom:var(--sp-3)">Edificios</h2>
        ${buildingsTable()}
      </section>

      <section class="card" style="margin-bottom:var(--sp-4)">
        <h2 style="margin-bottom:var(--sp-3)">Almacén</h2>
        ${inventoryTable(inventory)}
      </section>

      <section class="card">
        <h2 style="margin-bottom:var(--sp-3)">Últimos movimientos</h2>
        ${ledgerTable(ledger)}
      </section>
    </div>
  `);
}

function buildingsTable() {
  const rows = state.buildings ?? [];
  if (!rows.length) return '<div class="empty">Ningún edificio todavía.</div>';

  return `<div class="tablewrap"><table class="table">
    <thead><tr>
      <th>Edificio</th><th>Parcela</th><th>Estado</th><th>Produciendo</th><th class="num">Listo</th>
    </tr></thead>
    <tbody>
      ${rows.map((b) => {
        const bt = state.buildingTypes.find((x) => x.code === b.type_code);
        const plot = state.plots.find((p) => p.id === b.plot_id);
        const recipe = state.recipes.find((r) => r.id === b.recipe_id);
        const when = b.status === 'construction' ? b.ready_at : b.run_ends_at;
        return `<tr>
          <td>${bt?.icon ?? '🏗️'} ${esc(bt?.name ?? b.type_code)}
              <br><span class="faint" style="font-size:.76rem">${CATEGORY[bt?.category] ?? ''}</span></td>
          <td class="mono">${plot ? `${plot.x},${plot.y}` : '—'}</td>
          <td><span class="tag">${BUILDING_STATUS[b.status]}</span></td>
          <td>${recipe ? esc(recipe.name) : '<span class="faint">—</span>'}</td>
          <td class="num">${when ? esc(relTime(when) ?? '') : '—'}</td>
        </tr>`;
      }).join('')}
    </tbody>
  </table></div>`;
}

function inventoryTable(inventory) {
  if (!inventory.length) return '<div class="empty">El almacén está vacío.</div>';

  return `<div class="tablewrap"><table class="table">
    <thead><tr>
      <th>Recurso</th><th class="num">Cantidad</th><th class="num">Coste medio</th>
      <th class="num">Precio</th><th class="num">Margen</th>
    </tr></thead>
    <tbody>
      ${inventory.map((i) => {
        const res = state.resources.find((r) => r.code === i.resource_code);
        const price = priceOf(i.resource_code);
        const margin = price - Number(i.avg_cost);
        const color = margin >= 0 ? 'var(--accent)' : 'var(--danger)';
        return `<tr>
          <td>${res?.icon ?? ''} ${esc(res?.name ?? i.resource_code)}</td>
          <td class="num">${qty(i.qty)} ${esc(res?.unit ?? '')}</td>
          <td class="num">${money(i.avg_cost, { cents: true })}</td>
          <td class="num">${money(price, { cents: true })}</td>
          <td class="num" style="color:${color}">
            ${margin >= 0 ? '+' : ''}${money(margin, { cents: true })}
          </td>
        </tr>`;
      }).join('')}
    </tbody>
  </table></div>`;
}

function ledgerTable(ledger) {
  if (!ledger.length) return '<div class="empty">Sin movimientos todavía.</div>';

  return `<div class="tablewrap"><table class="table">
    <thead><tr>
      <th>Concepto</th><th>Detalle</th><th class="num">Importe</th><th class="num">Saldo</th>
    </tr></thead>
    <tbody>
      ${ledger.map((l) => `
        <tr>
          <td>${LEDGER_KIND[l.kind] ?? esc(l.kind)}</td>
          <td class="faint">${esc(l.memo ?? '')}</td>
          <td class="num" style="color:${Number(l.amount) >= 0 ? 'var(--accent)' : 'var(--danger)'}">
            ${Number(l.amount) >= 0 ? '+' : ''}${money(l.amount, { cents: true })}
          </td>
          <td class="num money">${money(l.balance_after)}</td>
        </tr>`).join('')}
    </tbody>
  </table></div>`;
}
