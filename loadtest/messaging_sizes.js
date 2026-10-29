// messaging_sizes.js: response sizes of the messaging RPCs, byte-exact, for the egress line of the cost model (W7-23, ADR-0027 "about
// 10 KB per DAU per day"). Plain Node (v18+), no dependencies. Emulators and a local API only, like every file in loadtest/.
//
//   API_URL=http://localhost:8081 AUTH_EMULATOR_HOST=localhost:9099 node loadtest/messaging_sizes.js
//
// For each call it measures the response BODY bytes four ways: JSON and binary proto (the app uses binary proto, ADR-0007; the
// Connect unary protocol takes the codec from the request Content-Type), each identity and gzip (the API gzips when the client
// sends Accept-Encoding: gzip; the bytes are counted on the socket before any decompression). HTTP headers are not counted.
// It builds its own users, mutual follows and conversations (20 conversations for one hub user, a 60-message thread), with chat
// messages of about 60 characters on average. The API needs FEATURE_MESSAGING=on FEATURE_GRAPH=on and the limits of loadtest/messaging.js raised.
const http = require('http');
const zlib = require('zlib');

const API = new URL(process.env.API_URL || 'http://localhost:8081');
const AUTH = process.env.AUTH_EMULATOR_HOST || 'localhost:9099';
const RUN = Math.floor(Date.now() / 1000).toString(36);
const TEXTS = [
  'hey, are you free this evening?', 'sure, send me the address and I will be there around 7',
  'did you see the match last night? that last over was unreal', 'thanks for the intro, I will follow up with her tomorrow morning',
  'can you share the doc again? the link you sent has expired', 'lol no way', 'running about ten minutes late, start without me',
  'Happy birthday! Hope you have a great day, let us catch up soon and celebrate properly', 'I think the second option works better for both of us',
  'ok', 'just landed, will call you once I am out of the airport and in a cab', 'Where did you get that photo? it looks amazing',
  'let me check with the team and get back to you by Friday', 'good morning!', 'that is fine by me, see you then', 'not yet, the build is still running',
];

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
  SendMessage: (b) => Buffer.concat([fStr(1, b.idempotencyKey), b.conversationId ? fStr(2, b.conversationId) : fStr(3, b.recipientUserId), fStr(4, b.text)]),
  ListConversations: (b) => Buffer.concat([fVarint(1, b.folder), fVarint(2, b.pageSize), fStr(3, b.pageToken), fStr(4, b.sinceToken)]),
  ListMessages: (b) => Buffer.concat([fStr(1, b.conversationId), fVarint(2, b.pageSize), fStr(3, b.pageToken), fStr(4, b.sinceToken)]),
  MarkConversationRead: (b) => Buffer.concat([fStr(1, b.idempotencyKey), fStr(2, b.conversationId)]),
};

async function rpc(service, method, token, body, codec, gzip) {
  const json = codec === 'json';
  const payload = json ? Buffer.from(JSON.stringify(body)) : PROTO[method](body);
  const headers = { 'Content-Type': json ? 'application/json' : 'application/proto', Authorization: `Bearer ${token}`, 'Content-Length': payload.length, 'Accept-Encoding': gzip ? 'gzip' : 'identity' };
  const res = await request('POST', API.hostname, API.port, `/${service}/${method}`, headers, payload);
  if (res.status !== 200) throw new Error(`${method} ${codec}: ${res.status} ${res.raw.toString().slice(0, 200)}`);
  return { bytes: res.raw.length, gzipped: res.headers['content-encoding'] === 'gzip', body: res.headers['content-encoding'] === 'gzip' ? zlib.gunzipSync(res.raw) : res.raw };
}

const MSG = 'dzeroth.messaging.v1.MessagingService';
const GRAPH = 'dzeroth.graph.v1.GraphService';
const IDENT = 'dzeroth.identity.v1.IdentityService';

async function jsonCall(service, method, token, body) {
  const r = await rpc(service, method, token, body, 'json', false);
  return JSON.parse(r.body.toString());
}

let n = 0;
async function mint(prefix) {
  const su = await request('POST', AUTH.split(':')[0], AUTH.split(':')[1], '/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake', { 'Content-Type': 'application/json' }, JSON.stringify({ returnSecureToken: true }));
  const j = JSON.parse(su.raw.toString());
  const u = { uid: j.localId, token: j.idToken };
  await jsonCall(IDENT, 'CreateProfile', u.token, { idempotencyKey: `sz-${RUN}-c-${n}-padpadpad`, handle: `${prefix.slice(0, 3)}${RUN}_${n++}`, displayName: `Sizes ${prefix}` });
  return u;
}
const mutual = async (a, b) => {
  await jsonCall(GRAPH, 'Follow', a.token, { idempotencyKey: `sz-${RUN}-f-${n++}-padpadpad`, userId: b.uid });
  await jsonCall(GRAPH, 'Follow', b.token, { idempotencyKey: `sz-${RUN}-f-${n++}-padpadpad`, userId: a.uid });
};
const send = (u, to, i, conv) => jsonCall(MSG, 'SendMessage', u.token, { idempotencyKey: `sz-${RUN}-s-${n++}-padpadpad`, ...(conv ? { conversationId: conv } : { recipientUserId: to.uid }), text: TEXTS[i % TEXTS.length] });

async function main() {
  const hub = await mint('hub');
  for (let i = 0; i < 20; i++) {
    const p = await mint('peer');
    await mutual(hub, p);
    await send(p, hub, i);
  }
  const t1 = await mint('thr');
  const t2 = await mint('thr');
  await mutual(t1, t2);
  const conv = (await send(t1, t2, 0)).conversation.id;
  for (let i = 1; i < 60; i++) await send(i % 2 ? t2 : t1, null, i, conv);
  const q1 = await mint('qui');
  const q2 = await mint('qui');
  await mutual(q1, q2);
  const qConv = (await send(q1, q2, 0)).conversation.id;
  await new Promise((r) => setTimeout(r, 6000)); // outside the 5 s settle window: a quiet thread
  const lc = await jsonCall(MSG, 'ListConversations', hub.token, { folder: 'FOLDER_INBOX', pageSize: 20 });
  const lmQuiet = await jsonCall(MSG, 'ListMessages', q2.token, { conversationId: qConv, pageSize: 20 });
  const lm12 = await jsonCall(MSG, 'ListMessages', t1.token, { conversationId: conv, pageSize: 12 });
  const sinceQuiet = lmQuiet.sinceToken;
  const sinceInbox = lc.sinceToken;

  const cases = [
    ['SendMessage (accepted conversation)', 'SendMessage', t1, { idempotencyKey: `sz-${RUN}-x-1-padpadpad`, conversationId: conv, text: TEXTS[2] }],
    ['ListConversations first page, 20 conversations', 'ListConversations', hub, { folder: 1, pageSize: 20 }],
    ['ListConversations first page, 6 conversations (the model mean)', 'ListConversations', hub, { folder: 1, pageSize: 6 }],
    ['ListConversations since, nothing new', 'ListConversations', hub, { folder: 1, sinceToken: sinceInbox }],
    ['ListMessages first page, 12 messages (the model mean)', 'ListMessages', t1, { conversationId: conv, pageSize: 12 }],
    ['ListMessages first page, 20 messages', 'ListMessages', t1, { conversationId: conv, pageSize: 20 }],
    ['ListMessages first page, 50 messages', 'ListMessages', t1, { conversationId: conv, pageSize: 50 }],
    ['ListMessages poll, quiet thread (newest message re-delivered)', 'ListMessages', q2, { conversationId: qConv, sinceToken: sinceQuiet }],
    ['ListMessages poll, 12 messages in the settle window', 'ListMessages', t1, { conversationId: conv, sinceToken: lm12.sinceToken }],
    ['MarkConversationRead', 'MarkConversationRead', hub, { idempotencyKey: `sz-${RUN}-m-1-padpadpad`, conversationId: lc.conversations[0].id }],
  ];
  console.log('| call | JSON identity | JSON gzip | proto identity | proto gzip |');
  console.log('|---|---|---|---|---|');
  const out = {};
  for (const [name, method, user, body] of cases) {
    // A send with a repeated key is a replay, so every call below gets its own key.
    const fresh = (b) => (b.idempotencyKey && method === 'SendMessage' ? { ...b, idempotencyKey: `sz-${RUN}-x-${n++}-padpadpad` } : b);
    const jb = { ...body };
    if (typeof jb.folder === 'number') jb.folder = 'FOLDER_INBOX';
    const ji = await rpc(MSG, method, user.token, fresh(jb), 'json', false);
    const jg = await rpc(MSG, method, user.token, fresh(jb), 'json', true);
    const pi = await rpc(MSG, method, user.token, fresh(body), 'proto', false);
    const pg = await rpc(MSG, method, user.token, fresh(body), 'proto', true);
    // The server only gzips above a size threshold: when it did not, the gzip column is the identity size.
    out[method + ':' + name] = { ji: ji.bytes, jg: jg.bytes, pi: pi.bytes, pg: pg.bytes };
    console.log(`| ${name} | ${ji.bytes} | ${jg.bytes}${jg.gzipped ? '' : ' (not gzipped)'} | ${pi.bytes} | ${pg.bytes}${pg.gzipped ? '' : ' (not gzipped)'} |`);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
