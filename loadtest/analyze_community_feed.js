// analyze_community_feed.js: W5 Part B reads, writes and server time per call from the API's JSON request log (W5-39; scenario
// community_feed.js). Plain Node, no dependencies.
//
//   node loadtest/analyze_community_feed.js api.log k6.out
//
// api.log is the API process's stdout (JSON lines); k6.out is the k6 console output (stdout and stderr together), which carries the
// `CF PHASE <name> <iso>` and `CF STEP <name> <iso>` markers. In the serial phase the i-th request line is the i-th STEP (one RPC per step,
// one virtual user), so each case prints its own reads. Request lines after `cold_calls_done` are the herds and the join burst: they are
// grouped by rpc, timeline_op, timeline_mode and cache_hit, with the server-side latency percentiles; the JoinCommunity group adds the
// histogram of `community_txn_attempts`, the codes, and the count of WARN `community_txn_contention` lines (the ABORTED retries above 3).
const fs = require('fs');

const [apiLog, k6Out] = process.argv.slice(2);
if (!apiLog || !k6Out) {
  console.error('usage: node loadtest/analyze_community_feed.js <api.log> <k6.out>');
  process.exit(2);
}

const steps = [];
let doneAt = Infinity;
let startAt = Infinity;
const phases = []; // herd and burst starts: {name, t}
for (const line of fs.readFileSync(k6Out, 'utf8').split(/\r?\n/)) {
  let m = /CF STEP (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m) steps.push({ name: m[1], start: Date.parse(m[2]) });
  m = /CF PHASE (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m && m[1] === 'cold_calls_done') doneAt = Date.parse(m[2]);
  if (m && m[1] === 'cold_calls') startAt = Date.parse(m[2]);
  if (m && ['cold_herd', 'warm_herd', 'join_burst'].includes(m[1])) phases.push({ name: m[1], t: Date.parse(m[2]) });
}
steps.sort((a, b) => a.start - b.start);
phases.sort((x, y) => x.t - y.t);
const phaseOf = (t) => { let n = 'after_serial'; for (const p of phases) if (t >= p.t) n = p.name; return n; };

const pct = (a, p) => {
  if (!a.length) return NaN;
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};
const mean = (a) => a.reduce((s, x) => s + x, 0) / (a.length || 1);
const short = (rpc) => String(rpc).split('/').pop();
const hist = (xs) => {
  const h = {};
  for (const x of xs) h[x] = (h[x] || 0) + 1;
  return JSON.stringify(h);
};

const seq = []; // the serial phase's request lines in log order
const later = []; // after cold_calls_done: the herds and the join burst
let errors = 0;
let warns = 0;
let contention = 0;
for (const line of fs.readFileSync(apiLog, 'utf8').split(/\r?\n/)) {
  if (!line.startsWith('{')) continue;
  let o;
  try {
    o = JSON.parse(line);
  } catch (e) {
    continue;
  }
  if (o.severity === 'ERROR') errors++;
  if (o.severity === 'WARNING' || o.severity === 'WARN') warns++;
  if (/contention/.test(String(o.message))) contention++;
  if (o.message !== 'request' || !o.rpc) continue;
  const t = Date.parse(o.time || o.timestamp);
  if (!(t >= startAt)) continue; // setup traffic
  if (t > doneAt) {
    o._phase = phaseOf(t);
    later.push(o);
    continue;
  }
  seq.push(o);
}

// Every STEP marker is followed by exactly one RPC and the phase has one virtual user, so the i-th request line is the i-th step.
// (Matching by clock time is not used: markers and the log line are 1 to 3 ms apart and the two clocks do not order them.) The cold
// herd starts at COLD_HERD_START, after the serial phase ends, so it cannot interleave.
if (seq.length !== steps.length) console.error(`WARNING: ${steps.length} steps but ${seq.length} request lines in the serial phase`);
const f = (x) => (x === undefined ? '-' : x);
console.log('step | rpc | code | reads | writes | deletes | latency_ms | mode | cache_hit | returned | filtered | removed | role | txn_attempts');
steps.forEach((st, i) => {
  const o = seq[i];
  if (!o) return;
  console.log(
    [st.name, short(o.rpc), f(o.code), f(o.fs_reads), f(o.fs_writes), f(o.fs_deletes), f(o.latency_ms), f(o.timeline_mode), f(o.cache_hit), f(o.items_returned), f(o.items_filtered), f(o.removed), f(o.viewer_role), f(o.community_txn_attempts)].join(' | '),
  );
});

console.log('\nAFTER cold_calls_done (herds and join burst)');
const groups = new Map();
for (const o of later) {
  const k = `${o._phase}: ${short(o.rpc)} [${o.timeline_op || o.community_op || '-'}/${o.timeline_mode || '-'}] cache_hit=${f(o.cache_hit)}`;
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(o);
}
for (const [k, rows] of [...groups.entries()].sort()) {
  const lat = rows.map((r) => r.latency_ms || 0);
  const reads = rows.map((r) => r.fs_reads || 0);
  const codes = {};
  for (const r of rows) codes[r.code] = (codes[r.code] || 0) + 1;
  console.log(
    `${k}: calls=${rows.length} latency_ms mean=${mean(lat).toFixed(1)} p50=${pct(lat, 50)} p95=${pct(lat, 95)} max=${Math.max(...lat)} | fs_reads mean=${mean(reads).toFixed(2)} max=${Math.max(...reads)} hist=${hist(reads)} | fs_writes mean=${mean(rows.map((r) => r.fs_writes || 0)).toFixed(2)} hist=${hist(rows.map((r) => r.fs_writes || 0))} | codes=${JSON.stringify(codes)}${rows.some((r) => r.community_txn_attempts !== undefined) ? ` | community_txn_attempts hist=${hist(rows.map((r) => r.community_txn_attempts))}` : ''}`,
  );
}
const joins = later.filter((o) => /JoinCommunity$/.test(o.rpc));
if (joins.length) {
  const ok = joins.filter((o) => o.code === 'ok').length;
  console.log(`\nJOIN BURST: ${joins.length} request lines, ok-like ${ok}, community_txn_attempts max ${Math.max(...joins.map((o) => o.community_txn_attempts || 0))}, txn_attempts max ${Math.max(...joins.map((o) => o.txn_attempts || 0))}`);
}
console.log(`\nERROR lines: ${errors}   WARN lines: ${warns}   lines mentioning contention: ${contention}`);
