// Supabase Edge Function: sync-ar-aging
// Pulls the DFL_ARAging Generic Inquiry from Acumatica OData and stores a
// snapshot in ar_aging_snapshots / ar_aging_rows. Scheduled Mon + Thu.
//
// Rules (agreed with the user):
// - Age on DOC DATE: days_aged = snapshot_date (Jamaica) - doc date.
//   Buckets: Current (<=30, incl. negative for future-dated), 31-60, 61-90, 90+.
// - Credit Memo + Payment arrive POSITIVE in the feed -> negated, bucket 'Credit'.
// - Totals use DocBal (JMD base balance).
// - Customer C000006724 (DFL INTERNAL OFFICE EXPENSE) is excluded.
// - Blank rep / HOUSE / Sales Office are kept with their code; RLS keeps them
//   management-only (a rep only ever sees rows where rep_code = their own code).
// - A snapshot only becomes 'complete' after every row is stored, so the app
//   never shows a half-loaded snapshot.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ACUMATICA_USERNAME = Deno.env.get('ACUMATICA_USERNAME')!;
const ACUMATICA_PASSWORD = Deno.env.get('ACUMATICA_PASSWORD')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const ENDPOINT = 'https://dflimporters.acumatica.com/odata/dfl%20importers/DFL_ARAging';
const EXCLUDED_CUSTOMERS = new Set(['C000006724']);
const CREDIT_TYPES = new Set(['Credit Memo', 'Payment']);
const KNOWN_TYPES = new Set(['Invoice', 'Debit Memo', 'Credit Memo', 'Payment']);
const BATCH = 500;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, apikey',
};

function t(v: any): string | null {
  if (v == null) return null;
  const s = String(v).trim();
  return s === '' ? null : s;
}
function n(v: any): number | null {
  if (v == null || v === '') return null;
  const x = Number(v);
  return isNaN(x) ? null : x;
}
function d(v: any): string | null {
  const s = t(v);
  return s ? s.slice(0, 10) : null; // ISO, no timezone -> plain date
}

function jamaicaToday(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Jamaica' }).format(new Date());
}
function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(a + 'T00:00:00Z') - Date.parse(b + 'T00:00:00Z')) / 86400000);
}
function bucketFor(days: number): string {
  if (days <= 30) return 'Current';
  if (days <= 60) return '31-60';
  if (days <= 90) return '61-90';
  return '90+';
}

async function fetchAll(): Promise<any[]> {
  const url = new URL(ENDPOINT);
  url.searchParams.set('$format', 'json');
  const res = await fetch(url.toString(), {
    headers: {
      Authorization: `Basic ${btoa(`${ACUMATICA_USERNAME}:${ACUMATICA_PASSWORD}`)}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) throw new Error(`OData fetch failed: ${res.status} ${await res.text()}`);
  const json = await res.json();
  return Array.isArray(json) ? json : (json.value ?? []);
}

async function runSync(): Promise<Record<string, any>> {
  const snapshotDate = jamaicaToday();
  const { data: snap, error: snapErr } = await supabase
    .from('ar_aging_snapshots')
    .insert({ snapshot_date: snapshotDate })
    .select('id')
    .single();
  if (snapErr) throw new Error(`snapshot insert: ${snapErr.message}`);
  const snapshotId = snap.id as number;

  try {
    const raw = await fetchAll();
    if (raw.length === 0) throw new Error('Feed returned 0 rows - refusing to store an empty snapshot');

    const rows = new Map<string, Record<string, any>>();
    const unknownTypes: Record<string, number> = {};
    let dupes = 0, excluded = 0, total = 0;

    for (const r of raw) {
      const customerId = t(r.CustomerID);
      const docType = t(r.Type);
      const ref = t(r.ReferenceNbr);
      if (!customerId || !docType || !ref) continue;
      if (EXCLUDED_CUSTOMERS.has(customerId)) { excluded++; continue; }
      if (!KNOWN_TYPES.has(docType)) unknownTypes[docType] = (unknownTypes[docType] ?? 0) + 1;

      const isCredit = CREDIT_TYPES.has(docType);
      const sign = isCredit ? -1 : 1;
      const docDate = d(r.Date);
      const days = docDate ? daysBetween(snapshotDate, docDate) : null;
      const balJmd = n(r.DocBal);
      const key = `${docType}|${ref}`;
      if (rows.has(key)) dupes++;

      const row = {
        snapshot_id: snapshotId,
        doc_type: docType,
        ref_nbr: ref,
        rep_code: t(r.SalespersonID),
        rep_name: t(r.Name),
        rep_numeric_id: n(r.SalesPersonID_2),
        customer_id: customerId,
        customer_name: t(r.CustomerName),
        doc_date: docDate,
        due_date: d(r.DueDate),
        currency: t(r.Currency),
        amount_doc: n(r.Amount) == null ? null : n(r.Amount)! * sign,
        balance_doc: n(r.Balance) == null ? null : n(r.Balance)! * sign,
        balance_jmd: balJmd == null ? null : balJmd * sign,
        terms: t(r.Terms),
        is_credit: isCredit,
        days_aged: isCredit ? null : days,
        bucket: isCredit ? 'Credit' : bucketFor(days ?? 0),
      };
      rows.set(key, row);
    }

    const all = Array.from(rows.values());
    for (const r of all) total += r.balance_jmd ?? 0;

    for (let i = 0; i < all.length; i += BATCH) {
      const { error } = await supabase.from('ar_aging_rows').insert(all.slice(i, i + BATCH));
      if (error) throw new Error(`rows insert at ${i}: ${error.message}`);
    }

    // Replace any earlier complete snapshot taken the same day.
    await supabase.from('ar_aging_snapshots').delete()
      .eq('snapshot_date', snapshotDate).eq('status', 'complete');

    const notes = { fetched: raw.length, stored: all.length, excluded, duplicate_keys: dupes, unknown_types: unknownTypes };
    const { error: doneErr } = await supabase.from('ar_aging_snapshots').update({
      status: 'complete', completed_at: new Date().toISOString(),
      row_count: all.length, total_jmd: Math.round(total * 100) / 100, notes,
    }).eq('id', snapshotId);
    if (doneErr) throw new Error(`snapshot complete: ${doneErr.message}`);

    // Tidy up failed/abandoned attempts older than a day.
    await supabase.from('ar_aging_snapshots').delete()
      .in('status', ['loading', 'failed']).lt('started_at', new Date(Date.now() - 86400000).toISOString());

    return { snapshot_id: snapshotId, snapshot_date: snapshotDate, total_jmd: total, ...notes };
  } catch (err) {
    await supabase.from('ar_aging_snapshots').update({
      status: 'failed', completed_at: new Date().toISOString(), notes: { error: String(err) },
    }).eq('id', snapshotId);
    throw err;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  try {
    const result = await runSync();
    return new Response(JSON.stringify({ success: true, ...result }), {
      headers: { 'Content-Type': 'application/json', ...CORS },
    });
  } catch (err) {
    console.error('sync-ar-aging failed:', err);
    return new Response(JSON.stringify({ success: false, error: String(err) }), {
      status: 500, headers: { 'Content-Type': 'application/json', ...CORS },
    });
  }
});
