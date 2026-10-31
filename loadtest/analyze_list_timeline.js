// analyze_list_timeline.js: W5 reads, writes and server time per call from the API's JSON request log (W5-18; scenario
// list_timeline.js). Plain Node, no dependencies.
//
//   node loadtest/analyze_list_timeline.js api.log k6.out
//
// api.log is the API process's stdout (JSON lines); k6.out is the k6 console output (stdout and stderr together), which carries the
// `W5 PHASE <name> <iso>` and `W5 STEP <name> <iso>` markers. In the serial phase the i-th request line is the i-th STEP (one RPC per step, one virtual user),
// so each case prints its own reads. Request lines after `cold_calls_done` are the herd: they are grouped by timeline_op and
// timeline_mode, with the server-side latency percentiles. Only lines with message "request" carry the request fields (fs_reads,
// fs_writes, fs_deletes, timeline_op, timeline_mode, list_members, timeline_chunks, authors_from_cache, items_returned, cache_hit, code).
const fs = require('fs');

const [apiLog, k6Out] = process.argv.slice(2);
if (!apiLog || !k6Out) {
  console.error('usage: node loadtest/analyze_list_timeline.js <api.log> <k6.out>');
  process.exit(2);
}

const steps = [];
let doneAt = Infinity;
let startAt = Infinity;
for (const line of fs.readFileSync(k6Out, 'utf8').split(/\r?\n/)) {
  let m = /W5 STEP (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m) steps.push({ name: m[1], start: Date.parse(m[2]) });
  m = /W5 PHASE (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m && m[1] === 'cold_calls_done') doneAt = Date.parse(m[2]);
  if (m && m[1] === 'cold_calls') startAt = Date.parse(m[2]);
}
steps.sort((a, b) => a.start - b.start);

const pct = (a, p) => {
  if (!a.length) return NaN;
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};
const mean = (a) => a.reduce((s, x) => s + x, 0) / (a.length || 1);
const short = (rpc) => String(rpc).split('/').pop();

const seq = []; // the serial phase's request lines in log order (one virtual user, one RPC per STEP)
const serial = new Map(); // step -> lines
const herd = [];
let errors = 0;
let warns = 0;
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
  if (o.message !== 'request' || !o.rpc) continue;
  const t = Date.parse(o.time || o.timestamp);
  if (!(t >= startAt)) continue; // setup traffic
  if (t > doneAt) {
    herd.push(o);
    continue;
  }
  seq.push(o);
}

// Every STEP marker is followed by exactly one RPC and the phase has one virtual user, so the i-th request line is the i-th step.
// (Matching by clock time is not used: markers and the log line are 1 to 3 ms apart and the two clocks do not order them.)
if (seq.length !== steps.length) console.error(`WARNING: ${steps.length} steps but ${seq.length} request lines in the serial phase`);
steps.forEach((st, i) => { if (seq[i]) serial.set(st.name, [seq[i]]); });
const f = (x) => (x === undefined ? '-' : x);
console.log('step | rpc | code | reads | writes | deletes | latency_ms | mode | list_members | chunks | from_cache | returned | cache_hit');
for (const s of steps) {
  for (const o of serial.get(s.name) || []) {
    console.log(
      [s.name, short(o.rpc), f(o.code), f(o.fs_reads), f(o.fs_writes), f(o.fs_deletes), f(o.latency_ms), f(o.timeline_mode), f(o.list_members), f(o.timeline_chunks), f(o.authors_from_cache), f(o.items_returned), f(o.cache_hit)].join(' | '),
    );
  }
}

console.log('\nHERD (request lines after cold_calls_done)');
const groups = new Map();
for (const o of herd) {
  const k = `${short(o.rpc)} [${o.timeline_op || '-'}/${o.timeline_mode || '-'}]`;
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(o);
}
for (const [k, rows] of [...groups.entries()].sort()) {
  const lat = rows.map((r) => r.latency_ms || 0);
  const reads = rows.map((r) => r.fs_reads || 0);
  const codes = {};
  for (const r of rows) codes[r.code] = (codes[r.code] || 0) + 1;
  const hist = {};
  for (const x of reads) hist[x] = (hist[x] || 0) + 1;
  console.log(
    `${k}: calls=${rows.length} latency_ms mean=${mean(lat).toFixed(1)} p50=${pct(lat, 50)} p95=${pct(lat, 95)} p99=${pct(lat, 99)} max=${Math.max(...lat)} | fs_reads mean=${mean(reads).toFixed(2)} max=${Math.max(...reads)} hist=${JSON.stringify(hist)} | fs_writes mean=${mean(rows.map((r) => r.fs_writes || 0)).toFixed(2)} | codes=${JSON.stringify(codes)}`,
  );
}
console.log(`\nERROR lines: ${errors}   WARN lines: ${warns}`);
