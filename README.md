# UrbanHills

Juego online de simulación económica y urbana, jugado en el navegador. Los
jugadores dirigen empresas que compran **terreno**, construyen sobre él y
compiten por el desarrollo de una ciudad compartida levantada sobre colinas.

La referencia es *Sim Companies*, pero el enfoque es otro: aquí el mapa no es
decoración. El territorio es el recurso escaso, la demanda la genera una
población simulada que vive en la ciudad, y lo que construye un jugador cambia
el barrio del vecino.

> **No construyes una empresa dentro de un mercado: construyes una ciudad que
> *es* el mercado.**

---

## Probarlo en dos minutos

```bash
python3 -m http.server 8080
```

Abre <http://localhost:8080>. Arranca en **modo demo**: genera un mundo en tu
navegador y lo simula ahí mismo, sin ningún backend detrás. Puedes fundar
empresa, comprar suelo, construir y producir.

Para montar una partida multijugador de verdad, ver **[docs/SETUP.md](docs/SETUP.md)**.

---

## Cómo está montado

| Capa | Tecnología |
|---|---|
| Alojamiento | GitHub Pages (estático, sin compilación) |
| Cliente | HTML + CSS + JS con módulos ES nativos, cero dependencias |
| Base de datos | Supabase (Postgres 17) — **aquí vive toda la lógica** |
| Autenticación | Supabase Auth |
| Tiempo real | Supabase Realtime |
| Reloj del mundo | pg_cron, o Edge Function |

El principio que ordena todo lo demás: **el cliente no es de fiar**. Ninguna
tabla económica acepta escritura directa; todo pasa por funciones RPC que
validan reglas y caja dentro de una transacción. En un juego con mercado, esto
no es opcional.

```
repositorio/
├── index.html                 el juego entero arranca aquí
├── src/
│   ├── css/                   tokens · base · estructura
│   ├── js/
│   │   ├── core/              store · router · cliente supabase · utilidades
│   │   ├── data/              capa de datos (dos proveedores intercambiables)
│   │   ├── game/              generador de mundo · mapa en canvas · sincronía
│   │   ├── ui/                armazón de navegación
│   │   └── views/             una vista, un módulo
│   └── data/catalog.json      catálogo exportado desde las migraciones
├── supabase/
│   ├── migrations/            0001…0015, el juego de verdad
│   └── functions/world-tick/  disparador alternativo del tick
├── tools/                     pruebas, balanceo y exportación del catálogo
└── docs/                      diseño, arquitectura, modelo de datos, plan
```

---

## Documentación

| | |
|---|---|
| **[docs/GDD.md](docs/GDD.md)** | Diseño del juego: pilares, territorio, economía, ciudad, capa política |
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | Cómo encaja todo y por qué |
| **[docs/DATA-MODEL.md](docs/DATA-MODEL.md)** | Las 29 tablas y las reglas de acceso |
| **[docs/SETUP.md](docs/SETUP.md)** | Ponerlo en marcha, en local y en producción |
| **[docs/ROADMAP.md](docs/ROADMAP.md)** | Qué está hecho, qué viene y qué deuda hay |

---

## Comprobaciones

```bash
./tools/test-migrations.sh                                 # migraciones + prueba de humo
psql -d urbanhills_test -f tools/check-balance.sql         # margen de cada receta
psql -d urbanhills_test -v ticks=80 -f tools/simulate.sql  # deriva de la ciudad
node tools/export-catalog.mjs                              # reexportar el catálogo
```

La prueba de humo recorre el camino real de un jugador —fundar, comprar,
construir, producir, vender, casar en el mercado— y falla si la caja de alguna
empresa deja de cuadrar con su libro mayor.

---

## Estado

Base de datos, economía y simulación urbana funcionando y probadas. Cliente
jugable con mapa, mercado y panel de ciudad. Pendientes las ampliaciones de
edificio, la obra pública y las elecciones: ver
**[docs/ROADMAP.md](docs/ROADMAP.md)**.
