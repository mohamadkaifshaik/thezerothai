// analyze_search.js: W4 reads and server time per call from the API's JSON request log (W4-23; scenario search.js). Plain Node, no
// dependencies.
//
//   node loadtest/analyze_search.js api.log k6.out [--from-line N]
//
// api.log is the API process's stdout (JSON lines); k6.out is the k6 console output (stdout and stderr together), which carries the
// `W4 PHASE <name> <iso>` and `W4 STEP <name> <iso>` markers. The log is cut into phases at the first marker of each phase. In the
// serial phases (cold_calls, refresh, trends) every line goes to the last STEP marker before it, so each case prints its own reads.
// In the load phases (trends_herd, typeahead_burst, hot_tag) lines are grouped by rpc, query_kind, tab and cache_hit. The
// `trends_refresh` / `trends_skipped` / `trends_backlog` lines of the refresher are printed with their fs_reads, fs_writes, posts
// scanned and duration. Only lines with message "request" carry the request fields (fs_reads, fs_writes, query_kind, tab, cache_hit,
// results, dropped, code). The raw query is never logged (ADR-0028 D10), so the unsupported share is query_kind=unsupported.
const fs = require('fs');

const args = process.argv.slice(2);
const fromLineIdx = args.indexOf('--from-line');
const fromLine = fromLineIdx >= 0 ? parseInt(args[fromLineIdx + 1], 10) : 0;
const files = args.filter((a, i) => !a.startsWith('--') && !(fromLineIdx >= 0 && i === fromLineIdx + 1));
if (files.length < 2) {
  console.error('usage: node loadtest/analyze_search.js <api.log> <k6.out> [--from-line N]');
  process.exit(2);
}
const [apiLog, k6Out] = files;

const phases = [];
const steps = [];
for (const line of fs.readFileSync(k6Out, 'utf8').split(/\r?\n/)) {
  let m = /W4 PHASE (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m) phases.push({ name: m[1], start: Date.parse(m[2]) });
  m = /W4 STEP (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m) steps.push({ name: m[1], start: Date.parse(m[2]) });
}
phases.sort((a, b) => a.start - b.start);
steps.sort((a, b) => a.start - b.start);
const phaseOf = (t) => {
  let cur = '(before the first phase)';
  for (const p of phases) if (t >= p.start) cur = p.name;
  return cur;
};
const stepOf = (t) => {
  let cur = '(before the first step)';
  for (const s of steps) if (t >= s.start) cur = s.name;
  return cur;
};

const short = (rpc) => String(rpc).split('/').pop();
const mean = (a) => a.reduce((s, x) => s + x, 0) / (a.length || 1);
const pct = (a, p) => {
  if (!a.length) return NaN;
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
const hist = (xs) => {
  const m = new Map();
  for (const x of xs) m.set(x, (m.get(x) || 0) + 1);
  return [...m.entries()].sort((a, b) => a[0] - b[0]).map(([k, v]) => `${k}x${v}`).join(' ');
};
const stat = (xs) => (xs.length ? `mean ${mean(xs).toFixed(2)} min ${Math.min(...xs)} max ${Math.max(...xs)} [${hist(xs)}]` : '-');
const SERIAL = new Set(['cold_calls', 'refresh', 'trends']);

const reqs = new Map(); // phase -> request lines (search service)
const all = new Map(); // phase -> count of every request line
const refreshLines = [];
let warns = 0;
let errors = 0;
const warnKinds = new Map();
const lines = fs.readFileSync(apiLog, 'utf8').split(/\r?\n/);
for (let n = fromLine; n < lines.length; n++) {
  if (!lines[n].startsWith('{')) continue;
  let o;
  try {
    o = JSON.parse(lines[n]);
  } catch (e) {
    continue;
  }
  if (o.severity === 'ERROR') errors++;
  if (o.severity === 'WARNING' || o.severity === 'WARN') {
    warns++;
    warnKinds.set(o.message, (warnKinds.get(o.message) || 0) + 1);
  }
  const t = Date.parse(o.time);
  if (['trends_refresh', 'trends_skipped', 'trends_backlog', 'trends_backlog_skipped'].includes(o.message)) refreshLines.push(o);
  if (o.message !== 'request') continue;
  const ph = phaseOf(t);
  all.set(ph, (all.get(ph) || 0) + 1);
  const rpc = String(o.rpc || '');
  if (!rpc.includes('SearchService') && !rpc.includes('/internal/cron/')) continue;
  if (!reqs.has(ph)) reqs.set(ph, []);
  reqs.get(ph).push(o);
}

const describe = (o) =>
  `${short(o.rpc)}${o.query_kind ? ' kind=' + o.query_kind : ''}${o.tab ? ' tab=' + o.tab : ''} code=${o.code}${o.limit_name ? ' limit=' + o.limit_name : ''}`;

for (const p of phases.map((x) => x.name)) {
  const rs = reqs.get(p);
  if (!rs) continue;
  console.log(`\n=== phase ${p}: ${rs.length} search request lines of ${all.get(p)} request lines`);
  if (SERIAL.has(p)) {
    // One virtual user, one request line per STEP: the k-th line of the phase is the k-th step. (A line's time can fall a few ms either
    // side of the marker on Windows, so matching by time mislabels fast calls.) Falls back to the time when the counts differ.
    const pStart = phases.find((x) => x.name === p).start;
    const nextStart = phases.filter((x) => x.start > pStart).map((x) => x.start).sort((a, b) => a - b)[0] ?? Infinity;
    const mine = steps.filter((x) => x.start >= pStart - 5 && x.start < nextStart && x.name !== 'end');
    const bySeq = mine.length === rs.length;
    if (!bySeq) console.log(`  (steps ${mine.length} != request lines ${rs.length}: labelled by time)`);
    let idx = 0;
    for (const o of rs) {
      const lat = o.latency_ms || 0;
      const label = bySeq ? mine[idx++].name : stepOf(Date.parse(o.time));
      console.log(
        `  ${label.padEnd(40)} ${describe(o)} fs_reads=${o.fs_reads ?? 0} fs_writes=${o.fs_writes ?? 0}` +
          `${o.cache_hit !== undefined ? ' cache_hit=' + o.cache_hit : ''}${o.results !== undefined ? ' results=' + o.results : ''}` +
          `${o.dropped ? ' dropped=' + o.dropped : ''} latency_ms=${lat}`,
      );
    }
    continue;
  }
  const groups = new Map();
  for (const r of rs) {
    const k = `${describe(r)}${r.cache_hit !== undefined ? ' cache_hit=' + r.cache_hit : ''}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r);
  }
  for (const [k, g] of [...groups.entries()].sort()) {
    const lat = g.map((r) => r.latency_ms || 0);
    console.log(`${k}  n=${g.length}`);
    console.log(`    fs_reads   ${stat(g.map((r) => r.fs_reads || 0))}`);
    if (g.some((r) => r.fs_writes)) console.log(`    fs_writes  ${stat(g.map((r) => r.fs_writes || 0))}`);
    console.log(`    latency_ms p50 ${pct(lat, 50)} p95 ${pct(lat, 95)} p99 ${pct(lat, 99)} max ${Math.max(...lat)} mean ${mean(lat).toFixed(1)}`);
    if (g.some((r) => r.results !== undefined)) console.log(`    results    ${stat(g.map((r) => r.results || 0))}`);
  }
  const reads = rs.filter((r) => String(r.rpc).includes('SearchService')).map((r) => r.fs_reads || 0);
  const t0 = Math.min(...rs.map((r) => Date.parse(r.time)));
  const t1 = Math.max(...rs.map((r) => Date.parse(r.time)));
  console.log(`  TOTAL search calls ${reads.length}, fs_reads sum ${reads.reduce((s, x) => s + x, 0)}, mean ${mean(reads).toFixed(3)}, window ${((t1 - t0) / 1000).toFixed(0)} s`);
}

console.log('\n=== refresher lines (trends_refresh / trends_skipped / backlog), in log order');
for (const o of refreshLines) {
  console.log(
    `  ${o.time} ${o.message} fs_reads=${o.fs_reads ?? '-'} fs_writes=${o.fs_writes ?? '-'} scanned=${o.trends_posts_scanned ?? '-'} tags=${o.trends_tags ?? '-'} kept=${o.tags_kept ?? '-'} backlog=${o.backlog ?? '-'} duration_ms=${o.duration_ms ?? '-'}${o.reason ? ' reason=' + o.reason : ''}${o.outcome ? ' outcome=' + o.outcome : ''}`,
  );
}
console.log(`\nWARN lines: ${warns} ${[...warnKinds.entries()].map(([k, v]) => `${k}=${v}`).join(' ')}; ERROR lines: ${errors}`);
