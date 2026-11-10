-- Missing Invoices tracker, step 1: the clerk's physical-invoice check.
-- The invoice list itself is public.invoices (already synced from Acumatica); this adds only the clerk's marks.
-- Unchecked invoice = no row in mi_checks. status: found | missing.

create table if not exists public.mi_checks (
  reference_number text primary key,
  status           text not null check (status in ('found','missing')),
  note             text,
  checked_by       uuid default auth.uid(),
  checked_by_name  text,
  checked_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists mi_checks_status_idx on public.mi_checks (status, checked_at desc);

-- Stamp who/when on the server so the browser cannot spoof it.
create or replace function public.mi_checks_stamp() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  new.checked_by      := auth.uid();
  new.checked_by_name := coalesce((select (public.ar_my_access())->>'name'), 'unknown');
  new.updated_at      := now();
  if tg_op = 'INSERT' or new.status is distinct from old.status then new.checked_at := now(); end if;
  return new;
end $$;
drop trigger if exists mi_checks_stamp_t on public.mi_checks;
create trigger mi_checks_stamp_t before insert or update on public.mi_checks
  for each row execute function public.mi_checks_stamp();

alter table public.mi_checks enable row level security;
create policy mi_checks_read on public.mi_checks for select using ((select public.ar_sees_all()));
create policy mi_checks_ins  on public.mi_checks for insert with check ((select public.ar_sees_all()));
create policy mi_checks_upd  on public.mi_checks for update using ((select public.ar_sees_all())) with check ((select public.ar_sees_all()));
create policy mi_checks_del  on public.mi_checks for delete using ((select public.ar_sees_all()));

-- public.invoices has RLS with no policies, so the page reads it through this view (runs as owner),
-- gated to finance users by ar_sees_all(). Cancelled documents are left out: there is no paper to find.
create or replace view public.mi_invoices with (security_invoker = false) as
  select i.reference_number, i.customer_id, i.customer_name, i.invoice_amount, i.currency_id,
         i.invoice_date, i.status as acu_status, i.order_number, i.branch, i.synced_at,
         c.status as check_status, c.note, c.checked_by_name, c.checked_at
  from public.invoices i
  left join public.mi_checks c on c.reference_number = i.reference_number
  where public.ar_sees_all() and i.status <> 'Canceled';
revoke all on public.mi_invoices from anon;
grant select on public.mi_invoices to authenticated;
