-- =====================================================================
--  DRIP CARTEL — Supabase schema
--  Run this once in the Supabase SQL editor (Dashboard → SQL → New query).
--  Money is stored in CENTS (integer). R500,00 = 50000.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- 1. PROFILES  (one row per auth user)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  full_name   text not null,
  username    text unique,
  email       text not null,
  phone       text,
  city        text,
  province    text default 'Gauteng',
  size        text,
  address     text,
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- new auth user -> profile row, filled from the sign-up metadata
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, username, email, phone, city, size, address)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    nullif(new.raw_user_meta_data->>'username',''),
    new.email,
    new.raw_user_meta_data->>'phone',
    new.raw_user_meta_data->>'city',
    new.raw_user_meta_data->>'size',
    new.raw_user_meta_data->>'address'
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- admin check that does NOT recurse into profiles RLS
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- ---------------------------------------------------------------------
-- 2. CATALOGUE
-- ---------------------------------------------------------------------
create table if not exists public.products (
  id           text primary key,              -- 'jacket', 'denimset' ...
  name         text not null,
  category     text not null check (category in ('tops','bottoms','sets','headwear','accessories')),
  description  text,
  price_cents  integer not null check (price_cents >= 0),
  tag          text default '',
  is_limited   boolean not null default false,
  is_active    boolean not null default true,
  sort_order   integer not null default 100,
  image_path   text,                          -- storage path in bucket 'products'
  created_at   timestamptz not null default now()
);

create table if not exists public.product_variants (
  id          uuid primary key default gen_random_uuid(),
  product_id  text not null references public.products on delete cascade,
  size        text not null,
  stock       integer not null default 0 check (stock >= 0),
  unique (product_id, size)
);
create index if not exists idx_variants_product on public.product_variants(product_id);

-- ---------------------------------------------------------------------
-- 3. ORDERS
-- ---------------------------------------------------------------------
-- status ladder used by the tracker:
--   awaiting_payment -> payment_review -> paid -> packed -> shipped -> delivered
--   (shipped == "ready for collection" when delivery_method = 'collect')
create table if not exists public.orders (
  id               uuid primary key default gen_random_uuid(),
  order_no         text unique not null,
  user_id          uuid references auth.users on delete set null,
  email            text not null,
  status           text not null default 'awaiting_payment'
                   check (status in ('awaiting_payment','payment_review','paid','packed','shipped','delivered','cancelled')),

  delivery_method  text not null check (delivery_method in ('door','locker','collect')),
  delivery_eta     text,
  recipient_name   text not null,
  phone            text not null,
  address          text,
  city             text,
  province         text,
  postal_code      text,
  notes            text,

  payment_method   text not null check (payment_method in ('eft','instant','voucher','cash')),
  payment_ref      text,                      -- what the customer must use as reference
  paid             boolean not null default false,
  paid_at          timestamptz,
  gateway          text,                      -- 'ozow' | 'payfast' | 'yoco' | null
  gateway_ref      text,
  voucher_last4    text,

  subtotal_cents   integer not null,
  discount_cents   integer not null default 0,
  shipping_cents   integer not null default 0,
  total_cents      integer not null,
  promo_code       text,

  tracking_no      text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_orders_user on public.orders(user_id);
create index if not exists idx_orders_status on public.orders(status);

create table if not exists public.order_items (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.orders on delete cascade,
  product_id       text references public.products on delete set null,
  name             text not null,             -- snapshot, survives product edits
  size             text not null,
  qty              integer not null check (qty > 0),
  unit_price_cents integer not null
);
create index if not exists idx_items_order on public.order_items(order_id);

create table if not exists public.order_events (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.orders on delete cascade,
  status     text not null,
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists idx_events_order on public.order_events(order_id);

create table if not exists public.payment_proofs (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders on delete cascade,
  storage_path text not null,                 -- bucket 'proofs'
  note         text,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. MESSAGES (contact form) + PROMOS + SETTINGS
-- ---------------------------------------------------------------------
create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  email      text not null,
  body       text not null,
  handled    boolean not null default false,
  reply_note text,
  created_at timestamptz not null default now()
);

create table if not exists public.promo_codes (
  code             text primary key,
  percent          integer not null check (percent between 1 and 100),
  first_order_only boolean not null default true,
  is_active        boolean not null default true
);

create table if not exists public.settings (
  key   text primary key,
  value jsonb not null
);

insert into public.settings (key, value) values
  ('shipping', '{
     "door":    {"fee_cents": 8000, "free_over_cents": 80000, "eta": "2–4 working days"},
     "locker":  {"fee_cents": 6000, "free_over_cents": null,  "eta": "2–3 working days"},
     "collect": {"fee_cents": 0,    "free_over_cents": null,  "eta": "Ready within 24 hours"}
   }'::jsonb),
  ('bank', '{
     "Bank": "FNB",
     "Account name": "Drip Cartel (Pty) Ltd",
     "Account number": "62812345678",
     "Account type": "Cheque / current",
     "Branch code": "250655"
   }'::jsonb),
  ('pickup', '"Cartel HQ, 42 Burnett St, Hatfield, Pretoria · Mon–Sat, 10:00–18:00"'::jsonb)
on conflict (key) do nothing;

insert into public.promo_codes (code, percent, first_order_only)
values ('DRIP10', 10, true) on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 5. ORDER CREATION  (server-side: prices and stock come from the DB,
--    never from the browser)
-- ---------------------------------------------------------------------
create or replace function public.new_order_no()
returns text language plpgsql as $$
declare n text;
begin
  loop
    n := 'DC-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.orders where order_no = n);
  end loop;
  return n;
end $$;

-- p = {
--   items:[{product_id,size,qty}], delivery_method, payment_method,
--   recipient_name, phone, address, city, province, postal_code, notes,
--   email, promo_code, voucher_last4
-- }
create or replace function public.create_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it            jsonb;
  v_order_id    uuid;
  v_order_no    text;
  v_sub         integer := 0;
  v_disc        integer := 0;
  v_ship        integer := 0;
  v_method      text := p->>'delivery_method';
  v_pay         text := p->>'payment_method';
  v_email       text := lower(coalesce(p->>'email', (select email from public.profiles where id = auth.uid())));
  v_ship_cfg    jsonb;
  v_free_over   integer;
  v_promo       record;
  v_prod        record;
  v_variant     record;
  v_qty         integer;
  v_status      text;
begin
  if v_method not in ('door','locker','collect') then raise exception 'Unknown delivery method'; end if;
  if v_pay not in ('eft','instant','voucher','cash') then raise exception 'Unknown payment method'; end if;
  if v_pay = 'cash' and v_method <> 'collect' then raise exception 'Pay on collection is only for collection orders'; end if;
  if v_email is null then raise exception 'An email address is required'; end if;
  if jsonb_array_length(coalesce(p->'items','[]'::jsonb)) = 0 then raise exception 'Your cart is empty'; end if;
  if v_method <> 'collect' and coalesce(p->>'postal_code','') !~ '^\d{4}$' then
    raise exception 'A 4-digit postal code is required';
  end if;

  v_order_no := public.new_order_no();

  insert into public.orders (
    order_no, user_id, email, delivery_method, recipient_name, phone, address, city, province, postal_code, notes,
    payment_method, payment_ref, voucher_last4, subtotal_cents, total_cents,
    delivery_eta
  ) values (
    v_order_no, auth.uid(), v_email, v_method,
    p->>'recipient_name', p->>'phone',
    case when v_method = 'collect' then (select value #>> '{}' from public.settings where key='pickup') else p->>'address' end,
    p->>'city', p->>'province', nullif(p->>'postal_code',''), nullif(p->>'notes',''),
    v_pay, v_order_no, nullif(p->>'voucher_last4',''), 0, 0,
    (select value->v_method->>'eta' from public.settings where key='shipping')
  ) returning id into v_order_id;

  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb))
  loop
    select * into v_prod
    from public.products
    where id = it->>'product_id' for update;

    if v_prod is null then raise exception 'Unknown product: %', it->>'product_id'; end if;

    select * into v_variant
    from public.product_variants
    where product_id = it->>'product_id' and size = it->>'size' for update;

    if v_variant is null then raise exception 'No inventory for % in size %', it->>'product_id', it->>'size'; end if;

    v_qty := coalesce((it->>'qty')::int, 0);
    if v_qty <= 0 then raise exception 'Quantity must be greater than zero'; end if;
    if v_variant.stock < v_qty then raise exception 'Not enough stock for % in size %', it->>'product_id', it->>'size'; end if;

    v_sub := v_sub + (v_prod.price_cents * v_qty);

    insert into public.order_items (order_id, product_id, name, size, qty, unit_price_cents)
    values (v_order_id, v_prod.id, v_prod.name, it->>'size', v_qty, v_prod.price_cents);

    update public.product_variants
    set stock = stock - v_qty
    where id = v_variant.id;
  end loop;

  v_ship_cfg := (select value from public.settings where key = 'shipping');
  if v_method = 'collect' then
    v_ship := 0;
  else
    v_ship := (v_ship_cfg->v_method->>'fee_cents')::int;
    if v_ship_cfg->v_method->>'free_over_cents' is not null then
      v_free_over := (v_ship_cfg->v_method->>'free_over_cents')::int;
      if v_sub >= v_free_over then
        v_ship := 0;
      end if;
    end if;
  end if;

  if coalesce(p->>'promo_code','') <> '' then
    select * into v_promo
    from public.promo_codes
    where code = upper(p->>'promo_code') and is_active and (not first_order_only or not exists (
      select 1 from public.orders where email = v_email and status <> 'cancelled'
    ));

    if v_promo is not null then
      v_disc := (v_sub * v_promo.percent) / 100;
      update public.orders
      set promo_code = upper(p->>'promo_code'), discount_cents = v_disc, subtotal_cents = v_sub,
          shipping_cents = v_ship, total_cents = v_sub - v_disc + v_ship
      where id = v_order_id;
    else
      update public.orders
      set subtotal_cents = v_sub, shipping_cents = v_ship, total_cents = v_sub + v_ship
      where id = v_order_id;
    end if;
  else
    update public.orders
    set subtotal_cents = v_sub, shipping_cents = v_ship, total_cents = v_sub + v_ship
    where id = v_order_id;
  end if;

  if v_pay = 'cash' then
    v_status := 'awaiting_payment';
  elsif v_pay = 'instant' then
    v_status := 'paid';
  else
    v_status := 'awaiting_payment';
  end if;

  update public.orders
  set status = v_status,
      updated_at = now()
  where id = v_order_id;

  insert into public.order_events (order_id, status, note)
  values (v_order_id, v_status, 'Order placed');

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_no', v_order_no,
    'status', v_status,
    'total_cents', (select total_cents from public.orders where id = v_order_id)
  );
end $$;

-- ---------------------------------------------------------------------
-- 6. RLS + SECURITY
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_events enable row level security;
alter table public.payment_proofs enable row level security;
alter table public.messages enable row level security;
alter table public.promo_codes enable row level security;
alter table public.settings enable row level security;

-- Public catalogue reads
create policy if not exists "Products are viewable by anyone"
on public.products
for select using (true);

create policy if not exists "Variants are viewable by anyone"
on public.product_variants
for select using (true);

-- Customers can manage their own profile
create policy if not exists "Users can view own profile"
on public.profiles
for select using (auth.uid() = id);

create policy if not exists "Users can update own profile"
on public.profiles
for update using (auth.uid() = id) with check (auth.uid() = id);

create policy if not exists "Users can insert own profile"
on public.profiles
for insert with check (auth.uid() = id);

-- Admin editable catalogue
create policy if not exists "Admins can manage products"
on public.products
for all using (public.is_admin()) with check (public.is_admin());

create policy if not exists "Admins can manage variants"
on public.product_variants
for all using (public.is_admin()) with check (public.is_admin());

-- Orders: users read own, admins all; customers can insert via function only
create policy if not exists "Users can read own orders"
on public.orders
for select using (auth.uid() = user_id or public.is_admin());

create policy if not exists "Users can insert own order"
on public.orders
for insert with check (auth.uid() = user_id or public.is_admin());

create policy if not exists "Admins can update all orders"
on public.orders
for update using (public.is_admin()) with check (public.is_admin());

create policy if not exists "Users can read own order items"
on public.order_items
for select using (exists (
  select 1 from public.orders o where o.id = order_id and (o.user_id = auth.uid() or public.is_admin())
));

create policy if not exists "Users can read own order events"
on public.order_events
for select using (exists (
  select 1 from public.orders o where o.id = order_id and (o.user_id = auth.uid() or public.is_admin())
));

create policy if not exists "Anyone can submit a message"
on public.messages
for insert with check (true);

create policy if not exists "Admins can read messages"
on public.messages
for select using (public.is_admin());

create policy if not exists "Admins can update messages"
on public.messages
for update using (public.is_admin()) with check (public.is_admin());

create policy if not exists "Public can view active promo codes"
on public.promo_codes
for select using (is_active);

create policy if not exists "Admins manage promo codes"
on public.promo_codes
for all using (public.is_admin()) with check (public.is_admin());

create policy if not exists "Public can read settings"
on public.settings
for select using (true);

create policy if not exists "Admins manage settings"
on public.settings
for all using (public.is_admin()) with check (public.is_admin());

-- Proofs: private, upload only by owner or admin
create policy if not exists "Users can read own proof records"
on public.payment_proofs
for select using (
  exists (
    select 1 from public.orders o where o.id = order_id and (o.user_id = auth.uid() or public.is_admin())
  )
);

create policy if not exists "Users can insert own proof"
on public.payment_proofs
for insert with check (
  exists (
    select 1 from public.orders o where o.id = order_id and (o.user_id = auth.uid() or public.is_admin())
  )
);

-- ---------------------------------------------------------------------
-- 7. STORAGE BUCKETS (optional but recommended)
-- ---------------------------------------------------------------------
-- create bucket proofs with private permissions;
-- create bucket products with public permissions;

-- ---------------------------------------------------------------------
-- 8. HELPER: keep first order discount only
-- ---------------------------------------------------------------------
-- handled by create_order() using orders lookup by email.

-- =====================================================================
--  DRIP CARTEL — END OF SCHEMA
-- =====================================================================
