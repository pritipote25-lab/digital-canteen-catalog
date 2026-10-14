-- Smart Canteen: schema, RLS, atomic order logic, realtime. All money in paise (integer).

create extension if not exists pgcrypto;

-- ───────── Tables ─────────
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text, phone text,
  role text not null default 'customer' check (role in ('customer','staff','admin')),
  created_at timestamptz not null default now()
);

create table canteens (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  opens_at time not null default '08:00',
  closes_at time not null default '20:00',
  service_charge_pct numeric(5,2) not null default 0 check (service_charge_pct between 0 and 50),
  tax_pct numeric(5,2) not null default 5 check (tax_pct between 0 and 50),
  reservations_enabled boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table canteen_staff (
  canteen_id uuid references canteens on delete cascade,
  user_id uuid references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (canteen_id, user_id)
);

create table food_categories (
  id uuid primary key default gen_random_uuid(),
  canteen_id uuid not null references canteens on delete cascade,
  name text not null, sort_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (canteen_id, name)
);

create table food_items (
  id uuid primary key default gen_random_uuid(),
  canteen_id uuid not null references canteens on delete cascade,
  category_id uuid references food_categories on delete set null,
  name text not null, description text, image_url text,
  price_paise int not null check (price_paise >= 0),
  is_veg boolean not null default true,
  is_available boolean not null default true,
  stock int not null default 0 check (stock >= 0),
  created_at timestamptz not null defaulindex.htmlt now(),
  updated_at timestamptz not null default now()
);
create index on food_items (canteen_id, category_id);

create table tables (
  id uuid primary key default gen_random_uuid(),
  canteen_id uuid not null references canteens on delete cascade,
  label text not null, seats int not null check (seats > 0),
  status text not null default 'available' check (status in ('available','occupied','reserved')),
  unique (canteen_id, label)
);

create table table_reservations (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references tables on delete cascade,
  customer_id uuid not null references profiles on delete cascade,
  reserved_for timestamptz not null, party_size int not null check (party_size > 0),
  status text not null default 'active' check (status in ('active','cancelled','completed')),
  created_at timestamptz not null default now()
);
create index on table_reservations (table_id, reserved_for);

create sequence order_seq;

create table orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  customer_id uuid not null references profiles,
  canteen_id uuid not null references canteens,
  order_type text not null check (order_type in ('dine_in','takeaway')),
  table_id uuid references tables,
  status text not null default 'pending'
    check (status in ('pending','confirmed','preparing','ready','completed','cancelled')),
  payment_method text not null check (payment_method in ('online','counter')),
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','paid','failed','refund_pending','refunded')),
  subtotal_paise int not null, service_charge_paise int not null,
  tax_paise int not null, total_paise int not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on orders (customer_id, created_at desc);
create index on orders (canteen_id, status, created_at desc);

create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders on delete cascade,
  food_item_id uuid references food_items on delete set null,
  name text not null,                       -- historical snapshot
  unit_price_paise int not null,            -- historical snapshot
  quantity int not null check (quantity > 0),
  line_total_paise int not null
);
create index on order_items (order_id);

create table payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders,
  razorpay_order_id text unique,
  razorpay_payment_id text unique,
  amount_paise int not null,
  status text not null default 'created' check (status in ('created','captured','failed','refunded')),
  raw jsonb, created_at timestamptz not null default now()
);
create index on payments (order_id);

-- ───────── Helpers ─────────
create function is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'admin') $$;

create function is_staff_of(c uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from canteen_staff where canteen_id = c and user_id = auth.uid()) $$;

-- Auto-create profile on signup (always 'customer')
create function handle_new_user() returns trigger language plpgsql security definer set search_path = public as
$$ begin
  insert into profiles (id, full_name) values (new.id, new.raw_user_meta_data->>'full_name');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Block role self-escalation
create function guard_role() returns trigger language plpgsql security definer set search_path = public as
$$ begin
  if new.role is distinct from old.role and not is_admin() then
    raise exception 'Only admins can change roles';
  end if;
  return new;
end $$;
create trigger guard_profile_role before update on profiles for each row execute function guard_role();

create function touch_updated_at() returns trigger language plpgsql as
$$ begin new.updated_at = now(); return new; end $$;
create trigger t_food before update on food_items for each row execute function touch_updated_at();
create trigger t_orders before update on orders for each row execute function touch_updated_at();

-- ───────── Atomic order placement (prices & stock verified server-side) ─────────
create function place_order(
  p_canteen uuid, p_order_type text, p_table uuid, p_payment_method text, p_items jsonb
) returns orders language plpgsql security definer set search_path = public as $$
declare
  c canteens; o orders; it record; f record;
  v_sub int := 0; v_svc int; v_tax int;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select * into c from canteens where id = p_canteen and is_active;
  if not found then raise exception 'Canteen unavailable'; end if;
  if localtime not between c.opens_at and c.closes_at then raise exception 'Canteen is closed'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;

  insert into orders (order_number, customer_id, canteen_id, order_type, table_id, payment_method,
                      subtotal_paise, service_charge_paise, tax_paise, total_paise)
  values ('SC-' || to_char(now(),'YYMMDD') || '-' || lpad(nextval('order_seq')::text,5,'0'),
          auth.uid(), p_canteen, p_order_type, p_table, p_payment_method, 0,0,0,0)
  returning * into o;

  -- Sorted by id to avoid deadlocks; conditional UPDATE makes the stock decrement atomic.
  for it in
    select (x->>'id')::uuid as id, (x->>'qty')::int as qty
    from jsonb_array_elements(p_items) x order by 1
  loop
    if it.qty is null or it.qty < 1 or it.qty > 50 then raise exception 'Invalid quantity'; end if;
    update food_items set stock = stock - it.qty
     where id = it.id and canteen_id = p_canteen and is_available and stock >= it.qty
     returning name, price_paise into f;
    if not found then raise exception 'Item unavailable or insufficient stock: %', it.id; end if;
    insert into order_items (order_id, food_item_id, name, unit_price_paise, quantity, line_total_paise)
    values (o.id, it.id, f.name, f.price_paise, it.qty, f.price_paise * it.qty);
    v_sub := v_sub + f.price_paise * it.qty;
  end loop;

  v_svc := round(v_sub * c.service_charge_pct / 100);
  v_tax := round((v_sub + v_svc) * c.tax_pct / 100);
  update orders set subtotal_paise = v_sub, service_charge_paise = v_svc,
         tax_paise = v_tax, total_paise = v_sub + v_svc + v_tax
   where id = o.id returning * into o;
  return o;
end $$;

-- ───────── Status changes & cancellation (restores stock exactly once) ─────────
create function cancel_order(p_order uuid) returns orders language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found'; end if;
  if not (is_admin() or is_staff_of(o.canteen_id) or (o.customer_id = auth.uid() and o.status = 'pending')) then
    raise exception 'Not allowed';
  end if;
  if o.status in ('cancelled','completed') then raise exception 'Order already %', o.status; end if;
  update food_items f set stock = f.stock + oi.quantity
    from order_items oi where oi.order_id = o.id and oi.food_item_id = f.id;
  update orders set status = 'cancelled',
         payment_status = case when payment_status = 'paid' then 'refund_pending' else payment_status end
   where id = o.id returning * into o;
  return o;
end $$;

create function set_order_status(p_order uuid, p_status text) returns orders language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  if p_status = 'cancelled' then return cancel_order(p_order); end if;
  select * into o from orders where id = p_order for update;
  if not found or not (is_admin() or is_staff_of(o.canteen_id)) then raise exception 'Not allowed'; end if;
  if o.status in ('cancelled','completed') then raise exception 'Order is closed'; end if;
  if p_status not in ('confirmed','preparing','ready','completed') then raise exception 'Invalid status'; end if;
  update orders set status = p_status where id = p_order returning * into o;
  return o;
end $$;

-- ───────── Row Level Security ─────────
alter table profiles enable row level security;
alter table canteens enable row level security;
alter table canteen_staff enable row level security;
alter table food_categories enable row level security;
alter table food_items enable row level security;
alter table tables enable row level security;
alter table table_reservations enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;
alter table payments enable row level security;

create policy profiles_read on profiles for select using (id = auth.uid() or is_admin());
create policy profiles_update on profiles for update using (id = auth.uid() or is_admin());

create policy canteens_read on canteens for select using (true);
create policy canteens_admin on canteens for all using (is_admin()) with check (is_admin());

create policy staff_read on canteen_staff for select using (user_id = auth.uid() or is_admin());
create policy staff_admin on canteen_staff for all using (is_admin()) with check (is_admin());

create policy cat_read on food_categories for select using (true);
create policy cat_write on food_categories for all
  using (is_admin() or is_staff_of(canteen_id)) with check (is_admin() or is_staff_of(canteen_id));

create policy food_read on food_items for select using (true);
create policy food_write on food_items for all
  using (is_admin() or is_staff_of(canteen_id)) with check (is_admin() or is_staff_of(canteen_id));

create policy tables_read on tables for select using (true);
create policy tables_write on tables for all
  using (is_admin() or is_staff_of(canteen_id)) with check (is_admin() or is_staff_of(canteen_id));

create policy resv_read on table_reservations for select using (
  customer_id = auth.uid() or is_admin()
  or exists (select 1 from tables t where t.id = table_id and is_staff_of(t.canteen_id)));
create policy resv_insert on table_reservations for insert with check (
  customer_id = auth.uid()
  and exists (select 1 from tables t join canteens c on c.id = t.canteen_id
              where t.id = table_id and c.reservations_enabled));
create policy resv_cancel on table_reservations for update using (customer_id = auth.uid() or is_admin());

-- Orders/items/payments: read-only for clients. Writes go through the RPCs above
-- or the service-role Edge Function (Razorpay verification / webhook).
create policy orders_read on orders for select using (
  customer_id = auth.uid() or is_admin() or is_staff_of(canteen_id));
create policy items_read on order_items for select using (
  exists (select 1 from orders o where o.id = order_id
          and (o.customer_id = auth.uid() or is_admin() or is_staff_of(o.canteen_id))));
create policy payments_read on payments for select using (
  exists (select 1 from orders o where o.id = order_id
          and (o.customer_id = auth.uid() or is_admin() or is_staff_of(o.canteen_id))));

revoke insert, update, delete on orders, order_items, payments from anon, authenticated;
revoke execute on function place_order, cancel_order, set_order_status from anon;

-- ───────── Realtime ─────────
alter publication supabase_realtime add table food_items, orders, tables;
