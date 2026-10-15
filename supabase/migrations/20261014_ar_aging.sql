-- AR aging: snapshots, rows, disputes, RLS. Applied to project hzagwndglwhcepsirafi
-- as two migrations (ar_aging_tables, ar_disputes_tighten) on 2026-10-14.
-- Cron (applied separately, same request pattern as sync-customers):
--   sync-ar-aging-mon-thu   '0 11 * * 1,4'  (06:00 Jamaica, Monday + Thursday)

create table public.ar_aging_snapshots (
  id bigint generated always as identity primary key,
  snapshot_date date not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'loading' check (status in ('loading','complete','failed')),
  row_count int,
  total_jmd numeric(18,2),
  notes jsonb
);
create index on public.ar_aging_snapshots (status, snapshot_date desc);

create table public.ar_aging_rows (
  snapshot_id bigint not null references public.ar_aging_snapshots(id) on delete cascade,
  doc_type text not null,
  ref_nbr text not null,
  rep_code text,
  rep_name text,
  rep_numeric_id int,
  customer_id text not null,
  customer_name text,
  doc_date date,
  due_date date,
  currency text,
  amount_doc numeric(18,4),
  balance_doc numeric(18,4),
  balance_jmd numeric(18,4),
  terms text,
  is_credit boolean not null,
  days_aged int,
  bucket text not null check (bucket in ('Current','31-60','61-90','90+','Credit')),
  primary key (snapshot_id, doc_type, ref_nbr)
);
create index on public.ar_aging_rows (snapshot_id, rep_code);
create index on public.ar_aging_rows (snapshot_id, customer_id);

create table public.ar_disputes (
  doc_type text not null,
  ref_nbr text not null,
  note text not null,
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (doc_type, ref_nbr)
);

create or replace function public.ar_sees_all() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles
    where id = auth.uid() and active = true
      and role in ('admin','management','manager','rep_management'));
$$;

create or replace function public.ar_my_rep_code() returns text
language sql stable security definer set search_path to 'public' as $$
  select salesperson_id from public.profiles
  where id = auth.uid() and active = true and role = 'rep';
$$;

alter table public.ar_aging_snapshots enable row level security;
alter table public.ar_aging_rows enable row level security;
alter table public.ar_disputes enable row level security;

create policy ar_snap_read on public.ar_aging_snapshots for select to authenticated
  using (status = 'complete' and (public.ar_sees_all() or public.ar_my_rep_code() is not null));
create policy ar_rows_read on public.ar_aging_rows for select to authenticated
  using (public.ar_sees_all() or (rep_code is not null and rep_code = public.ar_my_rep_code()));

-- ---- disputes: only on documents the user can see -------------------------
create or replace function public.ar_can_access_doc(p_doc_type text, p_ref_nbr text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.ar_sees_all() or exists (
    select 1 from public.ar_aging_rows r
    where r.snapshot_id = (select max(id) from public.ar_aging_snapshots where status='complete')
      and r.doc_type = p_doc_type and r.ref_nbr = p_ref_nbr
      and r.rep_code is not null and r.rep_code = public.ar_my_rep_code());
$$;
revoke execute on function public.ar_can_access_doc(text,text) from anon, public;
revoke execute on function public.ar_sees_all() from anon, public;
revoke execute on function public.ar_my_rep_code() from anon, public;
grant execute on function public.ar_can_access_doc(text,text) to authenticated;
grant execute on function public.ar_sees_all() to authenticated;
grant execute on function public.ar_my_rep_code() to authenticated;

create policy ar_disputes_read on public.ar_disputes for select to authenticated
  using (public.ar_can_access_doc(doc_type, ref_nbr));
create policy ar_disputes_ins on public.ar_disputes for insert to authenticated
  with check (public.ar_can_access_doc(doc_type, ref_nbr));
create policy ar_disputes_upd on public.ar_disputes for update to authenticated
  using (public.ar_can_access_doc(doc_type, ref_nbr))
  with check (public.ar_can_access_doc(doc_type, ref_nbr));
create policy ar_disputes_del on public.ar_disputes for delete to authenticated
  using (public.ar_can_access_doc(doc_type, ref_nbr));

create or replace function public.ar_disputes_stamp() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin new.updated_by := auth.uid(); new.updated_at := now(); return new; end $$;
create trigger ar_disputes_stamp before insert or update on public.ar_disputes
  for each row execute function public.ar_disputes_stamp();
