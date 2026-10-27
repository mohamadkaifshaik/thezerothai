// analyze_w3_part_a.js: W3 Part A reads per call from the API's JSON request log (W3-23; scenario profile_w3_part_a.js).
// Plain Node, no dependencies.
//
//   node loadtest/analyze_w3_part_a.js api.log          per call position and per RPC
//   node loadtest/analyze_w3_part_a.js --curated-ids [N]   the SUGGESTED_USER_IDS value the suggestions run needs (default 12)
//
// For each viewer (uid_hash) the Part A lines (GetUserTimeline, ListLikedPosts, GetProfileRelationship, ListSuggestedUsers,
// plus the GetProfile of the profile-open flow) are numbered in log order. The first table groups by (position in the
// viewer's sequence, rpc, tab, page size, source): position 1 is a viewer whose caches are cold, later positions show what
// the earlier calls of the same flow warmed. The second table groups by (rpc, tab, page size) over every call. Only lines
// with message "request" carry the fields (pkg/platform/mw Logging). It also checks that read_budget_spent rises by exactly
// fs_reads between two consecutive calls of one viewer, and counts read_budget_daily rejections and ERROR lines.
const fs = require('fs');

if (process.argv[2] === '--curated-ids') {
  const n = parseInt(process.argv[3] || '12', 10);
  console.log(Array.from({ length: n }, (_, i) => 'w323cur' + String(i + 1).padStart(21, '0')).join(','));
  process.exit(0);
}
const file = process.argv[2];
if (!file) {
  console.error('usage: node loadtest/analyze_w3_part_a.js <api.log> | --curated-ids [N]');
  process.exit(2);
}

const WANT = /(GetUserTimeline|ListLikedPosts|GetProfileRelationship|ListSuggestedUsers|IdentityService\/GetProfile$)/;
const short = (rpc) => String(rpc).split('/').pop();
const byUid = new Map();
let errors = 0;
let rejected = 0;
for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
  if (!line.startsWith('{')) continue;
  let o;
  try {
    o = JSON.parse(line);
  } catch (e) {
    continue;
  }
  if (o.severity === 'ERROR') errors++;
  if (o.message !== 'request' || !WANT.test(String(o.rpc || ''))) continue;
  if (o.limit_name === 'read_budget_daily') rejected++;
  if (!byUid.has(o.uid_hash)) byUid.set(o.uid_hash, []);
  byUid.get(o.uid_hash).push(o);
}

const pct = (a, p) => {
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};
const mean = (a) => a.reduce((s, x) => s + x, 0) / (a.length || 1);
const label = (r) => {
  const parts = [short(r.rpc)];
  if (r.tab) parts.push(`tab=${r.tab}`);
  if (r.page_size !== undefined) parts.push(`page=${r.page_size}`);
  if (r.rows_returned !== undefined) parts.push(`rows=${r.rows_returned}`);
  if (r.source) parts.push(`source=${r.source}`);
  if (r.suggestions_cache_hit !== undefined) parts.push(`sugg_cache_hit=${r.suggestions_cache_hit}`);
  return parts.join(' ');
};
const hist = (xs) => {
  const h = {};
  for (const x of xs) h[x] = (h[x] || 0) + 1;
  return JSON.stringify(h);
};
const row = (key, rows) => {
  const reads = rows.map((r) => r.fs_reads || 0);
  const lat = rows.map((r) => r.latency_ms || 0);
  return `${key}: calls=${rows.length} fs_reads min=${Math.min(...reads)} mean=${mean(reads).toFixed(2)} max=${Math.max(...reads)} hist=${hist(reads)} writes_max=${Math.max(...rows.map((r) => r.fs_writes || 0))} server_ms p50=${pct(lat, 50)} p95=${pct(lat, 95)}`;
};

const byPos = new Map();
const byRpc = new Map();
let spentChecks = 0;
let spentMismatch = 0;
for (const rows of byUid.values()) {
  rows.forEach((r, n) => {
    const pos = Math.min(n + 1, 12);
    const k1 = `#${String(pos).padStart(2, '0')}${n + 1 > 12 ? '+' : ' '} ${label(r)}`;
    if (!byPos.has(k1)) byPos.set(k1, []);
    byPos.get(k1).push(r);
    const k2 = label(r).replace(/ sugg_cache_hit=\w+/, '');
    if (!byRpc.has(k2)) byRpc.set(k2, []);
    byRpc.get(k2).push(r);
    if (n > 0 && r.read_budget_spent !== undefined && rows[n - 1].read_budget_spent !== undefined && r.code !== 'resource_exhausted') {
      spentChecks++;
      if (r.read_budget_spent - rows[n - 1].read_budget_spent !== (r.fs_reads || 0)) spentMismatch++;
    }
  });
}
console.log('--- by position in the viewer\'s sequence');
for (const [k, rows] of [...byPos.entries()].sort()) console.log(row(k, rows));
console.log('--- by rpc, tab and page size (all calls)');
for (const [k, rows] of [...byRpc.entries()].sort()) console.log(row(k, rows));
console.log(`read_budget_spent delta == fs_reads: ${spentChecks - spentMismatch}/${spentChecks} consecutive pairs`);
console.log(`read_budget_daily rejections: ${rejected}   ERROR lines: ${errors}   viewers: ${byUid.size}`);
