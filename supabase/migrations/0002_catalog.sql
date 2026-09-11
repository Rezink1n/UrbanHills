-- =============================================================================
-- UrbanHills · 0002 · Catálogo estático: recursos, tipos de edificio y recetas
-- -----------------------------------------------------------------------------
-- Estas tablas son *contenido*, no estado. Se leen mucho y se escriben sólo en
-- migraciones. Nunca se modifican desde el cliente.
-- =============================================================================

create table if not exists resources (
  code            text primary key,
  name            text        not null,
  category        resource_category not null,
  tier            smallint    not null check (tier between 0 and 3),
  unit            text        not null default 'ud',
  -- Precio ancla. El mercado puede alejarse de él, pero la demanda NPC y los
  -- precios de referencia de la UI parten de aquí.
  base_price      numeric(14,4) not null check (base_price > 0),
  -- Los servicios (tier 3) se consumen en el instante: no ocupan almacén.
  is_storable     boolean     not null default true,
  -- Volumen por unidad; determina cuánto cabe en un almacén.
  volume          numeric(10,4) not null default 1 check (volume >= 0),
  icon            text,
  sort_order      smallint    not null default 0
);

comment on table resources is 'Catálogo de recursos y servicios comerciables.';

create table if not exists building_types (
  code              text primary key,
  name              text not null,
  category          building_category not null,
  description       text,
  tier              smallint not null default 0 check (tier between 0 and 3),

  -- Construcción
  build_cost        numeric(14,2) not null check (build_cost >= 0),
  build_minutes     integer  not null default 30 check (build_minutes > 0),
  -- Materiales exigidos para levantarlo, además del dinero: {"cement": 40}
  build_materials   jsonb    not null default '{}'::jsonb,
  max_level         smallint not null default 3 check (max_level >= 1),
  upkeep_per_tick   numeric(12,2) not null default 0 check (upkeep_per_tick >= 0),

  -- Empleo
  jobs              integer  not null default 0 check (jobs >= 0),
  job_class         social_class not null default 'low',
  base_wage         numeric(12,2) not null default 0 check (base_wage >= 0),

  -- Consumos e impacto en el entorno (por nivel)
  power_use         numeric(10,2) not null default 0,
  water_use         numeric(10,2) not null default 0,
  pollution         numeric(10,2) not null default 0,
  noise             numeric(10,2) not null default 0,
  -- Cuánto revaloriza (o hunde) el suelo a su alrededor.
  prestige          numeric(10,2) not null default 0,
  effect_radius     smallint not null default 2 check (effect_radius >= 0),

  -- Servicio público que presta, si lo hay
  service           service_kind not null default 'none',
  service_strength  numeric(10,2) not null default 0,

  -- Residencial
  housing_capacity  integer  not null default 0 check (housing_capacity >= 0),
  housing_class     social_class,

  -- Comercial: cuántos hogares puede atender (define la demanda que capta)
  retail_capacity   integer  not null default 0 check (retail_capacity >= 0),

  -- Renta base por ocupante y tick (vivienda y oficinas). Se escala luego con
  -- el valor del suelo de la parcela: el mismo bloque renta más en buen barrio.
  base_rent         numeric(12,2) not null default 0 check (base_rent >= 0),

  -- Logística
  storage_capacity  numeric(14,2) not null default 0 check (storage_capacity >= 0),

  -- Restricciones de emplazamiento
  allowed_terrain   terrain_type[] not null default
                      '{lowland,hill,ridge,forest}'::terrain_type[],
  allowed_zoning    zoning_type[]  not null default
                      '{unzoned,residential,commercial,industrial,civic,mixed}'::zoning_type[],
  max_slope         smallint not null default 100,
  -- Sólo el municipio puede levantar los edificios cívicos.
  municipal_only    boolean  not null default false,
  min_reputation    numeric(6,2) not null default 0,

  icon              text,
  sort_order        smallint not null default 0
);

comment on table building_types is 'Catálogo de edificios construibles.';
comment on column building_types.build_materials is
  'Materiales necesarios además del dinero, como {"cement": 40, "steel": 10}.';

create table if not exists recipes (
  id              text primary key,
  building_code   text not null references building_types(code) on delete cascade,
  name            text not null,
  output_code     text not null references resources(code),
  output_qty      numeric(12,4) not null check (output_qty > 0),
  minutes         integer not null check (minutes > 0),
  -- Fracción de la plantilla que requiere. 1.0 = necesita el edificio al completo.
  labor_factor    numeric(6,3) not null default 1 check (labor_factor >= 0),
  -- La luz y el agua no pasan por el almacén: van por red y se facturan al
  -- precio vigente de la utility. Ver utility_meters en 0006.
  power_use       numeric(10,2) not null default 0,
  water_use       numeric(10,2) not null default 0,
  min_level       smallint not null default 1,
  sort_order      smallint not null default 0
);

comment on table recipes is 'Qué puede producir cada edificio y a qué ritmo.';

create table if not exists recipe_inputs (
  recipe_id       text not null references recipes(id) on delete cascade,
  resource_code   text not null references resources(code),
  qty             numeric(12,4) not null check (qty > 0),
  primary key (recipe_id, resource_code)
);

create index if not exists idx_recipes_building on recipes(building_code);
create index if not exists idx_resources_tier   on resources(tier, sort_order);
create index if not exists idx_btypes_category  on building_types(category, sort_order);
