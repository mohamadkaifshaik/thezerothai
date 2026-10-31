// analyze_poll.js: W6 reads, writes and server time per call from the API's JSON request log (W6-21; scenario poll_vote.js). Plain Node,
// no dependencies.
//
//   node loadtest/analyze_poll.js api.log k6.out [--from-line N]
//
// api.log is the API process's stdout (JSON lines); k6.out is the k6 console output (stdout and stderr together), which carries the
// `W6 PHASE <name> <iso>` and `W6 STEP <name> <iso>` markers. The log is cut into phases at the first marker of each phase. In the serial
// phase (cold_calls) the k-th request line is the k-th STEP (one virtual user), so each case prints its own reads and writes. In the load
// phases (hot_poll, mix, verify) lines are grouped by rpc, outcome, code and contention, with the txn_attempts histogram (the rule-3
// signal) and the count of poll_vote_contention / engagement_txn_contention WARN lines. Only lines with message "request" carry the
// request fields.
const fs = require('fs');

const args = process.argv.slice(2);
const fromLineIdx = args.indexOf('--from-line');
const fromLine = fromLineIdx >= 0 ? parseInt(args[fromLineIdx + 1], 10) : 0;
const files = args.filter((a, i) => !a.startsWith('--') && !(fromLineIdx >= 0 && i === fromLineIdx + 1));
if (files.length < 2) {
  console.error('usage: node loadtest/analyze_poll.js <api.log> <k6.out> [--from-line N]');
  process.exit(2);
}
const [apiLog, k6Out] = files;

const phases = [];
const steps = [];
for (const line of fs.readFileSync(k6Out, 'utf8').split(/\r?\n/)) {
  let m = /W6 PHASE (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m) phases.push({ name: m[1], start: Date.parse(m[2]) });
  m = /W6 STEP (\S+) (\d{4}-[^"\s]+)/.exec(line);
  if (m) steps.push({ name: m[1], start: Date.parse(m[2]) });
}
phases.sort((a, b) => a.start - b.start);
steps.sort((a, b) => a.start - b.start);
const phaseOf = (t) => {
  let cur = '(before the first phase)';
  for (const p of phases) if (t >= p.start) cur = p.name;
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

const reqs = new Map();
const warnKinds = new Map();
let errors = 0;
const lines = fs.readFileSync(apiLog, 'utf8').split(/\r?\n/);
for (let n = fromLine; n < lines.length; n++) {
  if (!lines[n].startsWith('{')) continue;
  let o;
  try { o = JSON.parse(lines[n]); } catch (e) { continue; }
  if (o.severity === 'ERROR') errors++;
  if (o.severity === 'WARNING' || o.severity === 'WARN') warnKinds.set(o.message, (warnKinds.get(o.message) || 0) + 1);
  if (o.message !== 'request') continue;
  const rpc = String(o.rpc || '');
  if (!rpc.includes('EngagementService/VotePoll') && !rpc.includes('PostService/')) continue;
  const ph = phaseOf(Date.parse(o.time));
  if (!reqs.has(ph)) reqs.set(ph, []);
  reqs.get(ph).push(o);
}

const describe = (o) =>
  `${short(o.rpc)} code=${o.code}${o.outcome ? ' outcome=' + o.outcome : ''}${o.limit_name ? ' limit=' + o.limit_name : ''}${o.contention ? ' contention=true' : ''}`;

for (const p of phases.map((x) => x.name)) {
  const rs = reqs.get(p);
  if (!rs) continue;
  console.log(`\n=== phase ${p}: ${rs.length} request lines`);
  if (p === 'cold_calls') {
    const pStart = phases.find((x) => x.name === p).start;
    const nextStart = phases.filter((x) => x.start > pStart).map((x) => x.start).sort((a, b) => a - b)[0] ?? Infinity;
    const mine = steps.filter((x) => x.start >= pStart - 5 && x.start < nextStart && x.name !== 'end');
    if (mine.length !== rs.length) console.log(`  WARNING: steps ${mine.length} != request lines ${rs.length}: labels may be off`);
    rs.forEach((o, i) => {
      console.log(
        `  ${(mine[i] ? mine[i].name : '?').padEnd(30)} ${describe(o)} fs_reads=${o.fs_reads ?? 0} fs_writes=${o.fs_writes ?? 0} fs_deletes=${o.fs_deletes ?? 0}` +
          `${o.txn_attempts !== undefined ? ' txn_attempts=' + o.txn_attempts : ''} latency_ms=${o.latency_ms ?? 0}`,
      );
    });
    continue;
  }
  const groups = new Map();
  for (const r of rs) {
    const k = describe(r);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r);
  }
  for (const [k, g] of [...groups.entries()].sort()) {
    const lat = g.map((r) => r.latency_ms || 0);
    console.log(`${k}  n=${g.length}`);
    console.log(`    fs_reads   ${stat(g.map((r) => r.fs_reads || 0))}`);
    console.log(`    fs_writes  ${stat(g.map((r) => r.fs_writes || 0))}`);
    if (g.some((r) => r.txn_attempts !== undefined)) console.log(`    txn_attempts ${stat(g.map((r) => r.txn_attempts ?? 0))}`);
    console.log(`    latency_ms p50 ${pct(lat, 50)} p95 ${pct(lat, 95)} p99 ${pct(lat, 99)} max ${Math.max(...lat)} mean ${mean(lat).toFixed(1)}`);
  }
  const t0 = Math.min(...rs.map((r) => Date.parse(r.time)));
  const t1 = Math.max(...rs.map((r) => Date.parse(r.time)));
  const votes = rs.filter((r) => String(r.rpc).includes('VotePoll'));
  console.log(`  TOTAL ${rs.length} lines, ${votes.length} VotePoll (committed: ${votes.filter((r) => r.outcome === 'voted').length}, contention: ${votes.filter((r) => r.contention).length}), window ${((t1 - t0) / 1000).toFixed(0)} s`);
}
console.log(`\nWARN lines: ${[...warnKinds.entries()].map(([k, v]) => `${k}=${v}`).join(' ') || 'none'}; ERROR lines: ${errors}`);
