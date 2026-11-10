-- Admins may also mark invoices (for testing). Other roles stay view-only.
create or replace function public.mi_can_edit() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(public.ar_level() in ('invoice_clerk','admin'), false);
$$;
