-- =============================================================================
-- UrbanHills · 0006 · Mercado: libro de órdenes, operaciones y precios
-- =============================================================================

create table if not exists market_orders (
  id              uuid primary key default gen_random_uuid(),
  world_id        uuid not null references worlds(id) on delete cascade,
  -- NULL = orden emitida por la población simulada (demanda NPC).
  company_id      uuid references companies(id) on delete cascade,
  resource_code   text not null references resources(code),
  side            order_side not null,
  qty             numeric(16,4) not null check (qty > 0),
  qty_filled      numeric(16,4) not null default 0 check (qty_filled >= 0),
  unit_price      numeric(14,4) not null check (unit_price > 0),
  status          order_status not null default 'open',
  is_npc          boolean not null default false,
  -- Dinero retenido para una orden de compra: impide vender la caja dos veces.
  escrow          numeric(16,2) not null default 0,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz,
  check (qty_filled <= qty)
);

comment on table market_orders is
  'Libro de órdenes con precio límite. Una fila por orden viva o histórica.';
comment on column market_orders.escrow is
  'Caja retenida al emitir una compra. Se libera al casar o al cancelar.';

-- El índice que hace barato el motor de casación.
create index if not exists idx_orders_book
  on market_orders(world_id, resource_code, side, unit_price, created_at)
  where status in ('open','partial');
create index if not exists idx_orders_company
  on market_orders(company_id, created_at desc);

create table if not exists market_trades (
  id                  bigserial primary key,
  world_id            uuid not null references worlds(id) on delete cascade,
  resource_code       text not null references resources(code),
  qty                 numeric(16,4) not null check (qty > 0),
  unit_price          numeric(14,4) not null check (unit_price > 0),
  buy_order_id        uuid,
  sell_order_id       uuid,
  buyer_company_id    uuid references companies(id) on delete set null,
  seller_company_id   uuid references companies(id) on delete set null,
  tick                bigint not null default 0,
  created_at          timestamptz not null default now()
);

create index if not exists idx_trades_resource
  on market_trades(world_id, resource_code, created_at desc);
create index if not exists idx_trades_company
  on market_trades(seller_company_id, created_at desc);

-- Velas horarias para las gráficas de precio.
create table if not exists price_history (
  world_id        uuid not null references worlds(id) on delete cascade,
  resource_code   text not null references resources(code),
  bucket          timestamptz not null,
  open            numeric(14,4) not null,
  high            numeric(14,4) not null,
  low             numeric(14,4) not null,
  close           numeric(14,4) not null,
  volume          numeric(16,4) not null default 0,
  primary key (world_id, resource_code, bucket)
);

-- Precio de referencia vigente por recurso: media ponderada de las últimas
-- operaciones, con el precio base como ancla cuando aún no hay mercado.
-- security_invoker: la vista respeta el RLS de quien consulta, no el del dueño.
create or replace view market_prices with (security_invoker = on) as
select
  r.code                                        as resource_code,
  r.name,
  r.category,
  r.tier,
  r.base_price,
  w.id                                          as world_id,
  coalesce(t.vwap, r.base_price)                as last_price,
  coalesce(t.volume_24h, 0)                     as volume_24h,
  b.best_bid,
  a.best_ask
from resources r
cross join worlds w
left join lateral (
  select sum(mt.qty * mt.unit_price) / nullif(sum(mt.qty), 0) as vwap,
         sum(mt.qty)                                          as volume_24h
  from market_trades mt
  where mt.world_id = w.id
    and mt.resource_code = r.code
    and mt.created_at > now() - interval '24 hours'
) t on true
left join lateral (
  select max(mo.unit_price) as best_bid
  from market_orders mo
  where mo.world_id = w.id and mo.resource_code = r.code
    and mo.side = 'buy' and mo.status in ('open','partial')
) b on true
left join lateral (
  select min(mo.unit_price) as best_ask
  from market_orders mo
  where mo.world_id = w.id and mo.resource_code = r.code
    and mo.side = 'sell' and mo.status in ('open','partial')
) a on true;

comment on view market_prices is
  'Precio de referencia y profundidad del libro, por recurso y mundo.';

-- -----------------------------------------------------------------------------
-- Red de suministros: electricidad y agua
-- -----------------------------------------------------------------------------
-- La luz y el agua no se almacenan ni pasan por el libro de órdenes: van por red.
-- Quien produce vende automáticamente a la red al precio vigente; quien consume
-- recibe una factura cada tick. El precio se mueve solo según oferta y demanda
-- del tick anterior, lo que convierte la energía en un negocio de verdad sin
-- necesidad de un segundo motor de casación.

create table if not exists utility_meters (
  world_id        uuid not null references worlds(id) on delete cascade,
  resource_code   text not null references resources(code),
  price           numeric(14,4) not null check (price > 0),
  supply          numeric(16,2) not null default 0,   -- producido en el último tick
  demand          numeric(16,2) not null default 0,   -- consumido en el último tick
  updated_tick    bigint not null default 0,
  primary key (world_id, resource_code)
);

comment on table utility_meters is
  'Precio y balance de red de los suministros no almacenables (luz y agua).';
