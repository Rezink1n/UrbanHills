# Arquitectura técnica

## 1. Principio rector

> **El cliente no es de fiar.** Todo lo que afecta a la economía se calcula en Postgres.

El navegador sólo lee estado y **pide** acciones. Ninguna tabla económica acepta `INSERT`,
`UPDATE` o `DELETE` directo desde el cliente: la escritura pasa siempre por funciones RPC
`SECURITY DEFINER` que validan reglas, cobran costes y escriben en el libro mayor.

Esto es innegociable en un juego con mercado: si un jugador puede hacer
`update companies set cash = 999999999`, no hay juego.

## 2. Stack

| Capa | Tecnología | Por qué |
|---|---|---|
| Hosting | **GitHub Pages** | Estático, gratis, HTTPS, CDN. Sin build step. |
| Cliente | **HTML + CSS + JS (ES modules)** | Cero dependencias, cero compilación, carga directa. |
| Base de datos | **Supabase (Postgres 17)** | Relacional, transaccional, con RLS. La lógica vive aquí. |
| Auth | **Supabase Auth** | Email+contraseña y magic link. JWT en el cliente. |
| Tiempo real | **Supabase Realtime** | Actualiza mercado y mapa sin polling. |
| Trabajos periódicos | **pg_cron** + **Edge Function** | El *tick* del mundo. |

No hay backend propio. No hay Node en producción. No hay bundler.

## 3. Diagrama

```
┌────────────────────────── GitHub Pages (estático) ──────────────────────────┐
│  index.html                                                                  │
│    └── src/js/main.js  (ES modules, sin bundler)                             │
│         ├── core/      router · store · auth · cliente supabase · toasts     │
│         ├── data/      capa de acceso a datos (2 proveedores intercambiables)│
│         │                ├── supabase.provider.js   → producción             │
│         │                └── demo.provider.js       → mundo local en memoria │
│         ├── game/      worldgen · economía · render del mapa en canvas       │
│         └── views/     landing · auth · mapa · parcela · empresa · mercado…  │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ HTTPS  (supabase-js vía CDN esm.sh)
                                   ▼
┌────────────────────────────── Supabase ──────────────────────────────────────┐
│  Auth  ──► auth.users ──► public.profiles (trigger)                          │
│                                                                              │
│  PostgREST                                                                   │
│    · SELECT sobre tablas de mundo (RLS: lectura pública)                     │
│    · RPC:  rpc_found_company · rpc_buy_plot · rpc_start_construction          │
│            rpc_start_production · rpc_place_order · rpc_cancel_order …       │
│                                                                              │
│  Realtime ──► canales: market_orders, plots, notifications                   │
│                                                                              │
│  pg_cron  ──► every 5 min ──► fn_world_tick()                                │
│                                 ├─ finalizar construcciones                  │
│                                 ├─ producir (inputs→outputs, salarios)       │
│                                 ├─ demanda NPC → órdenes de compra           │
│                                 ├─ casar el mercado                          │
│                                 ├─ recalcular distritos y valor del suelo    │
│                                 ├─ migración de población                    │
│                                 └─ impuestos y tesorería municipal           │
└──────────────────────────────────────────────────────────────────────────────┘
```

## 4. Capa de datos intercambiable

`src/js/data/index.js` exporta un único objeto `db` que implementa una interfaz fija
(`getWorld`, `getPlots`, `buyPlot`, `placeOrder`, …). Detrás hay dos implementaciones:

- **`supabase.provider.js`** — habla con Supabase. Se usa cuando `src/js/config.js` tiene
  credenciales válidas.
- **`demo.provider.js`** — genera un mundo procedural en memoria y simula los ticks en el
  navegador. Se usa automáticamente si no hay credenciales.

Ventaja: el juego **se puede abrir y jugar sin haber tocado Supabase**, y la UI se desarrolla
sin depender del backend. Misma interfaz, mismo código de vistas.

## 5. Flujo de una acción del jugador

Comprar una parcela:

```
Vista mapa → db.buyPlot(plotId)
           → supabase.rpc('rpc_buy_plot', { p_plot_id })
             └── Postgres, dentro de una transacción:
                 1. ¿la parcela existe y está en venta?
                 2. ¿la empresa del usuario tiene caja suficiente?
                 3. descontar caja, asignar propietario
                 4. asentar dos líneas en `ledger_entries`
                 5. devolver el nuevo estado de la parcela
           → Realtime notifica al resto de jugadores
           → la vista repinta
```

Si algo falla, la transacción entera se revierte. No hay estados a medias.

## 6. El tick del mundo

`fn_world_tick()` es una función SQL idempotente por número de tick: si se ejecuta dos veces
para el mismo tick, la segunda no hace nada. Se dispara desde **pg_cron** (recomendado, todo
dentro de la base de datos) o desde la **Edge Function `world-tick`** si se prefiere control
externo o telemetría.

El tick está diseñado para ser barato: opera en conjuntos (`UPDATE … FROM`), no fila a fila,
y no recorre las 4.096 parcelas salvo en el recálculo de valor del suelo, que es un único
`UPDATE` con ventanas.

## 7. Seguridad

- **RLS activo en todas las tablas.** Lectura pública del estado del mundo (es un juego, el
  mapa es público); escritura sólo vía RPC.
- Las funciones RPC son `SECURITY DEFINER` con `search_path` fijado, y validan siempre
  `auth.uid()` contra la propiedad de la empresa.
- La `anon key` de Supabase **va en el repositorio**: es pública por diseño y sólo sirve para
  hablar con PostgREST bajo RLS. La `service_role key` **nunca** entra en el cliente.
- Rate limiting de acciones vía tabla `action_log` y comprobaciones en las RPC.

## 8. Despliegue

`main` → GitHub Actions (`.github/workflows/deploy.yml`) → GitHub Pages. Sin build: se publica
el repositorio tal cual (con `.nojekyll` para que Pages no ignore nada).

Las migraciones de Supabase se aplican con la CLI (`supabase db push`) o pegando los ficheros de
`supabase/migrations/` en el SQL Editor, en orden.
