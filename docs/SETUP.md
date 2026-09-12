# Puesta en marcha

> **El proyecto ya está montado y conectado.** `src/js/config.js` apunta a un
> Supabase real con el mundo `alpha` generado (64×64, 4.096 parcelas) y el tick
> corriendo en pg_cron cada minuto. Lo único que queda por hacer a mano son los
> dos pasos del apartado 2.6.
>
> | | |
> |---|---|
> | Proyecto | `UrbanHills` (`nviwpcehgltwfhjnphas`, eu-west-1) |
> | URL | `https://nviwpcehgltwfhjnphas.supabase.co` |
> | Mundo | `alpha` · 64×64 · tick de 300 s |
>
> El resto de este documento sirve para levantar otra partida desde cero, o
> para entender qué hay montado.

---

## 1. Verlo funcionando ahora mismo

No hace falta nada instalado salvo Python o Node:

```bash
python3 -m http.server 8080
# o: npx serve .
```

Abre <http://localhost:8080>. Arranca en **modo demo**: genera un mundo en tu
navegador y lo simula ahí mismo, sin backend. La partida se guarda en
`localStorage` de ese navegador y el reloj va acelerado ×12 para que se vea
pasar algo en una sesión corta.

> No abras `index.html` con doble clic (`file://`): los módulos ES y el
> `fetch` del catálogo necesitan un servidor HTTP.

---

## 2. Montar la partida real

### 2.1 Crear el proyecto

1. Crea un proyecto en <https://supabase.com>.
2. Apunta la **Project URL** y la **anon/public key**
   (*Project Settings → API*).

### 2.2 Aplicar las migraciones

Con la CLI (recomendado):

```bash
npm install -g supabase
supabase link --project-ref <tu-ref>
supabase db push
```

O a mano: abre el **SQL Editor** del panel y pega el contenido de
`supabase/migrations/` **en orden numérico**, de `0001` a `0015`. El orden
importa: hay dependencias entre ficheros.

### 2.3 Generar el mundo

En el SQL Editor:

```sql
select game.generate_world(
  'alpha',            -- código del mundo (el que irá en config.js)
  'Alfa',             -- nombre visible
  20260911,           -- semilla: la misma semilla da siempre el mismo mapa
  64, 64,             -- ancho × alto en parcelas
  8,                  -- tamaño de distrito
  250000              -- capital inicial de cada jugador
);
```

Tarda unos segundos: genera 4.096 parcelas con su relieve, calcula pendientes y
vistas, crea los 64 distritos y arranca la hacienda municipal.

### 2.4 Poner en marcha el tick

**Opción A — pg_cron** (lo que hace la migración `0015` si la extensión está
disponible). Comprueba que quedó programado:

```sql
select jobname, schedule, active from cron.job;
```

**Opción B — Edge Function**, si prefieres control externo:

```bash
supabase functions deploy world-tick
supabase secrets set TICK_SECRET="$(openssl rand -hex 32)"
```

y llama a `POST https://<ref>.functions.supabase.co/world-tick` cada minuto
desde donde te venga bien, con la cabecera
`Authorization: Bearer <TICK_SECRET>`.

Para comprobar que el mundo avanza:

```sql
select code, current_tick, last_tick_at from worlds;
select tick, duration_ms, stats from tick_log order by tick desc limit 5;
```

### 2.5 Conectar el cliente

En `src/js/config.js`:

```js
export const SUPABASE_URL      = 'https://xxxxx.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOi...';
export const WORLD_CODE        = 'alpha';
```

La `anon key` es **pública por diseño** y puede vivir en el repositorio: sólo
sirve para hablar con PostgREST bajo las políticas de RLS. La `service_role
key` **nunca** entra aquí.

En *Authentication → URL Configuration* del panel, añade la URL de tu GitHub
Pages a **Site URL** y a **Redirect URLs**.

### 2.6 Despliegue: automático, con una condición

El flujo `.github/workflows/deploy.yml` publica el sitio solo. No hay que entrar
en *Settings → Pages*: `actions/configure-pages` lleva `enablement: true`, así
que activa Pages por API en su primera ejecución.

Qué hace, en orden:

1. **Comprueba el cliente**: sintaxis de los 22 módulos, que `catalog.json` sea
   JSON válido y no esté vacío, que exista todo lo que referencia `index.html`,
   que no haya rutas absolutas (romperían bajo `/UrbanHills/`), y avisa si se va
   a publicar sin credenciales de Supabase —es decir, en modo demo— por si es
   un descuido.
2. **Empaqueta** `index.html`, `.nojekyll` y `src/` en `_site`, y copia
   `index.html` como `404.html` para que cualquier ruta desconocida devuelva el
   juego (el router va por hash).
3. **Lo sirve bajo subdirectorio y lo comprueba**, replicando cómo lo sirve
   Pages en un repositorio de proyecto. Es ahí donde se ven las rutas mal
   puestas, no en la raíz.
4. **Activa Pages si hace falta y publica.**
5. **Comprueba que el sitio responde 200** y escribe la URL en el resumen del
   run.

Sólo se dispara si el commit toca algo que afecta al sitio (`index.html`,
`src/**` o el propio flujo): cambiar la documentación no provoca un despliegue.

> **La condición.** GitHub Pages en un repositorio **privado** exige plan de
> pago (Pro, Team o Enterprise). En el plan gratuito sólo se publica desde
> repositorios públicos. El flujo lo detecta antes de intentarlo y falla con un
> mensaje que explica las tres salidas: hacer el repositorio público, pasar a
> GitHub Pro, o publicar en Cloudflare Pages o Netlify, que sí admiten repos
> privados gratis.
>
> Si se hace público, la `anon key` de Supabase queda a la vista: eso es
> correcto y no es un problema. Es pública por diseño y lo único que permite es
> hablar con PostgREST bajo las políticas de RLS. La `service_role key` no está
> en el repositorio.

Y hay un requisito que no se puede automatizar: **el flujo tiene que estar en la
rama por defecto**. GitHub sólo reconoce los flujos que viven en `main`, así que
hasta que la rama de trabajo se fusione no hay despliegue ni botón de
*Run workflow*.

### 2.7 Lo único que sigue siendo manual

**Autorizar la URL del sitio en Supabase Auth.** En *Authentication → URL
Configuration*, poner la URL de Pages
(`https://rezink1n.github.io/UrbanHills/`) en **Site URL** y añadirla a
**Redirect URLs**. Sin esto, los enlaces de confirmación del correo devuelven al
jugador a `localhost` y el alta no se completa. No hay forma de hacerlo desde
código con las herramientas disponibles.

Conviene saber además que el SMTP que trae Supabase de serie está limitado a
unos pocos correos por hora: sirve para probar, no para abrir el juego al
público. Para eso hay que configurar un SMTP propio, o desactivar la
confirmación por correo en *Authentication → Providers → Email*.

---

## 3. Desarrollo en local con Supabase entero

```bash
supabase start          # Postgres + Auth + PostgREST + Studio en Docker
supabase db reset       # recrea la base y aplica todas las migraciones
```

Studio queda en <http://localhost:54323>. Para apuntar el cliente ahí, usa la
URL y la anon key que imprime `supabase start`.

---

## 4. Comprobar que todo está bien

```bash
./tools/test-migrations.sh          # migraciones + prueba de humo de cero
psql -d urbanhills_test -f tools/check-balance.sql    # margen de cada receta
psql -d urbanhills_test -v ticks=80 -f tools/simulate.sql   # deriva a 80 ticks
```

La prueba de humo recorre el camino real de un jugador —fundar, comprar,
construir, producir, vender— y falla si la caja de alguna empresa deja de
cuadrar con su libro mayor.

---

## 5. Tocar el catálogo del juego

Los recursos, edificios y recetas viven en `supabase/migrations/0008` y `0009`.
Ésa es la fuente de verdad. Después de cambiarlos hay que reexportar el JSON que
usa el modo demo:

```bash
node tools/export-catalog.mjs
```

La comprobación de CI falla si te olvidas.
