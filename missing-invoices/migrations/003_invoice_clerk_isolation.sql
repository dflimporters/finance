-- invoice_clerk sees ONLY the Missing Invoices page.
-- ar_sees_all() backs every other AR / Bad Goods policy, so it now excludes invoice_clerk.
-- The Missing Invoices objects use their own check, mi_can_view() (any finance level incl. invoice_clerk).
create or replace function public.ar_sees_all() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(public.ar_level() <> 'invoice_clerk', false);   -- null level (no access) -> false
$$;
create or replace function public.mi_can_view() returns boolean
  language sql stable security definer set search_path = public as $$
  select public.ar_level() is not null;
$$;
drop policy if exists mi_checks_read on public.mi_checks;
create policy mi_checks_read on public.mi_checks for select using ((select public.mi_can_view()));
create or replace view public.mi_invoices with (security_invoker = false) as
  select i.reference_number, i.customer_id, i.customer_name, i.invoice_amount, i.currency_id,
         i.invoice_date, i.status as acu_status, i.order_number, i.branch, i.synced_at,
         c.status as check_status, c.note, c.checked_by_name, c.checked_at
  from public.invoices i
  left join public.mi_checks c on c.reference_number = i.reference_number
  where public.mi_can_view() and i.status <> 'Canceled';
insert into public.ar_access (email, full_name, level, active)
values ('pam@dflimporters.com', 'Pamella Allen', 'invoice_clerk', true)
on conflict (email) do update set level = 'invoice_clerk', full_name = 'Pamella Allen', active = true;
