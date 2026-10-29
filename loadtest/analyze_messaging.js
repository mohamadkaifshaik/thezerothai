// analyze_messaging.js: W7 reads, writes, deletes and server time per call from the API's JSON request log (W7-23; scenario
// messaging.js). Plain Node, no dependencies.
//
//   node loadtest/analyze_messaging.js api.log k6.out [--from-line N]
//
// api.log is the API process's stdout (JSON lines); k6.out is the k6 console output (stdout and stderr together), which carries the
// `W723 PHASE <name> <iso time>` markers. The log is cut into phases at the first marker of each phase; a phase ends where the next
// one starts (the last one at the end of the log). Prints, per phase and per (rpc, kind, folder): calls, histogram and mean of
// fs_reads / fs_writes / fs_deletes, server time (latency_ms) p50 / p95 / max, the response codes, and for ListMessages the `results`
// (messages returned) histogram; the Send txn_attempts histogram and the contention WARNs; the poll share of all requests in the herd
// phase; the VERIFY line of the burst. Only lines with message "request" carry the fields. latency_ms is an integer number of ms.
const fs = require('fs');

const args = process.argv.slice(2);
const fromLineIdx = args.indexOf('--from-line');
const fromLine = fromLineIdx >= 0 ? parseInt(args[fromLineIdx + 1], 10) : 0;
const files = args.filter((a, i) => !a.startsWith('--') && !(fromLineIdx >= 0 && i === fromLineIdx + 1));
if (files.length < 2) {
  console.error('usage: node loadtest/analyze_messaging.js <api.log> <k6.out> [--from-line N]');
  process.exit(2);
}
const [apiLog, k6Out] = files;

const phases = [];
let verify = '';
for (const line of fs.readFileSync(k6Out, 'utf8').split(/\r?\n/)) {
  const m = /W723 PHASE (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m) phases.push({ name: m[1], start: Date.parse(m[2]) });
  const v = /W723 VERIFY ([^"]*)/.exec(line);
  if (v) verify = v[1];
}
phases.sort((a, b) => a.start - b.start);
// trickle and burst_poller markers run inside poll_herd and send_burst: keep them out of the phase boundaries.
const bounds = phases.filter((p) => !['trickle', 'burst_poller'].includes(p.name));
const phaseOf = (t) => {
  let cur = '(before the first phase)';
  for (const p of bounds) if (t >= p.start) cur = p.name;
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

const byPhase = new Map();
const allRequests = new Map(); // phase -> count of every request line
let warns = 0;
let errors = 0;
const warnKinds = new Map();
const lines = fs.readFileSync(apiLog, 'utf8').split(/\r?\n/);
for (let n = fromLine; n < lines.length; n++) {
  const line = lines[n];
  if (!line.startsWith('{')) continue;
  let o;
  try {
    o = JSON.parse(line);
  } catch (e) {
    continue;
  }
  if (o.severity === 'ERROR') errors++;
  if (o.severity === 'WARNING' || o.severity === 'WARN') {
    warns++;
    warnKinds.set(o.message, (warnKinds.get(o.message) || 0) + 1);
  }
  if (o.message !== 'request') continue;
  const ph = phaseOf(Date.parse(o.time));
  allRequests.set(ph, (allRequests.get(ph) || 0) + 1);
  if (!String(o.rpc || '').includes('MessagingService')) continue;
  if (!byPhase.has(ph)) byPhase.set(ph, []);
  byPhase.get(ph).push(o);
}

for (const p of bounds.map((b) => b.name).concat(['(before the first phase)'])) {
  const rs = byPhase.get(p);
  if (!rs) continue;
  console.log(`\n=== phase ${p}: ${rs.length} messaging request lines of ${allRequests.get(p)} request lines`);
  const groups = new Map();
  for (const r of rs) {
    const k = `${short(r.rpc)} kind=${r.kind || '-'}${r.folder ? ' folder=' + r.folder : ''} code=${r.code}${r.limit_name ? ' limit=' + r.limit_name : ''}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r);
  }
  for (const [k, g] of [...groups.entries()].sort()) {
    const lat = g.map((r) => r.latency_ms || 0);
    console.log(`${k}  n=${g.length}`);
    console.log(`    fs_reads   ${stat(g.map((r) => r.fs_reads || 0))}`);
    console.log(`    fs_writes  ${stat(g.map((r) => r.fs_writes || 0))}`);
    if (g.some((r) => r.fs_deletes)) console.log(`    fs_deletes ${stat(g.map((r) => r.fs_deletes || 0))}`);
    console.log(`    latency_ms p50 ${pct(lat, 50)} p95 ${pct(lat, 95)} p99 ${pct(lat, 99)} max ${Math.max(...lat)} mean ${mean(lat).toFixed(1)}`);
    if (g.some((r) => r.results !== undefined)) console.log(`    results    ${stat(g.map((r) => r.results || 0))}`);
    if (g.some((r) => r.txn_attempts !== undefined)) console.log(`    txn_attempts ${stat(g.map((r) => r.txn_attempts || 0))}`);
    if (g.some((r) => r.cache_hit !== undefined)) console.log(`    cache_hit  true=${g.filter((r) => r.cache_hit === true).length} false=${g.filter((r) => r.cache_hit === false).length}`);
    if (g.some((r) => r.replay !== undefined)) console.log(`    replay     true=${g.filter((r) => r.replay === true).length}`);
    if (g.some((r) => r.state !== undefined)) console.log(`    state      ${hist(g.map((r) => r.state))}`);
    if (g.some((r) => r.refused_reason !== undefined)) console.log(`    refused    ${hist(g.map((r) => r.refused_reason || '-'))}`);
  }
  if (p === 'poll_herd') {
    const polls = rs.filter((r) => String(r.rpc).endsWith('/ListMessages') && r.kind === 'poll');
    const all = allRequests.get(p);
    const sendLines = rs.filter((r) => String(r.rpc).endsWith('/SendMessage'));
    console.log(`  poll share of every request line in the phase: ${polls.length} of ${all} = ${((100 * polls.length) / all).toFixed(1)}%`);
    const nonEmpty = polls.filter((r) => (r.results || 0) > 0).length;
    console.log(`  polls returning 0 messages: ${polls.length - nonEmpty}; returning 1 or more: ${nonEmpty} (${((100 * nonEmpty) / polls.length).toFixed(1)}%); trickle sends: ${sendLines.length}`);
    const t0 = Math.min(...rs.map((r) => Date.parse(r.time)));
    const t1 = Math.max(...rs.map((r) => Date.parse(r.time)));
    console.log(`  window ${((t1 - t0) / 1000).toFixed(0)} s; poll rate ${(polls.length / ((t1 - t0) / 1000)).toFixed(1)}/s`);
    // Polls by their position in the user's own sequence (a poll is warm once the interceptor profile and conversation are cached).
    const byUser = new Map();
    for (const r of polls) {
      if (!byUser.has(r.uid_hash)) byUser.set(r.uid_hash, []);
      byUser.get(r.uid_hash).push(r);
    }
    const first = [];
    const later = [];
    for (const us of byUser.values()) us.forEach((r, i) => (i === 0 ? first : later).push(r.fs_reads || 0));
    console.log(`  fs_reads of each user's FIRST poll: ${stat(first)}`);
    console.log(`  fs_reads of every later poll:       ${stat(later)}`);
  }
}
console.log(`\nWARN lines: ${warns} ${[...warnKinds.entries()].map(([k, v]) => `${k}=${v}`).join(' ')}; ERROR lines: ${errors}`);
if (verify) console.log(`VERIFY ${verify}`);
