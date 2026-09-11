/* ============================================================================
 * UrbanHills · punto de entrada
 *
 * Sin bundler y sin framework: módulos ES nativos que el navegador carga tal
 * cual están en el repositorio. Es lo que permite que GitHub Pages sirva esto
 * sin ningún paso de compilación.
 * ========================================================================== */

import { initData, db } from './data/index.js';
import { state, setState, subscribe } from './core/store.js';
import { route, setNotFound, startRouter, currentRoute, render, navigate }
  from './core/router.js';
import { bootstrap, refreshWorld, refreshMine, refreshPrices } from './game/sync.js';
import { toast } from './core/ui.js';

import landing from './views/landing.js';
import auth    from './views/auth.js';
import start   from './views/start.js';
import mapView, { syncMap, refreshPanel } from './views/map.js';
import company from './views/company.js';
import market  from './views/market.js';
import city    from './views/city.js';
import help    from './views/help.js';

const app = document.getElementById('app');

route('/',        landing);
route('/entrar',  auth);
route('/empezar', start);
route('/mapa',    mapView);
route('/empresa', company);
route('/mercado', market);
route('/ciudad',  city);
route('/ayuda',   help);

setNotFound(() => `
  <div class="page center">
    <h1>Esa página no existe</h1>
    <p class="muted">Puede que el enlace esté mal, o que aún no la hayamos construido.</p>
    <a class="btn btn--primary" href="#/">Volver al principio</a>
  </div>
`);

async function main() {
  try {
    const provider = await initData();
    setState({ mode: provider.kind });

    await bootstrap();
    await refreshPrices();
  } catch (err) {
    console.error('[arranque]', err);
    app.innerHTML = `
      <div class="sheet">
        <h1>No se pudo arrancar</h1>
        <p class="muted">${String(err.message || err)}</p>
        <p class="faint">
          Si acabas de configurar Supabase, comprueba que las migraciones están
          aplicadas y que existe un mundo con el código de <code>config.js</code>.
        </p>
        <a class="btn" href="#/ayuda" onclick="location.reload()">Ver la guía</a>
      </div>`;
    return;
  }

  await startRouter(app);

  // Sin empresa, todas las rutas de juego llevan a fundarla: es la única
  // acción posible y así no hay pantallas vacías sin salida.
  if (!state.company && ['/mapa', '/empresa', '/mercado'].includes(currentRoute())) {
    navigate('/empezar', { replace: true });
  }

  wireTicks();
  wireLiveHeader();
}

/** Cuando el mundo avanza un tick, se refresca lo que ha podido cambiar. */
function wireTicks() {
  db.onTick(state.world.id, async () => {
    try {
      await refreshWorld();
      await refreshMine();

      if (currentRoute() === '/mapa') {
        syncMap();
        refreshPanel();
      } else {
        // Fuera del mapa basta con repintar la vista actual.
        await render(app);
      }
    } catch (err) {
      console.error('[tick]', err);
    }
  }).catch((err) => console.warn('Sin avisos en vivo:', err.message));
}

/** La caja y el contador de tick de la barra superior se refrescan solos. */
function wireLiveHeader() {
  let lastCash = state.company?.cash;
  let lastTick = state.world?.current_tick;

  subscribe((s) => {
    const cashChanged = s.company?.cash !== lastCash;
    const tickChanged = s.world?.current_tick !== lastTick;
    if (!cashChanged && !tickChanged) return;

    lastCash = s.company?.cash;
    lastTick = s.world?.current_tick;

    const purse = document.querySelector('.purse strong');
    if (purse && s.company) {
      import('./core/ui.js').then(({ compact }) => {
        purse.textContent = `${compact(s.company.cash)} €`;
      });
    }
  });
}

main();

// Una excepción no capturada no debería dejar la pantalla en blanco sin explicación.
addEventListener('unhandledrejection', (e) => {
  console.error('[promesa sin capturar]', e.reason);
  toast('Algo ha fallado por detrás. Mira la consola.', 'error');
});
