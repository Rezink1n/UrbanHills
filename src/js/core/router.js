/* ============================================================================
 * Router por hash.
 *
 * GitHub Pages sirve ficheros estáticos: no puede reescribir /mapa a
 * index.html. Con hash (#/mapa) la navegación funciona sin configurar nada y
 * los enlaces se pueden compartir.
 * ========================================================================== */

const routes = new Map();
let notFound = () => '<div class="page"><h1>404</h1></div>';
let current = null;

export function route(path, view) {
  routes.set(path, view);
}

export function setNotFound(view) {
  notFound = view;
}

export function parseHash() {
  const raw = location.hash.replace(/^#/, '') || '/';
  const [path, query = ''] = raw.split('?');
  return {
    path: path.replace(/\/+$/, '') || '/',
    params: Object.fromEntries(new URLSearchParams(query)),
  };
}

export function navigate(to, { replace = false } = {}) {
  const url = to.startsWith('#') ? to : `#${to}`;
  if (replace) location.replace(url);
  else location.hash = url;
}

export function currentRoute() {
  return current;
}

/**
 * Resuelve la ruta actual y monta la vista.
 * Cada vista es `async (params) => { html, mount? }`.
 */
export async function render(container) {
  const { path, params } = parseHash();
  current = path;

  const view = routes.get(path) || notFound;
  let result;
  try {
    result = await view(params);
  } catch (err) {
    console.error('[router]', err);
    result = {
      html: `<div class="page"><h1>Algo se ha roto</h1>
             <p class="muted">${String(err.message || err)}</p></div>`,
    };
  }

  const { html, mount } = typeof result === 'string' ? { html: result } : result;
  container.innerHTML = html;
  if (typeof mount === 'function') mount(container);

  // Al cambiar de vista se vuelve arriba, salvo en el mapa (que no scrollea).
  if (path !== '/mapa') window.scrollTo(0, 0);
}

export function startRouter(container) {
  addEventListener('hashchange', () => render(container));
  return render(container);
}
