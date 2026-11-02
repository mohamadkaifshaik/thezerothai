// community_feed: W5 Part B emulator load smoke (W5-39, docs/plans/ui-w5-lists-communities.md "W5-39"; ADR-0031 "Cost impact").
// One file, one timeline, ONE local API process ("one instance") and the Firebase emulators. Never point it at dzeroth-dev or
// dzeroth-prod: it mints about 450 users and raises every community, post and read-budget cap.
//
//   setup()       Signs in the creator OWNER (a fixed email and password pre-minted in the Auth emulator; its uid must be in
//                 COMMUNITY_CREATORS when the API starts, see below), mints AUTHORS (default 12) authors, VIEWERS (12), HERD_VIEWERS (24)
//                 and JOIN_RATE x JOIN_DURATION join users (default 20 x 20 = 400). The owner creates six communities through the API:
//                 CA (96 posts: the open, refresh, older-page and page-50 cases), CB (60 posts: page 50 all-cold), CE (12), CH (12: the
//                 hide), CG (36: the cold herd) and CJ (empty: the join burst). Every author joins CA, CB, CE, CH and CG and posts into
//                 them with CreatePost.community_id. Then it idles COLD_SETTLE s (default 70 > CACHE_TTL 60 s) so no cache holds anything.
//   cold_calls    t=0, ONE virtual user, serial; every call is preceded by a `CF STEP <name> <iso>` marker (the analyzer pairs the i-th
//                 step with the i-th request line: one RPC per step). Cases: the cold open of CA with everything cold (viewer, community
//                 doc, member doc, entry, graph, userLikes); a second viewer on the now-warm entry; the same viewer warm; a refresh with 0
//                 new; 5 new community posts then a refresh with 5 new; an older page; page 50 with a warm entry; page 50 and page 20
//                 on CB (all-cold, then warm entry); the hide on CH (open, refresh, HideCommunityPost, refresh with removed_ids,
//                 a second viewer's open, RestoreCommunityPost, refresh); then one idle of COLD_SETTLE s and the cases that need a
//                 cold instance: a refresh with 0 new on CE with a token that is one idle old (ADR value 4), the open of CA and the
//                 refresh of CH again all-cold. A refresh inside the entry's 60 s returns nothing new and reads 0 (the staleness bound), so
//                 the refresh with 5 new is measured twice: inside the TTL (0 reads, 0 posts) and after the idle (the incremental refill).
//   cold_herd     t=COLD_HERD_START (default 100): HERD_VIEWERS viewers open CG at once (page 20), the entry cold: how many fills?
//   warm_herd     t=WARM_HERD_START (default 115): WARM_RATE (default 8) iterations a second for WARM_DURATION s (default 30): one open
//                 (page 20) of CA by a herd viewer, then one refresh with the since_token (tags rpc=comm_open_warm, comm_refresh_warm).
//   join_burst    t=JOIN_START (default 160): JOIN_RATE (default 20) JoinCommunity calls a second for JOIN_DURATION s (default 20) on CJ, one
//                 new user each: the rule-3 counter shape (community_txn_attempts, ABORTED, memberCount exact).
//   verify        t=VERIFY_START (default 195): reads communities/CJ.memberCount through the Firestore emulator REST API (a check,
//                 not a measured path) and prints `CF VERIFY member_count=<n> expected=<joins ok + 1>` after the run in the summary.
//
// Reads are NOT a k6 metric: they come from the API request log (`fs_reads`, `fs_writes`, `fs_deletes`, `timeline_op`, `timeline_mode`,
// `cache_hit`, `removed`, `viewer_role`, `items_returned`, `items_filtered`, `community_txn_attempts`), see
// loadtest/analyze_community_feed.js. k6 prints `CF PHASE <name> <iso>` and `CF STEP <name> <iso>` lines that the analyzer uses to cut the
// log. Latency is emulator latency, indicative only. The emulator does not reproduce Firestore's per-document write limit or the
// production ABORTED behaviour: a clean burst here is evidence of the transaction shape (the Join never reads the community doc), not of
// production contention.
//
// Before the API starts: sign up the creator once and put its uid in COMMUNITY_CREATORS:
//   curl -s -X POST "http://$AUTH_EMULATOR_HOST/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key" \
//     -H 'Content-Type: application/json' -d '{"email":"w539owner@example.test","password":"w539-owner-pass-1","returnSecureToken":true}'
//   (the "localId" of the answer is the uid; OWNER_EMAIL and OWNER_PASSWORD override the pair in this file). CreateProfile needs a verified
//   email, so mark it verified in the emulator once (no real mail is involved):
//   curl -s -X POST "http://$AUTH_EMULATOR_HOST/identitytoolkit.googleapis.com/v1/projects/demo-dzeroth-local/accounts:update" \
//     -H "Authorization: Bearer owner" -H "Content-Type: application/json" -d "{\"localId\":\"<uid>\",\"emailVerified\":true}"
//
// API requirements (a local API against the emulators; load-testing skill): ENV=local FEATURE_POSTS=on FEATURE_GRAPH=on
// FEATURE_ENGAGEMENT=on (the budget counts the userLikes read) FEATURE_COMMUNITIES=on FEATURE_REMOVED_IDS=on, COMMUNITY_CREATORS=<owner uid>,
// and these raised (per instance / per user; every virtual user shares 127.0.0.1): RATE_LIMIT_PER_IP_PER_MIN,
// RATE_LIMIT_PRE_AUTH_IP_PER_MIN, RATE_LIMIT_PER_USER_PER_MIN, RATE_LIMIT_TIMELINE_PER_MIN, RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN,
// RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN, RATE_LIMIT_COMMUNITIES_READ_PER_MIN, RATE_LIMIT_POST_CREATE_PER_MIN, READ_BUDGET_PER_UID_PER_DAY,
// QUOTA_POSTS_PER_DAY, QUOTA_NEW_ACCOUNT_POSTS_PER_DAY, QUOTA_COMMUNITY_POSTS_PER_DAY, QUOTA_NEW_ACCOUNT_COMMUNITY_POSTS_PER_DAY,
// QUOTA_COMMUNITY_JOINS_PER_DAY, QUOTA_NEW_ACCOUNT_COMMUNITY_JOINS_PER_DAY, COMMUNITY_MUTATIONS_PER_DAY, COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY,
// COMMUNITY_MOD_ACTIONS_PER_DAY, COMMUNITIES_MAX_OWNED, COMMUNITIES_MAX_JOINED (all 1000000). The exact values of the recorded run are
// in docs/reviews/cost-model.md section 18.
//
//   k6 run loadtest/community_feed.js      # or: make loadtest SCENARIO=community_feed
//   node loadtest/analyze_community_feed.js api.log k6.out
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall, authHeaders, AUTH_EMULATOR_HOST, API_URL } from './graph_common.js';

const COMMUNITIES = 'dzeroth.communities.v1.CommunityService';
const TIMELINE = 'dzeroth.timeline.v1.TimelineService';
const POSTS = 'dzeroth.posts.v1.PostService';
const IDENTITY = 'dzeroth.identity.v1.IdentityService';

const FS_HOST = __ENV.FIRESTORE_EMULATOR_HOST || 'localhost:8080';
const PROJECT = __ENV.FIREBASE_PROJECT_ID || 'demo-dzeroth-local';
const OWNER_EMAIL = __ENV.OWNER_EMAIL || 'w539owner@example.test';
const OWNER_PASSWORD = __ENV.OWNER_PASSWORD || 'w539-owner-pass-1';

const AUTHORS = parseInt(__ENV.AUTHORS || '12', 10);
const VIEWERS = parseInt(__ENV.VIEWERS || '12', 10);
const HERD_VIEWERS = parseInt(__ENV.HERD_VIEWERS || '24', 10);
const COLD_SETTLE = parseInt(__ENV.COLD_SETTLE || '70', 10);
const COLD_HERD_START = parseInt(__ENV.COLD_HERD_START || '100', 10);
const WARM_HERD_START = parseInt(__ENV.WARM_HERD_START || '115', 10);
const WARM_DURATION = parseInt(__ENV.WARM_DURATION || '30', 10);
const WARM_RATE = parseInt(__ENV.WARM_RATE || '8', 10);
const JOIN_START = parseInt(__ENV.JOIN_START || '160', 10);
const JOIN_RATE = parseInt(__ENV.JOIN_RATE || '20', 10);
const JOIN_DURATION = parseInt(__ENV.JOIN_DURATION || '20', 10);
const VERIFY_START = parseInt(__ENV.VERIFY_START || '195', 10);
const POSTS_A = parseInt(__ENV.POSTS_A || '8', 10); // per author: 12 x 8 = 96
const POSTS_B = parseInt(__ENV.POSTS_B || '5', 10); // 60
const POSTS_G = parseInt(__ENV.POSTS_G || '3', 10); // 36

const unexpected = new Counter('community_unexpected_responses');
const joinOk = new Counter('community_join_ok');
const joinNotOk = new Counter('community_join_not_ok');

export const options = {
  setupTimeout: '1800s',
  scenarios: {
    cold_calls: { executor: 'per-vu-iterations', exec: 'coldCalls', vus: 1, iterations: 1, maxDuration: '15m' },
    cold_herd: { executor: 'per-vu-iterations', exec: 'coldHerd', vus: HERD_VIEWERS, iterations: 1, startTime: `${COLD_HERD_START}s`, maxDuration: '2m' },
    warm_herd: {
      executor: 'constant-arrival-rate',
      exec: 'warmHerd',
      rate: WARM_RATE,
      timeUnit: '1s',
      duration: `${WARM_DURATION}s`,
      startTime: `${WARM_HERD_START}s`,
      preAllocatedVUs: 30,
      maxVUs: 100,
    },
    join_burst: {
      executor: 'constant-arrival-rate',
      exec: 'joinBurst',
      rate: JOIN_RATE,
      timeUnit: '1s',
      duration: `${JOIN_DURATION}s`,
      startTime: `${JOIN_START}s`,
      preAllocatedVUs: 40,
      maxVUs: 120,
    },
    verify: { executor: 'per-vu-iterations', exec: 'verify', vus: 1, iterations: 1, startTime: `${VERIFY_START}s`, maxDuration: '1m' },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'], // the deliberate refusals are 4xx
    'http_req_duration{rpc:comm_open_warm}': ['p(95)<400'],
    'http_req_duration{rpc:comm_refresh_warm}': ['p(95)<400'],
    community_unexpected_responses: ['count==0'],
  },
};

let seq = 0;
const run = Math.floor(Date.now() / 1000).toString(36);
const key = (tag) => `cf-${run}-${tag}-${(seq++).toString(36)}-0123456789`.slice(0, 64);

function retry(fn, what) {
  for (let attempt = 0; attempt < 40; attempt++) {
    const res = fn();
    if (res.status === 200) return res;
    if (res.status !== 429) throw new Error(`setup: ${what}: status ${res.status}: ${res.body}`);
    sleep(2);
  }
  throw new Error(`setup: ${what}: still rate limited`);
}

function signInOwner() {
  const r = http.post(
    `http://${AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key`,
    JSON.stringify({ email: OWNER_EMAIL, password: OWNER_PASSWORD, returnSecureToken: true }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  if (r.status !== 200) throw new Error(`setup: owner sign-in ${r.status}: ${r.body} (sign the owner up first, see the file header)`);
  const owner = { uid: r.json('localId'), idToken: r.json('idToken') };
  // A profile once per emulator; an existing one answers with an error that is fine to ignore.
  http.post(
    `${API_URL}/${IDENTITY}/CreateProfile`,
    JSON.stringify({ idempotencyKey: `cf-owner-profile-${run}-0123456789`, handle: `cfown${run}`.slice(0, 15), displayName: 'CF owner' }),
    { headers: authHeaders(owner.idToken) },
  );
  return owner;
}

function createCommunity(owner, name) {
  const r = retry(() => rpcCall(COMMUNITIES, 'CreateCommunity', { idempotencyKey: key('cc'), name: `${name} ${run}`.slice(0, 30), description: 'W5-39 load smoke' }, owner.idToken, 'SeedCreate'), `create ${name}`);
  return r.json('community.communityId');
}

function join(user, cid) {
  retry(() => rpcCall(COMMUNITIES, 'JoinCommunity', { idempotencyKey: key('j'), communityId: cid }, user.idToken, 'SeedJoin'), `join ${cid}`);
}

function seedPosts(cid, authors, perAuthor, tag) {
  for (let a = 0; a < authors.length; a++) {
    for (let p = 0; p < perAuthor; p++) {
      retry(() => rpcCall(POSTS, 'CreatePost', { idempotencyKey: key('p'), text: `${tag} ${a}-${p} ${run}`, communityId: cid }, authors[a].idToken, 'SeedPost'), `seed ${tag} ${a}-${p}`);
    }
  }
}

export function setup() {
  const owner = signInOwner();
  const authors = mintUsers(AUTHORS, 'cauth');
  const viewers = mintUsers(VIEWERS, 'cview');
  const herd = mintUsers(HERD_VIEWERS, 'cherd');
  const joiners = mintUsers(JOIN_RATE * JOIN_DURATION + 20, 'cjoin');
  const c = {
    a: createCommunity(owner, 'W539 A'),
    b: createCommunity(owner, 'W539 B'),
    e: createCommunity(owner, 'W539 E'),
    h: createCommunity(owner, 'W539 H'),
    g: createCommunity(owner, 'W539 G'),
    j: createCommunity(owner, 'W539 J'),
  };
  for (const cid of [c.a, c.b, c.e, c.h, c.g]) for (const u of authors) join(u, cid);
  seedPosts(c.a, authors, POSTS_A, 'A');
  seedPosts(c.b, authors, POSTS_B, 'B');
  seedPosts(c.e, authors, 1, 'E');
  seedPosts(c.h, authors, 1, 'H');
  seedPosts(c.g, authors, POSTS_G, 'G');
  // Idle so every cache is older than CACHE_TTL when the timed phases start.
  sleep(COLD_SETTLE);
  return { owner, authors, viewers, herd, joiners, c };
}

function mark(kind, name) {
  console.log(`CF ${kind} ${name} ${new Date().toISOString()}`);
}

function expect(res, name, okStatuses) {
  const ok = (okStatuses || [200]).includes(res.status);
  check(res, { [`${name} status`]: () => ok });
  if (!ok) {
    unexpected.add(1);
    console.error(`unexpected ${name} status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
  return ok;
}

function ct(u, cid, body, name, okStatuses) {
  mark('STEP', name);
  const r = rpcCall(TIMELINE, 'GetCommunityTimeline', Object.assign({ communityId: cid }, body), u.idToken, name);
  expect(r, name, okStatuses);
  return r;
}

function mod(owner, method, cid, postId, name) {
  mark('STEP', name);
  const r = rpcCall(COMMUNITIES, method, { idempotencyKey: key('m'), communityId: cid, postId }, owner.idToken, name);
  expect(r, name);
  return r;
}

export function coldCalls(d) {
  mark('PHASE', 'cold_calls');
  const v = d.viewers;
  const { a, b, e, h } = d.c;

  // --- Community A: the open, the warm paths, the refreshes ------------------------------------------------------------
  const a1 = ct(v[1], a, { pageSize: 20 }, 'a_p20_allcold');
  const since1 = a1.json('sinceToken');
  const older1 = a1.json('nextPageToken');
  ct(v[2], a, { pageSize: 20 }, 'a_p20_warm_entry_cold_viewer');
  ct(v[1], a, { pageSize: 20 }, 'a_p20_warm_same_viewer');
  ct(v[1], a, { sinceToken: since1 }, 'a_refresh_0new_warm');
  for (let i = 0; i < 5; i++) {
    mark('STEP', `post_new_${i}`);
    expect(rpcCall(POSTS, 'CreatePost', { idempotencyKey: key('np'), text: `new ${i} ${run}`, communityId: a }, d.authors[i].idToken, 'new_post'), 'new_post');
  }
  // the same author, a plain post (no community_id): the extra reads and writes of CreatePost.community_id are the difference
  mark('STEP', 'post_plain_baseline');
  expect(rpcCall(POSTS, 'CreatePost', { idempotencyKey: key('pp'), text: `plain ${run}` }, d.authors[0].idToken, 'plain_post'), 'plain_post');
  sleep(1.1);
  const r5 = ct(v[1], a, { sinceToken: since1 }, 'a_refresh_5new_within_ttl');
  console.log(`CF NOTE a_refresh_5new_within_ttl returned ${(r5.json('posts') || []).length} posts`);
  ct(v[1], a, { pageToken: older1, pageSize: 20 }, 'a_older_page');
  ct(v[3], a, { pageSize: 50 }, 'a_p50_warm_entry_cold_viewer');

  // --- Community B: page 50 all-cold, then page 20 on the warm entry ---------------------------------------------------
  ct(v[4], b, { pageSize: 50 }, 'b_p50_allcold');
  ct(v[5], b, { pageSize: 20 }, 'b_p20_warm_entry_cold_viewer');

  // --- Community H: a hide during refreshes ---------------------------------------------------------------------------
  const h1 = ct(v[6], h, { pageSize: 20 }, 'h_open_p20_allcold');
  const hsince = h1.json('sinceToken');
  const victim = h1.json('posts.0.post.postId');
  ct(v[6], h, { sinceToken: hsince }, 'h_refresh_0new_warm');
  mod(d.owner, 'HideCommunityPost', h, victim, 'h_hide');
  const hr = ct(v[6], h, { sinceToken: hsince }, 'h_refresh_after_hide');
  console.log(`CF NOTE h_refresh_after_hide removed_ids=${JSON.stringify(hr.json('removedIds') || [])} victim=${victim}`);
  ct(v[7], h, { pageSize: 20 }, 'h_open_other_viewer_after_hide');
  mod(d.owner, 'RestoreCommunityPost', h, victim, 'h_restore');
  ct(v[6], h, { sinceToken: hsince }, 'h_refresh_after_restore');

  // --- an open of E to take a token, then one idle, then the cases that need a cold instance ---------------------------
  const e1 = ct(v[8], e, { pageSize: 20 }, 'e_open_p20_allcold');
  const esince = e1.json('sinceToken');
  mark('PHASE', 'idle_2');
  sleep(COLD_SETTLE);
  // Every cache and the shared entries are older than their 60 s now. The 5 posts of A were written before the idle: the entry refills
  // incrementally from the entry's own watermark (1 read per new post plus the empty-window floor), charged to this caller.
  const r5s = ct(v[1], a, { sinceToken: since1 }, 'a_refresh_5new_stale_entry');
  console.log(`CF NOTE a_refresh_5new_stale_entry returned ${(r5s.json('posts') || []).length} posts`);
  ct(v[8], e, { sinceToken: esince }, 'e_refresh_0new_cold_old_token');
  ct(v[9], a, { pageSize: 20 }, 'a_p20_after_idle_entry_refilled');
  ct(v[6], h, { sinceToken: hsince }, 'h_refresh_cold_old_token');
  mark('PHASE', 'cold_calls_done');
}

export function coldHerd(d) {
  const i = exec.scenario.iterationInTest;
  if (i === 0) mark('PHASE', 'cold_herd');
  const u = d.herd[i % d.herd.length];
  expect(rpcCall(TIMELINE, 'GetCommunityTimeline', { communityId: d.c.g, pageSize: 20 }, u.idToken, 'comm_open_coldherd'), 'comm_open_coldherd');
}

export function warmHerd(d) {
  const i = exec.scenario.iterationInTest;
  if (i === 0) mark('PHASE', 'warm_herd');
  const u = d.herd[i % d.herd.length];
  const open = rpcCall(TIMELINE, 'GetCommunityTimeline', { communityId: d.c.a, pageSize: 20 }, u.idToken, 'comm_open_warm');
  if (!expect(open, 'comm_open_warm')) return;
  const since = open.json('sinceToken');
  if (since) {
    expect(rpcCall(TIMELINE, 'GetCommunityTimeline', { communityId: d.c.a, sinceToken: since }, u.idToken, 'comm_refresh_warm'), 'comm_refresh_warm');
  }
}

export function joinBurst(d) {
  const i = exec.scenario.iterationInTest;
  if (i === 0) mark('PHASE', 'join_burst');
  const u = d.joiners[i % d.joiners.length];
  const r = rpcCall(COMMUNITIES, 'JoinCommunity', { idempotencyKey: key('jb'), communityId: d.c.j }, u.idToken, 'comm_join_burst');
  if (r.status === 200) joinOk.add(1);
  else {
    joinNotOk.add(1);
    console.error(`CF JOIN not ok status=${r.status} body=${String(r.body).slice(0, 160)}`);
  }
}

export function verify(d) {
  const r = http.get(`http://${FS_HOST}/v1/projects/${PROJECT}/databases/(default)/documents/communities/${d.c.j}`, { headers: { Authorization: 'Bearer owner' } });
  const n = r.status === 200 ? r.json('fields.memberCount.integerValue') : `status ${r.status}`;
  console.log(`CF VERIFY member_count=${n} (the owner counts 1; compare with community_join_ok + 1 in the summary)`);
}
