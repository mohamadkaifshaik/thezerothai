// analyze_bookmarks.js: ListBookmarks server latency per page from the API's JSON request log (scenario
// engagement_bookmarks_list.js). Plain Node, no dependencies.
//
//   node loadtest/analyze_bookmarks.js api.log
//
// Per viewer (uid_hash) the ListBookmarks lines are cut into passes: a pass ends at the first page with fewer rows than
// the viewer's page size (an exact multiple ends with one empty page). The first pass of a viewer is "cold" (posts not
// in the instance cache, scenario setup waited out CACHE_TTL), later passes "warm". For each (page size, pass, page
// position) it prints calls and server latency p50/p95/p99. Only lines with message "request" carry
// the fields (pkg/platform/mw Logging).
const fs = require('fs');

const file = process.argv[2];
if (!file) {
  console.error('usage: node loadtest/analyze_bookmarks.js <api.log>');
  process.exit(2);
}

const byUid = new Map();
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
  if (!byUid.has(o.uid_hash)) byUid.set(o.uid_hash, []);
  byUid.get(o.uid_hash).push(o);
}

const pct = (a, p) => {
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};

const groups = new Map(); // "ps20 cold first|later|last-empty" -> [lines]
for (const rows of byUid.values()) {
  const ps = Math.max(...rows.map((r) => r.rows_returned || 0)) >= 50 ? 50 : 20;
  let pass = 0;
  let idx = 0;
  rows.forEach((r) => {
    const returned = r.rows_returned || 0;
    const kind = idx === 0 ? 'first page' : returned === 0 ? 'terminal empty page' : returned < ps ? 'terminal short page' : 'later full page';
    const key = `page_size=${ps} ${pass === 0 ? 'cold' : 'warm'} ${kind}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
    idx++;
    if (returned < ps) {
      pass++;
      idx = 0;
    }
  });
}

for (const [key, rows] of [...groups.entries()].sort()) {
  const lat = rows.map((r) => r.latency_ms);
  console.log(
    `${key}: calls=${rows.length} server_latency_ms p50=${pct(lat, 50)} p95=${pct(lat, 95)} p99=${pct(lat, 99)}`,
  );
}
console.log(`ERROR lines: ${errors}   viewers: ${byUid.size}`);
