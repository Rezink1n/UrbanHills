-- =============================================================================
-- UrbanHills · 0012 · API pública del juego
-- -----------------------------------------------------------------------------
-- Todo lo que el cliente puede *hacer* pasa por aquí. Ninguna tabla económica
-- acepta escritura directa: estas funciones son la única puerta, y cada una
-- valida propiedad, reglas y caja antes de tocar nada.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Fundar empresa
-- -----------------------------------------------------------------------------
create or replace function rpc_found_company(p_world_code text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_world  worlds;
  v_slug   text;
  v_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  p_name := btrim(p_name);
  if length(p_name) < 3 or length(p_name) > 40 then
    raise exception 'INVALID_NAME' using errcode = 'P0001';
  end if;

  select * into v_world from worlds where code = p_world_code and status = 'active';
  if not found then
    raise exception 'WORLD_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_slug := lower(regexp_replace(p_name, '[^A-Za-z0-9]+', '-', 'g'));
  v_slug := btrim(v_slug, '-');
  if v_slug = '' then
    raise exception 'INVALID_NAME' using errcode = 'P0001';
  end if;

  insert into companies (world_id, owner_id, name, slug, cash)
  values (v_world.id, auth.uid(), p_name, v_slug, v_world.starting_cash)
  returning id into v_id;

  insert into ledger_entries
    (world_id, company_id, tick, kind, amount, balance_after, memo)
  values
    (v_world.id, v_id, v_world.current_tick, 'founding',
     v_world.starting_cash, v_world.starting_cash, 'Capital fundacional');

  return jsonb_build_object('company_id', v_id, 'cash', v_world.starting_cash);

exception
  when unique_violation then
    raise exception 'NAME_TAKEN_OR_ALREADY_PLAYING' using errcode = 'P0001';
end $$;

-- -----------------------------------------------------------------------------
-- Comprar parcela
-- -----------------------------------------------------------------------------
-- Sin dueño  → la vende el municipio a `land_value` y el dinero entra en la
--              hacienda pública.
-- Con dueño  → reventa entre jugadores a `ask_price`, con comisión municipal.
create or replace function rpc_buy_plot(p_plot_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_plot   plots;
  v_co     companies;
  v_price  numeric;
  v_fee    numeric;
begin
  select * into v_plot from plots where id = p_plot_id for update;
  if not found then
    raise exception 'PLOT_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_co := game.my_company(v_plot.world_id);
  perform game.rate_limit(v_co.id, 'buy_plot', 40, interval '1 minute');

  if v_plot.terrain = 'water' or v_plot.zoning = 'protected' then
    raise exception 'PLOT_NOT_FOR_SALE' using errcode = 'P0001';
  end if;

  if v_plot.owner_company_id = v_co.id then
    raise exception 'ALREADY_OWNED' using errcode = 'P0001';
  end if;

  if not v_plot.for_sale then
    raise exception 'PLOT_NOT_FOR_SALE' using errcode = 'P0001';
  end if;

  v_price := case
               when v_plot.owner_company_id is null then v_plot.land_value
               else coalesce(v_plot.ask_price, v_plot.land_value)
             end;

  if v_co.cash < v_price then
    raise exception 'INSUFFICIENT_FUNDS' using errcode = 'P0001';
  end if;

  perform game.post_ledger(v_co.id, 'land_purchase', -v_price,
    'Parcela ' || v_plot.x || ',' || v_plot.y, 'plots', v_plot.id);

  if v_plot.owner_company_id is null then
    update city_treasury set balance = balance + v_price, updated_at = now()
     where world_id = v_plot.world_id;
    insert into city_ledger (world_id, tick, kind, amount, balance_after, memo)
    select v_plot.world_id, w.current_tick, 'land_sale', v_price, t.balance,
           'Venta de suelo municipal'
      from worlds w join city_treasury t on t.world_id = w.id
     where w.id = v_plot.world_id;
  else
    v_fee := round(v_price * game.market_fee_rate(), 2);
    perform game.post_ledger(v_plot.owner_company_id, 'land_sale', v_price - v_fee,
      'Venta de parcela ' || v_plot.x || ',' || v_plot.y, 'plots', v_plot.id);
    update city_treasury set balance = balance + v_fee, updated_at = now()
     where world_id = v_plot.world_id;
  end if;

  update plots
     set owner_company_id = v_co.id,
         acquired_at      = now(),
         for_sale         = false,
         ask_price        = null,
         updated_at       = now()
   where id = v_plot.id;

  return jsonb_build_object('plot_id', v_plot.id, 'paid', v_price);
end $$;

-- -----------------------------------------------------------------------------
-- Poner o retirar una parcela del mercado
-- -----------------------------------------------------------------------------
create or replace function rpc_set_plot_sale(p_plot_id uuid, p_price numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_plot plots;
  v_co   companies;
begin
  select * into v_plot from plots where id = p_plot_id for update;
  if not found then
    raise exception 'PLOT_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_co := game.my_company(v_plot.world_id);
  if v_plot.owner_company_id is distinct from v_co.id then
    raise exception 'PLOT_NOT_OWNED' using errcode = '42501';
  end if;

  if p_price is null then
    update plots set for_sale = false, ask_price = null, updated_at = now()
     where id = v_plot.id;
    return jsonb_build_object('for_sale', false);
  end if;

  if p_price <= 0 then
    raise exception 'INVALID_PRICE' using errcode = 'P0001';
  end if;

  update plots set for_sale = true, ask_price = round(p_price, 2), updated_at = now()
   where id = v_plot.id;

  return jsonb_build_object('for_sale', true, 'ask_price', round(p_price, 2));
end $$;

-- -----------------------------------------------------------------------------
-- Construir
-- -----------------------------------------------------------------------------
create or replace function rpc_build(p_plot_id uuid, p_building_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_plot  plots;
  v_co    companies;
  v_bt    building_types;
  v_mat   record;
  v_id    uuid;
begin
  select * into v_plot from plots where id = p_plot_id for update;
  if not found then
    raise exception 'PLOT_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_co := game.my_company(v_plot.world_id);
  perform game.rate_limit(v_co.id, 'build', 30, interval '1 minute');

  if v_plot.owner_company_id is distinct from v_co.id then
    raise exception 'PLOT_NOT_OWNED' using errcode = '42501';
  end if;

  if exists (select 1 from buildings where plot_id = v_plot.id) then
    raise exception 'PLOT_OCCUPIED' using errcode = 'P0001';
  end if;

  select * into v_bt from building_types where code = p_building_code;
  if not found then
    raise exception 'UNKNOWN_BUILDING' using errcode = 'P0002';
  end if;

  if v_bt.municipal_only then
    raise exception 'MUNICIPAL_ONLY' using errcode = '42501';
  end if;
  if not (v_plot.terrain = any (v_bt.allowed_terrain)) then
    raise exception 'TERRAIN_NOT_ALLOWED' using errcode = 'P0001';
  end if;
  if not (v_plot.zoning = any (v_bt.allowed_zoning)) then
    raise exception 'ZONING_NOT_ALLOWED' using errcode = 'P0001';
  end if;
  if v_plot.slope > v_bt.max_slope then
    raise exception 'SLOPE_TOO_STEEP' using errcode = 'P0001';
  end if;
  if v_co.reputation < v_bt.min_reputation then
    raise exception 'REPUTATION_TOO_LOW' using errcode = 'P0001';
  end if;

  -- Construir en cuesta encarece la obra hasta un 45 %.
  declare v_cost numeric := round(v_bt.build_cost * (1 + v_plot.slope * 0.0075), 2);
  begin
    if v_co.cash < v_cost then
      raise exception 'INSUFFICIENT_FUNDS' using errcode = 'P0001';
    end if;

    -- Los materiales salen del almacén; si falta alguno, la transacción entera
    -- se revierte y el jugador no pierde ni dinero ni stock.
    for v_mat in
      select key as code, value::numeric as qty
        from jsonb_each_text(v_bt.build_materials)
    loop
      perform game.inventory_take(v_co.id, v_mat.code, v_mat.qty);
    end loop;

    perform game.post_ledger(v_co.id, 'construction', -v_cost,
      'Obra: ' || v_bt.name, 'plots', v_plot.id);

    insert into buildings (world_id, plot_id, company_id, type_code, status, ready_at,
                           rent_per_tick)
    values (v_plot.world_id, v_plot.id, v_co.id, v_bt.code, 'construction',
            now() + make_interval(mins => v_bt.build_minutes), v_bt.base_rent)
    returning id into v_id;

    update plots set for_sale = false, ask_price = null, updated_at = now()
     where id = v_plot.id;

    return jsonb_build_object(
      'building_id', v_id, 'cost', v_cost,
      'ready_at', now() + make_interval(mins => v_bt.build_minutes));
  end;
end $$;

-- -----------------------------------------------------------------------------
-- Producir
-- -----------------------------------------------------------------------------
create or replace function rpc_produce(
  p_building_id uuid,
  p_recipe_id   text,
  p_batches     integer default 1,
  p_auto        boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_b     buildings;
  v_r     recipes;
  v_in    record;
begin
  v_b := game.own_building(p_building_id);
  perform game.rate_limit(v_b.company_id, 'produce', 60, interval '1 minute');

  if v_b.status = 'construction' then
    raise exception 'STILL_UNDER_CONSTRUCTION' using errcode = 'P0001';
  end if;
  if v_b.status = 'producing' then
    raise exception 'ALREADY_PRODUCING' using errcode = 'P0001';
  end if;
  if p_batches < 1 or p_batches > 100 then
    raise exception 'INVALID_BATCHES' using errcode = 'P0001';
  end if;

  select * into v_r from recipes where id = p_recipe_id and building_code = v_b.type_code;
  if not found then
    raise exception 'RECIPE_NOT_AVAILABLE' using errcode = 'P0002';
  end if;
  if v_b.level < v_r.min_level then
    raise exception 'LEVEL_TOO_LOW' using errcode = 'P0001';
  end if;

  -- Las entradas se descuentan por adelantado: así no se puede encadenar
  -- producción con stock que ya se ha vendido a mitad del lote.
  for v_in in select resource_code, qty from recipe_inputs where recipe_id = v_r.id loop
    perform game.inventory_take(v_b.company_id, v_in.resource_code, v_in.qty * p_batches);
  end loop;

  update buildings
     set status      = 'producing',
         recipe_id   = v_r.id,
         run_batches = p_batches,
         run_ends_at = now() + make_interval(mins => v_r.minutes * p_batches),
         auto_repeat = p_auto
   where id = v_b.id;

  return jsonb_build_object(
    'building_id', v_b.id,
    'ends_at', now() + make_interval(mins => v_r.minutes * p_batches));
end $$;

-- -----------------------------------------------------------------------------
-- Ajustes de un edificio
-- -----------------------------------------------------------------------------
create or replace function rpc_set_wage(p_building_id uuid, p_wage numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare v_b buildings;
begin
  v_b := game.own_building(p_building_id);
  if p_wage < 0.5 or p_wage > 2 then
    raise exception 'INVALID_WAGE' using errcode = 'P0001';
  end if;

  update buildings set wage_level = p_wage where id = v_b.id;
  return jsonb_build_object('wage_level', p_wage);
end $$;

create or replace function rpc_demolish(p_building_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_b    buildings;
  v_bt   building_types;
  v_cost numeric;
begin
  v_b  := game.own_building(p_building_id);
  select * into v_bt from building_types where code = v_b.type_code;

  -- Derribar cuesta el 8 % de lo que costó levantarlo.
  v_cost := round(v_bt.build_cost * 0.08, 2);
  perform game.post_ledger(v_b.company_id, 'construction', -v_cost,
    'Derribo: ' || v_bt.name, 'buildings', v_b.id);

  delete from buildings where id = v_b.id;
  return jsonb_build_object('demolished', true, 'cost', v_cost);
end $$;

-- -----------------------------------------------------------------------------
-- Mercado
-- -----------------------------------------------------------------------------
create or replace function rpc_place_order(
  p_world_id uuid,
  p_resource text,
  p_side     text,
  p_qty      numeric,
  p_price    numeric
) returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_co    companies;
  v_res   resources;
  v_side  order_side;
  v_id    uuid;
  v_escrow numeric := 0;
begin
  v_co := game.my_company(p_world_id);
  perform game.rate_limit(v_co.id, 'order', 60, interval '1 minute');

  v_side := p_side::order_side;

  select * into v_res from resources where code = p_resource;
  if not found then
    raise exception 'UNKNOWN_RESOURCE' using errcode = 'P0002';
  end if;
  if not v_res.is_storable then
    raise exception 'NOT_TRADABLE' using errcode = 'P0001';  -- luz y agua van por red
  end if;
  if p_qty <= 0 or p_price <= 0 then
    raise exception 'INVALID_ORDER' using errcode = 'P0001';
  end if;

  if v_side = 'buy' then
    v_escrow := round(p_qty * p_price, 2);
    if v_co.cash < v_escrow then
      raise exception 'INSUFFICIENT_FUNDS' using errcode = 'P0001';
    end if;
    -- El dinero sale de caja ya: no se puede comprometer dos veces.
    perform game.post_ledger(v_co.id, 'market_buy', -v_escrow,
      'Retención por orden de compra de ' || p_resource);
  else
    -- La mercancía sale del almacén al poner la orden, por el mismo motivo.
    perform game.inventory_take(v_co.id, p_resource, p_qty);
  end if;

  insert into market_orders
    (world_id, company_id, resource_code, side, qty, unit_price, escrow, expires_at)
  values
    (p_world_id, v_co.id, p_resource, v_side, p_qty, round(p_price, 4), v_escrow,
     now() + interval '7 days')
  returning id into v_id;

  -- Se intenta casar en el acto: una orden que cruza no debería esperar al tick.
  perform game.match_market(p_world_id, p_resource);

  return jsonb_build_object('order_id', v_id);
end $$;

create or replace function rpc_cancel_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, game
as $$
declare v_o market_orders;
begin
  select o.* into v_o
    from market_orders o
    join companies c on c.id = o.company_id
   where o.id = p_order_id and c.owner_id = auth.uid();

  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform game.release_order(v_o.id, 'cancelled');
  return jsonb_build_object('cancelled', true);
end $$;

-- -----------------------------------------------------------------------------
-- Estado del jugador en un mundo, de una sola llamada
-- -----------------------------------------------------------------------------
create or replace function rpc_my_state(p_world_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, game
as $$
declare v_co companies;
begin
  if auth.uid() is null then
    return jsonb_build_object('authenticated', false);
  end if;

  select * into v_co
    from companies where world_id = p_world_id and owner_id = auth.uid() and is_active;

  if not found then
    return jsonb_build_object('authenticated', true, 'company', null);
  end if;

  return jsonb_build_object(
    'authenticated', true,
    'company', to_jsonb(v_co),
    'inventory', coalesce((
      select jsonb_agg(jsonb_build_object(
               'resource_code', i.resource_code, 'qty', i.qty, 'avg_cost', i.avg_cost))
        from inventories i where i.company_id = v_co.id and i.qty > 0), '[]'::jsonb),
    'plots', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'x', p.x, 'y', p.y,
               'land_value', p.land_value, 'for_sale', p.for_sale, 'ask_price', p.ask_price))
        from plots p where p.owner_company_id = v_co.id), '[]'::jsonb),
    'buildings', coalesce((
      select jsonb_agg(to_jsonb(b))
        from buildings b where b.company_id = v_co.id), '[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(to_jsonb(o))
        from market_orders o
       where o.company_id = v_co.id and o.status in ('open','partial')), '[]'::jsonb),
    'unread', (select count(*) from notifications n
                where n.company_id = v_co.id and n.read_at is null)
  );
end $$;

-- -----------------------------------------------------------------------------
-- Permisos: sólo usuarios autenticados pueden invocar la API de acción.
-- -----------------------------------------------------------------------------
do $$
declare fn text;
begin
  foreach fn in array array[
    'rpc_found_company(text,text)',
    'rpc_buy_plot(uuid)',
    'rpc_set_plot_sale(uuid,numeric)',
    'rpc_build(uuid,text)',
    'rpc_produce(uuid,text,integer,boolean)',
    'rpc_set_wage(uuid,numeric)',
    'rpc_demolish(uuid)',
    'rpc_place_order(uuid,text,text,numeric,numeric)',
    'rpc_cancel_order(uuid)',
    'rpc_my_state(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;
