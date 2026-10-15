const fs = require('fs');
const app = __dirname + '/../ar-aging.html';
const out = process.argv[2] || __dirname + '/index.html';
let html = fs.readFileSync(app, 'utf8');
// Replace the shared/supabase/guard scripts with a mock client.
html = html.replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase[\s\S]*?<script src="\/shared\/side-nav\.js"><\/script>/, `<script>
const MOCK = { rows: null };
function chain(table){
  const q = { table, filters:{}, _order:[], _range:null };
  const api = {
    select(){ return api; },
    eq(k,v){ q.filters[k]=v; return api; },
    order(){ return api; },
    limit(){ return api; },
    range(a,b){ q._range=[a,b]; return api; },
    upsert(row){ MOCK.lastUpsert=row; return Promise.resolve({error:null}); },
    delete(){ return { eq(){ return { eq(){ return Promise.resolve({error:null}); } }; } }; },
    then(res){ res(run(q)); }
  };
  return api;
}
function run(q){
  if(q.table==='ar_aging_snapshots') return { data:[
    {id:2,snapshot_date:'2026-10-14',completed_at:new Date().toISOString(),row_count:1,total_jmd:1},
    {id:1,snapshot_date:'2026-10-12',completed_at:'2026-10-12T11:00:00Z',row_count:1,total_jmd:1}], error:null };
  if(q.table==='ar_disputes') return { data:[{doc_type:'Invoice',ref_nbr:MOCK.rows[0].ref_nbr,note:'Customer says short delivery'}], error:null };
  let rows = MOCK.rows;
  if(MOCK.role==='rep') rows = rows.filter(r=>r.rep_code==='CLH');
  if(q.filters.snapshot_id===1) rows = rows.map(r=>Object.assign({},r,{balance_jmd:r.balance_jmd*0.9}));
  const [a,b]=q._range; return { data: rows.slice(a,b+1), error:null };
}
const sb = { from: chain };
</script>`);
html = html.replace('</body>', `<script>
fetch('rows.json').then(r=>r.json()).then(rows=>{
  MOCK.rows = rows; MOCK.role = new URLSearchParams(location.search).get('role') || 'manager';
  document.body.style.visibility='visible';
  document.dispatchEvent(new CustomEvent('dfl-auth-ready',{detail:{profile:{id:'u1',full_name:'Test',role:MOCK.role,salesperson_id:'CLH'}}}));
});
</script></body>`);
fs.writeFileSync(out, html);
