/* Portada: qué es esto y por dónde se entra. */

import { state } from '../core/store.js';

export default function landing() {
  const entrada = state.company
    ? '<a class="btn btn--primary" href="#/mapa">Volver a la ciudad</a>'
    : state.mode === 'demo'
      ? '<a class="btn btn--primary" href="#/empezar">Jugar en modo demo</a>'
      : '<a class="btn btn--primary" href="#/entrar">Entrar / crear cuenta</a>';

  return `
    <div class="hero">
      <span class="hero__mark">🏙️</span>
      <h1>UrbanHills</h1>
      <p class="hero__lede">
        Un juego online de simulación económica y urbana. Compras suelo en una
        ciudad construida sobre colinas, levantas lo que quieras encima y
        compites con los demás por el sitio, la mano de obra y el mercado.
      </p>

      <div class="hero__actions">
        ${entrada}
        <a class="btn" href="#/ayuda">Cómo se juega</a>
      </div>

      <div class="pillars">
        <article class="pillar">
          <h3>🗺️ El suelo manda</h3>
          <p>
            Cada parcela tiene altitud, pendiente, vistas y vecinos. Comprar bien
            es la primera decisión estratégica, y la que más se paga a la larga.
          </p>
        </article>
        <article class="pillar">
          <h3>🧍 La ciudad está viva</h3>
          <p>
            Los vecinos no son un número: buscan trabajo, consumen, se quejan del
            ruido y se mudan si el barrio empeora. Son tu demanda y tu plantilla.
          </p>
        </article>
        <article class="pillar">
          <h3>🏭 Las externalidades cuentan</h3>
          <p>
            Una acería da empleo y hunde el valor del suelo alrededor. Un parque
            no produce nada y revaloriza cuatro manzanas. Ahí está el juego.
          </p>
        </article>
        <article class="pillar">
          <h3>🏛️ Hay política</h3>
          <p>
            Impuestos, presupuesto municipal y una alcaldía que se elige. Quien
            manda en el ayuntamiento decide dónde se puede construir qué.
          </p>
        </article>
      </div>
    </div>
  `;
}
