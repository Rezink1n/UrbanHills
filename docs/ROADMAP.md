# Estado y plan

Lo que hay construido hoy, y por dónde seguir. Se actualiza según avanza.

---

## ✅ Listo y probado

**Base de datos** — 15 migraciones que aplican de cero sin errores sobre
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

- Despliegue a GitHub Pages sin paso de compilación.
- CI que aplica las migraciones de cero, corre la prueba de humo, imprime el
  balanceo y verifica que el catálogo exportado no se ha quedado atrás.

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
- **La ocupación de oficinas es una aproximación**: se calcula con la tasa de
  empleo del distrito, no con demanda real de metros.
- **La mano de obra no cruza distritos.** La cobertura de transporte debería
  ampliar el radio de contratación y todavía no lo hace.
- **El impuesto de sociedades no existe.** Se recauda IBI y cuotas sociales; el
  beneficio no se grava porque no se lleva cuenta de resultados por periodo.
- **El modo demo es una simplificación** y puede desviarse del comportamiento
  real: no tiene casación entre jugadores ni el modelo social completo.
- **Los textos de la interfaz están en el código**, no en ficheros de idioma.
