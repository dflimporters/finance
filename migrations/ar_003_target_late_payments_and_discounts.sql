-- AR Collections target: two adjustments to the frozen month-start target, per invoice.
--   late_adj  : payments / credits dated BEFORE the month but entered in Acumatica after the target was frozen (e.g. an
--               October payment keyed on 4 Nov). The invoice looked open on the 1st, but that money counts in the earlier
--               month, so it could never be collected this month. Worked out per invoice as
--               (everything applied with a date before the month) - (original amount - balance at the freeze), 0..balance.
--   small_adj : what is left on an invoice after that, when it is 2.5% or less of the invoice's original amount
--               (likely a cash discount; the AR team leaves these out of a rep's target).
-- adjusted_target = target - credits - write-offs - late_adj - small_adj. Cash on a targeted invoice counts as
-- "on targeted" up to what is still in the target for it. Voided-payment rule from ar_002 is unchanged.
-- Columns late_adj and small_adj are added at the end of ar_month_summary.

create or replace view public.ar_month_target_docs with (security_invoker = true) as
with d as (
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
), e as (
  select d.*, case when d.doc_type = 'Invoice' and d.orig is not null and d.bal > 0
                   then greatest(0::numeric, least(d.bal, d.pre - (d.orig - d.bal))) else 0::numeric end as late_adj
    from d
)
select e.month, e.doc_type, e.ref_nbr, e.currency, e.customer_id, e.customer_name, e.rep_code, e.rep_name, e.due_date, e.source,
       e.bal, e.orig, e.late_adj,
       case when e.doc_type = 'Invoice' and e.orig > 0 and e.bal - e.late_adj > 0 and e.bal - e.late_adj <= 0.025 * e.orig
            then e.bal - e.late_adj else 0::numeric end as small_adj
  from e;

create or replace view public.ar_month_summary with (security_invoker = true) as
 WITH months AS (
         SELECT DISTINCT ar_month_targets.month FROM ar_month_targets
        ), tdocs AS (
         SELECT * FROM ar_month_target_docs
        ), tg AS (
         SELECT tdocs.month, tdocs.rep_code, max(tdocs.rep_name) AS rep_name, tdocs.currency,
            sum(tdocs.bal) AS target, sum(tdocs.late_adj) AS late_adj, sum(tdocs.small_adj) AS small_adj,
            bool_or(tdocs.source = 'reconstructed'::text) AS reconstructed
           FROM tdocs
          GROUP BY tdocs.month, tdocs.rep_code, tdocs.currency
        ), fx AS (
         SELECT ar_month_targets.month,
            sum(ar_month_targets.balance_jmd) / NULLIF(sum(ar_month_targets.balance_doc), 0::numeric) AS rate
           FROM ar_month_targets
          WHERE ar_month_targets.currency = 'USD'::text
          GROUP BY ar_month_targets.month
        ), inv AS (
         SELECT tdocs.month, tdocs.ref_nbr, tdocs.currency, tdocs.rep_code,
            sum(tdocs.bal - tdocs.late_adj - tdocs.small_adj) AS bal
           FROM tdocs
          WHERE tdocs.doc_type = 'Invoice'::text
          GROUP BY tdocs.month, tdocs.ref_nbr, tdocs.currency, tdocs.rep_code
        ), cash AS (
         SELECT m.month, p.invoice_ref, COALESCE(p.rep_code, ''::text) AS rep_code, p.currency,
            max(p.rep_name) AS rep_name, sum(p.applied_amount) AS amt
           FROM ar_payments p
             JOIN months m ON date_trunc('month'::text, p.payment_date::timestamp with time zone)::date = m.month
          WHERE NOT p.is_missing
            AND (p.payment_type = ANY (ARRAY['Payment'::text, 'Prepayment'::text])
                 OR (p.payment_type = 'Voided Payment'::text AND EXISTS (
                      SELECT 1 FROM ar_payments o
                       WHERE o.payment_ref = p.payment_ref AND o.invoice_ref = p.invoice_ref
                         AND o.payment_type = ANY (ARRAY['Payment'::text, 'Prepayment'::text])
                         AND NOT o.is_missing
                         AND date_trunc('month'::text, o.payment_date::timestamp with time zone) = date_trunc('month'::text, p.payment_date::timestamp with time zone))))
          GROUP BY m.month, p.invoice_ref, (COALESCE(p.rep_code, ''::text)), p.currency
        ), cash_rows AS (
         SELECT c.month, i.rep_code, c.currency, NULL::text AS rep_name,
            LEAST(c.amt, i.bal) AS targeted, 0::numeric AS other
           FROM cash c
             JOIN inv i ON i.month = c.month AND i.ref_nbr = c.invoice_ref AND i.currency = c.currency
        UNION ALL
         SELECT c.month, c.rep_code, c.currency, c.rep_name, 0::numeric AS "numeric",
                CASE WHEN i.bal IS NULL THEN c.amt ELSE c.amt - LEAST(c.amt, i.bal) END AS "case"
           FROM cash c
             LEFT JOIN inv i ON i.month = c.month AND i.ref_nbr = c.invoice_ref AND i.currency = c.currency
        ), cash_agg AS (
         SELECT cash_rows.month, cash_rows.rep_code, cash_rows.currency, max(cash_rows.rep_name) AS rep_name,
            sum(cash_rows.targeted) AS actual_targeted, sum(cash_rows.other) AS actual_other
           FROM cash_rows
          GROUP BY cash_rows.month, cash_rows.rep_code, cash_rows.currency
        ), adj AS (
         SELECT i.month, i.rep_code, i.currency,
            sum(p.applied_amount) FILTER (WHERE p.payment_type = 'Credit Memo'::text) AS credit_adj,
            sum(p.applied_amount) FILTER (WHERE p.payment_type = 'Balance WO'::text) AS wo_adj
           FROM ar_payments p
             JOIN months m ON date_trunc('month'::text, p.payment_date::timestamp with time zone)::date = m.month
             JOIN inv i ON i.month = m.month AND i.ref_nbr = p.invoice_ref AND i.currency = p.currency
          WHERE NOT p.is_missing AND (p.payment_type = ANY (ARRAY['Credit Memo'::text, 'Balance WO'::text]))
          GROUP BY i.month, i.rep_code, i.currency
        ), keys AS (
         SELECT tg_1.month, tg_1.rep_code, tg_1.currency FROM tg tg_1
        UNION
         SELECT cash_agg.month, cash_agg.rep_code, cash_agg.currency FROM cash_agg
        UNION
         SELECT adj_1.month, adj_1.rep_code, adj_1.currency FROM adj adj_1
        )
 SELECT k.month,
    k.rep_code,
    COALESCE(tg.rep_name, ca.rep_name, k.rep_code) AS rep_name,
    k.currency,
    COALESCE(tg.target, 0::numeric) AS target,
    COALESCE(adj.credit_adj, 0::numeric) AS credit_adj,
    COALESCE(adj.wo_adj, 0::numeric) AS wo_adj,
    COALESCE(tg.target, 0::numeric) - COALESCE(adj.credit_adj, 0::numeric) - COALESCE(adj.wo_adj, 0::numeric)
      - COALESCE(tg.late_adj, 0::numeric) - COALESCE(tg.small_adj, 0::numeric) AS adjusted_target,
    COALESCE(ca.actual_targeted, 0::numeric) AS actual_targeted,
    COALESCE(ca.actual_other, 0::numeric) AS actual_other,
    COALESCE(ca.actual_targeted, 0::numeric) + COALESCE(ca.actual_other, 0::numeric) AS actual_total,
        CASE WHEN k.currency = 'USD'::text THEN COALESCE(fx.rate, 1::numeric) ELSE 1::numeric END AS rate,
    COALESCE(tg.reconstructed, false) AS reconstructed,
    COALESCE(tg.late_adj, 0::numeric) AS late_adj,
    COALESCE(tg.small_adj, 0::numeric) AS small_adj
   FROM keys k
     LEFT JOIN tg ON tg.month = k.month AND tg.rep_code = k.rep_code AND tg.currency = k.currency
     LEFT JOIN cash_agg ca ON ca.month = k.month AND ca.rep_code = k.rep_code AND ca.currency = k.currency
     LEFT JOIN adj ON adj.month = k.month AND adj.rep_code = k.rep_code AND adj.currency = k.currency
     LEFT JOIN fx ON fx.month = k.month;

grant select on public.ar_month_target_docs to authenticated;
