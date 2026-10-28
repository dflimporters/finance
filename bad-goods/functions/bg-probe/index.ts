// bg-probe: READ-ONLY check of the Acumatica TEST tenant for the Bad Goods portal.
// TEST and live are two tenants on the same host (dflimporters.acumatica.com), so
// switching to live later is just a change of ACU_BADGOODS_TENANT.
// Signs in with the bad goods API user, scans stock items for UOM conversions,
// looks for the generic BAD GOODS non-stock item, finds recent BAD GOODS credit
// memos, then signs out. Nothing is written.
//
// Calls run one at a time with a pause between them.
//
// POST with header x-test-token = SHIPVIA_TEST_TOKEN (same token acu-probe uses).

const BASE    = 'https://dflimporters.acumatica.com';
const VERSION = '24.200.001';
const GAP_MS  = 1500;

const USERNAME = Deno.env.get('ACU_BADGOODS_USERNAME') ?? '';
const PASSWORD = Deno.env.get('ACU_BADGOODS_PASSWORD') ?? '';
const TENANT   = Deno.env.get('ACU_BADGOODS_TENANT') ?? '';
const TOKEN    = Deno.env.get('SHIPVIA_TEST_TOKEN') ?? '';

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });
function sameToken(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const v = (f: any) => { const x = f?.value; return typeof x === 'string' ? (x.trim() || null) : (x ?? null); };

let cookie = '';
let calls = 0;
async function call(method: string, path: string, body?: unknown) {
  if (calls++) await sleep(GAP_MS);
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { Cookie: cookie, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 500); }
  return { status: res.status, ok: res.ok, data, setCookie: res.headers.getSetCookie() };
}
const err = (r: { status: number; data: any }) => ({ status: r.status, error: typeof r.data === 'string' ? r.data : (r.data?.message ?? r.data?.exceptionMessage ?? r.data) });
const FIELD_SKIP = ['id', 'rowNumber', 'note', 'custom', '_links'];

async function probe() {
  const out: Record<string, unknown> = { base: BASE, tenant: TENANT, version: VERSION };
  const login = await call('POST', '/entity/auth/login', { name: USERNAME, password: PASSWORD, tenant: TENANT });
  out.login = login.ok ? 'ok' : err(login);
  if (!login.ok) return out;
  cookie = login.setCookie.map(c => c.split(';')[0]).join('; ');

  try {
    const ent = `/entity/Default/${VERSION}`;

    // Scan a block of stock items for UOM conversions (items sold in units should have one).
    const si = await call('GET', `${ent}/StockItem?$top=300&$select=InventoryID,Description,BaseUOM,SalesUOM,DefaultPrice&$expand=UOMConversions`);
    if (si.ok) {
      const items = si.data as any[];
      const withConv = items.filter(x => (x.UOMConversions ?? []).length > 0);
      out.stock_scan = {
        scanned: items.length,
        with_conversions: withConv.length,
        base_uoms: [...new Set(items.map(x => v(x.BaseUOM)))],
        sales_uoms: [...new Set(items.map(x => v(x.SalesUOM)))],
        conversion_field_names: withConv[0]?.UOMConversions?.[0] ? Object.keys(withConv[0].UOMConversions[0]).filter(k => !FIELD_SKIP.includes(k)) : [],
        sample: withConv.slice(0, 6).map(x => ({
          id: v(x.InventoryID), desc: v(x.Description), base: v(x.BaseUOM), sales: v(x.SalesUOM), default_price: v(x.DefaultPrice),
          conversions: (x.UOMConversions ?? []).map((c: any) => Object.fromEntries(Object.entries(c).filter(([k]) => !FIELD_SKIP.includes(k)).map(([k, f]) => [k, v(f)]))),
        })),
      };
    } else out.stock_scan = err(si);

    // Generic non-stock item: plain lookups, no expand.
    const g1 = await call('GET', `${ent}/NonStockItem?$filter=InventoryID eq '10001840'`);
    out.generic_item_by_id = g1.ok ? (g1.data as any[]).map(x => ({ id: v(x.InventoryID), desc: v(x.Description), base: v(x.BaseUOM), sales: v(x.SalesUOM), status: v(x.ItemStatus) })) : err(g1);
    const g2 = await call('GET', `${ent}/NonStockItem?$top=5&$filter=startswith(Description,'BAD GOODS')&$select=InventoryID,Description,BaseUOM,SalesUOM,ItemStatus`);
    out.generic_item_by_name = g2.ok ? (g2.data as any[]).map(x => ({ id: v(x.InventoryID), desc: v(x.Description), base: v(x.BaseUOM), sales: v(x.SalesUOM), status: v(x.ItemStatus) })) : err(g2);

    // Existing BAD GOODS credit memos (if the TEST tenant has any recent ones).
    const inv = await call('GET', `${ent}/Invoice?$top=3&$filter=Type eq 'Credit Memo' and startswith(Description,'BAD GOODS')&$expand=Details`);
    out.bad_goods_memos = inv.ok
      ? (inv.data as any[]).map(x => ({
          ref: v(x.ReferenceNbr), customer: v(x.Customer), customer_order: v(x.CustomerOrder), description: v(x.Description),
          status: v(x.Status), hold: v(x.Hold), date: v(x.Date), tax_total: v(x.TaxTotal), amount: v(x.Amount),
          lines: (x.Details ?? []).slice(0, 10).map((d: any) => ({
            inv: v(d.InventoryID), descr: v(d.TransactionDescription), qty: v(d.Qty), uom: v(d.UOM), price: v(d.UnitPrice), ext: v(d.ExtendedPrice), branch: v(d.Branch), account: v(d.Account), taxcat: v(d.TaxCategory),
          })),
        }))
      : err(inv);
  } finally {
    const lo = await call('POST', '/entity/auth/logout');
    out.logout = lo.status;
  }
  out.calls = calls;
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  if (!TOKEN || !sameToken(req.headers.get('x-test-token') ?? '', TOKEN)) return json({ ok: false, error: 'bad or missing x-test-token' }, 401);
  if (!USERNAME || !PASSWORD || !TENANT) return json({ ok: false, error: 'ACU_BADGOODS_USERNAME / PASSWORD / TENANT not all set' }, 500);
  try { return json({ ok: true, ...(await probe()) }); }
  catch (e) { return json({ ok: false, error: String(e) }, 500); }
});
