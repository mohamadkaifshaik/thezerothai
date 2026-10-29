// messaging: W7 emulator load smoke (W7-23, docs/plans/ui-w7-messaging.md "W7-23"; ADR-0027 "Cost impact"). One file, one timeline
// of five phases, all against ONE local API process (one "instance") and the Firebase emulators. Never point it at dzeroth-dev or
// dzeroth-prod: it sends tens of thousands of messages and raises every messaging cap.
//
//   setup()        Mints the users, makes every pair of users follow each other (so every conversation is ACCEPTED and the 3-message
//                  request cap never applies), and seeds the conversations: HUB_PEERS peers each message one hub user (the inbox
//                  first page), a "thread" pair T and a "thread" pair S with THREAD_MSGS messages each (the thread pages of 20 and
//                  50), a quiet pair Q (the empty poll), the burst pair X/Y, and PAIRS poller pairs (2 x PAIRS poller users).
//   cold_pages     COLD_START s (default 70, so every per-instance cache older than CACHE_TTL 60 s is cold): the hub's inbox first
//                  page cold then warm, a `since` refresh, the REQUESTS folder, MarkConversationRead; T1's thread page 20 cold then
//                  warm, an older page and a poll; S1's thread page 50 cold then warm. One virtual user, serial.
//   empty_poll     EMPTY_START s (default 90): one virtual user polls the quiet pair's thread with the `since` token every 200 ms for
//                  EMPTY_DURATION (default 60 s). No other traffic runs: this is the server time of a poll on an otherwise idle
//                  instance (the CPU line of the cost model). The thread has one message and nothing new arrives.
//   poll_herd      HERD_START s (default 160): 2 x PAIRS virtual users (default 300), one per poller user; each opens its thread (page
//                  20), marks it read (the receiving side only) and then polls with `since` every POLL_INTERVAL s (default 15, the
//                  web hot interval) for HERD_DURATION (default 240 s, long enough to cross the 60 s conversation and interceptor
//                  caches many times). A human-rate trickle sender (TRICKLE_RATE messages/s over all pairs, default 1) makes some
//                  polls non-empty. The first poll of each virtual user is jittered over one interval.
//   send_burst     BURST_START s (default 420): BURST_RATE sends/s (default 50) for BURST_DURATION (default 20 s) into ONE
//                  conversation, alternating the sender between X and Y. This is the rule-3 counter-contention shape: every send
//                  writes both participants' inbox entries (`unreadCount` Increment) and X polls the thread at the same time.
//   verify         BURST_START + BURST_DURATION + 15 s: pages the whole burst thread and compares the thread with both unread counts
//                  (no message lost, no lost Increment); prints one `W723 VERIFY` line.
//
// Reads are NOT a k6 metric: they come from the API request log (`fs_reads`, `fs_writes`, `fs_deletes`, `txn_attempts`, `results`,
// `latency_ms`), see loadtest/analyze_messaging.js. k6 prints `W723 PHASE <name> <iso time>` lines (stdout/stderr) that the analyzer
// uses to cut the log into phases. k6 records the response sizes (`resp_bytes` = decompressed JSON, `wire_bytes` = Content-Length of
// the gzip response, the server gzips when the client sends Accept-Encoding: gzip) and the status of every call. Latency is emulator
// latency, indicative only.
//
// API requirements (a local API against the emulators; load-testing skill): FEATURE_MESSAGING=on FEATURE_GRAPH=on, ENV=local, and these
// raised (they are per instance and per user, and every virtual user shares 127.0.0.1): RATE_LIMIT_PER_IP_PER_MIN,
// RATE_LIMIT_PRE_AUTH_IP_PER_MIN, RATE_LIMIT_PER_USER_PER_MIN, RATE_LIMIT_MESSAGES_SEND_PER_MIN, RATE_LIMIT_MESSAGES_READ_PER_MIN,
// MESSAGES_SENDS_PER_DAY, MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY (freshly minted users are "new accounts", 50 a day), MESSAGES_MARK_READ_PER_DAY,
// RATE_LIMIT_GRAPH_FOLLOW_PER_MIN, QUOTA_FOLLOWS_PER_DAY, QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY, READ_BUDGET_PER_UID_PER_DAY. Leave
// MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR alone. The exact values of the recorded run are in docs/reviews/cost-model.md section 14.
//
//   k6 run loadtest/messaging.js      # or: make loadtest SCENARIO=messaging
//   node loadtest/analyze_messaging.js api.log k6.out
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate, Trend } from 'k6/metrics';
import { mintUsers, rpcCall } from './graph_common.js';

const GRAPH = 'dzeroth.graph.v1.GraphService';
const MSG = 'dzeroth.messaging.v1.MessagingService';

const PAIRS = parseInt(__ENV.PAIRS || '150', 10); // poller pairs; 2 x PAIRS virtual users
const HUB_PEERS = parseInt(__ENV.HUB_PEERS || '20', 10);
const THREAD_MSGS = parseInt(__ENV.THREAD_MSGS || '60', 10);
const COLD_START = parseInt(__ENV.COLD_START || '70', 10);
const EMPTY_START = parseInt(__ENV.EMPTY_START || '90', 10);
const EMPTY_DURATION = parseInt(__ENV.EMPTY_DURATION || '60', 10);
const HERD_START = parseInt(__ENV.HERD_START || '160', 10);
const HERD_DURATION = parseInt(__ENV.HERD_DURATION || '240', 10);
const POLL_INTERVAL = parseFloat(__ENV.POLL_INTERVAL || '15');
const TRICKLE_RATE = parseFloat(__ENV.TRICKLE_RATE || '1');
const BURST_START = parseInt(__ENV.BURST_START || '420', 10);
const BURST_RATE = parseInt(__ENV.BURST_RATE || '50', 10);
const BURST_DURATION = parseInt(__ENV.BURST_DURATION || '20', 10);
const VERIFY_START = BURST_START + BURST_DURATION + 15;

const RUN = Math.floor(Date.now() / 1000).toString(36);
const key = (what, i) => `w723-${RUN}-${what}-${i}-padpadpad`;

// Typical chat messages, 20 to 120 characters (mean about 60): the response sizes depend on them.
const TEXTS = [
  'hey, are you free this evening?',
  'sure, send me the address and I will be there around 7',
  'did you see the match last night? that last over was unreal',
  'thanks for the intro, I will follow up with her tomorrow morning',
  'can you share the doc again? the link you sent has expired',
  'lol no way',
  'running about ten minutes late, start without me',
  'Happy birthday! Hope you have a great day, let us catch up soon and celebrate properly',
  'I think the second option works better for both of us',
  'ok',
  'just landed, will call you once I am out of the airport and in a cab',
  'Where did you get that photo? it looks amazing',
  'let me check with the team and get back to you by Friday',
  'good morning!',
  'that is fine by me, see you then',
  'not yet, the build is still running',
];
const text = (i) => TEXTS[i % TEXTS.length];

const respBytes = new Trend('resp_bytes');
const wireBytes = new Trend('wire_bytes');
const burstOK = new Rate('burst_send_ok');
const burstStatus = new Counter('burst_send_status');
const burstSeen = new Counter('burst_polled_messages');
const burstGaps = new Counter('burst_poll_gap_pages');
const herdReopens = new Counter('herd_reopens');
const herdPollsEmpty = new Counter('herd_polls_with_no_messages');
const herdPollsTotal = new Counter('herd_polls');

export const options = {
  setupTimeout: '900s',
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'max'],
  scenarios: {
    cold_pages: { executor: 'per-vu-iterations', exec: 'coldPages', vus: 1, iterations: 1, maxDuration: '60s', startTime: `${COLD_START}s` },
    empty_poll: { executor: 'constant-vus', exec: 'emptyPoll', vus: 1, duration: `${EMPTY_DURATION}s`, startTime: `${EMPTY_START}s` },
    poll_herd: { executor: 'constant-vus', exec: 'pollHerd', vus: PAIRS * 2, duration: `${HERD_DURATION}s`, startTime: `${HERD_START}s` },
    trickle: {
      executor: 'constant-arrival-rate',
      exec: 'trickle',
      rate: Math.max(1, Math.round(TRICKLE_RATE * 10)),
      timeUnit: '10s',
      duration: `${HERD_DURATION}s`,
      preAllocatedVUs: 10,
      maxVUs: 40,
      startTime: `${HERD_START}s`,
    },
    send_burst: {
      executor: 'constant-arrival-rate',
      exec: 'sendBurst',
      rate: BURST_RATE,
      timeUnit: '1s',
      duration: `${BURST_DURATION}s`,
      preAllocatedVUs: 60,
      maxVUs: 200,
      startTime: `${BURST_START}s`,
    },
    burst_poller: { executor: 'constant-vus', exec: 'burstPoller', vus: 1, duration: `${BURST_DURATION + 5}s`, startTime: `${BURST_START}s` },
    verify: { executor: 'per-vu-iterations', exec: 'verify', vus: 1, iterations: 1, maxDuration: '120s', startTime: `${VERIFY_START}s` },
  },
  thresholds: {
    checks: ['rate>0.99'],
    // Stage 0 target for a warm read is p95 < 400 ms; on an emulator under 300 virtual users it is indicative only.
    'http_req_duration{rpc:Poll}': ['p(95)<800'],
    // Always-true thresholds whose only job is to make k6 print the per-call response sizes (the egress line) in the end summary.
    ...sizeLines(['Poll_open', 'Poll', 'EmptyPoll', 'Burst_Poll', 'Burst_Send', 'Trickle_Send', 'LC_first_cold', 'LC_first_warm', 'LC_since', 'LM_p20_cold', 'LM_p50_cold', 'LM_older', 'Mark']),
  },
};

function sizeLines(tags) {
  const t = {};
  for (const tag of tags) {
    t[`resp_bytes{rpc:${tag}}`] = ['max>=0'];
    t[`wire_bytes{rpc:${tag}}`] = ['max>=0'];
  }
  return t;
}

function call(service, method, body, user, tag) {
  const r = rpcCall(service, method, body, user.idToken, tag);
  respBytes.add(r.body ? r.body.length : 0, { rpc: tag });
  const cl = parseInt((r.headers['Content-Length'] || r.headers['content-length'] || '0'), 10);
  if (cl > 0) wireBytes.add(cl, { rpc: tag });
  return r;
}

function mark(name) {
  if (exec.scenario.iterationInTest === 0) console.log(`W723 PHASE ${name} ${new Date().toISOString()}`);
}

function follow(a, b, i) {
  const r = call(GRAPH, 'Follow', { idempotencyKey: key('f', i), userId: b.uid }, a, 'setup_Follow');
  if (r.status !== 200) throw new Error(`setup: Follow ${i}: ${r.status} ${r.body}`);
}

function mutual(a, b, i) {
  follow(a, b, i * 2);
  follow(b, a, i * 2 + 1);
}

function send(from, toUid, n, what) {
  const r = call(MSG, 'SendMessage', { idempotencyKey: key(what, n), recipientUserId: toUid, text: text(n) }, from, 'setup_Send');
  if (r.status !== 200) throw new Error(`setup: SendMessage ${what} ${n}: ${r.status} ${r.body}`);
  return r.json('conversation.id');
}

function sendTo(from, convId, n, what) {
  const r = call(MSG, 'SendMessage', { idempotencyKey: key(what, n), conversationId: convId, text: text(n) }, from, 'setup_Send');
  if (r.status !== 200) throw new Error(`setup: SendMessage ${what} ${n}: ${r.status} ${r.body}`);
}

export function setup() {
  const hub = mintUsers(1, 'hubx')[0];
  const peers = mintUsers(HUB_PEERS, 'peerx');
  const [t1, t2] = mintUsers(2, 'thrx');
  const [s1, s2] = mintUsers(2, 'scrx');
  const [q1, q2] = mintUsers(2, 'quix');
  const [x, y] = mintUsers(2, 'burx');
  const pollers = mintUsers(PAIRS * 2, 'polx');

  let f = 0;
  for (const p of peers) mutual(hub, p, f++);
  mutual(t1, t2, f++);
  mutual(s1, s2, f++);
  mutual(q1, q2, f++);
  mutual(x, y, f++);
  for (let i = 0; i < PAIRS; i++) mutual(pollers[2 * i], pollers[2 * i + 1], f++);

  // The hub's inbox: every peer sends one message (HUB_PEERS conversations, the first page of 20).
  const hubConvs = peers.map((p, i) => send(p, hub.uid, i, 'hub'));
  // Thread pairs: THREAD_MSGS messages, alternating senders (an accepted conversation).
  const tConv = send(t1, t2.uid, 0, 'thr');
  const sConv = send(s1, s2.uid, 0, 'scr');
  for (let i = 1; i < THREAD_MSGS; i++) {
    sendTo(i % 2 === 0 ? t1 : t2, tConv, i, 'thr');
    sendTo(i % 2 === 0 ? s1 : s2, sConv, i, 'scr');
  }
  const qConv = send(q1, q2.uid, 0, 'qui');
  const burstConv = send(x, y.uid, 0, 'bur');
  const pairs = [];
  for (let i = 0; i < PAIRS; i++) {
    const a = pollers[2 * i];
    const b = pollers[2 * i + 1];
    pairs.push({ conv: send(a, b.uid, i, 'pol') });
  }
  return { hub, peers, hubConvs, t1, t2, tConv, s1, s2, sConv, q1, q2, qConv, x, y, burstConv, pollers, pairs };
}

// ---- cold_pages -------------------------------------------------------------------------------------------------------------------

export function coldPages(d) {
  mark('cold_pages');
  const lc = (body, tag) => call(MSG, 'ListConversations', body, d.hub, tag);
  const first = lc({ folder: 'FOLDER_INBOX', pageSize: 20 }, 'LC_first_cold');
  check(first, { 'ListConversations first page 200': (r) => r.status === 200 });
  check(lc({ folder: 'FOLDER_INBOX', pageSize: 20 }, 'LC_first_warm'), { 'LC warm 200': (r) => r.status === 200 });
  check(lc({ folder: 'FOLDER_INBOX', sinceToken: first.json('sinceToken') }, 'LC_since'), { 'LC since 200': (r) => r.status === 200 });
  check(lc({ folder: 'FOLDER_REQUESTS', pageSize: 20 }, 'LC_requests'), { 'LC requests 200': (r) => r.status === 200 });
  check(call(MSG, 'MarkConversationRead', { idempotencyKey: key('mark', 0), conversationId: d.hubConvs[0] }, d.hub, 'Mark'), {
    'Mark 200': (r) => r.status === 200,
  });

  const lm = (user, body, tag) => call(MSG, 'ListMessages', body, user, tag);
  const p20 = lm(d.t1, { conversationId: d.tConv, pageSize: 20 }, 'LM_p20_cold');
  check(p20, { 'ListMessages p20 200': (r) => r.status === 200 });
  check(lm(d.t1, { conversationId: d.tConv, pageSize: 20 }, 'LM_p20_warm'), { 'LM p20 warm 200': (r) => r.status === 200 });
  const next = p20.json('nextPageToken');
  if (next) check(lm(d.t1, { conversationId: d.tConv, pageSize: 20, pageToken: next }, 'LM_older'), { 'LM older 200': (r) => r.status === 200 });
  check(lm(d.t1, { conversationId: d.tConv, sinceToken: p20.json('sinceToken') }, 'LM_poll_after_open'), { 'LM poll 200': (r) => r.status === 200 });
  check(lm(d.s1, { conversationId: d.sConv, pageSize: 50 }, 'LM_p50_cold'), { 'ListMessages p50 200': (r) => r.status === 200 });
  check(lm(d.s1, { conversationId: d.sConv, pageSize: 50 }, 'LM_p50_warm'), { 'LM p50 warm 200': (r) => r.status === 200 });
}

// ---- empty_poll -------------------------------------------------------------------------------------------------------------------

let emptyToken = '';
export function emptyPoll(d) {
  mark('empty_poll');
  if (!emptyToken) {
    const open = call(MSG, 'ListMessages', { conversationId: d.qConv, pageSize: 20 }, d.q2, 'EmptyPoll_open');
    emptyToken = open.json('sinceToken') || '';
    return;
  }
  const r = call(MSG, 'ListMessages', { conversationId: d.qConv, sinceToken: emptyToken }, d.q2, 'EmptyPoll');
  check(r, { 'empty poll 200': (x) => x.status === 200 });
  emptyToken = r.json('sinceToken') || emptyToken;
  sleep(0.2);
}

// ---- poll_herd --------------------------------------------------------------------------------------------------------------------

const herd = { token: '', opened: false, idx: -1 };
export function pollHerd(d) {
  mark('poll_herd');
  // VU ids are global across scenarios; the first N iterations of this scenario are the N virtual users' first iterations.
  if (herd.idx < 0) herd.idx = exec.scenario.iterationInTest;
  const i = herd.idx;
  const me = d.pollers[i];
  const conv = d.pairs[Math.floor(i / 2)].conv;
  if (!herd.opened) {
    sleep(Math.random() * POLL_INTERVAL); // spread the first poll of the 300 users over one interval
  }
  if (!herd.token) {
    const open = call(MSG, 'ListMessages', { conversationId: conv, pageSize: 20 }, me, 'Poll_open');
    check(open, { 'open 200': (r) => r.status === 200 });
    herd.token = open.json('sinceToken') || '';
    herd.opened = true;
    if (i % 2 === 1) {
      // the receiving side of the seed message marks the thread read (the client calls it only with unread > 0)
      call(MSG, 'MarkConversationRead', { idempotencyKey: key('herdmark', i), conversationId: conv }, me, 'Mark_herd');
    }
  } else {
    const r = call(MSG, 'ListMessages', { conversationId: conv, sinceToken: herd.token }, me, 'Poll');
    const ok = check(r, { 'poll 200': (x) => x.status === 200 });
    herdPollsTotal.add(1);
    if (ok) {
      herd.token = r.json('sinceToken') || herd.token;
      const msgs = r.json('messages');
      if (!msgs || msgs.length === 0) herdPollsEmpty.add(1);
    } else {
      herd.token = ''; // a refused token is a cold open (the token contract)
      herdReopens.add(1);
    }
  }
  sleep(POLL_INTERVAL);
}

export function trickle(d) {
  mark('trickle');
  const n = exec.scenario.iterationInTest;
  const pair = Math.floor(Math.random() * PAIRS);
  const sender = d.pollers[2 * pair + (Math.random() < 0.5 ? 0 : 1)];
  const r = call(MSG, 'SendMessage', { idempotencyKey: key('trk', n), conversationId: d.pairs[pair].conv, text: text(n) }, sender, 'Trickle_Send');
  check(r, { 'trickle send 200': (x) => x.status === 200 });
}

// ---- send_burst -------------------------------------------------------------------------------------------------------------------

export function sendBurst(d) {
  mark('send_burst');
  const n = exec.scenario.iterationInTest;
  const sender = n % 2 === 0 ? d.x : d.y;
  const r = call(MSG, 'SendMessage', { idempotencyKey: key('burst', n), conversationId: d.burstConv, text: text(n) }, sender, 'Burst_Send');
  burstOK.add(r.status === 200);
  burstStatus.add(1, { status: String(r.status) });
}

let burstToken = '';
export function burstPoller(d) {
  mark('burst_poller');
  if (!burstToken) {
    const open = call(MSG, 'ListMessages', { conversationId: d.burstConv, pageSize: 50 }, d.x, 'Burst_open');
    burstToken = open.json('sinceToken') || '';
    return;
  }
  const r = call(MSG, 'ListMessages', { conversationId: d.burstConv, pageSize: 50, sinceToken: burstToken }, d.x, 'Burst_Poll');
  if (r.status === 200) {
    burstToken = r.json('sinceToken') || burstToken;
    const msgs = r.json('messages');
    burstSeen.add(msgs ? msgs.length : 0);
    if (r.json('gapPageToken')) burstGaps.add(1);
  }
  sleep(1);
}

export function verify(d) {
  mark('verify');
  let token = '';
  let total = 0;
  let fromX = 0;
  const ids = {};
  for (let page = 0; page < 200; page++) {
    const body = { conversationId: d.burstConv, pageSize: 50 };
    if (token) body.pageToken = token;
    const r = call(MSG, 'ListMessages', body, d.x, 'Verify_page');
    if (r.status !== 200) break;
    for (const m of r.json('messages') || []) {
      ids[m.id] = true;
      total++;
      if (m.fromSelf) fromX++;
    }
    token = r.json('nextPageToken') || '';
    if (!token) break;
  }
  const inbox = (u) => {
    const r = call(MSG, 'ListConversations', { folder: 'FOLDER_INBOX', pageSize: 50 }, u, 'Verify_inbox');
    const c = (r.json('conversations') || []).find((e) => e.id === d.burstConv);
    return c ? parseInt(c.unreadCount || '0', 10) : -1;
  };
  const unreadX = inbox(d.x);
  const unreadY = inbox(d.y);
  const fromY = total - fromX;
  // Neither side reads, so each side's unread count is exactly the number of messages the other side sent.
  const consistent = unreadY === fromX && unreadX === fromY && Object.keys(ids).length === total;
  console.log(`W723 VERIFY total=${total} unique=${Object.keys(ids).length} fromX=${fromX} fromY=${fromY} unreadX=${unreadX} unreadY=${unreadY} consistent=${consistent}`);
  check(null, { 'burst thread consistent (no lost message, no lost unread Increment)': () => consistent });
}
