-- Cash discounts, second test (per payment). Customers pay one cheque for a batch of invoices and take ~2% off the
-- total, so the shortfall sits on one (or a few) of the invoices and can be well over 2.5% of THAT invoice.
-- An invoice is now left out of the target as a cash discount when EITHER
--   (a) what is left on it is 2.5% or less of the invoice (the existing per-invoice test), OR
--   (b) it was paid, before the month, by a payment whose batch has a small shortfall: add up everything that payment
--       applied to its invoices plus whatever is still open on those invoices; if the open part is 2.5% or less of that
--       total, the leftover on every invoice in the batch is a discount (one invoice or several).
-- "Open on those invoices" = invoice amount less everything applied to it before the month, read from the AR snapshot
-- the month's target was frozen from (same basis as late_adj). Only payments dated before the month count, so cash still
-- being collected on a part-paid invoice this month is never treated as a discount.
-- Everything else in ar_month_target_docs / ar_month_summary is unchanged (columns and types identical).

create index if not exists ar_payments_payment_ref on public.ar_payments (payment_ref);

create or replace view public.ar_month_target_docs with (security_invoker = true) as
with mon as (
  select distinct month, (month + interval '1 month')::date as nxt from ar_month_targets
), snapm as (
  select distinct month, snapshot_id from ar_month_targets
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
), inv_rem as (
  select s.month, a.ref_nbr, a.currency,
         a.amount_doc - coalesce((
           select sum(p.applied_amount) from ar_payments p
            where p.invoice_type = 'Invoice' and p.invoice_ref = a.ref_nbr and p.currency = a.currency and not p.is_missing
              and p.payment_date < s.month
              and p.payment_type = any (array['Payment','Prepayment','Voided Payment','Credit Memo','Balance WO'])), 0) as rem
    from snapm s
    join ar_aging_rows a on a.snapshot_id = s.snapshot_id and a.doc_type = 'Invoice' and a.amount_doc > 0
), inv_open as (
  select month, ref_nbr, currency, rem from inv_rem where rem > 0.005
), cand as (
  -- only payments that settled an invoice that still has something left on it are worth looking at
  select distinct o.month, p.payment_ref
    from inv_open o
    join ar_payments p on p.invoice_ref = o.ref_nbr and p.invoice_type = 'Invoice' and p.currency = o.currency
   where not p.is_missing and p.payment_type = any (array['Payment','Prepayment']) and p.payment_date < o.month
), batch as (
  select c.month, p.payment_ref, p.invoice_ref, p.currency, sum(p.applied_amount) as applied
    from cand c
    join ar_payments p on p.payment_ref = c.payment_ref
   where not p.is_missing and p.invoice_type = 'Invoice' and p.payment_type = any (array['Payment','Prepayment'])
     and p.payment_date < c.month
   group by c.month, p.payment_ref, p.invoice_ref, p.currency
  having sum(p.applied_amount) > 0.005
), pay_batch as (
  select b.month, b.payment_ref, sum(b.applied) as applied_total, coalesce(sum(greatest(o.rem, 0::numeric)), 0::numeric) as leftover
    from batch b
    left join inv_open o on o.month = b.month and o.ref_nbr = b.invoice_ref and o.currency = b.currency
   group by b.month, b.payment_ref
), batch_disc as (
  select distinct b.month, b.invoice_ref, b.currency
    from batch b
    join pay_batch pb on pb.month = b.month and pb.payment_ref = b.payment_ref
   where pb.leftover > 0.005 and pb.leftover <= 0.025 * (pb.applied_total + pb.leftover)
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
       case when e.doc_type = 'Invoice' and e.orig > 0 and e.bal - e.late_adj > 0
                 and (e.bal - e.late_adj <= 0.025 * e.orig or bd.invoice_ref is not null)
            then e.bal - e.late_adj else 0::numeric end as small_adj
  from e
  left join batch_disc bd on bd.month = e.month and bd.invoice_ref = e.ref_nbr and bd.currency = e.currency
union all
select month, doc_type, ref_nbr, currency, customer_id, customer_name, rep_code, rep_name, due_date, source, bal::numeric, orig::numeric(18,4),
       0::numeric, 0::numeric from new_seen
union all
select month, doc_type, ref_nbr, currency, customer_id, customer_name, rep_code, rep_name, due_date, source, bal::numeric, orig::numeric(18,4),
       0::numeric, 0::numeric from new_paid;
