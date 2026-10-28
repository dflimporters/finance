-- Bad Goods portal, step 1: core tables, RLS, price view.
-- APPLIED to hzagwndglwhcepsirafi on 2026-10-26 (migration name: bad_goods_core).
-- Existing public.bad_goods_reports (field photo reports) is untouched; new objects use the bg_ prefix.

create table if not exists public.bg_settings (
  id              boolean primary key default true check (id),
  rate            numeric(5,4) not null default 0.75,
  acu_item_id     text not null default '10001840',
  acu_item_label  text not null default 'BAD GOODS',
  updated_at      timestamptz not null default now()
);
insert into public.bg_settings (id) values (true) on conflict do nothing;

create table if not exists public.bg_reason_codes (
  code   text primary key,
  label  text not null,
  active boolean not null default true,
  sort   smallint not null default 0
);
insert into public.bg_reason_codes (code, label, sort) values
  ('DAMAGED',  'Damaged',           1),
  ('EXPIRED',  'Expired',           2),
  ('NEAREXP',  'Near expiry',       3),
  ('RETURN',   'Customer return',   4),
  ('OTHER',    'Other',             9)
on conflict do nothing;

create sequence if not exists public.bg_number_seq;

create table if not exists public.bg_batches (
  id               uuid primary key default gen_random_uuid(),
  bg_number        text not null unique default ('BG-' || lpad(nextval('public.bg_number_seq')::text, 6, '0')),
  slip_no          text,
  slip_date        date not null default current_date,
  customer_id      text not null,
  customer_name    text not null,
  currency_id      text,
  shipping_zone    text,
  salesperson_code text,
  entered_by       uuid not null default auth.uid(),
  entered_by_name  text,
  entry_source     text not null default 'finance_test'
                   check (entry_source in ('finance_test','rep_app','merch_app')),
  status           text not null default 'draft'
                   check (status in ('draft','submitted','approved','rejected','pushing','pushed','failed')),
  note             text,
  photo_urls       text[] not null default '{}',
  total_net        numeric(14,2) not null default 0,
  submitted_at     timestamptz,
  reviewed_by      uuid,
  reviewed_by_name text,
  reviewed_at      timestamptz,
  reject_reason    text,
  acu_target       text,
  acu_ref_nbr      text,
  push_error       text,
  pushed_at        timestamptz,
  created_at       timestamptz not null default now()
);
-- One live document per customer + slip number (rejected slips may be re-entered).
create unique index if not exists bg_batches_slip_uq
  on public.bg_batches (customer_id, slip_no)
  where slip_no is not null and status <> 'rejected';
create index if not exists bg_batches_status_idx   on public.bg_batches (status, created_at desc);
create index if not exists bg_batches_customer_idx on public.bg_batches (customer_id);
create index if not exists bg_batches_entered_idx  on public.bg_batches (entered_by);

create table if not exists public.bg_lines (
  id              uuid primary key default gen_random_uuid(),
  batch_id        uuid not null references public.bg_batches(id) on delete cascade,
  line_no         smallint not null,
  inventory_id    text not null,
  description     text not null,
  uom             text not null,
  qty             numeric(12,2) not null check (qty > 0),
  list_price      numeric(14,4) not null check (list_price >= 0),
  rate            numeric(5,4)  not null,
  unit_price      numeric(14,4) generated always as (round(list_price * rate, 2)) stored,
  override_price  numeric(14,4),
  override_reason text,
  ext_price       numeric(14,2) generated always as
                  (round(qty * coalesce(override_price, round(list_price * rate, 2)), 2)) stored,
  reason_code     text references public.bg_reason_codes(code),
  unique (batch_id, line_no),
  check (override_price is null or override_reason is not null)
);

create table if not exists public.bg_events (
  id         bigint generated always as identity primary key,
  batch_id   uuid not null references public.bg_batches(id) on delete cascade,
  at         timestamptz not null default now(),
  actor      uuid default auth.uid(),
  actor_name text,
  event      text not null,
  detail     jsonb
);
create index if not exists bg_events_batch_idx on public.bg_events (batch_id, at);

-- Who may review/approve: admins and the finance manager level on ar_access.
create or replace function public.bg_is_approver() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(public.ar_level() in ('admin','finance_manager'), false);
$$;

-- Item price list: 75% of default price, one row per SKU that has a default price.
create or replace view public.bg_item_prices with (security_invoker = true) as
  select distinct on (inventory_id)
         inventory_id, description, item_class, item_status, default_price,
         round(default_price * (select rate from public.bg_settings), 2) as bad_goods_price
  from public.stock_items_raw
  where default_price is not null and default_price > 0
  order by inventory_id, last_synced_at desc nulls last;

alter table public.bg_settings     enable row level security;
alter table public.bg_reason_codes enable row level security;
alter table public.bg_batches      enable row level security;
alter table public.bg_lines        enable row level security;
alter table public.bg_events       enable row level security;

create policy bg_settings_read on public.bg_settings for select using ((select public.is_active_staff()));
create policy bg_reason_read   on public.bg_reason_codes for select using ((select public.is_active_staff()));

-- Entry person: own rows. Finance (any ar_access level or admin): all rows.
create policy bg_batches_read on public.bg_batches for select
  using (entered_by = (select auth.uid()) or (select public.ar_sees_all()));
create policy bg_batches_ins on public.bg_batches for insert
  with check (entered_by = (select auth.uid()) and status in ('draft','submitted') and (select public.is_active_staff()));
create policy bg_batches_upd_own on public.bg_batches for update
  using (entered_by = (select auth.uid()) and status = 'draft')
  with check (entered_by = (select auth.uid()) and status in ('draft','submitted'));
create policy bg_batches_upd_approver on public.bg_batches for update
  using ((select public.bg_is_approver()))
  with check ((select public.bg_is_approver()));

create policy bg_lines_read on public.bg_lines for select using (
  exists (select 1 from public.bg_batches b where b.id = batch_id
          and (b.entered_by = (select auth.uid()) or (select public.ar_sees_all()))));
create policy bg_lines_write_own on public.bg_lines for all using (
  exists (select 1 from public.bg_batches b where b.id = batch_id
          and b.entered_by = (select auth.uid()) and b.status = 'draft'))
  with check (exists (select 1 from public.bg_batches b where b.id = batch_id
          and b.entered_by = (select auth.uid()) and b.status = 'draft'));
create policy bg_lines_approver on public.bg_lines for update
  using ((select public.bg_is_approver())) with check ((select public.bg_is_approver()));

create policy bg_events_read on public.bg_events for select using (
  exists (select 1 from public.bg_batches b where b.id = batch_id
          and (b.entered_by = (select auth.uid()) or (select public.ar_sees_all()))));
create policy bg_events_ins on public.bg_events for insert
  with check ((select public.is_active_staff()));

-- Pushes to Acumatica run in an Edge Function with the service role (bypasses RLS);
-- status moves to pushing/pushed/failed are made there, never from the browser.
