-- =============================================================================
-- Hoja de balanceo: margen por hora de cada receta a plantilla completa y
-- precios base. Es la comprobación de que el catálogo de 0008/0009 tiene
-- sentido económico antes de que nadie juegue.
--
--   psql -d urbanhills_test -f tools/check-balance.sql
--
-- Lo que hay que mirar:
--   · margen  > 0 en todas las filas. Una receta a pérdidas es contenido muerto.
--   · margen% entre el 20 % y el 55 %. Por encima, la receta rompe el juego;
--     por debajo, no compensa el riesgo.
--   · amortización razonable (decenas de horas, no miles).
-- =============================================================================
\set ON_ERROR_STOP on
\pset numericlocale off

with base as (
  select r.id, r.name as receta, bt.name as edificio, bt.category,
         r.minutes,
         60.0 / r.minutes                                   as lotes_hora,
         r.output_qty * 60.0 / r.minutes                     as uds_hora,
         r.output_qty * 60.0 / r.minutes * res.base_price    as ingreso,
         bt.jobs * bt.base_wage * 12                         as salarios,
         bt.upkeep_per_tick * 12                             as mantenimiento,
         (r.power_use * (select base_price from resources where code = 'power')
          + r.water_use * (select base_price from resources where code = 'water'))
           * 60.0 / r.minutes                                as suministros,
         bt.build_cost
    from recipes r
    join building_types bt on bt.code = r.building_code
    join resources res     on res.code = r.output_code
),
ins as (
  select r.id,
         coalesce(sum(ri.qty * 60.0 / r.minutes * res.base_price), 0) as entradas
    from recipes r
    left join recipe_inputs ri on ri.recipe_id = r.id
    left join resources res    on res.code = ri.resource_code
   group by r.id
)
select
  b.edificio,
  b.receta,
  round(b.ingreso)                                          as "ingreso/h",
  round(i.entradas)                                         as "entradas/h",
  round(b.salarios)                                         as "salarios/h",
  round(b.suministros + b.mantenimiento)                    as "otros/h",
  round(b.ingreso - i.entradas - b.salarios
        - b.suministros - b.mantenimiento)                  as "margen/h",
  round((b.ingreso - i.entradas - b.salarios - b.suministros - b.mantenimiento)
        / nullif(b.ingreso, 0) * 100)                       as "margen%",
  case when (b.ingreso - i.entradas - b.salarios - b.suministros - b.mantenimiento) > 0
       then round(b.build_cost
                  / (b.ingreso - i.entradas - b.salarios - b.suministros - b.mantenimiento))
       else null end                                        as "amortiza_h"
from base b
join ins i on i.id = b.id
order by
  (b.ingreso - i.entradas - b.salarios - b.suministros - b.mantenimiento) asc;
