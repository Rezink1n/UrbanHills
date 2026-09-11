/* ============================================================================
 * Armazón: barra superior, navegación y cintas de aviso.
 * ========================================================================== */

import { state } from '../core/store.js';
import { esc, compact, relTime } from '../core/ui.js';
import { currentRoute } from '../core/router.js';

const NAV = [
  { path: '/mapa',    label: 'Mapa' },
  { path: '/empresa', label: 'Empresa' },
  { path: '/mercado', label: 'Mercado' },
  { path: '/ciudad',  label: 'Ciudad' },
  { path: '/ayuda',   label: 'Cómo se juega' },
];

export function topbar() {
  const here = currentRoute();
  const nextTick = state.world?.last_tick_at
    ? relTime(new Date(
        new Date(state.world.last_tick_at).getTime() + (state.world.tick_seconds ?? 300) * 1000,
      ).toISOString())
    : null;

  return `
    <header class="topbar">
      <a class="brand" href="#/mapa">
        <span class="brand__mark">🏙️</span>
        <span>UrbanHills</span>
      </a>

      <nav class="nav">
        ${NAV.map((n) => `
          <a href="#${n.path}"${here === n.path ? ' aria-current="page"' : ''}>${n.label}</a>
        `).join('')}
      </nav>

      <div class="topbar__end">
        ${state.world ? `
          <span class="tickpill" title="Tick ${state.world.current_tick}">
            <span class="tickpill__dot"></span>
            ${nextTick ? `tick ${esc(nextTick)}` : `tick ${state.world.current_tick}`}
          </span>` : ''}

        ${state.company ? `
          <span class="purse">
            <span class="purse__label">Caja</span>
            <strong class="money">${compact(state.company.cash)} €</strong>
          </span>` : ''}
      </div>
    </header>
    ${demoBanner()}
  `;
}

function demoBanner() {
  if (state.mode !== 'demo') return '';
  return `
    <div class="banner">
      <span class="banner__icon">🧪</span>
      <span>
        <strong>Modo demo.</strong> Mundo generado en tu navegador, sin servidor:
        la partida vive en este dispositivo y el reloj va acelerado ×20.
        Para jugar de verdad hay que configurar Supabase.
      </span>
      <a class="btn btn--sm" href="#/ayuda" style="margin-left:auto">Ver cómo</a>
    </div>
  `;
}

/** Envuelve el contenido de una vista con la barra superior. */
export function chrome(inner) {
  return topbar() + inner;
}
