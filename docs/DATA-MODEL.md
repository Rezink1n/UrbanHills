# Modelo de datos

29 tablas en `public`, más el esquema `game` con las funciones del motor (que
no se expone por PostgREST).

## Mapa de tablas

```
CATÁLOGO (contenido, sólo se escribe en migraciones)
  resources ─────────┐
  building_types ────┼── recipes ── recipe_inputs
                     └── consumption_profile

MUNDO
  worlds ── districts ── plots ── buildings ── production_runs
                │            │
                │            └─ (owner_company_id → companies)
                ├─ district_stats · district_stats_history
                └─ population_cohorts

JUGADORES
  auth.users ── profiles ── companies ── ledger_entries
                                 ├── inventories
                                 ├── notifications
                                 └── action_log

MERCADO
  market_orders ── market_trades ── price_history
  utility_meters          (luz y agua: van por red, no por el libro de órdenes)

MUNICIPIO
  city_treasury ── city_ledger
  elections ── election_candidates ── election_votes

OPERACIÓN
  world_events · tick_log
```

## Piezas que conviene entender

### `plots` — la unidad de todo

Cada parcela guarda dos valores distintos:

- **`base_land_value`**: se calcula una vez, al generar el mundo, a partir de
  centralidad, vistas, terreno y pendiente. No cambia nunca.
- **`land_value`**: se recalcula en cada tick aplicando al anterior un
  multiplicador que sale de los servicios, el prestigio, la contaminación y la
  criminalidad del distrito. Se mueve entre el 25 % y el 400 % del base.

Un distrito sin servicios deja su suelo en el 55 % del potencial. Ése es el
punto de partida de una ciudad y el margen de mejora que tienen los jugadores.

### `ledger_entries` — el libro mayor

Toda variación de caja pasa por `game.post_ledger()`, que actualiza
`companies.cash` y asienta la línea en la misma transacción. El invariante que
comprueba la prueba de humo:

```sql
select c.id
from companies c
where c.cash <> (select coalesce(sum(l.amount), 0)
                 from ledger_entries l where l.company_id = c.id);
-- debe devolver 0 filas, siempre
```

Si alguna vez devuelve filas, hay un camino que mueve dinero sin asentarlo, y
eso es un agujero por el que se cuela un exploit.

### `market_orders` — retenciones

Al poner una orden, lo comprometido sale inmediatamente:

- **Compra**: el dinero sale de caja a `escrow`. No se puede comprometer dos
  veces la misma caja.
- **Venta**: la mercancía sale del almacén. No se puede vender dos veces el
  mismo stock.

Al cancelar o caducar, `game.release_order()` devuelve lo que quede sin
ejecutar. Sin esto, un jugador podría poner mil órdenes de compra con la caja
de una sola.

### `utility_meters` — la red

La electricidad y el agua **no se almacenan ni se negocian**: quien las produce
las vierte a la red y cobra al precio vigente; quien las consume recibe factura
cada tick. El precio se mueve solo con el desequilibrio del tick anterior,
acotado entre el 40 % y el 400 % del precio ancla.

Es más simple que un segundo libro de órdenes y modela mejor lo que es: un
suministro continuo, no un bien que guardas en un almacén.

### `tick_log` — idempotencia

`fn_world_tick()` empieza insertando `(world_id, tick)` en esta tabla. Si la
inserción choca con la clave primaria, ese tick ya se ejecutó y la función pasa
al siguiente mundo sin hacer nada. Eso permite tener pg_cron y una Edge
Function disparando a la vez sin duplicar producción ni cobrar dos veces.

## Reglas de acceso

| | anon | authenticated | vía RPC |
|---|---|---|---|
| Estado del mundo (mapa, mercado, distritos, hacienda) | leer | leer | — |
| Almacén, libro mayor, avisos | ✗ | leer **lo propio** | — |
| Cualquier escritura económica | ✗ | ✗ | ✓ |
| `profiles.display_name`, `avatar_url`, `bio` | ✗ | escribir lo propio | — |

No existe ni una sola política de `INSERT`, `UPDATE` o `DELETE` sobre las
tablas económicas. Las funciones RPC son `SECURITY DEFINER`, así que corren
como el dueño de las tablas y se saltan RLS legítimamente, después de validar
`auth.uid()` contra la propiedad de la empresa.
