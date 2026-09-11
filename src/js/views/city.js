/* Ciudad: el pulso social distrito a distrito. */

import { state } from '../core/store.js';
import { chrome } from '../ui/shell.js';
import { esc, compact, pct } from '../core/ui.js';

export default function city() {
  const districts = [...state.districts].sort((a, b) => a.code.localeCompare(b.code));
  const stats = state.districtStats;
  const all = Object.values(stats);

  const total = all.reduce((a, s) => a + (s.population || 0), 0);
  const avg = (key) => all.length
    ? all.reduce((a, s) => a + Number(s[key] || 0), 0) / all.length
    : 0;

  return chrome(`
    <div class="page">
      <div class="page__head">
        <h1>La ciudad</h1>
        <p>
          Cada distrito se recalcula en cada tick. Lo que pasa aquí es
          consecuencia directa de lo que se construye ahí fuera.
        </p>
      </div>

      <div class="stats" style="margin-bottom:var(--sp-5)">
        <div class="stat">
          <div class="stat__label">Población</div>
          <div class="stat__value">${compact(total)}</div>
        </div>
        <div class="stat">
          <div class="stat__label">Felicidad media</div>
          <div class="stat__value">${avg('happiness').toFixed(0)}</div>
        </div>
        <div class="stat">
          <div class="stat__label">Empleo</div>
          <div class="stat__value">${pct(avg('employment_rate') * 100)}</div>
        </div>
        <div class="stat">
          <div class="stat__label">Contaminación</div>
          <div class="stat__value">${avg('pollution').toFixed(0)}</div>
        </div>
      </div>

      <section class="card">
        <h2 style="margin-bottom:var(--sp-3)">Distritos</h2>
        <div class="tablewrap"><table class="table">
          <thead><tr>
            <th>Distrito</th>
            <th class="num">Población</th>
            <th class="num">Vivienda</th>
            <th class="num">Empleos</th>
            <th class="num">Felicidad</th>
            <th class="num">Contam.</th>
            <th class="num">Criminal.</th>
            <th class="num">Índice suelo</th>
            <th class="num">Presión</th>
          </tr></thead>
          <tbody>
            ${districts.map((d) => {
              const s = stats[d.id] ?? {};
              const press = Number(s.migration_pressure ?? 0);
              return `<tr>
                <td><strong>${esc(d.code)}</strong></td>
                <td class="num">${compact(s.population ?? 0)}</td>
                <td class="num ${(s.population ?? 0) > (s.housing_capacity ?? 0)
                    ? '' : 'faint'}">${compact(s.housing_capacity ?? 0)}</td>
                <td class="num">${compact(s.jobs ?? 0)}</td>
                <td class="num" style="color:${tone(s.happiness)}">
                  ${Math.round(s.happiness ?? 0)}</td>
                <td class="num" style="color:${tone(100 - (s.pollution ?? 0))}">
                  ${Math.round(s.pollution ?? 0)}</td>
                <td class="num" style="color:${tone(100 - (s.crime ?? 0))}">
                  ${Math.round(s.crime ?? 0)}</td>
                <td class="num">${Math.round(s.land_value_index ?? 100)}</td>
                <td class="num" style="color:${press >= 0 ? 'var(--accent)' : 'var(--danger)'}">
                  ${press >= 0 ? '+' : ''}${Math.round(press)}</td>
              </tr>`;
            }).join('')}
          </tbody>
        </table></div>
        <p class="faint" style="font-size:.78rem;margin:var(--sp-3) 0 0">
          <strong>Presión</strong> positiva = el barrio atrae gente. Negativa = se
          está vaciando, y con él los locales de quien apostó por él.
        </p>
      </section>
    </div>
  `);
}

function tone(v) {
  const n = Number(v) || 0;
  if (n >= 60) return 'var(--accent)';
  if (n >= 40) return 'var(--warn)';
  return 'var(--danger)';
}
