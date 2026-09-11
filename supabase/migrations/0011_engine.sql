-- =============================================================================
-- UrbanHills · 0011 · Motor económico
-- -----------------------------------------------------------------------------
-- Casación del mercado, tarifa de la red y utilidades compartidas por las RPC
-- y por el tick del mundo.
-- =============================================================================

-- Comisión de mercado que se queda el municipio. Es el sumidero que impide que
-- la masa monetaria crezca sin freno.
create or replace function game.market_fee_rate() returns numeric
language sql immutable as $$ select 0.01::numeric $$;

-- -----------------------------------------------------------------------------
-- Motor de casación
-- -----------------------------------------------------------------------------
-- Precio-tiempo: casa la mejor compra contra la mejor venta mientras se crucen,
-- y ejecuta al precio de la orden que llegó antes (la que "descansaba" en el
-- libro). Es la regla estándar y la única que no premia al que llega tarde.

create or replace function game.match_market(p_world uuid, p_resource text)
returns integer
language plpgsql
security definer
set search_path = public, game
as $$
declare
  v_bid        record;
  v_ask        record;
  v_qty        numeric;
  v_price      numeric;
  v_gross      numeric;
  v_fee        numeric;
  v_trades     integer := 0;
  v_tick       bigint;
  v_guard      integer := 0;
  -- Compras que en esta pasada no tienen contraparte válida. Sin esta lista,
  -- una orden imposible de casar bloquearía el libro entero.
  v_skip       uuid[] := '{}';
begin
  select current_tick into v_tick from worlds where id = p_world;

  loop
    -- Salvaguarda: ningún recurso debería necesitar más de 500 casaciones por
    -- llamada. Si las necesita, es que algo va mal y prefiero cortar.
    v_guard := v_guard + 1;
    exit when v_guard > 500;

    select o.* into v_bid
      from market_orders o
     where o.world_id = p_world and o.resource_code = p_resource
       and o.side = 'buy' and o.status in ('open','partial')
       and o.qty > o.qty_filled
       and not (o.id = any (v_skip))
     order by o.unit_price desc, o.created_at asc
     limit 1
       for update skip locked;

    exit when not found;

    select o.* into v_ask
      from market_orders o
     where o.world_id = p_world and o.resource_code = p_resource
       and o.side = 'sell' and o.status in ('open','partial')
       and o.qty > o.qty_filled
       and o.unit_price <= v_bid.unit_price
       -- Nadie se cruza consigo mismo: sería lavado de precios. Se busca
       -- directamente la mejor venta de otra empresa, sin tocar la propia:
       -- cancelarla aquí haría desaparecer su mercancía.
       and o.company_id is distinct from v_bid.company_id
     order by o.unit_price asc, o.created_at asc
     limit 1
       for update skip locked;

    if not found then
      v_skip := v_skip || v_bid.id;
      continue;
    end if;

    v_qty   := least(v_bid.qty - v_bid.qty_filled, v_ask.qty - v_ask.qty_filled);
    v_price := case when v_ask.created_at <= v_bid.created_at
                    then v_ask.unit_price else v_bid.unit_price end;
    v_gross := round(v_qty * v_price, 2);
    v_fee   := round(v_gross * game.market_fee_rate(), 2);

    -- Vendedor: cobra. La mercancía ya salió de su almacén al poner la orden.
    if v_ask.company_id is not null then
      perform game.post_ledger(
        v_ask.company_id, 'market_sale', v_gross - v_fee,
        v_qty || ' × ' || p_resource || ' @ ' || v_price, 'market_trades', null);
    end if;

    -- Comprador: ya tenía el dinero retenido; recibe la mercancía y se le
    -- devuelve la diferencia si compró por debajo de su precio límite.
    if v_bid.company_id is not null then
      perform game.inventory_add(v_bid.company_id, p_resource, v_qty, v_price);

      if v_bid.unit_price > v_price then
        perform game.post_ledger(
          v_bid.company_id, 'market_buy', round(v_qty * (v_bid.unit_price - v_price), 2),
          'Devolución por mejor precio en ' || p_resource, 'market_orders', v_bid.id);
      end if;

      update market_orders
         set escrow = greatest(0, escrow - round(v_qty * v_bid.unit_price, 2))
       where id = v_bid.id;
    end if;

    -- La comisión va a la hacienda municipal.
    update city_treasury
       set balance = balance + v_fee, updated_at = now()
     where world_id = p_world;

    update market_orders
       set qty_filled = qty_filled + v_qty,
           -- Los dos literales de un CASE se resuelven como text: sin el cast
           -- explícito, Postgres rechaza la asignación al enum.
           status = case when qty_filled + v_qty >= qty
                         then 'filled'::order_status
                         else 'partial'::order_status end
     where id in (v_bid.id, v_ask.id);

    insert into market_trades (world_id, resource_code, qty, unit_price,
                               buy_order_id, sell_order_id,
                               buyer_company_id, seller_company_id, tick)
    values (p_world, p_resource, v_qty, v_price, v_bid.id, v_ask.id,
            v_bid.company_id, v_ask.company_id, coalesce(v_tick, 0));

    v_trades := v_trades + 1;
  end loop;

  return v_trades;
end $$;

-- -----------------------------------------------------------------------------
-- Devuelve al emisor lo retenido por una orden que ya no se va a ejecutar.
-- -----------------------------------------------------------------------------
create or replace function game.release_order(p_order_id uuid, p_status order_status)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare o record;
begin
  select * into o from market_orders where id = p_order_id for update;
  if not found or o.status in ('filled','cancelled','expired') then
    return;
  end if;

  if o.company_id is not null then
    if o.side = 'buy' and o.escrow > 0 then
      perform game.post_ledger(o.company_id, 'market_buy', o.escrow,
        'Liberación de retención', 'market_orders', o.id);
    elsif o.side = 'sell' then
      -- La mercancía no vendida vuelve al almacén al coste al que salió.
      perform game.inventory_add(o.company_id, o.resource_code,
        o.qty - o.qty_filled, o.unit_price);
    end if;
  end if;

  update market_orders
     set status = p_status, escrow = 0
   where id = o.id;
end $$;

-- -----------------------------------------------------------------------------
-- Tarifa de la red (luz y agua)
-- -----------------------------------------------------------------------------
-- El precio se mueve con el desequilibrio del tick anterior y está acotado
-- entre 0,4× y 4× el precio ancla: un apagón encarece la luz, pero no infinito.

create or replace function game.utility_reprice(p_world uuid)
returns void
language plpgsql
security definer
set search_path = public, game
as $$
begin
  update utility_meters um
     set price = game.clamp(
           um.price * game.clamp(
             1 + 0.25 * ((um.demand - um.supply) / greatest(um.supply, um.demand, 1)),
             0.85, 1.20),
           r.base_price * 0.4, r.base_price * 4.0)
    from resources r
   where r.code = um.resource_code
     and um.world_id = p_world;
end $$;

create or replace function game.utility_price(p_world uuid, p_resource text)
returns numeric
language sql stable
security definer
set search_path = public, game
as $$
  select coalesce(
    (select price from utility_meters
      where world_id = p_world and resource_code = p_resource),
    (select base_price from resources where code = p_resource),
    1);
$$;

-- -----------------------------------------------------------------------------
-- Freno anti-script. No pretende ser infranqueable, sólo caro de saltarse.
-- -----------------------------------------------------------------------------
create or replace function game.rate_limit(
  p_company uuid, p_action text, p_max integer, p_window interval
) returns void
language plpgsql
security definer
set search_path = public, game
as $$
declare v_count integer;
begin
  select count(*) into v_count
    from action_log
   where company_id = p_company
     and action = p_action
     and created_at > now() - p_window;

  if v_count >= p_max then
    raise exception 'RATE_LIMITED:%', p_action using errcode = 'P0001';
  end if;

  insert into action_log (company_id, action) values (p_company, p_action);
end $$;

-- -----------------------------------------------------------------------------
-- La empresa del usuario autenticado en un mundo dado.
-- -----------------------------------------------------------------------------
create or replace function game.my_company(p_world uuid)
returns companies
language plpgsql
stable
security definer
set search_path = public, game
as $$
declare c companies;
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  select * into c
    from companies
   where world_id = p_world and owner_id = auth.uid() and is_active;

  if not found then
    raise exception 'NO_COMPANY_IN_WORLD' using errcode = 'P0002';
  end if;

  return c;
end $$;

-- Comprueba que un edificio es del jugador y lo bloquea para la transacción.
create or replace function game.own_building(p_building uuid)
returns buildings
language plpgsql
security definer
set search_path = public, game
as $$
declare b buildings;
begin
  select bl.* into b
    from buildings bl
    join companies c on c.id = bl.company_id
   where bl.id = p_building and c.owner_id = auth.uid()
     for update of bl;

  if not found then
    raise exception 'BUILDING_NOT_OWNED' using errcode = '42501';
  end if;

  return b;
end $$;
