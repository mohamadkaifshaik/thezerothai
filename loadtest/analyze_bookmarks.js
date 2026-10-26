// analyze_bookmarks.js: ListBookmarks reads per page from the API's JSON request log (W2-15; scenario
// engagement_bookmarks_list.js). Plain Node, no dependencies.
//
//   node loadtest/analyze_bookmarks.js api.log
//
// Per viewer (uid_hash) the ListBookmarks lines are cut into passes: a pass ends at the first page with fewer rows than
// the viewer's page size (an exact multiple ends with one empty page). The first pass of a viewer is "cold" (posts not
// in the instance cache, scenario setup waited out CACHE_TTL), later passes "warm". For each (page size, pass, page
// position) it prints calls, fs_reads min/mean/max and server latency p50/p95, then checks that read_budget_spent
// rises by exactly fs_reads between two consecutive lines of the same viewer (ListBookmarks is charged to the per-uid
// daily read budget, ADR-0010 D5) and counts read_budget_daily rejections. Only lines with message "request" carry
// the fields (pkg/platform/mw Logging).
const fs = require('fs');

const file = process.argv[2];
if (!file) {
  console.error('usage: node loadtest/analyze_bookmarks.js <api.log>');
  process.exit(2);
}

const byUid = new Map();
let rejected = 0;
let errors = 0;
for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
  if (!line.startsWith('{')) continue;
  let o;
  try {
    o = JSON.parse(line);
  } catch (e) {
    continue;
  }
  if (o.severity === 'ERROR') errors++;
  if (o.message !== 'request' || !String(o.rpc || '').includes('ListBookmarks')) continue;
  if (o.limit_name === 'read_budget_daily') rejected++;
  if (!byUid.has(o.uid_hash)) byUid.set(o.uid_hash, []);
  byUid.get(o.uid_hash).push(o);
}

const pct = (a, p) => {
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};
const mean = (a) => a.reduce((s, x) => s + x, 0) / (a.length || 1);

const groups = new Map(); // "ps20 cold first|later|last-empty" -> [lines]
let spentChecks = 0;
let spentMismatch = 0;
const mismatches = [];
for (const [uid, rows] of byUid) {
  const ps = Math.max(...rows.map((r) => r.rows_returned || 0)) >= 50 ? 50 : 20;
  let pass = 0;
  let idx = 0;
  rows.forEach((r, n) => {
    const returned = r.rows_returned || 0;
    const kind = idx === 0 ? 'first page' : returned === 0 ? 'terminal empty page' : returned < ps ? 'terminal short page' : 'later full page';
    const key = `page_size=${ps} ${pass === 0 ? 'cold' : 'warm'} ${kind}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
    if (n > 0 && r.read_budget_spent !== undefined && rows[n - 1].read_budget_spent !== undefined && r.code !== 'resource_exhausted') {
      spentChecks++;
      const delta = r.read_budget_spent - rows[n - 1].read_budget_spent;
      if (delta !== (r.fs_reads || 0)) {
        spentMismatch++;
        if (mismatches.length < 5) mismatches.push(`uid ${uid} line ${n}: spent +${delta} vs fs_reads ${r.fs_reads}`);
      }
    }
    idx++;
    if (returned < ps) {
      pass++;
      idx = 0;
    }
  });
}

for (const [key, rows] of [...groups.entries()].sort()) {
  const reads = rows.map((r) => r.fs_reads || 0);
  const lat = rows.map((r) => r.latency_ms);
  const hist = {};
  for (const x of reads) hist[x] = (hist[x] || 0) + 1;
  console.log(
    `${key}: calls=${rows.length} fs_reads min=${Math.min(...reads)} mean=${mean(reads).toFixed(2)} max=${Math.max(...reads)} hist=${JSON.stringify(hist)} server_latency_ms p50=${pct(lat, 50)} p95=${pct(lat, 95)} writes_max=${Math.max(...rows.map((r) => r.fs_writes || 0))}`,
  );
}
console.log(`read_budget_spent delta == fs_reads: ${spentChecks - spentMismatch}/${spentChecks} consecutive pairs${mismatches.length ? ' MISMATCHES: ' + mismatches.join('; ') : ''}`);
console.log(`read_budget_daily rejections: ${rejected}   ERROR lines: ${errors}   viewers: ${byUid.size}`);
