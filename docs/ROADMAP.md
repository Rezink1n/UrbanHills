# Estado y plan

Lo que hay construido hoy, y por dónde seguir. Se actualiza según avanza.

---

## 🟢 En marcha

El juego está **desplegado y funcionando**: proyecto de Supabase real, mundo
`alpha` de 64×64 generado, y el tick corriendo solo en pg_cron cada minuto.
Al escribir esto llevaba 87 ticks sin intervención, con la población en ~9.850
habitantes y la felicidad estabilizada en 47,8.

Rendimiento medido en el proyecto real:

| | |
|---|---|
| Un tick del mundo | 135–570 ms, mediana ~170 ms |
| Generar un mundo 64×64 | 28,6 s (operación única) |

Falta activar GitHub Pages y autorizar la URL del sitio en Supabase Auth: son
dos ajustes de panel, están en [SETUP.md](./SETUP.md#26-lo-que-queda-por-hacer-a-mano).

---

## ✅ Listo y probado

**Base de datos** — 20 migraciones que aplican de cero sin errores sobre
Postgres 17.

- Catálogo completo: 26 recursos, 43 edificios, 31 recetas, con cadenas de
  producción de cuatro niveles.
- Generación procedural del mundo: ruido de valor con interpolación bilineal,
  valle central, bandas de terreno por percentil (cualquier semilla da un mapa
  jugable), pendiente y vistas derivadas del relieve.
- Economía: libro mayor por empresa, almacén con coste medio ponderado,
  mercado con libro de órdenes y casación precio-tiempo, red de suministros
  para luz y agua con precio que reacciona a oferta y demanda.
- Simulación urbana: estadísticas por distrito, contaminación y servicios con
  derrame al vecindario, felicidad, migración, alquileres ligados al valor del
  suelo, hacienda municipal con IBI y cuotas sociales.
- API de acciones: 10 funciones RPC `SECURITY DEFINER`, con validación de
  propiedad, caja y reglas de emplazamiento.
- Seguridad: RLS activo y forzado en las 29 tablas, lectura pública del mundo,
  cero políticas de escritura directa.
- Tick idempotente por número de tick, programable con pg_cron o Edge Function.

**Cliente** — sin bundler, sin dependencias, módulos ES nativos.

- Mapa en canvas con desplazamiento, zoom anclado al puntero, sombreado de
  relieve y cinco capas temáticas.
- Vistas de mapa, empresa, mercado, ciudad y ayuda.
- Capa de datos con dos proveedores intercambiables: Supabase y modo demo.
- Modo demo jugable sin backend, con el catálogo real exportado de las
  migraciones.

**Infraestructura**

- Proyecto de Supabase creado, migrado y con el mundo generado.
- Despliegue a GitHub Pages sin paso de compilación.
- CI que aplica las migraciones de cero, corre la prueba de humo, imprime el
  balanceo y verifica que el catálogo exportado no se ha quedado atrás.

---

## 🐛 Lo que sólo apareció al arrancar el mundo real

Cuatro fallos que las pruebas locales no cazaron porque sólo se manifiestan con
un mundo completo y vacío de jugadores. Los cuatro están corregidos, y los tres
primeros tienen ya su prueba de regresión en `tools/smoke-test.sql`.

1. **La mayor demanda del juego era inalcanzable** (migración `0016`).
   `groceries`, `meals` y `leisure` estaban marcados como no almacenables
   pensando que se consumen en el acto, pero `rpc_place_order` rechaza los no
   almacenables. La población pedía más de mil cestas por tick y ningún jugador
   podía servirlas. Ahora lo único fuera del mercado es lo que va por red: luz
   y agua.

2. **Dependencia circular en los materiales** (migración `0017`). El acero
   necesita hormigón y ladrillo; el hormigón necesita acero; el ladrillo
   necesita acero. En un mundo nuevo no existía ninguno de los tres, así que la
   economía se quedaba congelada en la extracción para siempre. Se resolvió con
   **importaciones municipales**: el puerto vende cada tick un cupo limitado de
   materiales al 135 % del precio ancla. Además de desbloquear el arranque, pone
   un techo al precio —nadie puede estrangular el mercado del acero— y se apaga
   solo en cuanto la industria local es más barata.

3. **Una empresa disuelta dejaba basura** (migración `0018`). Sus edificios
   quedaban sin dueño, y como el municipio pagaba el mantenimiento de "los
   edificios sin empresa", se ponía a costear la fábrica de alguien que ya no
   juega. Sus parcelas, además, quedaban atrapadas: sin dueño y sin poder
   comprarse.

4. **Permisos de escritura colgando de la vista `market_prices`** (migración
   `0020`). El bucle que revocaba escrituras recorría tablas y se dejó las
   vistas. No era explotable —la vista lleva agregados, no es actualizable— pero
   sobraba.

Y uno en el cliente, que sólo se ve con datos de verdad: la ficha de empresa
desbordaba en móvil. La causa no estaba en esa vista sino en la maquetación:
`.page` usaba `max-width` con `margin: 0 auto`, y un elemento flex con márgenes
automáticos se dimensiona a `fit-content`, que nunca baja del ancho mínimo de su
contenido. Una tabla ancha estiraba la página entera.

---

## 🔜 Siguiente

Por orden de lo que más cambia el juego:

1. **Ampliar edificios (niveles 2 y 3).** La tabla ya lleva `level` y
   `max_level`, y la maquinaria existe como bien de capital. Falta la RPC
   `rpc_upgrade` y que el tick escale producción y consumos por nivel.
2. **Edificios cívicos de verdad.** Están en el catálogo y marcados como
   `municipal_only`, pero no hay forma de levantarlos: hace falta el flujo de
   obra pública pagada con la tesorería.
3. **Elecciones.** Las tablas están (`elections`, `election_candidates`,
   `election_votes`); falta el proceso: convocatoria, campaña, recuento
   ponderado por felicidad y toma de posesión con aplicación del programa.
4. **Gráficas de precio.** `price_history` ya acumula velas horarias; falta
   pintarlas.
5. **Notificaciones en vivo.** La tabla y el canal de Realtime existen; falta
   la bandeja en el cliente.
6. **Tutorial de las primeras cinco decisiones.** Ahora mismo un jugador nuevo
   se planta delante de 4.096 parcelas sin saber por dónde empezar.

---

## 🧊 Más adelante

- Contratos B2B recurrentes entre jugadores.
- Corporaciones: varios jugadores, una empresa.
- Préstamos y calificación crediticia (`credit_limit` ya está en la tabla).
- Eventos del mundo activos (`world_events` está creada y vacía).
- Transporte con recorridos reales en vez de cobertura por radio.
- Traducción a otros idiomas: hoy los textos están incrustados en las vistas.

---

## ⚠️ Deuda conocida

Cosas que funcionan pero que habrá que tocar:

- **El balanceo es un punto de partida, no un equilibrio probado.** Los
  márgenes salen entre el 21 % y el 70 % con amortizaciones de 65 a 364 horas
  (`tools/check-balance.sql`), pero nadie ha jugado una partida larga todavía.
- **El cupo de importación está puesto a ojo**: `greatest(15, 5000 / precio)`
  por tick. Con muchos jugadores puede quedarse corto y con pocos ser
  demasiado generoso. Hay que verlo con gente dentro.
- **Fijar `search_path` triplica el tiempo de generar un mundo** (9,6 s → 28,6 s),
  porque una función con cláusula SET no se puede incrustar en la consulta que
  la llama y las de ruido se ejecutan decenas de miles de veces. Se aceptó
  porque generar un mundo es una operación única y el tick —medido— no se
  entera. Si algún día hay que generar mundos a menudo, aquí hay 19 segundos.
- **La ocupación de oficinas es una aproximación**: se calcula con la tasa de
  empleo del distrito, no con demanda real de metros.
- **La mano de obra no cruza distritos.** La cobertura de transporte debería
  ampliar el radio de contratación y todavía no lo hace.
- **El impuesto de sociedades no existe.** Se recauda IBI y cuotas sociales; el
  beneficio no se grava porque no se lleva cuenta de resultados por periodo.
- **El modo demo es una simplificación** y puede desviarse del comportamiento
  real: no tiene casación entre jugadores ni el modelo social completo.
- **Los textos de la interfaz están en el código**, no en ficheros de idioma.
