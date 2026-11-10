-- New ar_access level invoice_clerk: the only role that can mark invoices Found/Missing and write notes.
-- Every other finance role (admin, finance_admin, clerk) keeps read-only access to the page.
alter table public.ar_access drop constraint if exists ar_access_level_check;
alter table public.ar_access add constraint ar_access_level_check
  check (level = any (array['finance_admin','clerk','invoice_clerk']));

insert into public.ar_access (email, full_name, level, active)
values ('jenelle@dflimporters.com', 'Jenelle Gordon', 'invoice_clerk', true)
on conflict (email) do update set level = 'invoice_clerk', full_name = 'Jenelle Gordon', active = true;

create or replace function public.mi_can_edit() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(public.ar_level() = 'invoice_clerk', false);
$$;

drop policy if exists mi_checks_ins on public.mi_checks;
drop policy if exists mi_checks_upd on public.mi_checks;
drop policy if exists mi_checks_del on public.mi_checks;
create policy mi_checks_ins on public.mi_checks for insert with check ((select public.mi_can_edit()));
create policy mi_checks_upd on public.mi_checks for update using ((select public.mi_can_edit())) with check ((select public.mi_can_edit()));
create policy mi_checks_del on public.mi_checks for delete using ((select public.mi_can_edit()));
