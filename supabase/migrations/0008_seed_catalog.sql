-- =============================================================================
-- UrbanHills · 0008 · Contenido: recursos, edificios y recetas
-- -----------------------------------------------------------------------------
-- Los números de esta migración son el *balanceo* del juego. Están puestos con
-- una regla: a plantilla completa, el valor producido por tick debe rondar 2,5–3,5
-- veces el coste salarial. tools/check-balance.sql comprueba que se cumple.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Recursos
-- -----------------------------------------------------------------------------
insert into resources
  (code, name, category, tier, unit, base_price, is_storable, volume, icon, sort_order)
values
  -- Tier 0 · extracción y utilidades
  ('power',       'Electricidad',         'utility',  0, 'kWh',      0.08, false, 0,    '⚡', 10),
  ('water',       'Agua',                 'utility',  0, 'm³',       0.15, false, 0,    '💧', 11),
  ('stone',       'Piedra',               'raw',      0, 't',       12.00, true,  1.0,  '🪨', 12),
  ('sand',        'Arena',                'raw',      0, 't',        9.00, true,  1.0,  '⏳', 13),
  ('clay',        'Arcilla',              'raw',      0, 't',       10.00, true,  1.0,  '🧱', 14),
  ('timber',      'Madera en rollo',      'raw',      0, 'm³',      28.00, true,  1.4,  '🪵', 15),
  ('iron_ore',    'Mineral de hierro',    'raw',      0, 't',       35.00, true,  1.0,  '⛏️', 16),
  ('coal',        'Carbón',               'raw',      0, 't',       30.00, true,  1.1,  '🪨', 17),
  ('crude_oil',   'Petróleo',             'raw',      0, 'bbl',     55.00, true,  0.2,  '🛢️', 18),
  ('crops',       'Cultivo',              'raw',      0, 't',       40.00, true,  1.2,  '🌾', 19),

  -- Tier 1 · materiales
  ('cement',      'Cemento',              'material', 1, 't',       85.00, true,  0.9,  '🏗️', 20),
  ('brick',       'Ladrillo',             'material', 1, 'palé',    60.00, true,  1.2,  '🧱', 21),
  ('glass',       'Vidrio',               'material', 1, 'm²',      70.00, true,  0.3,  '🪟', 22),
  ('steel',       'Acero',                'material', 1, 't',      190.00, true,  0.8,  '🔩', 23),
  ('lumber',      'Tablones',             'material', 1, 'm³',      95.00, true,  1.3,  '🪚', 24),
  ('plastic',     'Plástico',             'material', 1, 't',      150.00, true,  1.6,  '🧴', 25),
  ('fuel',        'Combustible',          'material', 1, 'L',        1.40, true,  0.01, '⛽', 26),
  ('food',        'Alimentos',            'material', 1, 't',      120.00, true,  1.0,  '🥫', 27),

  -- Tier 2 · manufactura
  ('concrete',    'Hormigón',             'material',  2, 'm³',    160.00, true,  1.0,  '🏭', 30),
  ('components',  'Componentes',          'component', 2, 'ud',     45.00, true,  0.05, '⚙️', 31),
  ('furniture',   'Muebles',              'good',      2, 'ud',    320.00, true,  1.8,  '🛋️', 32),
  ('electronics', 'Electrónica',          'component', 2, 'ud',    260.00, true,  0.1,  '📱', 33),
  ('machinery',   'Maquinaria',           'component', 2, 'ud',   2000.00, true,  4.0,  '🚜', 34),

  -- Tier 3 · consumo final (lo compra la población, no se almacena)
  ('groceries',   'Compra diaria',        'good',      3, 'cesta',   24.00, false, 0,   '🛒', 40),
  ('meals',       'Comida preparada',     'service',   3, 'menú',    18.00, false, 0,   '🍽️', 41),
  ('leisure',     'Ocio',                 'service',   3, 'entrada', 22.00, false, 0,   '🎬', 42)
on conflict (code) do update set
  name       = excluded.name,
  category   = excluded.category,
  tier       = excluded.tier,
  unit       = excluded.unit,
  base_price = excluded.base_price,
  is_storable= excluded.is_storable,
  volume     = excluded.volume,
  icon       = excluded.icon,
  sort_order = excluded.sort_order;

-- -----------------------------------------------------------------------------
-- Tipos de edificio
-- -----------------------------------------------------------------------------
insert into building_types (
  code, name, category, tier, description,
  build_cost, build_minutes, build_materials, upkeep_per_tick,
  jobs, job_class, base_wage,
  power_use, water_use, pollution, noise, prestige, effect_radius,
  service, service_strength,
  housing_capacity, housing_class, retail_capacity, base_rent, storage_capacity,
  allowed_terrain, allowed_zoning, max_slope, municipal_only, min_reputation,
  icon, sort_order
) values

-- ── Extracción ───────────────────────────────────────────────────────────────
('quarry','Cantera','extraction',0,
 'Arranca piedra y arena de la roca viva. Ruidosa, polvorienta y el primer negocio de casi todo el mundo.',
 45000, 20, '{}', 8, 8,'low',3, 2,0, 6,9,-6,3,'none',0, 0,null,0,0,0,
 '{rock,hill,ridge}','{unzoned,industrial}',80,false,0,'⛰️',100),

('clay_pit','Arcillera','extraction',0,
 'Extracción de arcilla en terreno bajo. Barata de montar, margen corto.',
 32000, 20, '{}', 6, 6,'low',3, 2,2, 4,4,-4,2,'none',0, 0,null,0,0,0,
 '{lowland,forest}','{unzoned,industrial}',30,false,0,'🕳️',101),

('sawmill','Aserradero','extraction',0,
 'Tala controlada y descortezado. Sólo funciona sobre suelo forestal.',
 52000, 20, '{}', 8, 8,'low',3, 3,1, 3,7,-3,2,'none',0, 0,null,0,0,0,
 '{forest}','{unzoned,industrial}',60,false,0,'🌲',102),

('iron_mine','Mina de hierro','extraction',0,
 'Galería en la ladera. Mucho empleo poco cualificado y un paisaje arruinado.',
 140000, 20, '{"cement":20}', 15, 14,'low',3, 12,4, 14,14,-12,4,'none',0, 0,null,0,0,0,
 '{hill,ridge,rock}','{unzoned,industrial}',90,false,0,'⛏️',103),

('coal_mine','Mina de carbón','extraction',0,
 'Sucia y rentable mientras la ciudad queme carbón para tener luz.',
 130000, 20, '{"cement":20}', 15, 14,'low',3, 12,4, 18,12,-16,4,'none',0, 0,null,0,0,0,
 '{hill,rock}','{unzoned,industrial}',90,false,0,'🏴',104),

('oil_well','Pozo petrolífero','extraction',0,
 'Pocas manos, mucho dinero y un vecindario que lo va a notar.',
 260000, 20, '{"steel":15,"cement":25}', 30, 10,'mid',6, 18,6, 16,10,-14,4,'none',0, 0,null,0,0,0,
 '{lowland,rock}','{unzoned,industrial}',25,false,0,'🛢️',105),

('farm','Granja','extraction',0,
 'Cultivo en las vegas bajas. Ocupa mucho suelo para lo que renta.',
 60000, 30, '{}', 12, 12,'low',3, 4,40, 2,2,2,2,'none',0, 0,null,0,0,0,
 '{lowland}','{unzoned,industrial}',20,false,0,'🌾',106),

('water_plant','Captación de agua','extraction',0,
 'Toma y potabilización. Sin ella no hay hormigón, ni comida, ni ciudad.',
 95000, 10, '{"concrete":10}', 10, 4,'low',3, 30,0, 1,3,0,2,'utility',8, 0,null,0,0,0,
 '{lowland,water}','{unzoned,industrial,civic}',20,false,0,'🚰',107),

-- ── Energía ──────────────────────────────────────────────────────────────────
('solar_farm','Huerto solar','energy',1,
 'Silencioso y limpio. Rinde más cuanto más alto y despejado esté.',
 180000, 30, '{"glass":40,"steel":10}', 20, 2,'low',3, 0,0, 0,0,-1,2,'none',0, 0,null,0,0,0,
 '{lowland,hill,ridge,rock}','{unzoned,industrial}',40,false,0,'☀️',110),

('wind_farm','Parque eólico','energy',1,
 'Sólo en cresta, donde pega el viento. Molesta a la vista y al oído del vecino.',
 240000, 30, '{"steel":30,"concrete":20}', 30, 3,'low',3, 0,0, 0,12,-4,3,'none',0, 0,null,0,0,0,
 '{ridge}','{unzoned,industrial}',100,false,0,'🌬️',111),

('coal_plant','Central térmica','energy',1,
 'La forma más barata y más sucia de encender la ciudad.',
 520000, 40, '{"steel":60,"concrete":80}', 80, 20,'mid',6, 0,20, 45,20,-28,6,'none',0, 0,null,0,0,0,
 '{lowland,hill,rock}','{industrial}',30,false,0,'🏭',112),

-- ── Procesado ────────────────────────────────────────────────────────────────
('cement_plant','Cementera','processing',1,
 'Convierte piedra en la base material de toda la ciudad.',
 210000, 30, '{"steel":20}', 30, 16,'mid',6, 200,2, 22,16,-14,4,'none',0, 0,null,0,0,0,
 '{lowland,hill,rock}','{industrial}',40,false,0,'🏗️',120),

('brickworks','Ladrillería','processing',1,
 'Horno de ladrillo. Negocio modesto y estable.',
 120000, 25, '{"steel":8}', 20, 12,'low',3, 100,2, 12,10,-8,3,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial}',40,false,0,'🧱',121),

('glassworks','Vidriería','processing',1,
 'Arena y muchísimo calor. Imprescindible en cuanto la ciudad crece a lo alto.',
 200000, 30, '{"steel":15,"brick":20}', 25, 12,'mid',6, 300,4, 14,10,-8,3,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial}',40,false,0,'🪟',122),

('steel_mill','Acería','processing',1,
 'El corazón industrial. Emplea a un barrio entero y hunde su valor de suelo.',
 620000, 40, '{"concrete":80,"brick":40}', 60, 24,'mid',6, 750,10, 40,26,-26,6,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial}',30,false,0,'🔥',123),

('lumber_mill','Maderera','processing',1,
 'Tronco a tablón. La entrada natural del que empezó con un aserradero.',
 110000, 25, '{"brick":15}', 20, 10,'low',3, 75,1, 8,12,-6,3,'none',0, 0,null,0,0,0,
 '{lowland,forest,hill}','{industrial}',50,false,0,'🪚',124),

('refinery','Refinería','processing',1,
 'Combustible y plásticos. La instalación más rentable y más odiada del mapa.',
 980000, 60, '{"steel":90,"concrete":120}', 100, 16,'high',12, 500,12, 50,22,-34,7,'none',0, 0,null,0,0,0,
 '{lowland,rock}','{industrial}',20,false,10,'⚗️',125),

('food_plant','Procesadora alimentaria','processing',1,
 'Cultivo a alimento envasado. Alimenta a las tiendas de media ciudad.',
 175000, 30, '{"steel":15,"brick":25}', 25, 14,'low',3, 150,50, 8,8,-4,3,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial}',40,false,0,'🥫',126),

-- ── Manufactura ──────────────────────────────────────────────────────────────
('concrete_plant','Hormigonera','manufacturing',2,
 'Cemento, arena y agua. Todo el que construya te va a comprar.',
 155000, 25, '{"steel":20}', 25, 10,'low',3, 60,30, 10,14,-8,3,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial}',40,false,0,'🧮',130),

('component_factory','Fábrica de componentes','manufacturing',2,
 'La pieza intermedia que necesita todo lo demás.',
 380000, 40, '{"concrete":50,"steel":30}', 50, 18,'mid',6, 300,5, 16,12,-8,4,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial}',40,false,0,'⚙️',131),

('furniture_factory','Carpintería industrial','manufacturing',2,
 'Muebles para los pisos que están levantando los demás.',
 290000, 35, '{"concrete":40,"brick":30}', 45, 14,'mid',6, 130,3, 10,12,-4,3,'none',0, 0,null,0,0,0,
 '{lowland,hill,forest}','{industrial}',40,false,0,'🛋️',132),

('electronics_factory','Fábrica de electrónica','manufacturing',2,
 'Alto valor añadido y plantilla cualificada: necesita barrio bueno cerca.',
 720000, 50, '{"concrete":70,"steel":50,"glass":40}', 80, 20,'high',12, 600,6, 12,8,0,3,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial,mixed}',35,false,15,'📱',133),

('machinery_factory','Fábrica de maquinaria','manufacturing',2,
 'El bien de capital del juego: sin maquinaria no se amplía ningún edificio.',
 890000, 60, '{"concrete":90,"steel":70}', 100, 22,'high',12, 600,8, 20,18,-8,4,'none',0, 0,null,0,0,0,
 '{lowland,hill}','{industrial}',35,false,15,'🚜',134),

-- ── Residencial ──────────────────────────────────────────────────────────────
('social_housing','Vivienda protegida','residential',1,
 'Alquiler bajo y obligatorio agradecimiento municipal. Sube reputación.',
 240000, 40, '{"concrete":60,"brick":80}', 20, 0,'low',0, 10,30, 1,3,0,2,'none',0,
 70,'low',0,4,0,
 '{lowland,hill,ridge}','{residential,mixed}',50,false,0,'🏘️',140),

('townhouses','Adosados','residential',1,
 'Baja densidad, clase media y un césped diminuto. Revaloriza el barrio.',
 185000, 35, '{"brick":90,"lumber":40,"glass":20}', 18, 0,'mid',0, 8,25, 0,2,5,2,'none',0,
 24,'mid',0,9,0,
 '{lowland,hill,forest}','{residential,mixed}',45,false,0,'🏡',141),

('apartment_block','Bloque de apartamentos','residential',2,
 'La máquina de densidad. Mucha gente, mucha renta, mucha presión de servicios.',
 430000, 50, '{"concrete":140,"steel":40,"glass":60}', 45, 0,'mid',0, 25,90, 2,6,2,3,'none',0,
 90,'mid',0,8,0,
 '{lowland,hill}','{residential,mixed}',40,false,0,'🏢',142),

('hillside_villas','Villas en ladera','residential',3,
 'Pocos vecinos, mucha vista. Sólo funciona en alto y con el barrio impecable.',
 560000, 60, '{"concrete":80,"glass":90,"lumber":70}', 50, 0,'high',0, 15,40, 0,1,18,4,'none',0,
 10,'high',0,34,0,
 '{hill,ridge}','{residential}',70,false,25,'🏞️',143),

-- ── Comercial ────────────────────────────────────────────────────────────────
('corner_shop','Tienda de barrio','commercial',1,
 'El primer negocio de cara al público. Vive de los vecinos de dos manzanas.',
 48000, 15, '{"brick":20,"glass":10}', 8, 4,'low',3, 25,2, 1,3,3,2,'none',0,
 0,null,60,0,0,
 '{lowland,hill,ridge}','{commercial,residential,mixed}',60,false,0,'🏪',150),

('supermarket','Supermercado','commercial',2,
 'Escala de verdad en la compra diaria, a cambio de tráfico y aparcamiento.',
 260000, 35, '{"concrete":70,"steel":30,"glass":40}', 40, 18,'low',3, 150,8, 4,9,1,3,'none',0,
 0,null,400,0,0,
 '{lowland,hill}','{commercial,mixed}',35,false,0,'🛒',151),

('restaurant','Restaurante','commercial',1,
 'Convierte alimento en menús y una calle muerta en una calle viva.',
 95000, 20, '{"brick":30,"glass":20,"lumber":15}', 25, 12,'low',3, 75,15, 2,7,6,2,'leisure',4,
 0,null,120,0,0,
 '{lowland,hill,ridge}','{commercial,mixed}',50,false,0,'🍽️',152),

('cinema','Cine','commercial',2,
 'Ocio de masas. Poca gente lo echa en falta hasta que no lo tiene.',
 230000, 35, '{"concrete":60,"steel":25,"glass":30}', 35, 8,'low',3, 225,4, 1,8,8,3,'leisure',14,
 0,null,300,0,0,
 '{lowland,hill}','{commercial,mixed}',40,false,0,'🎬',153),

('mall','Centro comercial','commercial',3,
 'La pieza que reordena un distrito entero a su alrededor. Y su tráfico.',
 760000, 60, '{"concrete":200,"steel":90,"glass":120}', 90, 30,'mid',6, 600,20, 6,14,6,5,'leisure',18,
 0,null,1200,0,0,
 '{lowland,hill}','{commercial}',30,false,10,'🏬',154),

('office','Edificio de oficinas','commercial',2,
 'No fabrica nada: alquila metros a empresas y llena el barrio de sueldos medios.',
 480000, 45, '{"concrete":150,"steel":70,"glass":110}', 55, 40,'mid',6, 200,25, 1,5,10,3,'none',0,
 0,null,220,7,0,
 '{lowland,hill}','{commercial,mixed}',35,false,0,'🏙️',155),

-- ── Cívico (sólo el municipio) ───────────────────────────────────────────────
('school','Escuela','civic',1,
 'Sin escuelas no hay mano de obra cualificada. Es inversión, no gasto.',
 320000, 45, '{"concrete":90,"brick":70,"glass":40}', 60, 24,'mid',6, 80,30, 0,6,8,4,'education',30,
 0,null,0,0,0,
 '{lowland,hill,ridge}','{civic,residential,mixed}',45,true,0,'🏫',160),

('hospital','Hospital','civic',2,
 'Caro de mantener e imprescindible: la felicidad se desploma sin él.',
 880000, 70, '{"concrete":220,"steel":110,"glass":90}', 160, 60,'high',12, 500,90, 3,10,12,6,'health',45,
 0,null,0,0,0,
 '{lowland,hill}','{civic,mixed}',35,true,0,'🏥',161),

('police_station','Comisaría','civic',1,
 'Baja la criminalidad del entorno. Nadie la quiere justo debajo de casa.',
 260000, 35, '{"concrete":70,"brick":50}', 70, 30,'mid',6, 90,15, 0,7,2,5,'safety',32,
 0,null,0,0,0,
 '{lowland,hill,ridge}','{civic,residential,commercial,mixed}',50,true,0,'🚓',162),

('park','Parque','civic',0,
 'No produce nada y es de lo más rentable que puede hacer un municipio: limpia el aire y revaloriza cuatro manzanas.',
 90000, 20, '{"lumber":30}', 25, 4,'low',3, 5,60, -14,-8,16,4,'leisure',20,
 0,null,0,0,0,
 '{lowland,hill,ridge,forest}','{civic,residential,commercial,mixed,protected}',60,true,0,'🌳',163),

('bus_station','Estación de autobuses','civic',1,
 'Transporte barato. Amplía el radio desde el que tus fábricas pueden contratar.',
 180000, 30, '{"concrete":60,"steel":30}', 55, 14,'low',3, 60,10, 4,12,0,5,'transport',24,
 0,null,0,0,0,
 '{lowland,hill}','{civic,commercial,mixed}',30,true,0,'🚌',164),

('metro_station','Estación de metro','civic',3,
 'La infraestructura que más revaloriza el suelo del juego. Y la que más cuesta.',
 1400000, 90, '{"concrete":400,"steel":220,"machinery":10}', 200, 26,'mid',6, 900,40, 2,8,22,7,'transport',55,
 0,null,0,0,0,
 '{lowland,hill}','{civic,commercial,residential,mixed}',25,true,0,'🚇',165),

('water_treatment','Depuradora','civic',2,
 'Trata lo que la ciudad tira. Fea, olorosa y la única forma de crecer sin ahogarse.',
 520000, 50, '{"concrete":160,"steel":80}', 110, 18,'mid',6, 700,0, -22,10,-10,5,'utility',30,
 0,null,0,0,0,
 '{lowland,water}','{civic,industrial}',20,true,0,'♻️',166),

('recycling_plant','Planta de reciclaje','civic',2,
 'Rebaja la contaminación del distrito sin obligar a cerrar ninguna fábrica.',
 410000, 45, '{"concrete":120,"steel":70}', 95, 20,'low',3, 400,15, -28,14,-12,5,'utility',22,
 0,null,0,0,0,
 '{lowland,hill,rock}','{civic,industrial}',35,true,0,'🔄',167),

-- ── Logística ────────────────────────────────────────────────────────────────
('warehouse','Almacén','logistics',1,
 'Sin almacén no hay stock, y sin stock no hay forma de esperar a un buen precio.',
 85000, 20, '{"concrete":40,"steel":20}', 15, 4,'low',3, 15,2, 1,4,-2,2,'none',0,
 0,null,0,0,8000,
 '{lowland,hill}','{industrial,commercial,mixed}',40,false,0,'📦',170),

('logistics_hub','Centro logístico','logistics',2,
 'Almacén grande más flota propia: amplía tu alcance de contratación y de reparto.',
 340000, 40, '{"concrete":140,"steel":80}', 55, 12,'low',3, 120,8, 6,16,-6,4,'transport',12,
 0,null,0,0,32000,
 '{lowland,hill}','{industrial}',30,false,0,'🚚',171)

on conflict (code) do update set
  name = excluded.name, category = excluded.category, tier = excluded.tier,
  description = excluded.description, build_cost = excluded.build_cost,
  build_minutes = excluded.build_minutes, build_materials = excluded.build_materials,
  upkeep_per_tick = excluded.upkeep_per_tick, jobs = excluded.jobs,
  job_class = excluded.job_class, base_wage = excluded.base_wage,
  power_use = excluded.power_use, water_use = excluded.water_use,
  pollution = excluded.pollution, noise = excluded.noise, prestige = excluded.prestige,
  effect_radius = excluded.effect_radius, service = excluded.service,
  service_strength = excluded.service_strength, housing_capacity = excluded.housing_capacity,
  housing_class = excluded.housing_class, retail_capacity = excluded.retail_capacity,
  base_rent = excluded.base_rent, storage_capacity = excluded.storage_capacity,
  allowed_terrain = excluded.allowed_terrain, allowed_zoning = excluded.allowed_zoning,
  max_slope = excluded.max_slope, municipal_only = excluded.municipal_only,
  min_reputation = excluded.min_reputation, icon = excluded.icon,
  sort_order = excluded.sort_order;
