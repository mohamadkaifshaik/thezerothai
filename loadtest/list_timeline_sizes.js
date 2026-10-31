// list_timeline_sizes.js: response sizes of the list RPCs, byte-exact, for the egress line of the cost model (W5-18, ADR-0030 "about 18.7 KB
// per DAU per day"). Plain Node (v18+), no dependencies. Emulators and a local API only, like every file in loadtest/.
//
//   API_URL=http://localhost:8081 AUTH_EMULATOR_HOST=localhost:9099 node loadtest/list_timeline_sizes.js
//
// Measures the response BODY bytes four ways, as loadtest/search_sizes.js does: JSON and binary proto (the app uses binary proto, ADR-0007;
// the Connect unary protocol takes the codec from the request Content-Type), each identity and gzip (the API gzips when the client sends
// Accept-Encoding: gzip; the bytes are counted on the socket before any decompression). HTTP headers are not counted. It builds its own
// accounts (display names of realistic length), a list of LIST_MEMBERS (default 40, the plan's average) members who each posted one post of
// about 90 characters, and needs FEATURE_LISTS=on FEATURE_POSTS=on FEATURE_GRAPH=on FEATURE_ENGAGEMENT=on and the limits of
// loadtest/list_timeline.js raised. The posts carry no media (the emulator run never uploads), so a post with images is larger than
// measured here; the cost model carries the allowance.
const http = require('http');
const zlib = require('zlib');

const API = new URL(process.env.API_URL || 'http://localhost:8081');
const AUTH = process.env.AUTH_EMULATOR_HOST || 'localhost:9099';
const RUN = Math.floor(Date.now() / 1000).toString(36);
const MEMBERS = parseInt(process.env.LIST_MEMBERS || '40', 10);

function request(method, host, port, path, headers, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ method, host, port, path, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, raw: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

const varint = (n) => { const o = []; while (n > 127) { o.push((n & 127) | 128); n = Math.floor(n / 128); } o.push(n); return Buffer.from(o); };
const fVarint = (f, n) => (n ? Buffer.concat([varint(f * 8), varint(n)]) : Buffer.alloc(0));
const fStr = (f, s) => (s ? Buffer.concat([varint(f * 8 + 2), varint(Buffer.byteLength(s)), Buffer.from(s)]) : Buffer.alloc(0));
const PROTO = {
  GetListTimeline: (b) => Buffer.concat([fStr(1, b.listId), fVarint(2, b.pageSize), fStr(3, b.pageToken), fStr(4, b.sinceToken)]),
  GetList: (b) => fStr(1, b.listId),
  ListListMembers: (b) => Buffer.concat([fStr(1, b.listId), fVarint(2, b.pageSize), fStr(3, b.pageToken)]),
  ListUserLists: (b) => Buffer.concat([fStr(1, b.ownerId), fStr(2, b.containsUserId), fVarint(3, b.pageSize), fStr(4, b.pageToken)]),
};

async function rpc(service, method, token, body, codec, gzip) {
  const json = codec === 'json';
  const payload = json ? Buffer.from(JSON.stringify(body)) : PROTO[method](body);
  const headers = { 'Content-Type': json ? 'application/json' : 'application/proto', Authorization: `Bearer ${token}`, 'Content-Length': payload.length, 'Accept-Encoding': gzip ? 'gzip' : 'identity' };
  const res = await request('POST', API.hostname, API.port, `/${service}/${method}`, headers, payload);
  if (res.status !== 200) throw new Error(`${method} ${codec}: ${res.status} ${res.raw.toString().slice(0, 200)}`);
  return { bytes: res.raw.length, body: res.headers['content-encoding'] === 'gzip' ? zlib.gunzipSync(res.raw) : res.raw };
}

const LISTS = 'dzeroth.lists.v1.ListService';
const TIMELINE = 'dzeroth.timeline.v1.TimelineService';
const POSTS = 'dzeroth.posts.v1.PostService';
const IDENT = 'dzeroth.identity.v1.IdentityService';
async function jsonCall(service, method, token, body) {
  return JSON.parse((await rpc(service, method, token, body, 'json', false)).body.toString());
}

let seed = 12345;
const rnd = (m) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % m; };
const word = () => Array.from({ length: 2 + rnd(3) }, () => 'bcdfghjklmnprstvwy'[rnd(18)] + 'aeiou'[rnd(5)]).join('');
const cap = (w) => w[0].toUpperCase() + w.slice(1);
const name = () => cap(word()) + ' ' + cap(word());
const sentence = () => Array.from({ length: 8 + rnd(10) }, word).join(' ');

let n = 0;
async function mint(tail, display) {
  const su = await request('POST', AUTH.split(':')[0], AUTH.split(':')[1], '/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake', { 'Content-Type': 'application/json' }, JSON.stringify({ returnSecureToken: true }));
  const j = JSON.parse(su.raw.toString());
  await jsonCall(IDENT, 'CreateProfile', j.idToken, { idempotencyKey: `ls-${RUN}-c-${n++}-padpadpad`, handle: `lsz${RUN}_${tail}`, displayName: display });
  return { uid: j.localId, token: j.idToken };
}

async function main() {
  const owner = await mint('o', name());
  const viewer = await mint('v', 'Viewer Person');
  const members = [];
  for (let i = 0; i < MEMBERS; i++) {
    const m = await mint(`m${i}`, name());
    members.push(m);
    await jsonCall(POSTS, 'CreatePost', m.token, { idempotencyKey: `ls-${RUN}-p-${n++}-padpadpad`, text: sentence() });
  }
  const list = (await jsonCall(LISTS, 'CreateList', owner.token, { idempotencyKey: `ls-${RUN}-l-${n++}-padpadpad`, name: 'Sizes list', isPrivate: false })).list.listId;
  for (const m of members) await jsonCall(LISTS, 'AddListMember', owner.token, { idempotencyKey: `ls-${RUN}-a-${n++}-padpadpad`, listId: list, userId: m.uid });
  await new Promise((r) => setTimeout(r, 6000)); // the since_token trails the newest post by the settle window: let the seed posts fall behind it
  const first = await jsonCall(TIMELINE, 'GetListTimeline', viewer.token, { listId: list, pageSize: 20 });
  // 3 new posts, then a refresh
  for (let i = 0; i < 3; i++) await jsonCall(POSTS, 'CreatePost', members[i].token, { idempotencyKey: `ls-${RUN}-n-${n++}-padpadpad`, text: sentence() });
  await new Promise((r) => setTimeout(r, 1200));
  const cases = [
    ['GetListTimeline page 1, 20 posts', TIMELINE, 'GetListTimeline', { listId: list, pageSize: 20 }],
    ['GetListTimeline refresh, 3 new posts', TIMELINE, 'GetListTimeline', { listId: list, sinceToken: first.sinceToken }],
    ['GetListTimeline page 1, 50 posts (posts available: ' + (MEMBERS + 3) + ')', TIMELINE, 'GetListTimeline', { listId: list, pageSize: 50 }],
    ['GetList', LISTS, 'GetList', { listId: list }],
    ['ListUserLists (the owner, 1 list)', LISTS, 'ListUserLists', {}],
    ['ListListMembers page 20', LISTS, 'ListListMembers', { listId: list, pageSize: 20 }],
  ];
  console.log('| Call | JSON | JSON gzip | binary proto | proto gzip (the app) |\n|---|---|---|---|---|');
  for (const [label, svc, m, body] of cases) {
    const tok = m === 'ListUserLists' ? owner.token : viewer.token;
    const a = await rpc(svc, m, tok, body, 'json', false);
    const b = await rpc(svc, m, tok, body, 'json', true);
    const c = await rpc(svc, m, tok, body, 'proto', false);
    const d = await rpc(svc, m, tok, body, 'proto', true);
    console.log(`| ${label} | ${a.bytes} | ${b.bytes} | ${c.bytes} | **${d.bytes}** |`);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
