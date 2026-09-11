/* Cómo se juega, y cómo se conecta esto a un Supabase de verdad. */

import { state } from '../core/store.js';
import { chrome } from '../ui/shell.js';

export default function help() {
  return chrome(`
    <div class="page" style="max-width:760px">
      <div class="page__head">
        <h1>Cómo se juega</h1>
        <p>Cinco minutos de lectura y ya puedes empezar.</p>
      </div>

      <section class="card" style="margin-bottom:var(--sp-4)">
        <h2>El bucle</h2>
        <ol class="muted" style="padding-left:1.2em;line-height:1.8">
          <li><strong>Compra suelo.</strong> Barato en la periferia, caro en el centro.
              Mira la pendiente: construir en cuesta cuesta más dinero.</li>
          <li><strong>Construye.</strong> Cada edificio exige un terreno y una
              calificación concretos. Una cantera quiere roca sin calificar; un
              bloque de pisos, suelo residencial.</li>
          <li><strong>Produce.</strong> Elige receta y lotes. Las entradas salen de
              tu almacén al empezar, no al terminar.</li>
          <li><strong>Vende.</strong> A otros jugadores en el mercado, o a la
              población: los hogares compran comida, ocio y muebles cada tick.</li>
          <li><strong>Mira el barrio.</strong> Lo que construyes cambia la
              contaminación, el empleo y el valor del suelo de tu distrito y de
              los de al lado.</li>
        </ol>
      </section>

      <section class="card" style="margin-bottom:var(--sp-4)">
        <h2>Lo que casi nadie ve venir</h2>
        <ul class="muted" style="padding-left:1.2em;line-height:1.8">
          <li><strong>La mano de obra es local.</strong> Una fábrica sin vecinos
              cerca produce a media máquina. Construir vivienda al lado de tu
              industria no es altruismo: es logística.</li>
          <li><strong>Contaminar sale caro a la larga.</strong> Hunde el valor de
              tu propio suelo y espanta a la clase alta, que es la que paga los
              alquileres buenos.</li>
          <li><strong>El suelo vacío también tributa.</strong> El IBI se cobra
              sobre el valor, tengas algo encima o no.</li>
          <li><strong>La luz y el agua van por red.</strong> No se compran en el
              mercado: se facturan cada tick al precio vigente, que sube si la
              ciudad consume más de lo que genera.</li>
        </ul>
      </section>

      ${state.mode === 'demo' ? `
      <section class="card">
        <h2>Pasar del modo demo a una partida real</h2>
        <p class="muted">
          Ahora mismo el mundo está generado en tu navegador y no hay nadie más
          jugando. Para abrir una partida multijugador de verdad:
        </p>
        <ol class="muted" style="padding-left:1.2em;line-height:1.8">
          <li>Crea un proyecto en <a href="https://supabase.com" target="_blank"
              rel="noopener">supabase.com</a>.</li>
          <li>Aplica las migraciones de <code>supabase/migrations/</code> en orden,
              desde el SQL Editor o con <code>supabase db push</code>.</li>
          <li>Genera el mundo:
              <code>select game.generate_world('alpha', 'Alfa', 20260911, 64, 64);</code></li>
          <li>Pega la URL y la <em>anon key</em> del proyecto en
              <code>src/js/config.js</code>.</li>
        </ol>
        <p class="muted">
          Está todo detallado en <code>docs/SETUP.md</code>.
        </p>
      </section>` : ''}
    </div>
  `);
}
