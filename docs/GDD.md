# UrbanHills — Documento de Diseño de Juego (GDD)

> Versión 0.1 — documento vivo. Todo lo que aquí se describe es la visión objetivo;
> el estado real de implementación está en [ROADMAP.md](./ROADMAP.md).

---

## 1. Concepto

**UrbanHills** es un juego de simulación económica y urbana **online, persistente y multijugador**,
jugado en el navegador. Los jugadores dirigen empresas que compran **terreno**, construyen sobre él
y compiten por el desarrollo de una ciudad compartida levantada sobre colinas.

La referencia obvia es *Sim Companies*, pero el enfoque es distinto:

| Sim Companies | UrbanHills |
|---|---|
| El mapa es decorativo; importa la cadena productiva | **El territorio es el recurso escaso central** |
| Demanda abstracta generada por el servidor | La demanda la genera una **población simulada** que vive en la ciudad |
| Cada jugador opera aislado | Las decisiones de un jugador **alteran el barrio del vecino** (contaminación, tráfico, valor del suelo) |
| Sin capa política | **Capa municipal**: impuestos, presupuesto, alcaldía electa |

La frase que resume el juego: *no construyes una empresa dentro de un mercado, construyes
una ciudad que **es** el mercado.*

---

## 2. Pilares de diseño

1. **El suelo manda.** Cada parcela es única: altitud, pendiente, vistas, distancia al centro,
   vecinos. Comprar bien es la primera decisión estratégica y la que más se paga a largo plazo.
2. **La ciudad está viva.** Los ciudadanos no son un número: se mudan, buscan empleo, consumen,
   se quejan del ruido y se van si el barrio empeora. Son la demanda y la mano de obra.
3. **Las externalidades son jugables.** Una acería sube el empleo y hunde el valor del suelo a su
   alrededor. Un parque no produce nada y revaloriza cuatro manzanas. El conflicto entre
   rentabilidad privada y calidad urbana es el corazón del juego.
4. **Tiempo real lento.** El mundo avanza en *ticks* de servidor (por defecto 5 min). No es un
   clicker: es un juego de decisiones espaciadas, revisable dos o tres veces al día.
5. **Economía cerrada.** No hay dinero que aparezca de la nada: todo euro entra al sistema vía
   consumo de la población y gasto municipal, y sale vía costes, salarios e impuestos.

---

## 3. El mundo

### 3.1 Estructura del territorio

El mundo es una **retícula de parcelas** (por defecto 64 × 64 = 4.096) agrupadas en **distritos**.

Cada parcela tiene:

| Atributo | Descripción | Efecto de juego |
|---|---|---|
| `elevation` | 0–100, generado con ruido procedural | Coste de construcción y **vistas** |
| `slope` | Desnivel respecto a las vecinas | Pendiente alta = penalización de coste, prohibido para industria pesada |
| `terrain` | `water`, `lowland`, `hill`, `ridge`, `forest`, `rock` | Restringe qué se puede construir |
| `zoning` | `residential`, `commercial`, `industrial`, `civic`, `mixed`, `protected` | La define el municipio, no el jugador |
| `base_land_value` | Valor intrínseco (centralidad + vistas + terreno) | Suelo de precio |
| `land_value` | Valor dinámico recalculado cada tick | Precio de compra/venta e impuestos |

El **valor del suelo** es la variable más importante del juego y se recalcula cada tick como:

```
land_value = base_land_value
           × f(servicios del distrito)
           × f(prestigio de los edificios vecinos)
           × f(contaminación y ruido en radio 3)
           × f(accesibilidad / transporte)
           × f(escasez: % de parcelas libres en el distrito)
```

### 3.2 Distritos

Un distrito agrupa ~64 parcelas y mantiene sus propias estadísticas: población, empleo,
felicidad, contaminación, criminalidad, cobertura de servicios, alquiler medio e índice de
valor del suelo. Los distritos son la unidad de la **simulación social** y la unidad
**electoral**.

---

## 4. El jugador

### 4.1 Empresa

Cada cuenta funda **una empresa** por mundo: nombre, sede (parcela HQ), caja, reputación y
calificación crediticia. La empresa es el avatar económico del jugador.

### 4.2 Progresión

No hay niveles artificiales. La progresión es económica y espacial:

1. **Fase 1 — Solar.** Capital inicial. Se compra 1–2 parcelas baratas en la periferia y se
   levanta extracción básica (cantera, aserradero, pozo).
2. **Fase 2 — Cadena.** Se procesan materias primas (cemento, acero, vidrio) y se vende a otros
   jugadores que construyen.
3. **Fase 3 — Renta.** Se construye residencial y comercial: ingresos recurrentes por alquiler,
   dependientes de la calidad del barrio. Aquí empieza el juego urbano de verdad.
4. **Fase 4 — Ciudad.** Concesiones municipales, infraestructura, presión política, compra
   estratégica de suelo antes de que el municipio recalifique.

### 4.3 Reputación

Construir vivienda social, parques o infraestructura sube reputación; contaminar, especular con
suelo vacío o desahuciar la baja. La reputación afecta al coste del crédito, a los votos en las
elecciones municipales y al acceso a concesiones.

---

## 5. Economía

### 5.1 Cadenas de producción

Cuatro niveles (`tier`):

```
T0  EXTRACCIÓN     agua · piedra · arena · madera · hierro · carbón · petróleo · cultivo · electricidad
                              ↓
T1  PROCESADO      cemento · acero · vidrio · tablones · plásticos · combustible · alimentos · ladrillo
                              ↓
T2  MANUFACTURA    hormigón · componentes · muebles · electrónica · maquinaria
                              ↓
T3  CONSUMO        comida preparada · ocio · vivienda · salud · educación · transporte
```

Los bienes T3 no se almacenan: los **consume la población** cada tick. Ese consumo es la única
fuente real de dinero nuevo en el sistema (junto con el gasto municipal).

### 5.2 Mercado

Un **libro de órdenes** por recurso (compra/venta con precio límite), con motor de casación en
el servidor. Además:

- **Demanda NPC**: cada tick, los hogares emiten órdenes de compra automáticas de bienes T3 y
  alimentos, con un precio de reserva que depende de su clase social y felicidad.
- **Histórico de precios**: OHLCV por hora para gráficas.
- **Contratos** (fase posterior): acuerdos B2B recurrentes entre jugadores.

### 5.3 Trabajo

Cada edificio productivo necesita **empleados** de un nivel de cualificación. Los trabajadores
salen de la población del distrito y de los limítrofes. Si no hay mano de obra cualificada cerca,
el edificio produce por debajo de su capacidad. Los salarios los fija el jugador: salario alto =
más productividad y más felicidad; salario bajo = riesgo de rotación.

Esto cierra el bucle: **construir vivienda cerca de tu fábrica no es altruismo, es logística.**

---

## 6. Simulación de la ciudad

Cada tick, para cada distrito:

1. **Servicios.** Cobertura de salud, educación, seguridad, transporte y ocio en función de los
   edificios cívicos y su radio de influencia.
2. **Contaminación y ruido.** Emitidos por edificios industriales, propagados por radio con
   decaimiento, atenuados por parques y por la altitud (las colinas ventilan).
3. **Felicidad.** Función de servicios, contaminación, criminalidad, tasa de empleo,
   alquiler/ingreso y hacinamiento.
4. **Migración.** Si `felicidad > umbral` y hay vivienda libre, entra población. Si baja, la
   gente se va (y se vacían los locales comerciales del jugador que dependía de ellos).
5. **Consumo.** Los hogares compran bienes T3 en el mercado según su clase e ingresos.
6. **Fiscalidad.** IBI sobre `land_value`, impuesto de sociedades sobre beneficio, tasas de
   actividad. Recaudación → tesorería municipal.
7. **Gasto municipal.** Mantenimiento de edificios cívicos e infraestructura. Si el municipio
   entra en déficit, los servicios se degradan y la ciudad entera lo nota.

### 6.1 Clases sociales

Tres cohortes (`low`, `mid`, `high`) con distinto ingreso, patrón de consumo, exigencia de
servicios y tolerancia a la contaminación. Atraer clase alta revaloriza el suelo pero exige
servicios caros; la clase baja llena las fábricas.

---

## 7. Capa municipal

- **Tesorería** pública alimentada por impuestos.
- **Políticas**: tipos impositivos, reparto del presupuesto entre servicios, recalificación de
  suelo, límites de altura y de contaminación.
- **Alcaldía electa**: cada N días se celebran elecciones. Votan los ciudadanos simulados
  (ponderados por felicidad) y los jugadores. El alcalde controla las políticas durante su
  mandato.
- **Concesiones**: obras públicas licitadas a empresas de jugadores (metro, depuradora,
  hospital), pagadas con dinero público.

La capa municipal es lo que convierte un juego económico en un juego **político**.

---

## 8. Eventos del mundo

Aleatorios y anunciados: ola de calor (sube consumo eléctrico), boom migratorio, huelga,
subida del precio del petróleo, incendio en una colina, inspección ambiental. Duran varios ticks
y desplazan precios y felicidad.

---

## 9. Bucle de juego

```
                ┌──────────────────────────────────────────┐
                │                                          │
   comprar suelo → construir → producir → vender en mercado → caja
                │                                          │
                │            la ciudad reacciona           │
                │   (valor del suelo, población, servicios)│
                └──────────────────────────────────────────┘
```

Sesión típica del jugador (5–10 min, 2–3 veces al día): revisar caja y alertas, recoger
producción, reponer órdenes en el mercado, decidir una construcción, echar un ojo al mapa de
calor del valor del suelo.

---

## 10. Fuera de alcance en v0

Para evitar que el diseño se desborde, **no** entran en la primera versión jugable:

- Combate, sabotaje o cualquier mecánica PvP directa.
- Alianzas/corporaciones multi-jugador.
- Mercado con dinero real o cualquier monetización.
- Simulación de tráfico con pathfinding real (se aproxima con cobertura de transporte).
- Vista 3D. La primera versión es un mapa 2D cenital sobre canvas.
