-- =============================================================================
-- Prueba de humo: una partida entera en miniatura.
-- Recorre el camino real de un jugador y comprueba que la economía cuadra.
-- =============================================================================
\set ON_ERROR_STOP on
\timing off

do $$
declare
  v_world   uuid;
  v_user    uuid := gen_random_uuid();
  v_co      uuid;
  v_plot    uuid;
  v_b       uuid;
  v_cash    numeric;
  v_res     jsonb;
  v_stone   numeric;
  v_user2   uuid := gen_random_uuid();
  v_co2     uuid;
  v_stone2  numeric;
  v_order   uuid;
  v_b2      uuid;
  v_plot2   uuid;
  v_groc    numeric;
begin
  raise notice '--- Generando mundo 32x32 ---';
  v_world := game.generate_world('test', 'Mundo de pruebas', 424242, 32, 32, 8, 250000);

  raise notice 'parcelas: %, distritos: %',
    (select count(*) from plots where world_id = v_world),
    (select count(*) from districts where world_id = v_world);

  -- Un jugador se registra: el trigger debe crearle el perfil.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user, 'probador@example.com', '{"username":"probador"}');

  if not exists (select 1 from profiles where id = v_user) then
    raise exception 'FALLO: el trigger no creó el perfil';
  end if;

  perform set_config('request.jwt.claim.sub', v_user::text, false);

  raise notice '--- Fundando empresa ---';
  v_res := rpc_found_company('test', 'Constructora del Cerro');
  v_co  := (v_res ->> 'company_id')::uuid;

  -- Una cantera necesita roca o colina, pendiente tolerable y suelo no protegido.
  select p.id into v_plot
    from plots p
   where p.world_id = v_world
     and p.terrain in ('rock','hill','ridge')
     and p.slope <= 80
     and p.zoning in ('unzoned','industrial')
     and p.owner_company_id is null and p.for_sale
   order by p.land_value asc
   limit 1;

  if v_plot is null then
    raise exception 'FALLO: el generador no produjo ninguna parcela apta para cantera';
  end if;

  raise notice '--- Comprando parcela ---';
  v_res := rpc_buy_plot(v_plot);
  raise notice 'pagado: %', v_res ->> 'paid';

  raise notice '--- Construyendo cantera ---';
  v_res := rpc_build(v_plot, 'quarry');
  v_b := (v_res ->> 'building_id')::uuid;

  -- El libro mayor y la caja tienen que coincidir siempre.
  select cash into v_cash from companies where id = v_co;
  if v_cash <> (select sum(amount) from ledger_entries where company_id = v_co) then
    raise exception 'FALLO: caja (%) no cuadra con el libro mayor (%)',
      v_cash, (select sum(amount) from ledger_entries where company_id = v_co);
  end if;
  raise notice 'caja tras la obra: % (cuadra con el libro mayor)', v_cash;

  -- No se puede producir mientras la obra está en marcha.
  begin
    perform rpc_produce(v_b, 'quarry_stone', 1, false);
    raise exception 'FALLO: dejó producir con la obra sin terminar';
  exception when sqlstate 'P0001' then
    raise notice 'ok: producir durante la obra está bloqueado';
  end;

  -- Se adelanta el reloj de la obra para no esperar 20 minutos reales.
  update buildings set ready_at = now() - interval '1 minute' where id = v_b;

  raise notice '--- Tick 1: entrega de obra ---';
  perform fn_world_tick('test');

  if (select status from buildings where id = v_b) <> 'idle' then
    raise exception 'FALLO: la obra no se entregó en el tick';
  end if;

  raise notice '--- Produciendo piedra ---';
  perform rpc_produce(v_b, 'quarry_stone', 2, false);
  update buildings set run_ends_at = now() - interval '1 second' where id = v_b;

  raise notice '--- Tick 2: cierre de producción ---';
  perform fn_world_tick('test');

  select qty into v_stone from inventories
   where company_id = v_co and resource_code = 'stone';
  raise notice 'piedra en almacén: %', coalesce(v_stone, 0);

  if coalesce(v_stone, 0) <= 0 then
    raise exception 'FALLO: la producción no entregó piedra (plantilla=%)',
      (select staffed_ratio from buildings where id = v_b);
  end if;

  raise notice '--- Mercado: vender piedra ---';
  perform rpc_place_order(v_world, 'stone', 'sell', round(v_stone / 2, 2), 11.0);

  if (select qty from inventories where company_id = v_co and resource_code = 'stone')
     > v_stone / 2 + 0.01 then
    raise exception 'FALLO: la orden de venta no retiró la mercancía del almacén';
  end if;

  raise notice '--- Mercado: el autocruce debe rechazarse sin perder mercancía ---';
  perform rpc_place_order(v_world, 'stone', 'buy', 1, 12.0);

  if exists (select 1 from market_trades
              where buyer_company_id = v_co and seller_company_id = v_co) then
    raise exception 'FALLO: una empresa se ha cruzado consigo misma';
  end if;
  if (select qty_filled from market_orders
       where company_id = v_co and side = 'sell' and resource_code = 'stone') > 0 then
    raise exception 'FALLO: el autocruce ha tocado la orden de venta propia';
  end if;
  raise notice 'ok: autocruce bloqueado y la venta sigue intacta';

  -- Se retira la compra propia para dejar el libro limpio.
  select id into v_order from market_orders
   where company_id = v_co and side = 'buy' and status in ('open','partial') limit 1;
  perform rpc_cancel_order(v_order);

  raise notice '--- Segunda empresa: casación real ---';
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_user2, 'rival@example.com', '{"username":"rival"}');
  perform set_config('request.jwt.claim.sub', v_user2::text, false);

  v_res := rpc_found_company('test', 'Promotora Rival');
  v_co2 := (v_res ->> 'company_id')::uuid;

  perform rpc_place_order(v_world, 'stone', 'buy', 10, 12.0);

  if not exists (select 1 from market_trades
                  where buyer_company_id = v_co2 and seller_company_id = v_co) then
    raise exception 'FALLO: la casación entre dos empresas no se ha producido';
  end if;

  select qty into v_stone2 from inventories
   where company_id = v_co2 and resource_code = 'stone';
  if coalesce(v_stone2, 0) < 10 then
    raise exception 'FALLO: el comprador no recibió la piedra (recibió %)', v_stone2;
  end if;

  -- La orden descansaba a 11, así que se ejecuta a 11 y no a 12: quien llega
  -- después no empeora el precio del que ya estaba.
  if (select max(unit_price) from market_trades where resource_code = 'stone') <> 11.0 then
    raise exception 'FALLO: la ejecución no respetó el precio de la orden en reposo';
  end if;
  raise notice 'ok: casadas % ud a % (comisión municipal incluida)',
    (select sum(qty) from market_trades), (select max(unit_price) from market_trades);

  perform set_config('request.jwt.claim.sub', v_user::text, false);

  -- ── Regresión 1 ────────────────────────────────────────────────────────────
  -- El puerto tiene que ofrecer materiales. Sin esto, en un mundo nuevo no se
  -- puede levantar nada que lleve ladrillo, acero u hormigón, porque los tres
  -- se necesitan entre sí en círculo.
  raise notice '--- Importaciones municipales ---';
  perform game.tick_imports(v_world);

  if not exists (select 1 from market_orders
                  where world_id = v_world and is_npc and side = 'sell'
                    and resource_code = 'brick' and status = 'open') then
    raise exception 'FALLO: el puerto no ofrece ladrillo; el mundo no puede arrancar';
  end if;
  raise notice 'ok: el puerto ofrece % materiales',
    (select count(*) from market_orders
      where world_id = v_world and is_npc and side='sell' and status='open');

  -- ── Regresión 2 ────────────────────────────────────────────────────────────
  -- Los bienes que consume la población tienen que ser vendibles. Estuvieron
  -- marcados como no almacenables, y `rpc_place_order` los rechazaba: la mayor
  -- demanda del juego era inalcanzable para cualquier jugador.
  raise notice '--- Bienes de consumo: producir y vender a la población ---';

  perform rpc_place_order(v_world, 'brick', 'buy', 20, 90.00);
  perform rpc_place_order(v_world, 'glass', 'buy', 10, 100.00);

  if (select coalesce(qty,0) from inventories
       where company_id = v_co and resource_code = 'brick') < 20 then
    raise exception 'FALLO: la importación de ladrillo no se ejecutó';
  end if;
  raise notice 'ok: materiales importados y en almacén';

  select p.id into v_plot2 from plots p
   where p.world_id = v_world and p.owner_company_id is null and p.for_sale
     and p.terrain in ('lowland','hill','ridge')
     and p.zoning in ('commercial','residential','mixed')
     and p.slope <= 60
   order by p.land_value asc limit 1;

  perform rpc_buy_plot(v_plot2);
  v_res := rpc_build(v_plot2, 'corner_shop');
  v_b2 := (v_res ->> 'building_id')::uuid;

  update buildings set ready_at = now() - interval '1 second' where id = v_b2;
  update worlds set last_tick_at = null where id = v_world;
  perform fn_world_tick('test');

  perform game.inventory_add(v_co, 'food', 40, 120);
  perform rpc_produce(v_b2, 'shop_groceries', 2, false);
  update buildings set run_ends_at = now() - interval '1 second' where id = v_b2;
  update worlds set last_tick_at = null where id = v_world;
  perform fn_world_tick('test');

  select qty into v_groc from inventories
   where company_id = v_co and resource_code = 'groceries';
  if coalesce(v_groc, 0) <= 0 then
    raise exception 'FALLO: la tienda no produjo cestas';
  end if;

  -- trunc, no round: pedir más de lo que hay debe fallar, y falla.
  perform rpc_place_order(v_world, 'groceries', 'sell', trunc(v_groc, 2), 23.00);
  perform game.match_market(v_world, 'groceries');

  if not exists (select 1 from market_trades
                  where world_id = v_world and resource_code = 'groceries'
                    and seller_company_id = v_co) then
    raise exception 'FALLO: la población no pudo comprar las cestas';
  end if;
  raise notice 'ok: la población compró % cestas',
    (select round(sum(qty),1) from market_trades
      where resource_code='groceries' and seller_company_id = v_co);

  -- La luz y el agua siguen fuera del mercado: van por red.
  begin
    perform rpc_place_order(v_world, 'power', 'sell', 10, 0.10);
    raise exception 'FALLO: dejó negociar electricidad en el mercado';
  exception when sqlstate 'P0001' then
    raise notice 'ok: la luz no se negocia, va por red';
  end;

  -- ── Regresión 3 ────────────────────────────────────────────────────────────
  -- El municipio sólo paga el mantenimiento de lo público, no el de los
  -- edificios que se quedaron sin dueño.
  if (select count(*) from buildings b
        join building_types bt on bt.code = b.type_code
       where b.world_id = v_world and bt.municipal_only) > 0 then
    raise exception 'FALLO: hay edificios municipales donde no debería';
  end if;
  raise notice 'ok: el municipio no paga edificios privados';

  raise notice '--- 5 ticks seguidos ---';
  for i in 1..5 loop
    update worlds set last_tick_at = null where id = v_world;
    perform fn_world_tick('test');
  end loop;

  raise notice 'tick actual: %', (select current_tick from worlds where id = v_world);
  raise notice 'población total: %',
    (select sum(population) from district_stats where world_id = v_world);
  raise notice 'felicidad media: %',
    (select round(avg(happiness), 1) from district_stats where world_id = v_world);
  raise notice 'caja municipal: %',
    (select round(balance) from city_treasury where world_id = v_world);
  raise notice 'operaciones cerradas: %',
    (select count(*) from market_trades where world_id = v_world);

  -- Invariante central: la caja de cada empresa es la suma de su libro mayor.
  if exists (
    select 1 from companies c
     where c.world_id = v_world
       and c.cash <> coalesce(
             (select sum(l.amount) from ledger_entries l where l.company_id = c.id), 0)
  ) then
    raise exception 'FALLO: alguna caja no cuadra con su libro mayor';
  end if;

  -- Idempotencia: repetir un tick ya ejecutado no debe cambiar nada.
  declare v_before bigint; v_after bigint;
  begin
    select current_tick into v_before from worlds where id = v_world;
    perform fn_world_tick('test');   -- last_tick_at es de ahora mismo
    select current_tick into v_after  from worlds where id = v_world;
    raise notice 'ticks: antes=% después=%', v_before, v_after;
  end;

  raise notice '=== Prueba de humo superada ===';
end $$;

-- Resumen del mundo generado, para poder mirar el relieve a ojo.
select terrain, count(*) as parcelas,
       round(avg(elevation)) as altitud_media,
       round(avg(land_value)) as valor_medio
  from plots group by terrain order by 2 desc;
