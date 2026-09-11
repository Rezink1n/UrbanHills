/* Fundar empresa: la puerta de entrada a una partida. */

import { db } from '../data/index.js';
import { state } from '../core/store.js';
import { toast, humanError, money, esc } from '../core/ui.js';
import { navigate } from '../core/router.js';
import { refreshMine } from '../game/sync.js';

export default function start() {
  if (state.company) {
    navigate('/mapa', { replace: true });
    return '<div class="boot"><p class="boot__text">Entrando…</p></div>';
  }

  // Fundar empresa exige sesión: la RPC valida auth.uid().
  if (state.mode === 'supabase' && !state.session) {
    navigate('/entrar', { replace: true });
    return '<div class="boot"><p class="boot__text">Identifícate para jugar…</p></div>';
  }

  const cash = state.world?.starting_cash ?? 250000;

  return {
    html: `
      <div class="sheet">
        <h1>Funda tu empresa</h1>
        <p class="muted">
          Empiezas con <strong class="money">${money(cash)}</strong> y ninguna
          parcela. El primer movimiento suele ser comprar suelo barato en la
          periferia y abrir una cantera o un aserradero.
        </p>

        <form id="found" class="stack" style="margin-top:var(--sp-4)">
          <div class="field">
            <label for="name">Nombre de la empresa</label>
            <input class="input" id="name" name="name" type="text"
                   minlength="3" maxlength="40" required
                   placeholder="Constructora del Cerro" autocomplete="off">
          </div>
          <button class="btn btn--primary btn--block" type="submit" id="go">
            Fundar y entrar
          </button>
        </form>

        ${state.mode === 'demo' ? `
          <p class="faint" style="margin-top:var(--sp-4);font-size:.82rem">
            Estás en modo demo: la partida se guarda sólo en este navegador.
          </p>` : ''}
      </div>
    `,

    mount(root) {
      const form = root.querySelector('#found');
      const go = root.querySelector('#go');

      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        go.disabled = true;
        try {
          const name = new FormData(form).get('name');
          await db.foundCompany(name);
          await refreshMine();
          toast(`${name} en marcha. Suerte.`);
          navigate('/mapa');
        } catch (err) {
          toast(humanError(err), 'error');
          go.disabled = false;
        }
      });
    },
  };
}
