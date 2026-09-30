// analyze_logs.js: summarise the API's JSON request log per RPC (T18). No dependencies; plain Node.
//
//   node loadtest/analyze_logs.js api.log [rpcSubstring ...]
//
// Prints, per rpc: calls, mean/max/p50/p95 server latency_ms, mean/max fs_reads, mean fs_writes/fs_deletes and a
// code histogram; plus the count of severity=ERROR lines. Only lines with message "request" carry the fields
// (pkg/platform/mw Logging). Server-side latency excludes the network/k6 client.
const fs = require('fs');

const [file, ...filters] = process.argv.slice(2);
if (!file) {
  console.error('usage: node loadtest/analyze_logs.js <api.log> [rpcSubstring ...]');
  process.exit(2);
}

const byRpc = new Map();
let errors = 0;
let warns = 0;
for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
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
  if (filters.length && !filters.some((f) => o.rpc.includes(f))) continue;
  if (!byRpc.has(o.rpc)) byRpc.set(o.rpc, []);
  byRpc.get(o.rpc).push(o);
}

const pct = (sorted, p) => sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
const mean = (a) => a.reduce((s, x) => s + x, 0) / (a.length || 1);

for (const [rpc, rows] of [...byRpc.entries()].sort()) {
  const lat = rows.map((r) => r.latency_ms).sort((a, b) => a - b);
  const reads = rows.map((r) => r.fs_reads || 0);
  const writes = rows.map((r) => r.fs_writes || 0);
  const dels = rows.map((r) => r.fs_deletes || 0);
  const codes = {};
  for (const r of rows) codes[r.code] = (codes[r.code] || 0) + 1;
  const readHist = {};
  for (const x of reads) readHist[x] = (readHist[x] || 0) + 1;
  console.log(
    `${rpc}\n  calls=${rows.length} server_latency_ms mean=${mean(lat).toFixed(1)} p50=${pct(lat, 50)} p95=${pct(lat, 95)} max=${lat[lat.length - 1]}\n` +
      `  fs_reads mean=${mean(reads).toFixed(2)} max=${Math.max(...reads)} hist=${JSON.stringify(readHist)}\n` +
      `  fs_writes mean=${mean(writes).toFixed(2)} max=${Math.max(...writes)}  fs_deletes mean=${mean(dels).toFixed(2)} max=${Math.max(...dels)}\n` +
      `  codes=${JSON.stringify(codes)}`,
  );
}
console.log(`ERROR lines: ${errors}   WARN lines: ${warns}`);
