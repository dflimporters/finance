-- AR portal: move named key-account stores to a set rep (Shallet = SM, Andrea = ASM) on AR Aging and Collections.
-- Acumatica is not changed. A trigger on the three AR tables rewrites rep_code / rep_name for listed customers on every
-- insert or update, so the daily syncs keep them moved; the one-off UPDATEs below move the rows already loaded,
-- past months included. RLS, ar_month_summary and both pages all key off these columns, so they follow automatically.
-- The rows as they were before are kept in ar_rep_override_backup_20261125 so this can be undone.

create table if not exists public.ar_rep_overrides (
  customer_id text primary key,
  rep_code    text not null,
  rep_name    text not null,
  note        text,
  added_at    timestamptz not null default now()
);
alter table public.ar_rep_overrides enable row level security;
drop policy if exists ar_rep_overrides_read on public.ar_rep_overrides;
create policy ar_rep_overrides_read on public.ar_rep_overrides for select using ((select ar_sees_all()));

insert into public.ar_rep_overrides (customer_id, rep_code, rep_name, note) values
  -- Shallet
  ('C000002795','SM','Shallet Marsh.','Loshusan'), ('C000002794','SM','Shallet Marsh.','Loshusan'),
  ('C000000554','SM','Shallet Marsh.','Brooklyn'), ('C000000556','SM','Shallet Marsh.','Brooklyn'),
  ('C000004462','SM','Shallet Marsh.','Sovereign'),
  ('C000002679','SM','Shallet Marsh.','Lees'), ('C000002680','SM','Shallet Marsh.','Lees'),
  ('C000001490','SM','Shallet Marsh.','Family Pride'),
  ('C000001689','SM','Shallet Marsh.','General Foods Liguanea'),
  -- Andrea: Hilo
  ('C000001907','ASM','Andrea Skelton','Hilo'), ('C000001908','ASM','Andrea Skelton','Hilo'), ('C000006029','ASM','Andrea Skelton','Hilo'),
  ('C000001909','ASM','Andrea Skelton','Hilo'), ('C000001911','ASM','Andrea Skelton','Hilo'), ('C000001912','ASM','Andrea Skelton','Hilo'),
  ('C000001913','ASM','Andrea Skelton','Hilo'), ('C000001915','ASM','Andrea Skelton','Hilo'), ('C000001916','ASM','Andrea Skelton','Hilo'),
  ('C000001917','ASM','Andrea Skelton','Hilo'), ('C000001920','ASM','Andrea Skelton','Hilo'), ('C000001921','ASM','Andrea Skelton','Hilo'),
  ('C000001923','ASM','Andrea Skelton','Hilo'), ('C000009381','ASM','Andrea Skelton','Hilo'), ('C000009140','ASM','Andrea Skelton','Hilo'),
  -- Andrea: Progressive / Shoppers Fair (D&Y)
  ('C000005617','ASM','Andrea Skelton','Progressive'), ('C000007077','ASM','Andrea Skelton','Progressive'), ('C000003798','ASM','Andrea Skelton','Progressive'),
  ('C000005618','ASM','Andrea Skelton','Progressive'), ('C000005619','ASM','Andrea Skelton','Progressive'), ('C000003799','ASM','Andrea Skelton','Progressive'),
  ('C000005648','ASM','Andrea Skelton','Shoppers Fair'), ('C000009487','ASM','Andrea Skelton','Shoppers Fair'), ('C000004357','ASM','Andrea Skelton','Shoppers Fair'),
  ('C000004358','ASM','Andrea Skelton','Shoppers Fair'), ('C000005649','ASM','Andrea Skelton','Shoppers Fair'), ('C000005651','ASM','Andrea Skelton','Shoppers Fair'),
  ('C000004359','ASM','Andrea Skelton','Shoppers Fair'), ('C000004360','ASM','Andrea Skelton','Shoppers Fair'), ('C000005652','ASM','Andrea Skelton','Shoppers Fair'),
  ('C000004361','ASM','Andrea Skelton','Shoppers Fair'), ('C000004362','ASM','Andrea Skelton','Shoppers Fair'), ('C000005653','ASM','Andrea Skelton','Shoppers Fair'),
  ('C000005654','ASM','Andrea Skelton','Shoppers Fair'), ('C000004656','ASM','Andrea Skelton','Shoppers Fair'), ('C000004657','ASM','Andrea Skelton','Shoppers Fair'),
  ('C000005650','ASM','Andrea Skelton','Shoppers Fair'), ('C000006386','ASM','Andrea Skelton','Shoppers Fair'), ('C000009109','ASM','Andrea Skelton','Shoppers Fair'),
  ('C000005455','ASM','Andrea Skelton','D&Y'),
  -- Andrea: Super Valu Fresh Foods, Sampars / Select, MegaMart
  ('C000004658','ASM','Andrea Skelton','Super Valu Fresh Foods'),
  ('C000004156','ASM','Andrea Skelton','Sampars'), ('C000004157','ASM','Andrea Skelton','Sampars'), ('C000004158','ASM','Andrea Skelton','Sampars'),
  ('C000004159','ASM','Andrea Skelton','Sampars'), ('C000004160','ASM','Andrea Skelton','Sampars'), ('C000004161','ASM','Andrea Skelton','Sampars / Select'),
  ('C000006110','ASM','Andrea Skelton','Select'),
  ('C000003041','ASM','Andrea Skelton','MegaMart'), ('C000003042','ASM','Andrea Skelton','MegaMart'), ('C000003043','ASM','Andrea Skelton','MegaMart'),
  ('C000003044','ASM','Andrea Skelton','MegaMart'), ('C000005818','ASM','Andrea Skelton','MegaMart')
on conflict (customer_id) do update set rep_code = excluded.rep_code, rep_name = excluded.rep_name, note = excluded.note;

create or replace function public.ar_apply_rep_override() returns trigger
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select rep_code, rep_name into o from ar_rep_overrides where customer_id = new.customer_id;
  if found then new.rep_code := o.rep_code; new.rep_name := o.rep_name; end if;
  return new;
end $$;

drop trigger if exists ar_rep_override on public.ar_aging_rows;
create trigger ar_rep_override before insert or update on public.ar_aging_rows for each row execute function public.ar_apply_rep_override();
drop trigger if exists ar_rep_override on public.ar_month_targets;
create trigger ar_rep_override before insert or update on public.ar_month_targets for each row execute function public.ar_apply_rep_override();
drop trigger if exists ar_rep_override on public.ar_payments;
create trigger ar_rep_override before insert or update on public.ar_payments for each row execute function public.ar_apply_rep_override();

-- keep the original rep on every row we are about to move
create table if not exists public.ar_rep_override_backup_20261125 as
  select 'ar_aging_rows'::text tbl, customer_id, rep_code, rep_name, null::text k1, null::text k2 from public.ar_aging_rows where false;
alter table public.ar_rep_override_backup_20261125 enable row level security;
insert into public.ar_rep_override_backup_20261125 (tbl, customer_id, rep_code, rep_name, k1, k2)
  select 'ar_aging_rows', a.customer_id, a.rep_code, a.rep_name, a.snapshot_id::text, a.doc_type || '|' || a.ref_nbr
    from public.ar_aging_rows a join public.ar_rep_overrides o on o.customer_id = a.customer_id where a.rep_code is distinct from o.rep_code
  union all
  select 'ar_month_targets', t.customer_id, t.rep_code, t.rep_name, t.id::text, null
    from public.ar_month_targets t join public.ar_rep_overrides o on o.customer_id = t.customer_id where t.rep_code is distinct from o.rep_code
  union all
  select 'ar_payments', p.customer_id, p.rep_code, p.rep_name, p.adjg_doc_type || '|' || p.adjg_ref_nbr || '|' || p.line_nbr || '|' || p.adjustment_nbr, p.invoice_type || '|' || p.invoice_ref
    from public.ar_payments p join public.ar_rep_overrides o on o.customer_id = p.customer_id where p.rep_code is distinct from o.rep_code;

-- move the rows already loaded (the trigger sets the values)
update public.ar_aging_rows a set rep_code = o.rep_code from public.ar_rep_overrides o where a.customer_id = o.customer_id and a.rep_code is distinct from o.rep_code;
update public.ar_month_targets t set rep_code = o.rep_code from public.ar_rep_overrides o where t.customer_id = o.customer_id and t.rep_code is distinct from o.rep_code;
update public.ar_payments p set rep_code = o.rep_code from public.ar_rep_overrides o where p.customer_id = o.customer_id and p.rep_code is distinct from o.rep_code;
