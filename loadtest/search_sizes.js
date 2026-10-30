// search_sizes.js: response sizes of the search RPCs, byte-exact, for the egress line of the cost model (W4-23, ADR-0028 "about 41 KB
// per DAU per day"). Plain Node (v18+), no dependencies. Emulators and a local API only, like every file in loadtest/.
//
//   API_URL=http://localhost:8081 AUTH_EMULATOR_HOST=localhost:9099 node loadtest/search_sizes.js
//
// For each call it measures the response BODY bytes four ways: JSON and binary proto (the app uses binary proto, ADR-0007; the Connect
// unary protocol takes the codec from the request Content-Type), each identity and gzip (the API gzips when the client sends
// Accept-Encoding: gzip; the bytes are counted on the socket before any decompression). HTTP headers are not counted. It builds its own
// accounts (display names of realistic length), PAGE_POSTS hashtag posts of about 90 characters from 10 authors, runs the trends
// refresh once (POST /internal/cron/trends-refresh, ENV=local) so GetTrends has a list, and needs FEATURE_SEARCH=on FEATURE_TRENDS=on
// FEATURE_POSTS=on and the limits of loadtest/search.js raised. The posts carry no media (the emulator run never uploads), so a post
// with images is larger than measured here; the cost model carries the allowance.
const http = require('http');
const zlib = require('zlib');

const API = new URL(process.env.API_URL || 'http://localhost:8081');
const AUTH = process.env.AUTH_EMULATOR_HOST || 'localhost:9099';
const RUN = Math.floor(Date.now() / 1000).toString(36);
const PAGE_POSTS = parseInt(process.env.PAGE_POSTS || '34', 10);

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

// ---- tiny protobuf writer (varint and length-delimited fields only) ---------------------------------------------------------------
const varint = (n) => { const o = []; while (n > 127) { o.push((n & 127) | 128); n = Math.floor(n / 128); } o.push(n); return Buffer.from(o); };
const fVarint = (f, n) => (n ? Buffer.concat([varint(f * 8), varint(n)]) : Buffer.alloc(0));
const fStr = (f, s) => (s ? Buffer.concat([varint(f * 8 + 2), varint(Buffer.byteLength(s)), Buffer.from(s)]) : Buffer.alloc(0));
const PROTO = {
  SearchPeople: (b) => Buffer.concat([fStr(1, b.query), fVarint(2, b.limit)]),
  SearchPosts: (b) => Buffer.concat([fStr(1, b.query), fVarint(2, b.tab), fVarint(3, b.pageSize), fStr(4, b.pageToken)]),
  GetTrends: (b) => Buffer.concat([fVarint(1, b.limit), fStr(2, b.prefix)]),
};

async function rpc(service, method, token, body, codec, gzip) {
  const json = codec === 'json';
  const payload = json ? Buffer.from(JSON.stringify(body)) : PROTO[method](body);
  const headers = { 'Content-Type': json ? 'application/json' : 'application/proto', Authorization: `Bearer ${token}`, 'Content-Length': payload.length, 'Accept-Encoding': gzip ? 'gzip' : 'identity' };
  const res = await request('POST', API.hostname, API.port, `/${service}/${method}`, headers, payload);
  if (res.status !== 200) throw new Error(`${method} ${codec}: ${res.status} ${res.raw.toString().slice(0, 200)}`);
  return { bytes: res.raw.length, gzipped: res.headers['content-encoding'] === 'gzip', body: res.headers['content-encoding'] === 'gzip' ? zlib.gunzipSync(res.raw) : res.raw };
}

const SEARCH = 'dzeroth.search.v1.SearchService';
const POSTS = 'dzeroth.posts.v1.PostService';
const IDENT = 'dzeroth.identity.v1.IdentityService';
async function jsonCall(service, method, token, body) {
  const r = await rpc(service, method, token, body, 'json', false);
  return JSON.parse(r.body.toString());
}
// CreatePost has no proto writer here: it goes as JSON (rpc() takes the codec from the argument).

let seed = 12345;
const rnd = (m) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % m; };
// Pseudo-words of 2 to 4 consonant-vowel syllables: more entropy than English, so gzip is not flattered by a tiny vocabulary.
const word = () => Array.from({ length: 2 + rnd(3) }, () => 'bcdfghjklmnprstvwy'[rnd(18)] + 'aeiou'[rnd(5)]).join('');
const cap = (w) => w[0].toUpperCase() + w.slice(1);
const name = () => cap(word()) + ' ' + cap(word());
const sentence = () => Array.from({ length: 8 + rnd(10) }, word).join(' '); // 8 to 17 words, about 60 to 130 characters

let n = 0;
async function mint(handleTail, name) {
  const su = await request('POST', AUTH.split(':')[0], AUTH.split(':')[1], '/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake', { 'Content-Type': 'application/json' }, JSON.stringify({ returnSecureToken: true }));
  const j = JSON.parse(su.raw.toString());
  await jsonCall(IDENT, 'CreateProfile', j.idToken, { idempotencyKey: `ss-${RUN}-c-${n++}-padpadpad`, handle: `szs${RUN}_${handleTail}`, displayName: name });
  return { uid: j.localId, token: j.idToken };
}

// markMedia gives a post one image (media + hasMedia) through the Firestore emulator REST API; the upload path is not run.
async function markMedia(postId, i) {
  const host = (process.env.FIRESTORE_EMULATOR_HOST || 'localhost:8080').split(':');
  const url = `https://storage.googleapis.com/dzeroth-prod-media/media/u/${postId}/${i}/full.webp`;
  const str = (v) => ({ stringValue: v });
  const image = { mapValue: { fields: { mediaId: str(`m${postId}${i}`), url: str(url), thumbUrl: str(url.replace('full', 'thumb')), width: { integerValue: '1080' }, height: { integerValue: '720' }, blurhash: str('LEHV6nWB2yk8pyo0adR*.7kCMdnj') } } };
  const body = Buffer.from(JSON.stringify({ fields: { hasMedia: { booleanValue: true }, media: { arrayValue: { values: [image] } } } }));
  const project = process.env.FIREBASE_PROJECT_ID || 'demo-dzeroth-local';
  const r = await request('PATCH', host[0], host[1], `/v1/projects/${project}/databases/(default)/documents/posts/${postId}?updateMask.fieldPaths=hasMedia&updateMask.fieldPaths=media`, { 'Content-Type': 'application/json', Authorization: 'Bearer owner', 'Content-Length': body.length }, body);
  if (r.status !== 200) throw new Error(`mark media: ${r.status} ${r.raw.toString().slice(0, 200)}`);
}

async function main() {
  const authors = [];
  for (let i = 0; i < 10; i++) authors.push(await mint(String(i), name()));
  const viewer = await mint('v', 'Viewer Person');
  for (let i = 10; i < 22; i++) await mint(String(i), name()); // more handles under the same prefix (23 accounts in all)
  const tag = `szt${RUN}`;
  for (let p = 0; p < PAGE_POSTS; p++) {
    const created = await jsonCall(POSTS, 'CreatePost', authors[p % 10].token, { idempotencyKey: `ss-${RUN}-p-${n++}-padpadpad`, text: `${sentence()} #${tag}` });
    if (p % 3 === 0) await markMedia(created.post.post.postId, p); // one post in three carries one image (the result mix of a hashtag page)
  }
  // Trends need 3 distinct authors per tag: 4 posts each of 12 tags from 4 authors.
  for (let t = 0; t < 12; t++) {
    for (let p = 0; p < 4; p++) {
      await jsonCall(POSTS, 'CreatePost', authors[(t + p) % 10].token, { idempotencyKey: `ss-${RUN}-t-${n++}-padpadpad`, text: `${sentence()} #szr${RUN}x${t}` });
    }
  }
  await request('POST', API.hostname, API.port, '/internal/cron/trends-refresh', { 'Content-Type': 'application/json', 'Content-Length': 0 }, null);

  const PFX = `szs${RUN}_`;
  const cases = [
    ['SearchPeople, limit 5 (typeahead)', 'SearchPeople', { query: PFX, limit: 5 }],
    ['SearchPeople, limit 20 (People tab)', 'SearchPeople', { query: PFX, limit: 20 }],
    ['SearchPeople, empty result', 'SearchPeople', { query: `zq${RUN}`, limit: 20 }],
    ['SearchPeople, unsupported query', 'SearchPeople', { query: 'hello world', limit: 5 }],
    ['SearchPosts TOP page 1, page_size 20', 'SearchPosts', { query: `#${tag}`, tab: 1, pageSize: 20 }],
    ['SearchPosts TOP page 1, page_size 30', 'SearchPosts', { query: `#${tag}`, tab: 1, pageSize: 30 }],
    ['SearchPosts LATEST page 1, page_size 20', 'SearchPosts', { query: `#${tag}`, tab: 2, pageSize: 20 }],
    ['SearchPosts LATEST page 1, page_size 50', 'SearchPosts', { query: `#${tag}`, tab: 2, pageSize: 50 }],
    ['SearchPosts MEDIA page 1 (every third post has one image)', 'SearchPosts', { query: `#${tag}`, tab: 3, pageSize: 20 }],
    ['SearchPosts, unsupported query', 'SearchPosts', { query: '@someone', tab: 1, pageSize: 20 }],
    ['GetTrends, limit 10', 'GetTrends', { limit: 10 }],
    ['GetTrends, limit 30', 'GetTrends', { limit: 30 }],
  ];
  const TAB = { 1: 'SEARCH_TAB_TOP', 2: 'SEARCH_TAB_LATEST', 3: 'SEARCH_TAB_MEDIA' };
  console.log('| call | JSON identity | JSON gzip | proto identity | proto gzip |');
  console.log('|---|---|---|---|---|');
  for (const [name, method, body] of cases) {
    const jb = { ...body };
    if (jb.tab) jb.tab = TAB[jb.tab];
    const ji = await rpc(SEARCH, method, viewer.token, jb, 'json', false);
    const jg = await rpc(SEARCH, method, viewer.token, jb, 'json', true);
    const pi = await rpc(SEARCH, method, viewer.token, body, 'proto', false);
    const pg = await rpc(SEARCH, method, viewer.token, body, 'proto', true);
    let rows = '';
    try {
      const j = JSON.parse(ji.body.toString());
      rows = ` (${(j.users || j.posts || j.trends || []).length} rows)`;
    } catch (e) { /* not JSON */ }
    console.log(`| ${name}${rows} | ${ji.bytes} | ${jg.bytes}${jg.gzipped ? '' : ' (not gzipped)'} | ${pi.bytes} | ${pg.bytes}${pg.gzipped ? '' : ' (not gzipped)'} |`);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
