// private_accounts_w3b: W3 Part B emulator smoke (W3-37, docs/plans/ui-w3-profile-graph-completion.md "Part B: cost";
// ADR-0025 "Cost impact"). One file, one timeline of five scenarios, all against ONE local API process (one "instance").
//
//   setup()          Mints OWNER (P), OWNER2 (P2), N requesters, M strangers. P posts one public post, then protects the account
//                    (UpdateProfile is_private=true: 4 cold reads / 3 writes). P2 protects too (the 60-request page-50 owner).
//   follow_burst     t=0. N shared iterations on VUS virtual users: requester i follows P (a REQUEST, not an edge: 3 writes). This is
//                    the "viral protected account" shape: every Follow reads and transacts on P's users doc at the same moment, so the
//                    `txn_attempts` of the API log is the contention signal (graph_txn_contention WARN above 3). The last P2_N requesters
//                    follow P2 instead.
//   owner_flow       starts OWNER_START s later (default 100, after the burst has drained and every cache is older than CACHE_TTL
//                    60 s): P: GetMe (pending_follow_request_count, the one count()), ListFollowRequests page 20 cold, the same
//                    page again (warm), page 2 and page 3 by token; P2: ListFollowRequests page 50 cold, again warm. Planning: 42 / 21 and
//                    102 / 51; GetMe +1 read per 1,000 matches, cached 30 s.
//   respond_burst    starts RESPOND_START s (default 125): RESPOND_N shared iterations on 10 VUs; requester i is accepted (2 of 3) or
//                    declined (1 of 3); every 25th is replayed with the same idempotency key (0 writes). Planning 3 cold / 2 warm
//                    reads after a List; accept 4 writes + 1 delete, decline 1 + 1.
//   stranger_refusal starts REFUSE_START s (default RESPOND_START + 80, so the protected set is older than 60 s when it starts): 50
//                    stranger VUs fire once at the same instant (the singleflight check: ONE refresh, protected_set_reads=1 on one request
//                    line), then REFUSE_RATE calls/s for REFUSE_DURATION (default 150 s, 2.5 refresh windows) of stranger GetPost on P's post
//                    (NOT_FOUND) and GetUserTimeline of P (200 with author_protected). Planning: 4 cold / 3 cold reads, 0 warm.
//
// Reads are NOT a k6 metric: they come from the API request log (`fs_reads`, `fs_writes`, `fs_deletes`, `txn_attempts`,
// `protected_set_reads`), see loadtest/analyze_w3_part_b.js. k6 only checks status codes (the expected one per call). Latency is
// emulator latency, indicative only.
//
// API requirements (a local API against the emulators, nothing else; load-testing skill):
//   FEATURE_POSTS=on FEATURE_GRAPH=on FEATURE_PRIVATE_ACCOUNTS=on FEATURE_ENGAGEMENT=on (for the 4 + 1 userLikes cold read of GetPost) and
//   FEATURE_REPLIES not needed. CACHE_TTL=60s (default). Raise: RATE_LIMIT_PER_IP_PER_MIN, RATE_LIMIT_PRE_AUTH_IP_PER_MIN (every VU shares
//   127.0.0.1), RATE_LIMIT_PER_USER_PER_MIN, RATE_LIMIT_GRAPH_FOLLOW_PER_MIN, RATE_LIMIT_GRAPH_LIST_PER_MIN,
//   RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN, RATE_LIMIT_USER_TIMELINE_PER_MIN, LIST_CALLS_PER_DAY, GRAPH_MUTATIONS_PER_DAY,
//   QUOTA_FOLLOWS_PER_DAY, QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY, READ_BUDGET_PER_UID_PER_DAY. The exact values of the recorded run are in
//   docs/reviews/cost-model.md section 13.
//
//   k6 run loadtest/private_accounts_w3b.js      # or: make loadtest SCENARIO=private_accounts_w3b
import { check } from 'k6';
import exec from 'k6/execution';
import { mintUsers, rpcCall } from './graph_common.js';

const GRAPH = 'dzeroth.graph.v1.GraphService';
const IDENT = 'dzeroth.identity.v1.IdentityService';
const POSTS = 'dzeroth.posts.v1.PostService';
const TIMELINE = 'dzeroth.timeline.v1.TimelineService';

const N = parseInt(__ENV.REQUESTERS || '560', 10); // requesters in total
const P2_N = parseInt(__ENV.P2_REQUESTERS || '60', 10); // the last P2_N follow P2 (page 50 needs 50)
const STRANGERS = parseInt(__ENV.STRANGERS || '20', 10);
const VUS = parseInt(__ENV.VUS || '40', 10);
const OWNER_START = parseInt(__ENV.OWNER_START || '100', 10);
const RESPOND_START = parseInt(__ENV.RESPOND_START || '125', 10);
const RESPOND_N = parseInt(__ENV.RESPOND_N || '150', 10);
const REFUSE_START = parseInt(__ENV.REFUSE_START || String(RESPOND_START + 80), 10);
const REFUSE_RATE = parseInt(__ENV.REFUSE_RATE || '6', 10);
const REFUSE_DURATION = __ENV.REFUSE_DURATION || '150s';
const HERD = parseInt(__ENV.HERD || '50', 10);

const RUN = Math.floor(Date.now() / 1000).toString(36);
const key = (what, i) => `w337-${RUN}-${what}-${i}-padpadpad`;

export const options = {
  setupTimeout: '900s',
  scenarios: {
    follow_burst: {
      executor: 'shared-iterations',
      exec: 'followBurst',
      vus: VUS,
      iterations: N,
      maxDuration: '95s',
      startTime: '0s',
    },
    owner_flow: {
      executor: 'per-vu-iterations',
      exec: 'ownerFlow',
      vus: 1,
      iterations: 1,
      maxDuration: '60s',
      startTime: `${OWNER_START}s`,
    },
    respond_burst: {
      executor: 'shared-iterations',
      exec: 'respondBurst',
      vus: 10,
      iterations: RESPOND_N,
      maxDuration: '60s',
      startTime: `${RESPOND_START}s`,
    },
    stranger_herd: {
      executor: 'per-vu-iterations',
      exec: 'strangerHerd',
      vus: HERD,
      iterations: 1,
      maxDuration: '30s',
      startTime: `${REFUSE_START}s`,
    },
    stranger_refusal: {
      executor: 'constant-arrival-rate',
      exec: 'strangerRefusal',
      rate: REFUSE_RATE,
      timeUnit: '1s',
      duration: REFUSE_DURATION,
      preAllocatedVUs: 20,
      maxVUs: 60,
      startTime: `${REFUSE_START + 10}s`,
    },
  },
  thresholds: {
    checks: ['rate>0.99'],
    'http_req_duration{rpc:Follow}': ['p(95)<2000'],
  },
};

export function setup() {
  const owner = mintUsers(1, 'ownerx')[0];
  const owner2 = mintUsers(1, 'ow2x')[0];
  const requesters = mintUsers(N, 'reqx');
  const strangers = mintUsers(STRANGERS, 'strx');

  // P writes one public post, then protects the account (the post becomes FOLLOWERS-only by computed visibility).
  const created = rpcCall(POSTS, 'CreatePost', { idempotencyKey: key('post', 0), text: 'protected post for the W3-37 smoke' }, owner.idToken, 'CreatePost');
  if (created.status !== 200) throw new Error(`setup: CreatePost ${created.status} ${created.body}`);
  const postId = created.json('post.post.postId');
  for (const [u, k] of [[owner, 'own'], [owner2, 'ow2']]) {
    const r = rpcCall(IDENT, 'UpdateProfile', { idempotencyKey: key('protect-' + k, 0), isPrivate: true }, u.idToken, 'UpdateProfile');
    if (r.status !== 200) throw new Error(`setup: protect ${k} ${r.status} ${r.body}`);
  }
  return { owner, owner2, requesters, strangers, postId };
}

function targetFor(data, i) {
  return i >= N - P2_N ? data.owner2 : data.owner;
}

export function followBurst(data) {
  const i = exec.scenario.iterationInTest;
  const req = data.requesters[i];
  const target = targetFor(data, i);
  const r = rpcCall(GRAPH, 'Follow', { idempotencyKey: key('follow', i), userId: target.uid }, req.idToken, 'Follow');
  check(r, { 'follow -> REQUESTED (200)': (x) => x.status === 200 && JSON.stringify(x.json()).indexOf('REQUESTED') >= 0 });
}

export function ownerFlow(data) {
  const p = data.owner;
  const p2 = data.owner2;
  const me = rpcCall(IDENT, 'GetMe', {}, p.idToken, 'GetMe_cold');
  check(me, { 'GetMe 200': (x) => x.status === 200 });
  check(rpcCall(IDENT, 'GetMe', {}, p.idToken, 'GetMe_warm'), { 'GetMe warm 200': (x) => x.status === 200 });
  const l1 = rpcCall(GRAPH, 'ListFollowRequests', { pageSize: 20 }, p.idToken, 'List_p20_cold');
  check(l1, { 'list p20 200': (x) => x.status === 200 });
  const next = l1.json('nextPageToken');
  check(rpcCall(GRAPH, 'ListFollowRequests', { pageSize: 20 }, p.idToken, 'List_p20_warm'), { 'list p20 warm 200': (x) => x.status === 200 });
  if (next) {
    const l2 = rpcCall(GRAPH, 'ListFollowRequests', { pageSize: 20, pageToken: next }, p.idToken, 'List_p20_page2');
    check(l2, { 'list p20 page 2 200': (x) => x.status === 200 });
    const n2 = l2.json('nextPageToken');
    if (n2) check(rpcCall(GRAPH, 'ListFollowRequests', { pageSize: 20, pageToken: n2 }, p.idToken, 'List_p20_page3'), { 'page 3 200': (x) => x.status === 200 });
  }
  check(rpcCall(GRAPH, 'ListFollowRequests', { pageSize: 50 }, p2.idToken, 'List_p50_cold'), { 'list p50 200': (x) => x.status === 200 });
  check(rpcCall(GRAPH, 'ListFollowRequests', { pageSize: 50 }, p2.idToken, 'List_p50_warm'), { 'list p50 warm 200': (x) => x.status === 200 });
}

export function respondBurst(data) {
  const i = exec.scenario.iterationInTest;
  const req = data.requesters[i];
  const accept = i % 3 !== 2;
  const body = { idempotencyKey: key('respond', i), requesterUserId: req.uid, accept };
  const r = rpcCall(GRAPH, 'RespondToFollowRequest', body, data.owner.idToken, accept ? 'Respond_accept' : 'Respond_decline');
  check(r, { 'respond 200': (x) => x.status === 200 });
  if (i % 25 === 0) {
    const again = rpcCall(GRAPH, 'RespondToFollowRequest', body, data.owner.idToken, 'Respond_replay');
    check(again, { 'respond replay 200': (x) => x.status === 200 });
  }
}

function refuse(data, who) {
  if (Math.random() < 0.5) {
    const r = rpcCall(POSTS, 'GetPost', { postId: data.postId }, who.idToken, 'Stranger_GetPost');
    check(r, { 'stranger GetPost -> 404': (x) => x.status === 404 });
  } else {
    const r = rpcCall(TIMELINE, 'GetUserTimeline', { userId: data.owner.uid, pageSize: 20 }, who.idToken, 'Stranger_GetUserTimeline');
    check(r, { 'stranger GetUserTimeline -> 200 author_protected': (x) => x.status === 200 && x.json('authorProtected') === true });
  }
}

export function strangerHerd(data) {
  refuse(data, data.strangers[(exec.vu.idInTest - 1) % data.strangers.length]);
}

export function strangerRefusal(data) {
  refuse(data, data.strangers[Math.floor(Math.random() * data.strangers.length)]);
}
