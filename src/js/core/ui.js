/* ============================================================================
 * Utilidades de presentación: escapado, formato y avisos.
 * ========================================================================== */

/** Escapa texto antes de meterlo en una plantilla. Nombres de empresa incluidos. */
export function esc(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const eur = new Intl.NumberFormat('es-ES', {
  style: 'currency', currency: 'EUR', maximumFractionDigits: 0,
});
const eurCents = new Intl.NumberFormat('es-ES', {
  style: 'currency', currency: 'EUR', minimumFractionDigits: 2, maximumFractionDigits: 2,
});
const num = new Intl.NumberFormat('es-ES', { maximumFractionDigits: 2 });

export function money(v, { cents = false } = {}) {
  const n = Number(v) || 0;
  if (!cents && Math.abs(n) >= 1000) return eur.format(n);
  return cents ? eurCents.format(n) : eur.format(n);
}

/** Cifras grandes en el HUD: 1,2 M cabe donde 1.234.567 no. */
export function compact(v) {
  const n = Number(v) || 0;
  const abs = Math.abs(n);
  if (abs >= 1e9) return (n / 1e9).toFixed(1).replace('.', ',') + ' MM';
  if (abs >= 1e6) return (n / 1e6).toFixed(1).replace('.', ',') + ' M';
  if (abs >= 1e4) return Math.round(n / 1e3) + ' k';
  return num.format(n);
}

export function qty(v) { return num.format(Number(v) || 0); }

export function pct(v, digits = 0) {
  return `${(Number(v) || 0).toFixed(digits).replace('.', ',')} %`;
}

/** "en 4 min", "hace 2 h". Devuelve null si no hay fecha. */
export function relTime(iso) {
  if (!iso) return null;
  const diff = new Date(iso).getTime() - Date.now();
  const mins = Math.round(diff / 60000);
  const rtf = new Intl.RelativeTimeFormat('es-ES', { numeric: 'auto' });
  if (Math.abs(mins) < 60) return rtf.format(mins, 'minute');
  const hours = Math.round(mins / 60);
  if (Math.abs(hours) < 24) return rtf.format(hours, 'hour');
  return rtf.format(Math.round(hours / 24), 'day');
}

// --- Avisos -----------------------------------------------------------------

export function toast(message, kind = 'info', ms = 4200) {
  const host = document.getElementById('toasts');
  if (!host) return;

  const el = document.createElement('div');
  el.className = `toast${kind === 'info' ? '' : ` toast--${kind}`}`;
  el.textContent = message;
  host.appendChild(el);

  setTimeout(() => {
    el.style.transition = 'opacity .2s, transform .2s';
    el.style.opacity = '0';
    el.style.transform = 'translateY(6px)';
    setTimeout(() => el.remove(), 220);
  }, ms);
}

/**
 * Traduce los códigos de error de las RPC a algo que un jugador entienda.
 * Postgres devuelve 'INSUFFICIENT_FUNDS'; el jugador lee "No tienes caja
 * suficiente."
 */
const ERRORS = {
  NOT_AUTHENTICATED:        'Necesitas iniciar sesión.',
  NO_COMPANY_IN_WORLD:      'Todavía no has fundado tu empresa.',
  WORLD_NOT_FOUND:          'Ese mundo no existe o está cerrado.',
  INVALID_NAME:             'Ese nombre no vale: entre 3 y 40 caracteres.',
  NAME_TAKEN_OR_ALREADY_PLAYING: 'Ese nombre ya está cogido, o ya tienes empresa aquí.',
  PLOT_NOT_FOUND:           'Esa parcela no existe.',
  PLOT_NOT_FOR_SALE:        'Esa parcela no está en venta.',
  PLOT_NOT_OWNED:           'Esa parcela no es tuya.',
  PLOT_OCCUPIED:            'Ya hay un edificio en esa parcela.',
  ALREADY_OWNED:            'Esa parcela ya es tuya.',
  INSUFFICIENT_FUNDS:       'No tienes caja suficiente.',
  UNKNOWN_BUILDING:         'Ese tipo de edificio no existe.',
  MUNICIPAL_ONLY:           'Eso sólo lo puede construir el municipio.',
  TERRAIN_NOT_ALLOWED:      'Ese edificio no se puede levantar en este terreno.',
  ZONING_NOT_ALLOWED:       'La calificación del suelo no admite ese edificio.',
  SLOPE_TOO_STEEP:          'Demasiada pendiente para ese edificio.',
  REPUTATION_TOO_LOW:       'Te falta reputación para construir eso.',
  STILL_UNDER_CONSTRUCTION: 'La obra todavía no ha terminado.',
  ALREADY_PRODUCING:        'Ese edificio ya está produciendo.',
  RECIPE_NOT_AVAILABLE:     'Ese edificio no puede fabricar eso.',
  LEVEL_TOO_LOW:            'Necesitas ampliar el edificio antes.',
  INVALID_BATCHES:          'Número de lotes fuera de rango.',
  BUILDING_NOT_OWNED:       'Ese edificio no es tuyo.',
  NOT_TRADABLE:             'La luz y el agua van por red: no se negocian en el mercado.',
  UNKNOWN_RESOURCE:         'Ese recurso no existe.',
  INVALID_ORDER:            'Cantidad o precio no válidos.',
  ORDER_NOT_FOUND:          'Esa orden ya no existe.',
  INVALID_PRICE:            'Precio no válido.',
  INVALID_WAGE:             'El salario debe estar entre 0,5× y 2×.',
};

export function humanError(err) {
  const raw = String(err?.message || err || '');

  for (const [code, text] of Object.entries(ERRORS)) {
    if (raw.includes(code)) return text;
  }
  if (raw.includes('INSUFFICIENT_STOCK')) {
    const what = raw.split('INSUFFICIENT_STOCK:')[1]?.split(/[^a-z_]/)[0];
    return `No tienes suficiente material${what ? ` (${what})` : ''} en el almacén.`;
  }
  if (raw.includes('RATE_LIMITED')) {
    return 'Vas demasiado deprisa. Espera unos segundos.';
  }
  return raw || 'Ha fallado algo.';
}
