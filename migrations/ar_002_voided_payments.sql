-- AR Collections: a voided payment only counts when the payment it cancels was itself counted in the same month.
-- When a payment is voided in Acumatica its original application lines disappear (is_missing) or never reach the sync,
-- so the void's negative lines were being subtracted from Collected with nothing to offset them: an invoice that was
-- simply still open showed "Collected -84,847" and "Still open 169,695". With this rule a payment received and voided
-- in the same month still nets to zero, and a void of a payment that was never counted is ignored.
-- Only the cash CTE changes; everything else is ar_month_summary as it was.

create or replace view public.ar_month_summary with (security_invoker = true) as
 WITH months AS (
         SELECT DISTINCT ar_month_targets.month
           FROM ar_month_targets
        ), tg AS (
         SELECT ar_month_targets.month,
            COALESCE(ar_month_targets.rep_code, ''::text) AS rep_code,
            max(ar_month_targets.rep_name) AS rep_name,
            ar_month_targets.currency,
            sum(ar_month_targets.balance_doc) AS target,
            sum(ar_month_targets.balance_jmd) AS target_jmd,
            bool_or(ar_month_targets.source = 'reconstructed'::text) AS reconstructed
           FROM ar_month_targets
          GROUP BY ar_month_targets.month, (COALESCE(ar_month_targets.rep_code, ''::text)), ar_month_targets.currency
        ), fx AS (
         SELECT ar_month_targets.month,
            sum(ar_month_targets.balance_jmd) / NULLIF(sum(ar_month_targets.balance_doc), 0::numeric) AS rate
           FROM ar_month_targets
          WHERE ar_month_targets.currency = 'USD'::text
          GROUP BY ar_month_targets.month
        ), inv AS (
         SELECT ar_month_targets.month,
            ar_month_targets.ref_nbr,
            ar_month_targets.currency,
            COALESCE(ar_month_targets.rep_code, ''::text) AS rep_code,
            sum(ar_month_targets.balance_doc) AS bal
           FROM ar_month_targets
          WHERE ar_month_targets.doc_type = 'Invoice'::text
          GROUP BY ar_month_targets.month, ar_month_targets.ref_nbr, ar_month_targets.currency, (COALESCE(ar_month_targets.rep_code, ''::text))
        ), cash AS (
         SELECT m.month,
            p.invoice_ref,
            COALESCE(p.rep_code, ''::text) AS rep_code,
            p.currency,
            max(p.rep_name) AS rep_name,
            sum(p.applied_amount) AS amt
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
         SELECT c.month,
            i.rep_code,
            c.currency,
            NULL::text AS rep_name,
            LEAST(c.amt, i.bal) AS targeted,
            0::numeric AS other
           FROM cash c
             JOIN inv i ON i.month = c.month AND i.ref_nbr = c.invoice_ref AND i.currency = c.currency
        UNION ALL
         SELECT c.month,
            c.rep_code,
            c.currency,
            c.rep_name,
            0::numeric AS "numeric",
                CASE
                    WHEN i.bal IS NULL THEN c.amt
                    ELSE c.amt - LEAST(c.amt, i.bal)
                END AS "case"
           FROM cash c
             LEFT JOIN inv i ON i.month = c.month AND i.ref_nbr = c.invoice_ref AND i.currency = c.currency
        ), cash_agg AS (
         SELECT cash_rows.month,
            cash_rows.rep_code,
            cash_rows.currency,
            max(cash_rows.rep_name) AS rep_name,
            sum(cash_rows.targeted) AS actual_targeted,
            sum(cash_rows.other) AS actual_other
           FROM cash_rows
          GROUP BY cash_rows.month, cash_rows.rep_code, cash_rows.currency
        ), adj AS (
         SELECT i.month,
            i.rep_code,
            i.currency,
            sum(p.applied_amount) FILTER (WHERE p.payment_type = 'Credit Memo'::text) AS credit_adj,
            sum(p.applied_amount) FILTER (WHERE p.payment_type = 'Balance WO'::text) AS wo_adj
           FROM ar_payments p
             JOIN months m ON date_trunc('month'::text, p.payment_date::timestamp with time zone)::date = m.month
             JOIN inv i ON i.month = m.month AND i.ref_nbr = p.invoice_ref AND i.currency = p.currency
          WHERE NOT p.is_missing AND (p.payment_type = ANY (ARRAY['Credit Memo'::text, 'Balance WO'::text]))
          GROUP BY i.month, i.rep_code, i.currency
        ), keys AS (
         SELECT tg_1.month,
            tg_1.rep_code,
            tg_1.currency
           FROM tg tg_1
        UNION
         SELECT cash_agg.month,
            cash_agg.rep_code,
            cash_agg.currency
           FROM cash_agg
        UNION
         SELECT adj_1.month,
            adj_1.rep_code,
            adj_1.currency
           FROM adj adj_1
        )
 SELECT k.month,
    k.rep_code,
    COALESCE(tg.rep_name, ca.rep_name, k.rep_code) AS rep_name,
    k.currency,
    COALESCE(tg.target, 0::numeric) AS target,
    COALESCE(adj.credit_adj, 0::numeric) AS credit_adj,
    COALESCE(adj.wo_adj, 0::numeric) AS wo_adj,
    COALESCE(tg.target, 0::numeric) - COALESCE(adj.credit_adj, 0::numeric) - COALESCE(adj.wo_adj, 0::numeric) AS adjusted_target,
    COALESCE(ca.actual_targeted, 0::numeric) AS actual_targeted,
    COALESCE(ca.actual_other, 0::numeric) AS actual_other,
    COALESCE(ca.actual_targeted, 0::numeric) + COALESCE(ca.actual_other, 0::numeric) AS actual_total,
        CASE
            WHEN k.currency = 'USD'::text THEN COALESCE(fx.rate, 1::numeric)
            ELSE 1::numeric
        END AS rate,
    COALESCE(tg.reconstructed, false) AS reconstructed
   FROM keys k
     LEFT JOIN tg ON tg.month = k.month AND tg.rep_code = k.rep_code AND tg.currency = k.currency
     LEFT JOIN cash_agg ca ON ca.month = k.month AND ca.rep_code = k.rep_code AND ca.currency = k.currency
     LEFT JOIN adj ON adj.month = k.month AND adj.rep_code = k.rep_code AND adj.currency = k.currency
     LEFT JOIN fx ON fx.month = k.month;
