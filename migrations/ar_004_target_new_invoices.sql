-- AR Collections target: add invoices raised during the month that fall due by month end ("new this month").
--   * seen open in any AR snapshot taken that month: added at their original amount, from the first snapshot they appear in
--   * paid before any snapshot saw them open (e.g. cash on delivery): added from the payment history at the amount
--     applied, with the due date estimated from customer terms (same estimate ar_freeze_month uses)
-- They are not frozen: the target grows through the month as invoices are raised. Cash on them now counts as
-- "on targeted" instead of "early / other"; credit memos applied to them lower the target like any targeted invoice.
-- ar_month_target_docs gains source = 'new' rows; ar_month_summary gets a new_target column (appended), target stays the
-- month-start figure and adjusted_target = target + new_target - credits - write-offs - late_adj - small_adj.

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
    left join customers c on c.customer_id = r.customer_id
    cross join lateral (select r.invoice_date + coalesce(nullif(regexp_replace(coalesce(c.terms, ''), '\D', '', 'g'), '')::int, 0) as due) x
   where r.amt > 0.005 and x.due < (r.month + interval '1 month')::date
     and not exists (select 1 from ar_month_targets t where t.month = r.month and t.doc_type = 'Invoice' and t.ref_nbr = r.invoice_ref)
     and not exists (select 1 from new_seen n where n.month = r.month and n.ref_nbr = r.invoice_ref)
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

create or replace view public.ar_month_summary with (security_invoker = true) as
 WITH months AS (
         SELECT DISTINCT ar_month_targets.month FROM ar_month_targets
        ), tdocs AS (
         SELECT * FROM ar_month_target_docs
        ), tg AS (
         SELECT tdocs.month, tdocs.rep_code, max(tdocs.rep_name) AS rep_name, tdocs.currency,
            sum(tdocs.bal) FILTER (WHERE tdocs.source <> 'new'::text) AS target,
            sum(tdocs.bal) FILTER (WHERE tdocs.source = 'new'::text) AS new_target,
            sum(tdocs.late_adj) AS late_adj, sum(tdocs.small_adj) AS small_adj,
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
    COALESCE(tg.target, 0::numeric) + COALESCE(tg.new_target, 0::numeric) - COALESCE(adj.credit_adj, 0::numeric) - COALESCE(adj.wo_adj, 0::numeric)
      - COALESCE(tg.late_adj, 0::numeric) - COALESCE(tg.small_adj, 0::numeric) AS adjusted_target,
    COALESCE(ca.actual_targeted, 0::numeric) AS actual_targeted,
    COALESCE(ca.actual_other, 0::numeric) AS actual_other,
    COALESCE(ca.actual_targeted, 0::numeric) + COALESCE(ca.actual_other, 0::numeric) AS actual_total,
        CASE WHEN k.currency = 'USD'::text THEN COALESCE(fx.rate, 1::numeric) ELSE 1::numeric END AS rate,
    COALESCE(tg.reconstructed, false) AS reconstructed,
    COALESCE(tg.late_adj, 0::numeric) AS late_adj,
    COALESCE(tg.small_adj, 0::numeric) AS small_adj,
    COALESCE(tg.new_target, 0::numeric) AS new_target
   FROM keys k
     LEFT JOIN tg ON tg.month = k.month AND tg.rep_code = k.rep_code AND tg.currency = k.currency
     LEFT JOIN cash_agg ca ON ca.month = k.month AND ca.rep_code = k.rep_code AND ca.currency = k.currency
     LEFT JOIN adj ON adj.month = k.month AND adj.rep_code = k.rep_code AND adj.currency = k.currency
     LEFT JOIN fx ON fx.month = k.month;
