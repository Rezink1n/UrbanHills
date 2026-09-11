-- =============================================================================
-- UrbanHills · 0009 · Recetas y patrón de consumo de la población
-- -----------------------------------------------------------------------------
-- Los caudales de salida son la palanca de balanceo: tocar uno cambia el margen
-- de toda su cadena. tools/check-balance.sql imprime el margen por hora de cada
-- receta; lo sano es un margen entre el 20 % y el 55 % y una amortización de
-- entre 60 y 350 horas.
-- =============================================================================

insert into recipes
  (id, building_code, name, output_code, output_qty, minutes,
   labor_factor, power_use, water_use, min_level, sort_order)
values
  -- Extracción
  ('quarry_stone',    'quarry',      'Extraer piedra',      'stone',      24,   20, 1.00,    40,    0, 1, 1),
  ('quarry_sand',     'quarry',      'Extraer arena',       'sand',       26,   20, 0.90,    30,    0, 1, 2),
  ('clay_clay',       'clay_pit',    'Extraer arcilla',     'clay',       20,   20, 1.00,    30,   20, 1, 1),
  ('sawmill_timber',  'sawmill',     'Talar y descortezar', 'timber',     12,   20, 1.00,    50,    0, 1, 1),
  ('iron_ore',        'iron_mine',   'Extraer mineral',     'iron_ore',   14,   20, 1.00,   220,   40, 1, 1),
  ('coal_coal',       'coal_mine',   'Extraer carbón',      'coal',       14,   20, 1.00,   220,   40, 1, 1),
  ('oil_crude',       'oil_well',    'Bombear crudo',       'crude_oil',  18,   20, 1.00,   340,   60, 1, 1),
  ('farm_crops',      'farm',        'Cosechar',            'crops',      16,   30, 1.00,    90,  800, 1, 1),
  ('water_supply',    'water_plant', 'Potabilizar',         'water',    1200,   10, 1.00,   240,    0, 1, 1),

  -- Energía
  ('solar_power',     'solar_farm',  'Generar (solar)',     'power',    4200,   20, 1.00,     0,    0, 1, 1),
  ('wind_power',      'wind_farm',   'Generar (eólica)',    'power',    6500,   20, 1.00,     0,    0, 1, 1),
  ('coal_power',      'coal_plant',  'Generar (carbón)',    'power',   32000,   20, 1.00,     0,  400, 1, 1),

  -- Procesado
  ('cement',          'cement_plant','Calcinar cemento',    'cement',     12,   20, 1.00,   800,   40, 1, 1),
  ('brick',           'brickworks',  'Cocer ladrillo',      'brick',      10,   20, 1.00,   400,   40, 1, 1),
  ('glass',           'glassworks',  'Fundir vidrio',       'glass',      12,   20, 1.00,  1200,   80, 1, 1),
  ('steel',           'steel_mill',  'Colar acero',         'steel',      22,   30, 1.00,  4500,  300, 1, 1),
  ('lumber',          'lumber_mill', 'Aserrar tablones',    'lumber',     10,   20, 1.00,   300,   20, 1, 1),
  ('fuel',            'refinery',    'Refinar combustible', 'fuel',     7000,   30, 1.00,  3000,  400, 1, 1),
  ('plastic',         'refinery',    'Producir plástico',   'plastic',    48,   30, 1.00,  2500,  300, 1, 2),
  ('food',            'food_plant',  'Procesar alimento',   'food',        8,   20, 1.00,   600,  200, 1, 1),

  -- Manufactura
  ('concrete',        'concrete_plant',     'Amasar hormigón',   'concrete',     6, 20, 1.00,  120,  60, 1, 1),
  ('components',      'component_factory',  'Montar componentes','components',  60, 30, 1.00, 1800,  60, 1, 1),
  ('furniture',       'furniture_factory',  'Fabricar muebles',  'furniture',    8, 30, 1.00,  400,  30, 1, 1),
  ('electronics',     'electronics_factory','Ensamblar aparatos','electronics', 30, 30, 1.00, 3600,  60, 1, 1),
  ('machinery',       'machinery_factory',  'Fabricar maquinaria','machinery',  10, 60, 1.00, 7200, 100, 1, 1),

  -- Comercio (bienes que consume directamente la población)
  ('shop_groceries',  'corner_shop', 'Despachar la compra', 'groceries',  16,   20, 1.00,   100,   10, 1, 1),
  ('super_groceries', 'supermarket', 'Despachar la compra', 'groceries',  50,   20, 1.00,   600,   40, 1, 1),
  ('restaurant_meals','restaurant',  'Servir menús',        'meals',      40,   20, 1.00,   300,   60, 1, 1),
  ('cinema_leisure',  'cinema',      'Programar sesiones',  'leisure',    26,   20, 1.00,   900,   20, 1, 1),
  ('mall_leisure',    'mall',        'Ocio y restauración', 'leisure',    90,   20, 0.60,  2400,   80, 1, 1),
  ('mall_groceries',  'mall',        'Gran superficie',     'groceries', 110,   20, 0.60,  2000,   80, 1, 2)
on conflict (id) do update set
  building_code = excluded.building_code, name = excluded.name,
  output_code = excluded.output_code, output_qty = excluded.output_qty,
  minutes = excluded.minutes, labor_factor = excluded.labor_factor,
  power_use = excluded.power_use, water_use = excluded.water_use,
  min_level = excluded.min_level, sort_order = excluded.sort_order;

-- -----------------------------------------------------------------------------
-- Entradas de cada receta (sólo recursos almacenables)
-- -----------------------------------------------------------------------------
delete from recipe_inputs;
insert into recipe_inputs (recipe_id, resource_code, qty) values
  ('coal_power',      'coal',        20),

  ('cement',          'stone',       18),
  ('brick',           'clay',        15),
  ('glass',           'sand',        12),
  ('steel',           'iron_ore',    24),
  ('steel',           'coal',        12),
  ('lumber',          'timber',      14),
  ('fuel',            'crude_oil',   90),
  ('plastic',         'crude_oil',   50),
  ('food',            'crops',       10),

  ('concrete',        'cement',       3),
  ('concrete',        'sand',         4),
  ('components',      'steel',        3),
  ('components',      'plastic',    1.5),
  ('furniture',       'lumber',       5),
  ('furniture',       'components',   8),
  ('electronics',     'components',  40),
  ('electronics',     'glass',       20),
  ('electronics',     'plastic',      1),
  ('machinery',       'steel',       12),
  ('machinery',       'components', 100),
  ('machinery',       'electronics', 16),

  ('shop_groceries',  'food',       0.4),
  ('super_groceries', 'food',       1.4),
  ('restaurant_meals','food',       1.2),
  ('mall_groceries',  'food',         3);

-- -----------------------------------------------------------------------------
-- Qué consume cada clase social, por hogar y tick
-- -----------------------------------------------------------------------------
-- Esto es el sumidero de la economía: la única vía por la que entra dinero
-- nuevo al sistema desde fuera de las empresas. `necessity` mide cuánto castiga
-- a la felicidad no conseguirlo; `price_tolerance`, hasta qué múltiplo del
-- precio base está dispuesto a pagar ese hogar.

insert into consumption_profile (class, resource_code, qty_per_household, price_tolerance, necessity)
values
  ('low',  'groceries',   0.300, 0.90, 1.00),
  ('low',  'meals',       0.040, 0.85, 0.30),
  ('low',  'leisure',     0.020, 0.85, 0.30),
  ('low',  'furniture',   0.004, 0.80, 0.20),
  ('low',  'electronics', 0.003, 0.85, 0.25),

  ('mid',  'groceries',   0.380, 1.10, 1.00),
  ('mid',  'meals',       0.140, 1.10, 0.45),
  ('mid',  'leisure',     0.100, 1.10, 0.40),
  ('mid',  'furniture',   0.010, 1.05, 0.25),
  ('mid',  'electronics', 0.008, 1.10, 0.30),

  ('high', 'groceries',   0.500, 1.40, 1.00),
  ('high', 'meals',       0.320, 1.50, 0.55),
  ('high', 'leisure',     0.260, 1.50, 0.55),
  ('high', 'furniture',   0.022, 1.40, 0.35),
  ('high', 'electronics', 0.018, 1.45, 0.40)
on conflict (class, resource_code) do update set
  qty_per_household = excluded.qty_per_household,
  price_tolerance   = excluded.price_tolerance,
  necessity         = excluded.necessity;
