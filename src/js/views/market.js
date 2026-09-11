/* Mercado: precios, libro de órdenes y colocación de órdenes propias. */

import { state, setState } from '../core/store.js';
import { db } from '../data/index.js';
import { chrome } from '../ui/shell.js';
import { esc, money, qty, toast, humanError, relTime } from '../core/ui.js';
import { RESOURCE_CATEGORY } from '../game/labels.js';
import { refreshPrices, refreshMine, priceOf } from '../game/sync.js';

export default async function market(params) {
  await refreshPrices();

  const tradables = state.resources.filter((r) => r.is_storable);
  const selected = params.r && tradables.some((r) => r.code === params.r)
    ? params.r
    : tradables[0]?.code;

  let book = [];
  if (selected) {
    try { book = await db.getOrderBook(state.world.id, selected); } catch { book = []; }
  }

  return {
    html: chrome(`
      <div class="page">
        <div class="page__head">
          <h1>Mercado</h1>
          <p>
            Libro de órdenes con precio límite. La electricidad y el agua no
            aparecen: van por red y se facturan solas.
          </p>
        </div>

        <div class="split">
          <section class="card">
            <h2 style="margin-bottom:var(--sp-3)">Precios</h2>
            ${pricesTable(tradables, selected)}
          </section>

          <div class="stack">
            ${orderForm(selected)}
            ${bookCard(selected, book)}
            ${myOrdersCard()}
          </div>
        </div>
      </div>
    `),

    mount(root) {
      root.querySelector('#prices')?.addEventListener('click', (e) => {
        const row = e.target.closest('[data-resource]');
        if (row) location.hash = `#/mercado?r=${row.dataset.resource}`;
      });

      root.querySelector('#order-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const form = e.target;
        const btn = form.querySelector('button[type=submit]');
        btn.disabled = true;

        try {
          const f = new FormData(form);
          await db.placeOrder(
            state.world.id,
            f.get('resource'),
            f.get('side'),
            Number(f.get('quantity')),
            Number(f.get('price')),
          );
          toast('Orden colocada.');
          await refreshMine();
          location.reload();
        } catch (err) {
          toast(humanError(err), 'error');
          btn.disabled = false;
        }
      });

      root.querySelector('#my-orders')?.addEventListener('click', async (e) => {
        const btn = e.target.closest('[data-cancel]');
        if (!btn) return;
        btn.disabled = true;
        try {
          await db.cancelOrder(btn.dataset.cancel);
          toast('Orden cancelada.');
          await refreshMine();
          location.reload();
        } catch (err) {
          toast(humanError(err), 'error');
          btn.disabled = false;
        }
      });
    },
  };
}

function pricesTable(resources, selected) {
  return `<div class="tablewrap"><table class="table table--click" id="prices">
    <thead><tr>
      <th>Recurso</th><th>Tipo</th>
      <th class="num">Referencia</th><th class="num">Compra</th><th class="num">Venta</th>
      <th class="num">Tuyo</th>
    </tr></thead>
    <tbody>
      ${resources.map((r) => {
        const p = state.prices[r.code] ?? {};
        const mine = state.inventory[r.code]?.qty ?? 0;
        const last = priceOf(r.code);
        const delta = (last - r.base_price) / r.base_price;
        const color = Math.abs(delta) < 0.02 ? 'var(--text)'
                    : delta > 0 ? 'var(--accent)' : 'var(--danger)';
        return `<tr data-resource="${esc(r.code)}"
                    style="${r.code === selected ? 'background:var(--surface-3)' : ''}">
          <td>${r.icon ?? ''} ${esc(r.name)}
              <span class="faint" style="font-size:.76rem">T${r.tier}</span></td>
          <td class="faint">${RESOURCE_CATEGORY[r.category]}</td>
          <td class="num" style="color:${color}">${money(last, { cents: true })}</td>
          <td class="num faint">${p.best_bid ? money(p.best_bid, { cents: true }) : '—'}</td>
          <td class="num faint">${p.best_ask ? money(p.best_ask, { cents: true }) : '—'}</td>
          <td class="num">${mine > 0 ? qty(mine) : '<span class="faint">—</span>'}</td>
        </tr>`;
      }).join('')}
    </tbody>
  </table></div>`;
}

function orderForm(resourceCode) {
  if (!state.company) {
    return '<div class="empty">Funda tu empresa para operar en el mercado.</div>';
  }
  const res = state.resources.find((r) => r.code === resourceCode);
  if (!res) return '';

  const price = priceOf(resourceCode);
  const held = state.inventory[resourceCode]?.qty ?? 0;

  return `
    <section class="card">
      <h2 style="margin-bottom:var(--sp-3)">
        ${res.icon ?? ''} ${esc(res.name)}
      </h2>
      <form class="stack" id="order-form">
        <input type="hidden" name="resource" value="${esc(resourceCode)}">

        <div class="field">
          <label for="side">Operación</label>
          <select class="input" id="side" name="side">
            <option value="buy">Comprar</option>
            <option value="sell" ${held > 0 ? '' : 'disabled'}>
              Vender${held > 0 ? ` (tienes ${qty(held)})` : ' — sin stock'}
            </option>
          </select>
        </div>

        <div class="field">
          <label for="quantity">Cantidad (${esc(res.unit)})</label>
          <input class="input" id="quantity" name="quantity" type="number"
                 min="0.01" step="0.01" value="${held > 0 ? Math.floor(held) : 10}" required>
        </div>

        <div class="field">
          <label for="price">Precio unitario</label>
          <input class="input" id="price" name="price" type="number"
                 min="0.01" step="0.01" value="${price.toFixed(2)}" required>
          <span class="faint" style="font-size:.78rem">
            Referencia ${money(price, { cents: true })} · ancla ${money(res.base_price, { cents: true })}
          </span>
        </div>

        <button class="btn btn--primary btn--block" type="submit">Colocar orden</button>
      </form>
    </section>`;
}

function bookCard(resourceCode, book) {
  if (!resourceCode) return '';
  const bids = book.filter((o) => o.side === 'buy')
    .sort((a, b) => b.unit_price - a.unit_price).slice(0, 8);
  const asks = book.filter((o) => o.side === 'sell')
    .sort((a, b) => a.unit_price - b.unit_price).slice(0, 8);

  const side = (rows, label, color) => `
    <div>
      <div class="muted" style="font-size:.74rem;text-transform:uppercase;
           letter-spacing:.05em;margin-bottom:4px">${label}</div>
      ${rows.length ? rows.map((o) => `
        <div class="row row--sb mono" style="font-size:.82rem;padding:2px 0">
          <span style="color:${color}">${money(o.unit_price, { cents: true })}</span>
          <span class="faint">${qty(o.qty - o.qty_filled)}${o.is_npc ? ' 👥' : ''}</span>
        </div>`).join('')
        : '<span class="faint" style="font-size:.82rem">vacío</span>'}
    </div>`;

  return `
    <section class="card">
      <h3 style="margin-bottom:var(--sp-3)">Libro de órdenes</h3>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:var(--sp-3)">
        ${side(bids, 'Compras', 'var(--accent)')}
        ${side(asks, 'Ventas', 'var(--danger)')}
      </div>
      <p class="faint" style="font-size:.74rem;margin:var(--sp-3) 0 0">
        👥 = demanda de la población, que se renueva en cada tick.
      </p>
    </section>`;
}

function myOrdersCard() {
  const orders = state.orders ?? [];
  if (!orders.length) return '';

  return `
    <section class="card" id="my-orders">
      <h3 style="margin-bottom:var(--sp-3)">Tus órdenes vivas</h3>
      <div class="stack" style="gap:var(--sp-2)">
        ${orders.map((o) => `
          <div class="row row--sb" style="font-size:.84rem">
            <span>
              <strong style="color:${o.side === 'buy' ? 'var(--accent)' : 'var(--danger)'}">
                ${o.side === 'buy' ? 'C' : 'V'}
              </strong>
              ${qty(o.qty - o.qty_filled)} × ${esc(o.resource_code)}
              <span class="faint">@ ${money(o.unit_price, { cents: true })}</span>
            </span>
            <button class="btn btn--sm btn--ghost" data-cancel="${esc(o.id)}">✕</button>
          </div>`).join('')}
      </div>
    </section>`;
}
