-- Fix: the "new this month" target differed by viewer. Invoices paid before any snapshot saw them get their due date from
-- customer terms, read from the customers table - but customers is only readable by people with a staff profile, so
-- for anyone else (e.g. a finance_admin with no profile) every terms value was empty, those invoices looked due on the
-- day they were raised, and invoices really due next month were pulled into this month's target.
--   * ar_terms_days(customer) reads the terms with the owner's rights, so the result is the same for every viewer
--   * an invoice that appears anywhere in the month's AR snapshots is never estimated from terms; its real due date
--     there decides (new_seen picks it up if it is due this month)

create or replace function public.ar_terms_days(p_customer text) returns integer
language sql stable security definer set search_path = public as $fn$
  select coalesce(nullif(regexp_replace(coalesce((select c.terms from customers c where c.customer_id = p_customer limit 1), ''), '\D', '', 'g'), '')::int, 0)
$fn$;
revoke all on function public.ar_terms_days(text) from public;
grant execute on function public.ar_terms_days(text) to authenticated;

create or replace view public.ar_month_target_docs with (security_invoker = true) as
with mon as (
  select distinct month, (month + interval '1 month')::date as nxt from ar_month_targets
), tgt as (
  select t.month, t.doc_type, t.ref_nbr, t.currency, t.customer_id, t.customer_name,
         coalesce(t.rep_code, ''::text) as rep_code, t.rep_name, t.due_date, t.source,
         t.balance_doc as bal, a.amount_doc as orig,
         case when t.doc_type = 'Invoice' then coalesce((
           select sum(p.applied_amount) from ar_payments p
            where p.invoice_type = 'Invoice' and p.invoice_ref = t.ref_nbr and p.currency = t.currency and not p.is_missing
              and p.payment_date < t.month
              and p.payment_type = any (array['Payment','Prepayment','Voided Payment','Credit Memo','Balance WO'])), 0) end as pre
    from ar_month_targets t
    left join ar_aging_rows a on a.snapshot_id = t.snapshot_id and a.doc_type = t.doc_type and a.ref_nbr = t.ref_nbr
), new_seen as (
  select distinct on (m.month, a.ref_nbr)
         m.month, a.doc_type, a.ref_nbr, a.currency, a.customer_id, a.customer_name,
         coalesce(a.rep_code, ''::text) as rep_code, a.rep_name, a.due_date, 'new'::text as source,
         a.amount_doc as bal, a.amount_doc as orig
    from mon m
    join ar_aging_snapshots s on s.status = 'complete' and s.snapshot_date >= m.month and s.snapshot_date < m.nxt
    join ar_aging_rows a on a.snapshot_id = s.id
   where a.doc_type = 'Invoice' and a.doc_date >= m.month and a.due_date < m.nxt and a.amount_doc > 0
     and not exists (select 1 from ar_month_targets t where t.month = m.month and t.doc_type = 'Invoice' and t.ref_nbr = a.ref_nbr)
   order by m.month, a.ref_nbr, s.id
), paid_raw as (
  select m.month, p.invoice_ref, min(p.customer_id) as customer_id, min(p.customer_name) as customer_name,
         coalesce(min(p.rep_code), ''::text) as rep_code, min(p.rep_name) as rep_name, min(p.currency) as currency,
         min(p.invoice_date) as invoice_date, sum(p.applied_amount) as amt
    from mon m
    join ar_payments p on p.invoice_date >= m.month and p.invoice_date < m.nxt
   where not p.is_missing and p.invoice_type = 'Invoice'
     and p.payment_type = any (array['Payment','Prepayment','Credit Memo','Balance WO'])
   group by m.month, m.nxt, p.invoice_ref
), new_paid as (
  select r.month, 'Invoice'::text as doc_type, r.invoice_ref as ref_nbr, r.currency, r.customer_id, r.customer_name,
         r.rep_code, r.rep_name, x.due as due_date, 'new'::text as source, r.amt as bal, r.amt as orig
    from paid_raw r
    cross join lateral (select r.invoice_date + ar_terms_days(r.customer_id) as due) x
   where r.amt > 0.005 and x.due < (r.month + interval '1 month')::date
     and not exists (select 1 from ar_month_targets t where t.month = r.month and t.doc_type = 'Invoice' and t.ref_nbr = r.invoice_ref)
     and not exists (select 1 from ar_aging_snapshots s join ar_aging_rows a on a.snapshot_id = s.id
                      where s.status = 'complete' and s.snapshot_date >= r.month and s.snapshot_date < (r.month + interval '1 month')::date
                        and a.doc_type = 'Invoice' and a.ref_nbr = r.invoice_ref)
), e as (
  select tgt.month, tgt.doc_type, tgt.ref_nbr, tgt.currency, tgt.customer_id, tgt.customer_name, tgt.rep_code, tgt.rep_name,
         tgt.due_date, tgt.source, tgt.bal, tgt.orig,
         case when tgt.doc_type = 'Invoice' and tgt.orig is not null and tgt.bal > 0
              then greatest(0::numeric, least(tgt.bal, tgt.pre - (tgt.orig - tgt.bal))) else 0::numeric end as late_adj
    from tgt
)
select e.month, e.doc_type, e.ref_nbr, e.currency, e.customer_id, e.customer_name, e.rep_code, e.rep_name, e.due_date, e.source,
       e.bal::numeric, e.orig::numeric(18,4), e.late_adj,
       case when e.doc_type = 'Invoice' and e.orig > 0 and e.bal - e.late_adj > 0 and e.bal - e.late_adj <= 0.025 * e.orig
            then e.bal - e.late_adj else 0::numeric end as small_adj
  from e
union all
select month, doc_type, ref_nbr, currency, customer_id, customer_name, rep_code, rep_name, due_date, source, bal::numeric, orig::numeric(18,4),
       0::numeric, 0::numeric from new_seen
union all
select month, doc_type, ref_nbr, currency, customer_id, customer_name, rep_code, rep_name, due_date, source, bal::numeric, orig::numeric(18,4),
       0::numeric, 0::numeric from new_paid;
