-- =============================================================================
-- Prueba de seguridad: ¿aguanta RLS lo que dice aguantar?
--
-- Se ejecuta como el rol `authenticated`, que es exactamente el que usa un
-- jugador a través de PostgREST. Comprueba que puede leer el mundo, que NO
-- puede tocar la economía a mano, que no ve el almacén ajeno, y que las RPC
-- sí funcionan.
--
--   psql -d urbanhills_test -f tools/rls-test.sql
-- =============================================================================
\set ON_ERROR_STOP on

-- --- Preparación como dueño -------------------------------------------------
do $$
declare
  v_world uuid;
  v_u1 uuid := gen_random_uuid();
  v_u2 uuid := gen_random_uuid();
begin
  delete from worlds where code = 'rls';
  v_world := game.generate_world('rls', 'Prueba RLS', 777, 16, 16, 8, 250000);

  -- Correos únicos por ejecución: así la prueba se puede repetir sobre la misma
  -- base sin tener que limpiarla antes.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_u1, 'uno+' || substr(v_u1::text, 1, 8) || '@example.com', '{"username":"uno"}'),
         (v_u2, 'dos+' || substr(v_u2::text, 1, 8) || '@example.com', '{"username":"dos"}');

  perform set_config('request.jwt.claim.sub', v_u1::text, false);
  perform rpc_found_company('rls', 'Empresa Uno');
  perform game.inventory_add(
    (select id from companies where owner_id = v_u1), 'stone', 100, 10);

  perform set_config('request.jwt.claim.sub', v_u2::text, false);
  perform rpc_found_company('rls', 'Empresa Dos');

  perform set_config('urbanhills.u1', v_u1::text, false);
  perform set_config('urbanhills.u2', v_u2::text, false);
end $$;

-- --- Ahora, como jugador ----------------------------------------------------
set role authenticated;

do $$
declare
  v_u1  uuid := current_setting('urbanhills.u1')::uuid;
  v_u2  uuid := current_setting('urbanhills.u2')::uuid;
  v_co1 uuid;
  v_n   integer;
  v_res jsonb;
  v_plot uuid;
begin
  -- Jugador 2 autenticado.
  perform set_config('request.jwt.claim.sub', v_u2::text, false);
  select id into v_co1 from companies where owner_id = v_u1;

  ---------------------------------------------------------------- lectura pública
  select count(*) into v_n from plots p
    join worlds w on w.id = p.world_id where w.code = 'rls';
  if v_n = 0 then raise exception 'FALLO: un jugador no puede ver el mapa'; end if;
  raise notice 'ok: el mapa es público (% parcelas)', v_n;

  select count(*) into v_n from companies;
  if v_n < 2 then raise exception 'FALLO: no se ven las empresas rivales'; end if;
  raise notice 'ok: las empresas rivales son visibles';

  ------------------------------------------------------------- almacén ajeno
  select count(*) into v_n from inventories where company_id = v_co1;
  if v_n <> 0 then
    raise exception 'FALLO: se ve el almacén de otra empresa (% filas)', v_n;
  end if;
  raise notice 'ok: el almacén ajeno está oculto';

  select count(*) into v_n from ledger_entries where company_id = v_co1;
  if v_n <> 0 then raise exception 'FALLO: se ve el libro mayor ajeno'; end if;
  raise notice 'ok: el libro mayor ajeno está oculto';

  ----------------------------------------------------------- escritura directa
  begin
    update companies set cash = 999999999 where owner_id = v_u2;
    raise exception 'FALLO CRÍTICO: un jugador puede regalarse dinero';
  exception
    when insufficient_privilege then raise notice 'ok: no puede tocar su caja a mano';
    when others then
      if sqlstate = 'P0001' and sqlerrm like 'FALLO%' then raise;
      end if;
      raise notice 'ok: no puede tocar su caja a mano (%)', sqlstate;
  end;

  begin
    update plots set owner_company_id = null where owner_company_id is not null;
    raise exception 'FALLO CRÍTICO: un jugador puede expropiar parcelas';
  exception
    when insufficient_privilege then raise notice 'ok: no puede expropiar parcelas';
    when others then
      if sqlstate = 'P0001' and sqlerrm like 'FALLO%' then raise;
      end if;
      raise notice 'ok: no puede expropiar parcelas (%)', sqlstate;
  end;

  begin
    insert into inventories (company_id, resource_code, qty)
    values ((select id from companies where owner_id = v_u2), 'steel', 10000);
    raise exception 'FALLO CRÍTICO: un jugador puede inventarse stock';
  exception
    when insufficient_privilege then raise notice 'ok: no puede inventarse stock';
    when others then
      if sqlstate = 'P0001' and sqlerrm like 'FALLO%' then raise;
      end if;
      raise notice 'ok: no puede inventarse stock (%)', sqlstate;
  end;

  begin
    update building_types set build_cost = 1;
    raise exception 'FALLO CRÍTICO: un jugador puede reescribir el catálogo';
  exception
    when insufficient_privilege then raise notice 'ok: el catálogo es de sólo lectura';
    when others then
      if sqlstate = 'P0001' and sqlerrm like 'FALLO%' then raise;
      end if;
      raise notice 'ok: el catálogo es de sólo lectura (%)', sqlstate;
  end;

  ------------------------------------------------------------------- el tick
  begin
    perform fn_world_tick('rls');
    raise exception 'FALLO CRÍTICO: un jugador puede avanzar el mundo a voluntad';
  exception
    when insufficient_privilege then raise notice 'ok: el tick no es invocable por jugadores';
    when others then
      if sqlstate = 'P0001' and sqlerrm like 'FALLO%' then raise;
      end if;
      raise notice 'ok: el tick no es invocable por jugadores (%)', sqlstate;
  end;

  -------------------------------------------------------- las RPC sí funcionan
  -- Acotado al mundo de la prueba: en una base compartida con otros mundos,
  -- coger "cualquier parcela libre" puede caer en una partida donde este
  -- jugador no tiene empresa.
  select p.id into v_plot
    from plots p
    join worlds w on w.id = p.world_id
   where w.code = 'rls'
     and p.owner_company_id is null and p.for_sale and p.zoning <> 'protected'
   order by p.land_value asc limit 1;

  v_res := rpc_buy_plot(v_plot);
  raise notice 'ok: la RPC de compra funciona (pagado %)', v_res ->> 'paid';

  if (select owner_company_id from plots where id = v_plot)
     <> (select id from companies where owner_id = v_u2) then
    raise exception 'FALLO: la compra no asignó la parcela';
  end if;

  -- Y no permite comprar lo que no está en venta.
  begin
    perform rpc_buy_plot(v_plot);
    raise exception 'FALLO: dejó comprar dos veces la misma parcela';
  exception when sqlstate 'P0001' then
    raise notice 'ok: no se puede comprar lo ya comprado';
  end;

  raise notice '=== Prueba de seguridad superada ===';
end $$;

reset role;
