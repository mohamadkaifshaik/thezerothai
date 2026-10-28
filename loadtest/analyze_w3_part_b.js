// analyze_w3_part_b.js: W3 Part B reads, writes and deletes per call from the API's JSON request log (W3-37; scenario
// private_accounts_w3b.js). Plain Node, no dependencies.
//
//   node loadtest/analyze_w3_part_b.js api.log
//
// Prints, for the Part B RPCs, the histogram of fs_reads / fs_writes / fs_deletes per (rpc, outcome); the ListFollowRequests and GetMe
// calls in log order per caller (position 1 is cold, the later ones show what the earlier calls warmed); the Follow txn_attempts
// histogram per target (the viral protected account signal); and the protected-set refresh: every request line that carries
// protected_set_reads (a detached counter, NOT part of fs_reads), the gaps between them, and the stranger-call reads with and
// without it. It also counts graph_txn_contention WARNs and ERROR lines. Only lines with message "request" carry the fields.
const fs = require('fs');

const file = process.argv[2];
if (!file) {
  console.error('usage: node loadtest/analyze_w3_part_b.js <api.log>');
  process.exit(2);
}
const short = (rpc) => String(rpc).split('/').pop();
const WANT = /(Follow|Unfollow|ListFollowRequests|RespondToFollowRequest|GetMe|UpdateProfile|GetPost|GetUserTimeline|CreatePost)$/;

const lines = [];
let errors = 0;
let contention = 0;
let setStale = 0;
let setUnavailable = 0;
const setRefreshLines = [];
for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
  if (!line.startsWith('{')) continue;
  let o;
  try {
    o = JSON.parse(line);
  } catch (e) {
    continue;
  }
  if (o.severity === 'ERROR') errors++;
  if (o.message === 'graph_txn_contention') contention++;
  if (o.message === 'protected_set_stale') setStale++;
  if (o.message === 'protected_set_unavailable') setUnavailable++;
  if (o.message !== 'request') continue;
  if (o.protected_set_reads !== undefined) setRefreshLines.push(o);
  if (WANT.test(String(o.rpc || ''))) lines.push(o);
}

const mean = (a) => a.reduce((s, x) => s + x, 0) / (a.length || 1);
const hist = (xs) => {
  const m = new Map();
  for (const x of xs) m.set(x, (m.get(x) || 0) + 1);
  return [...m.entries()].sort((a, b) => a[0] - b[0]).map(([k, v]) => `${k}x${v}`).join(' ');
};
const stat = (xs) => `mean ${mean(xs).toFixed(2)} min ${Math.min(...xs)} max ${Math.max(...xs)} [${hist(xs)}]`;

console.log('== per (rpc, outcome): reads / writes / deletes per call');
const groups = new Map();
for (const r of lines) {
  const k = `${short(r.rpc)} outcome=${r.outcome || '-'} follow_outcome=${r.follow_outcome || '-'} code=${r.code}`;
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(r);
}
for (const [k, rs] of [...groups.entries()].sort()) {
  console.log(`${k}  n=${rs.length}`);
  console.log(`    reads   ${stat(rs.map((r) => r.fs_reads || 0))}`);
  console.log(`    writes  ${stat(rs.map((r) => r.fs_writes || 0))}`);
  console.log(`    deletes ${stat(rs.map((r) => r.fs_deletes || 0))}`);
}

console.log('\n== ListFollowRequests and GetMe, in log order per caller (position 1 = cold)');
const seq = new Map();
for (const r of lines) {
  if (!/(ListFollowRequests|GetMe)$/.test(r.rpc)) continue;
  const k = `${short(r.rpc)} caller=${r.uid_hash}`;
  if (!seq.has(k)) seq.set(k, []);
  seq.get(k).push(r);
}
for (const [k, rs] of seq) {
  console.log(`${k}: ` + rs.map((r, i) => `#${i + 1} reads=${r.fs_reads}${r.page_size !== undefined ? ' page=' + r.page_size : ''}${r.rows_returned !== undefined ? ' rows=' + r.rows_returned : ''}`).join(' | '));
}

console.log('\n== Follow txn_attempts (target = the viral protected account)');
const fol = lines.filter((r) => /\/Follow$/.test(r.rpc));
const byTarget = new Map();
for (const r of fol) {
  const k = r.target_uid_hash || '-';
  if (!byTarget.has(k)) byTarget.set(k, []);
  byTarget.get(k).push(r.txn_attempts || 0);
}
for (const [k, xs] of byTarget) console.log(`target ${k}: n=${xs.length} txn_attempts ${stat(xs)}`);
console.log(`graph_txn_contention WARN lines: ${contention}`);
const latencies = fol.map((r) => r.latency_ms).sort((a, b) => a - b);
if (latencies.length) console.log(`Follow server latency_ms p50 ${latencies[Math.floor(latencies.length * 0.5)]} p95 ${latencies[Math.floor(latencies.length * 0.95)]} max ${latencies[latencies.length - 1]}`);

console.log('\n== protected-set refresh (protected_set_reads is a detached counter: not in fs_reads)');
const t0 = setRefreshLines.length ? Date.parse(setRefreshLines[0].time) : 0;
let prev = 0;
for (const r of setRefreshLines) {
  const t = Date.parse(r.time);
  console.log(`  +${((t - t0) / 1000).toFixed(1)} s (gap ${prev ? ((t - prev) / 1000).toFixed(1) : '-'} s)  ${short(r.rpc)}  protected_set_reads=${r.protected_set_reads}  its fs_reads=${r.fs_reads}`);
  prev = t;
}
console.log(`refresh lines: ${setRefreshLines.length}, sum protected_set_reads: ${setRefreshLines.reduce((s, r) => s + (r.protected_set_reads || 0), 0)}, protected_set_stale: ${setStale}, protected_set_unavailable: ${setUnavailable}`);
const stranger = lines.filter((r) => /(GetPost|GetUserTimeline)$/.test(r.rpc));
if (stranger.length) {
  const a = stranger;
  const t1 = Date.parse(a[0].time);
  const t2 = Date.parse(a[a.length - 1].time);
  console.log(`stranger-phase calls: ${a.length} over ${((t2 - t1) / 1000).toFixed(0)} s`);
  for (const rpc of ['GetPost', 'GetUserTimeline']) {
    const xs = a.filter((r) => short(r.rpc) === rpc);
    const withSet = xs.filter((r) => r.protected_set_reads !== undefined);
    const without = xs.filter((r) => r.protected_set_reads === undefined);
    console.log(`  ${rpc}: n=${xs.length}  fs_reads ${stat(xs.map((r) => r.fs_reads || 0))}`);
    console.log(`     on the refresh line (n=${withSet.length}): fs_reads ${withSet.length ? stat(withSet.map((r) => r.fs_reads || 0)) : '-'}; other lines: ${stat(without.map((r) => r.fs_reads || 0))}`);
  }
}
console.log(`\nERROR lines: ${errors}`);
