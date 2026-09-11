/* Alta y acceso con Supabase Auth. En modo demo esta vista no se usa. */

import { db } from '../data/index.js';
import { toast, humanError, esc } from '../core/ui.js';
import { navigate } from '../core/router.js';

export default function auth() {
  return {
    html: `
      <div class="sheet">
        <h1>Entrar en UrbanHills</h1>
        <p class="muted">Con tu correo basta. La contraseña es sólo para volver a entrar.</p>

        <form id="auth-form" class="stack" style="margin-top:var(--sp-4)">
          <div class="field">
            <label for="email">Correo</label>
            <input class="input" id="email" name="email" type="email"
                   autocomplete="email" required placeholder="tu@correo.com">
          </div>

          <div class="field">
            <label for="password">Contraseña</label>
            <input class="input" id="password" name="password" type="password"
                   autocomplete="current-password" required minlength="8"
                   placeholder="Mínimo 8 caracteres">
          </div>

          <div class="field" id="username-field" hidden>
            <label for="username">Nombre de jugador</label>
            <input class="input" id="username" name="username" type="text"
                   pattern="[A-Za-z0-9_]{3,20}" placeholder="entre 3 y 20 caracteres">
          </div>

          <button class="btn btn--primary btn--block" type="submit" id="submit">
            Entrar
          </button>
          <button class="btn btn--ghost btn--block" type="button" id="toggle">
            No tengo cuenta todavía
          </button>
        </form>
      </div>
    `,

    mount(root) {
      let signingUp = false;
      const form = root.querySelector('#auth-form');
      const submit = root.querySelector('#submit');
      const toggle = root.querySelector('#toggle');
      const userField = root.querySelector('#username-field');

      toggle.addEventListener('click', () => {
        signingUp = !signingUp;
        userField.hidden = !signingUp;
        root.querySelector('#username').required = signingUp;
        submit.textContent = signingUp ? 'Crear cuenta' : 'Entrar';
        toggle.textContent = signingUp
          ? 'Ya tengo cuenta'
          : 'No tengo cuenta todavía';
      });

      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        submit.disabled = true;

        const data = Object.fromEntries(new FormData(form));
        try {
          if (signingUp) {
            await db.signUp(data);
            toast('Cuenta creada. Revisa tu correo si te pide confirmación.');
          } else {
            await db.signIn(data);
          }
          navigate('/empezar');
        } catch (err) {
          toast(humanError(err), 'error');
        } finally {
          submit.disabled = false;
        }
      });
    },
  };
}
