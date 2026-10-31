// list_timeline: W5 Part A emulator load smoke (W5-18, docs/plans/ui-w5-lists-communities.md "W5-18"; ADR-0030 "Cost impact").
// One file, one timeline, ONE local API process ("one instance") and the Firebase emulators. Never point it at dzeroth-dev or
// dzeroth-prod: it mints about 300 users and raises every list, post, graph and read-budget cap.
//
//   setup()       Mints 3 owners (O1..O3), AUTHORS (default 250) authors with one post each, VIEWERS (default 12) named viewers and
//                 HERD_VIEWERS (default 20) herd viewers. Lists (all public): LA = 50 members (authors 0-49, owner O1), LB = 150
//                 members (authors 50-199, owner O2, the LIST_MAX_MEMBERS default), LC = 50 members (authors 200-249, owner O3),
//                 and 4 empty lists of O1 (X1..X4, for the 5-tab SetHomeTabs worst case). Viewer H follows the 50 authors of LC.
//                 Then it idles COLD_SETTLE s (default 70 > CACHE_TTL 60 s) so no per-instance cache holds anything.
//   cold_calls    t=0, ONE virtual user, serial; every call is preceded by a `W5 STEP <name> <iso>` marker so the analyzer gives each
//                 request line its case (the analyzer pairs the i-th step with the i-th request line: one RPC per step). Two further
//                 idles of COLD_SETTLE s (before the tab group and before the list-read group) make those groups cold. Groups: list timeline (cold page 20 / 50, refresh with 0 and with 5 new, older page, owner,
//                 the 150-member page 50, the author-recent entries shared with Home), SetHomeTabs / GetMe, then the list reads and
//                 writes (CreateList, AddListMember, GetList, ListUserLists, ListListMembers, Update/Delete/Remove).
//   herd          t=HERD_START (default 240, after the two further idles of the serial phase): HERD_RATE (default 8) iterations a second for HERD_DURATION s (default 40); an
//                 iteration is one open (page 20) of LA or LB by a herd viewer followed by one refresh with the since_token. This
//                 is the warm-path p95 (tags: rpc=list_open_warm, list_refresh_warm).
//
// Reads are NOT a k6 metric: they come from the API request log (`fs_reads`, `fs_writes`, `fs_deletes`, `timeline_op`, `timeline_mode`,
// `list_members`, `timeline_chunks`, `authors_from_cache`, `cache_hit`), see loadtest/analyze_list_timeline.js. k6 prints
// `W5 PHASE <name> <iso>` and `W5 STEP <name> <iso>` lines that the analyzer uses to cut the log. Latency is emulator latency, indicative only.
//
// API requirements (a local API against the emulators; load-testing skill): ENV=local FEATURE_LISTS=on FEATURE_POSTS=on FEATURE_GRAPH=on
// FEATURE_ENGAGEMENT=on (the budget counts the userLikes read; FEATURE_REMOVED_IDS=on adds the removal-log window query to a refresh with an old token), and these raised (per instance / per user; every virtual user shares
// 127.0.0.1): RATE_LIMIT_PER_IP_PER_MIN, RATE_LIMIT_PRE_AUTH_IP_PER_MIN, RATE_LIMIT_PER_USER_PER_MIN, RATE_LIMIT_LISTS_WRITE_PER_MIN,
// RATE_LIMIT_LISTS_READ_PER_MIN, RATE_LIMIT_LIST_TIMELINE_PER_MIN, RATE_LIMIT_TIMELINE_PER_MIN, RATE_LIMIT_GRAPH_FOLLOW_PER_MIN,
// LIST_MUTATIONS_PER_DAY, QUOTA_NEW_ACCOUNT_LIST_ADDS_PER_DAY, QUOTA_LIST_ADDS_PER_DAY, QUOTA_NEW_ACCOUNT_LIST_CREATES_PER_DAY,
// QUOTA_LIST_CREATES_PER_DAY, READ_BUDGET_PER_UID_PER_DAY, RATE_LIMIT_POST_CREATE_PER_MIN, QUOTA_POSTS_PER_DAY,
// QUOTA_NEW_ACCOUNT_POSTS_PER_DAY, QUOTA_FOLLOWS_PER_DAY, QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY. The exact values of the recorded run are in
// docs/reviews/cost-model.md section 17.
//
//   k6 run loadtest/list_timeline.js      # or: make loadtest SCENARIO=list_timeline
//   node loadtest/analyze_list_timeline.js api.log k6.out
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall, graphCall } from './graph_common.js';

const LISTS = 'dzeroth.lists.v1.ListService';
const TIMELINE = 'dzeroth.timeline.v1.TimelineService';
const IDENTITY = 'dzeroth.identity.v1.IdentityService';
const POSTS = 'dzeroth.posts.v1.PostService';

const AUTHORS = parseInt(__ENV.AUTHORS || '250', 10); // 0-49 LA, 50-199 LB, 200-249 LC
const VIEWERS = parseInt(__ENV.VIEWERS || '12', 10);
const HERD_VIEWERS = parseInt(__ENV.HERD_VIEWERS || '20', 10);
const COLD_SETTLE = parseInt(__ENV.COLD_SETTLE || '70', 10);
const HERD_START = parseInt(__ENV.HERD_START || '240', 10);
const HERD_DURATION = parseInt(__ENV.HERD_DURATION || '40', 10);
const HERD_RATE = parseInt(__ENV.HERD_RATE || '8', 10);
const unexpected = new Counter('list_unexpected_responses');

export const options = {
  setupTimeout: '1500s',
  scenarios: {
    cold_calls: { executor: 'per-vu-iterations', exec: 'coldCalls', vus: 1, iterations: 1, maxDuration: '15m' },
    herd: {
      executor: 'constant-arrival-rate',
      exec: 'herd',
      rate: HERD_RATE,
      timeUnit: '1s',
      duration: `${HERD_DURATION}s`,
      startTime: `${HERD_START}s`,
      preAllocatedVUs: 30,
      maxVUs: 100,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'], // the deliberate refusals (NOT_FOUND, LIMIT_REACHED) are 4xx
    'http_req_duration{rpc:list_open_warm}': ['p(95)<400'],
    'http_req_duration{rpc:list_refresh_warm}': ['p(95)<400'],
    list_unexpected_responses: ['count==0'],
  },
};

let seq = 0;
const run = Math.floor(Date.now() / 1000).toString(36);
const key = (tag) => `lt-${run}-${tag}-${(seq++).toString(36)}-0123456789`.slice(0, 64);

function retry(fn, what) {
  for (let attempt = 0; attempt < 40; attempt++) {
    const res = fn();
    if (res.status === 200) return res;
    if (res.status !== 429) throw new Error(`setup: ${what}: status ${res.status}: ${res.body}`);
    sleep(2);
  }
  throw new Error(`setup: ${what}: still rate limited`);
}

function createList(owner, name, isPrivate) {
  const r = retry(() => rpcCall(LISTS, 'CreateList', { idempotencyKey: key('cl'), name, isPrivate: !!isPrivate }, owner.idToken, 'SeedCreateList'), `create ${name}`);
  return r.json('list.listId');
}

function addMembers(owner, listId, users) {
  for (const u of users) {
    retry(() => rpcCall(LISTS, 'AddListMember', { idempotencyKey: key('am'), listId, userId: u.uid }, owner.idToken, 'SeedAdd'), `add ${u.uid}`);
  }
}

export function setup() {
  const owners = mintUsers(3, 'lowner');
  const authors = mintUsers(AUTHORS, 'lauth');
  const viewers = mintUsers(VIEWERS, 'lview');
  const herd = mintUsers(HERD_VIEWERS, 'lherd');
  for (let a = 0; a < authors.length; a++) {
    retry(() => rpcCall(POSTS, 'CreatePost', { idempotencyKey: key('p'), text: `list seed ${a} ${run}` }, authors[a].idToken, 'SeedPost'), `seed post ${a}`);
  }
  const lists = {
    la: createList(owners[0], 'W5 LA 50', false),
    lb: createList(owners[1], 'W5 LB 150', false),
    lc: createList(owners[2], 'W5 LC 50', false),
    x: [1, 2, 3, 4].map((i) => createList(owners[0], `W5 X${i}`, false)),
  };
  addMembers(owners[0], lists.la, authors.slice(0, 50));
  addMembers(owners[1], lists.lb, authors.slice(50, 200));
  addMembers(owners[2], lists.lc, authors.slice(200, 250));
  // Viewer 0 (H) follows the 50 authors of LC so Home and the list share author-recent entries.
  for (let j = 200; j < 250; j++) {
    retry(() => graphCall('Follow', { idempotencyKey: key('f'), userId: authors[j].uid }, viewers[0].idToken, 'SeedFollow'), `follow ${j}`);
  }
  // A herd open needs a clean slate per run, not per viewer: nothing to seed. Idle so every cache is older than CACHE_TTL.
  sleep(COLD_SETTLE);
  return { owners, authors, viewers, herd, lists };
}

function mark(kind, name) {
  console.log(`W5 ${kind} ${name} ${new Date().toISOString()}`);
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

function lt(u, listId, body, name, okStatuses) {
  mark('STEP', name);
  const r = rpcCall(TIMELINE, 'GetListTimeline', Object.assign({ listId }, body), u.idToken, name);
  expect(r, name, okStatuses);
  return r;
}

export function coldCalls(d) {
  mark('PHASE', 'cold_calls');
  const [o1, o2, o3] = d.owners;
  const v = d.viewers;
  const { la, lb, lc, x } = d.lists;

  // --- List timeline -------------------------------------------------------------------------------------------------
  // everything cold: a non-owner viewer, a cold list, a cold owner, 50 cold authors (2 chunks)
  const c1 = lt(v[1], la, { pageSize: 20 }, 'lt_la_p20_cold_nonowner');
  const since1 = c1.json('sinceToken');
  const older1 = c1.json('nextPageToken');
  lt(v[1], la, { sinceToken: since1 }, 'lt_la_refresh_0new');
  // 5 new posts by 5 members, then the refresh of the same viewer
  for (let i = 0; i < 5; i++) {
    mark('STEP', `post_new_${i}`);
    expect(rpcCall(POSTS, 'CreatePost', { idempotencyKey: key('np'), text: `new ${i} ${run}` }, d.authors[i].idToken, 'new_post'), 'new_post');
  }
  sleep(1.1);
  const r5 = lt(v[1], la, { sinceToken: since1 }, 'lt_la_refresh_5new');
  console.log(`refresh_5new returned ${(r5.json('posts') || []).length} posts`);
  lt(v[1], la, { pageToken: older1, pageSize: 20 }, 'lt_la_older_page');
  // a second cold viewer on the now-warm list/owner (viewer cold only), page 50
  lt(v[2], la, { pageSize: 50 }, 'lt_la_p50_viewer_cold');
  // the 150-member list: owner O2, list, viewer and 150 authors (5 chunks) all cold
  const b3 = lt(v[3], lb, { pageSize: 50 }, 'lt_lb150_p50_cold_nonowner');
  lt(v[3], lb, { sinceToken: b3.json('sinceToken') }, 'lt_lb150_refresh_0new');
  lt(v[4], lb, { pageSize: 20 }, 'lt_lb150_p20_viewer_cold');
  // the owner of a list (no owner-graph read), list cold: O3 on LC page 20 (cold owner caches)
  lt(o3, lc, { pageSize: 20 }, 'lt_lc_p20_cold_owner');
  // Home <-> list sharing. Viewer H follows the 50 authors of LC. Home page 50 (cold) caches the authors that did not
  // fill a chunk; the list then finds them in the author-recent entries.
  mark('STEP', 'home_h_p50_cold');
  expect(rpcCall(TIMELINE, 'GetHomeTimeline', { pageSize: 50 }, v[0].idToken, 'home_h_p50'), 'home_h_p50');
  lt(v[0], lc, { pageSize: 20 }, 'lt_lc_p20_after_home_shared');
  lt(v[5], lc, { pageSize: 20 }, 'lt_lc_p20_other_viewer_shared');
  // an unreadable list: a private list of another owner (NOT_FOUND, byte-identical to a missing id)
  mark('STEP', 'seed_private_list');
  const priv = createList(o3, 'W5 private', true);
  lt(v[6], priv, { pageSize: 20 }, 'lt_private_not_found', [404]);
  lt(v[6], '1234567890123456789', { pageSize: 20 }, 'lt_missing_not_found', [404]);
  lt(v[6], 'not-an-id', { pageSize: 20 }, 'lt_invalid_id', [400]);

  // A second idle: every cache (list docs, profiles, graphs, author-recent) is older than CACHE_TTL again, so the tab and list-read
  // cases below are cold too.
  mark('PHASE', 'idle_2');
  sleep(COLD_SETTLE);
  // A refresh with the first call's since_token, now two idles old, from a cold viewer on a cold list. With FEATURE_REMOVED_IDS on this
  // is the path the ADR prices at +107 (the removal-log window query, ADR-0016); with it off it is a plain cold refresh (3 + C).
  lt(v[1], la, { sinceToken: since1 }, 'lt_la_refresh_old_token_cold', [200, 400]);

  // --- SetHomeTabs / GetMe -------------------------------------------------------------------------------------------
  const tab = (id) => ({ kind: 'HOME_TAB_KIND_LIST', id });
  const T = v[7];
  mark('STEP', 'getme_before_tabs_cold');
  expect(rpcCall(IDENTITY, 'GetMe', {}, T.idToken, 'GetMe'), 'getme');
  mark('STEP', 'getme_warm');
  expect(rpcCall(IDENTITY, 'GetMe', {}, T.idToken, 'GetMe'), 'getme');
  const k5 = key('ht');
  mark('STEP', 'sethometabs_5_foreign_lists');
  const s5 = rpcCall(TIMELINE, 'SetHomeTabs', { idempotencyKey: k5, tabs: [la, lb, lc, x[0], x[1]].map(tab) }, T.idToken, 'SetHomeTabs');
  expect(s5, 'sethometabs5');
  mark('STEP', 'sethometabs_5_replay_same_key');
  expect(rpcCall(TIMELINE, 'SetHomeTabs', { idempotencyKey: k5, tabs: [la, lb, lc, x[0], x[1]].map(tab) }, T.idToken, 'SetHomeTabs'), 'sethometabs5r');
  mark('STEP', 'sethometabs_5_same_content_new_key');
  expect(rpcCall(TIMELINE, 'SetHomeTabs', { idempotencyKey: key('ht'), tabs: [la, lb, lc, x[0], x[1]].map(tab) }, T.idToken, 'SetHomeTabs'), 'sethometabs5u');
  mark('STEP', 'sethometabs_6_limit');
  expect(rpcCall(TIMELINE, 'SetHomeTabs', { idempotencyKey: key('ht'), tabs: [la, lb, lc, x[0], x[1], x[2]].map(tab) }, T.idToken, 'SetHomeTabs'), 'sethometabs6', [400, 412, 429]);
  mark('STEP', 'sethometabs_reorder_3');
  expect(rpcCall(TIMELINE, 'SetHomeTabs', { idempotencyKey: key('ht'), tabs: [lc, la, lb].map(tab) }, T.idToken, 'SetHomeTabs'), 'sethometabs3');
  mark('STEP', 'getme_with_tabs_warm');
  expect(rpcCall(IDENTITY, 'GetMe', {}, T.idToken, 'GetMe'), 'getme');
  // the owner pinning own lists (titles are copied, owner path)
  mark('STEP', 'sethometabs_owner_2_own_lists');
  expect(rpcCall(TIMELINE, 'SetHomeTabs', { idempotencyKey: key('ht'), tabs: [la, x[0]].map(tab) }, o1.idToken, 'SetHomeTabs'), 'sethometabs_owner');
  mark('STEP', 'sethometabs_clear');
  expect(rpcCall(TIMELINE, 'SetHomeTabs', { idempotencyKey: key('ht'), tabs: [] }, o1.idToken, 'SetHomeTabs'), 'sethometabs_clear');

  mark('PHASE', 'idle_3');
  sleep(COLD_SETTLE);

  // --- List reads (W5-5..W5-7) -------------------------------------------------------------------------------------
  // GetMe of the viewer who pinned tabs earlier, now cold again (ADR-0030: GetMe.home_tabs adds 0 reads over the profile read).
  mark('STEP', 'getme_with_tabs_cold');
  expect(rpcCall(IDENTITY, 'GetMe', {}, T.idToken, 'GetMe'), 'getme');
  const R = v[8];
  const call = (step, method, body, who, ok) => {
    mark('STEP', step);
    const r = rpcCall(LISTS, method, body, who.idToken, step);
    expect(r, step, ok);
    return r;
  };
  call('getlist_nonowner_cold', 'GetList', { listId: lb }, R);
  call('getlist_nonowner_warm', 'GetList', { listId: lb }, R);
  call('getlist_owner', 'GetList', { listId: la }, o1);
  call('listuserlists_owner_own', 'ListUserLists', {}, o1);
  call('listuserlists_other_owner_cold', 'ListUserLists', { ownerId: o1.uid || '' }, v[9]);
  call('listuserlists_contains_user', 'ListUserLists', { containsUserId: d.authors[0].uid }, o1);
  const m20 = call('listmembers_nonowner_p20_cold', 'ListListMembers', { listId: lb, pageSize: 20 }, v[10]);
  call('listmembers_nonowner_p50_warm', 'ListListMembers', { listId: lb, pageSize: 50 }, v[10]);
  call('listmembers_nonowner_p20_next_page', 'ListListMembers', { listId: lb, pageSize: 20, pageToken: m20.json('nextPageToken') }, v[10]);
  call('listmembers_owner_p50_cold', 'ListListMembers', { listId: la, pageSize: 50 }, o1);

  // --- List writes (W5-4) ------------------------------------------------------------------------------------------
  const ck = key('wc');
  const cr = call('createlist_cold', 'CreateList', { idempotencyKey: ck, name: 'W5 writes', isPrivate: false }, o2);
  const wl = cr.json('list.listId');
  call('createlist_replay', 'CreateList', { idempotencyKey: ck, name: 'W5 writes', isPrivate: false }, o2);
  const ak = key('wa');
  call('addmember_cold', 'AddListMember', { idempotencyKey: ak, listId: wl, userId: d.authors[0].uid }, o2);
  call('addmember_replay', 'AddListMember', { idempotencyKey: ak, listId: wl, userId: d.authors[0].uid }, o2);
  call('addmember_already_member', 'AddListMember', { idempotencyKey: key('wa'), listId: wl, userId: d.authors[0].uid }, o2);
  call('addmember_second', 'AddListMember', { idempotencyKey: key('wa'), listId: wl, userId: d.authors[1].uid }, o2);
  call('removemember', 'RemoveListMember', { idempotencyKey: key('wr'), listId: wl, userId: d.authors[1].uid }, o2);
  call('removemember_not_member', 'RemoveListMember', { idempotencyKey: key('wr'), listId: wl, userId: d.authors[1].uid }, o2);
  call('updatelist_rename', 'UpdateList', { idempotencyKey: key('wu'), listId: wl, name: 'W5 writes 2' }, o2);
  call('updatelist_unchanged', 'UpdateList', { idempotencyKey: key('wu'), listId: wl, name: 'W5 writes 2' }, o2);
  // the 151st member: LB is full (150)
  call('addmember_list_full_150', 'AddListMember', { idempotencyKey: key('wa'), listId: lb, userId: d.authors[0].uid }, o2, [412, 429, 400]);
  call('deletelist', 'DeleteList', { idempotencyKey: key('wd'), listId: wl }, o2);
  call('deletelist_again', 'DeleteList', { idempotencyKey: key('wd'), listId: wl }, o2);
  mark('PHASE', 'cold_calls_done');
}

export function herd(d) {
  const i = exec.scenario.iterationInTest;
  const u = d.herd[i % d.herd.length];
  const listId = i % 4 === 0 ? d.lists.lb : d.lists.la; // one in four on the 150-member list
  const open = rpcCall(TIMELINE, 'GetListTimeline', { listId, pageSize: 20 }, u.idToken, 'list_open_warm');
  if (!expect(open, 'list_open_warm')) return;
  const since = open.json('sinceToken');
  if (since) {
    expect(rpcCall(TIMELINE, 'GetListTimeline', { listId, sinceToken: since }, u.idToken, 'list_refresh_warm'), 'list_refresh_warm');
  }
}
