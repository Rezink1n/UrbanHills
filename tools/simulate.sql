-- =============================================================================
-- Simulación larga sin jugadores: ¿hacia dónde deriva la ciudad si nadie toca
-- nada? Sirve para ver si el balanceo tiene un punto de equilibrio o se va a
-- un extremo. Uso:
--    psql -d urbanhills_test -v ticks=60 -f tools/simulate.sql
-- =============================================================================
\set ON_ERROR_STOP on
\if :{?ticks} \else \set ticks 60 \endif

-- psql no sustituye variables dentro de un bloque dollar-quoted, así que el
-- número de ticks se pasa por GUC.
select set_config('sim.ticks', :'ticks', false);

do $$
declare
  v_world uuid;
  v_n     int := current_setting('sim.ticks')::int;
begin
  delete from worlds where code = 'sim';
  v_world := game.generate_world('sim', 'Simulación', 20260911, 48, 48, 8, 250000);

  for i in 1..v_n loop
    update worlds set last_tick_at = null where id = v_world;
    perform fn_world_tick('sim');
  end loop;
end $$;

select h.tick,
       sum(h.population)                 as poblacion,
       round(avg(h.happiness), 1)        as felicidad,
       round(avg(h.pollution), 1)        as contaminacion,
       round(avg(h.employment_rate) * 100, 1) as empleo_pct,
       round(avg(h.land_value_index), 1) as indice_suelo
  from district_stats_history h
  join districts d on d.id = h.district_id
  join worlds w on w.id = d.world_id
 where w.code = 'sim'
   and h.tick % greatest(1, (:ticks / 15)) = 0
 group by h.tick
 order by h.tick;
