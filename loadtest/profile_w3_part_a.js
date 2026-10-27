// profile_w3_part_a: W3 Part A emulator smoke (W3-23, docs/plans/ui-w3-profile-graph-completion.md; ADR-0024 "Cost impact").
// One file, three MODEs, each seeding its own data in setup():
//
//   MODE=tabs          GetUserTimeline tab MEDIA and REPOSTS (profile_tabs), GetProfileRelationship. VIEWERS viewers (default 40) of
//                      one author with MEDIA_N media posts, PLAIN_N plain posts and REPOST_N reposts. Setup idles TABS_SETTLE
//                      seconds (default 65 > CACHE_TTL 60 s) so every cache is cold. A solo VU runs first: viewer 0 asks the
//                      author's Media tab (nothing cached anywhere), viewer 1 asks GetProfileRelationship of another account
//                      (nothing cached). Then the other viewers do the profile-open flow GetProfile -> GetProfileRelationship ->
//                      MEDIA p20 (twice) -> REPOSTS p20 (twice), odd viewers then MEDIA p50 and its second page. Then a "viral
//                      profile" load: RATE calls/s (default 15) for DURATION (default 20s) of random viewers on the same
//                      author's Media tab (the tabs have no result cache, so every call reads its page).
//   MODE=likes         ListLikedPosts (likes_list). PAIRS pairs of viewers (default 2): each likes LIKES (default 60) posts of its
//                      own authors (disjoint sets, so no viewer warms another's post cache); setup idles SETTLE seconds (default
//                      75 > CACHE_TTL 60 s); even viewers page at 20 and odd at 50, a cold pass then an immediate warm pass.
//                      CAP_LIKES=1000 adds one viewer at the 1,000-like cap that scrolls the whole list at page 50 (the read
//                      budget bound).
//   MODE=suggestions   ListSuggestedUsers (follow_suggestions). VIEWERS viewers (default 6) each follow FOLLOWEES (default 30)
//                      accounts; the newest 30 of those follow FOF_PER_FOLLOWEE (default 4) of CANDIDATES (default 60) accounts.
//                      Call 1 is cold, call 2 immediate (warm), call 3 after SETTLE_WARM seconds (default 65: the 60 s profile
//                      cache expired, the 1 h suggestion entry not). CURATED_VIEWERS (default 3) follow nobody and hit the
//                      curated list: the API must run with SUGGESTED_USER_IDS set to CURATED_IDS (printed by `node
//                      loadtest/analyze_w3_part_a.js --curated-ids`; CURATED_N uids of 28 characters). FOLLOWEES=600 VIEWERS=1 is
//                      the "user following 600 accounts" shape (the read cap must not grow with F).
//
// Reads are NOT a k6 metric: they come from the API request log (`fs_reads`, `read_budget_spent`, `source`, `candidates`,
// `tab`), see loadtest/analyze_w3_part_a.js. Latency is emulator latency, indicative only.
//
// API requirements (a local API against the emulators, nothing else; load-testing skill):
//   FEATURE_POSTS=on FEATURE_GRAPH=on FEATURE_ENGAGEMENT=on FEATURE_PROFILE_TABS=on FEATURE_LIKES_LIST=on
//   FEATURE_FOLLOW_SUGGESTIONS=on, RATE_LIMIT_PER_IP_PER_MIN and RATE_LIMIT_PRE_AUTH_IP_PER_MIN raised (every VU shares
//   127.0.0.1). Seeding limits to raise: RATE_LIMIT_POST_CREATE_PER_MIN, QUOTA_POSTS_PER_DAY, QUOTA_NEW_ACCOUNT_POSTS_PER_DAY,
//   RATE_LIMIT_LIKES_PER_MIN, QUOTA_LIKES_PER_DAY, QUOTA_NEW_ACCOUNT_LIKES_PER_DAY, RATE_LIMIT_GRAPH_FOLLOW_PER_MIN,
//   QUOTA_FOLLOWS_PER_DAY, QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY, GRAPH_MUTATIONS_PER_DAY and READ_BUDGET_PER_UID_PER_DAY (seeding spends the seeder's own
//   budget; MODE=tabs runs at the default 2000). Per-RPC limits for the timed calls: RATE_LIMIT_USER_TIMELINE_PER_MIN,
//   RATE_LIMIT_LIKES_LIST_PER_MIN, RATE_LIMIT_SUGGESTIONS_PER_MIN, RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN,
//   SUGGESTIONS_CALLS_PER_DAY. The exact values of the recorded run are in docs/reviews/cost-model.md section 12.
// The Media tab selects on `hasMedia`, which only the image-upload path writes; setup writes it through the Firestore emulator's
// REST API (FIRESTORE_EMULATOR_HOST, default localhost:8080; FIREBASE_PROJECT_ID) so that no Cloud Vision path is involved.
//
//   MODE=tabs k6 run loadtest/profile_w3_part_a.js      # or: MODE=tabs make loadtest SCENARIO=profile_w3_part_a
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall, authHeaders, API_URL, AUTH_EMULATOR_HOST } from './graph_common.js';

const MODE = __ENV.MODE || 'tabs';
const FS_HOST = __ENV.FIRESTORE_EMULATOR_HOST || 'localhost:8080';
const PROJECT = __ENV.FIREBASE_PROJECT_ID || 'demo-dzeroth-local';
const POSTS = 'dzeroth.posts.v1.PostService';
const ENG = 'dzeroth.engagement.v1.EngagementService';
const GRAPH = 'dzeroth.graph.v1.GraphService';
const TL = 'dzeroth.timeline.v1.TimelineService';
const ID = 'dzeroth.identity.v1.IdentityService';
const MEDIA = 'USER_TIMELINE_TAB_MEDIA';
const REPOSTS = 'USER_TIMELINE_TAB_REPOSTS';
const unexpected = new Counter('w3a_unexpected_responses');

const int = (name, def) => parseInt(__ENV[name] || String(def), 10);
const VIEWERS = int('VIEWERS', MODE === 'suggestions' ? 6 : 40);
const MEDIA_N = int('MEDIA_N', 60);
const PLAIN_N = int('PLAIN_N', 30);
const REPOST_N = int('REPOST_N', 60);
const PAIRS = int('PAIRS', 2);
const LIKES = int('LIKES', 60);
const CAP_LIKES = int('CAP_LIKES', 0);
const SETTLE = int('SETTLE', 75);
const SETTLE_WARM = int('SETTLE_WARM', 65);
const FOLLOWEES = int('FOLLOWEES', 30);
const FOF_PER_FOLLOWEE = int('FOF_PER_FOLLOWEE', 4);
const CANDIDATES = int('CANDIDATES', 60);
const CURATED_VIEWERS = int('CURATED_VIEWERS', 3);
const CURATED_N = int('CURATED_N', 12);
// The curated uids are fixed (the API reads SUGGESTED_USER_IDS at start): w323cur0000000000000000001 .. NN, 28 characters.
const CURATED_PREFIX = 'w323cur';
const CURATED_IDS = Array.from({ length: CURATED_N }, (_, i) => CURATED_PREFIX + String(i + 1).padStart(28 - CURATED_PREFIX.length, '0'));

const latency = (tag) => ({ [`http_req_duration{rpc:${tag}}`]: ['p(95)<400'] });

function buildOptions() {
  const base = { setupTimeout: '1800s', thresholds: { w3a_unexpected_responses: ['count==0'], http_req_failed: ['rate<0.01'] } };
  if (MODE === 'tabs') {
    return Object.assign(base, {
      scenarios: {
        solo: { executor: 'shared-iterations', exec: 'tabsSolo', vus: 1, iterations: 1, maxDuration: '1m' },
        flow: { executor: 'shared-iterations', exec: 'tabsFlow', startTime: '5s', vus: VIEWERS - 2, iterations: VIEWERS - 2, maxDuration: '3m' },
        viral: {
          executor: 'constant-arrival-rate', exec: 'tabsViral', startTime: '40s', rate: int('RATE', 15), timeUnit: '1s',
          duration: __ENV.DURATION || '20s', preAllocatedVUs: 20, maxVUs: 60,
        },
      },
      thresholds: Object.assign({}, base.thresholds, latency('tab_media_p20_warm'), latency('tab_viral')),
    });
  }
  if (MODE === 'likes') {
    const n = 2 * PAIRS + (CAP_LIKES > 0 ? 1 : 0);
    return Object.assign(base, { scenarios: { pass: { executor: 'shared-iterations', exec: 'likesRun', vus: n, iterations: n, maxDuration: '10m' } } });
  }
  const n = VIEWERS + CURATED_VIEWERS;
  return Object.assign(base, { scenarios: { calls: { executor: 'shared-iterations', exec: 'suggestionsCalls', vus: n, iterations: n, maxDuration: '10m' } } });
}
export const options = buildOptions();

function must(res, what) {
  if (res.status !== 200) throw new Error(`setup: ${what}: status ${res.status}: ${String(res.body).slice(0, 300)}`);
  return res;
}

// call is one timed RPC; a non-200 counts as unexpected.
function call(service, method, body, user, tag, extra) {
  const res = rpcCall(service, method, body, user.idToken, tag, extra);
  if (res.status !== 200) {
    unexpected.add(1);
    console.error(`${method} (${tag}) status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
  return res;
}

let seq = 0;
function createPost(user, run, text) {
  seq++;
  const res = must(rpcCall(POSTS, 'CreatePost', { idempotencyKey: `w3a-${run}-${seq}-0123456789`, text: `${text} ${run}` }, user.idToken), 'CreatePost');
  return res.json('post.post.postId');
}

// markHasMedia writes posts/{id}.hasMedia = true through the Firestore emulator's REST API (the upload path is not run).
function markHasMedia(postId) {
  must(
    http.patch(
      `http://${FS_HOST}/v1/projects/${PROJECT}/databases/(default)/documents/posts/${postId}?updateMask.fieldPaths=hasMedia`,
      JSON.stringify({ fields: { hasMedia: { booleanValue: true } } }),
      { headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' } },
    ),
    'mark hasMedia',
  );
}

function follow(user, targetUid, run, tag) {
  const key = `w3a-f-${run}-${tag}`.padEnd(16, '0').slice(0, 64);
  must(rpcCall(GRAPH, 'Follow', { idempotencyKey: key, userId: targetUid }, user.idToken), `Follow ${tag}`);
}

// mintFixed signs up (or re-uses) the account with the given uid and gives it a profile.
function mintFixed(uid, handle) {
  const email = `${uid}@example.com`;
  http.post(
    `http://${AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    JSON.stringify({ localId: uid, email, password: 'Passw0rd!x', emailVerified: true, returnSecureToken: true }),
    { headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' }, responseCallback: http.expectedStatuses(200, 400) },
  ); // a 400 on a re-run (the account exists) is expected, and not counted as a failed request
  const sign = must(
    http.post(
      `http://${AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key`,
      JSON.stringify({ email, password: 'Passw0rd!x', returnSecureToken: true }),
      { headers: { 'Content-Type': 'application/json' } },
    ),
    'signInWithPassword',
  );
  const idToken = sign.json('idToken');
  http.post(
    `${API_URL}/${ID}/CreateProfile`,
    JSON.stringify({ idempotencyKey: `w3a-cur-${uid}`.padEnd(16, '0'), handle, displayName: `Curated ${handle}` }),
    { headers: authHeaders(idToken), responseCallback: http.expectedStatuses(200, 409) },
  ); // ALREADY_EXISTS (409) on a re-run is expected, and not counted as a failed request
  return { uid, idToken };
}

// ---------------------------------------------------------------------------------------------------------------------
export function setup() {
  const run = Math.floor(Date.now() / 1000).toString(36);
  if (MODE === 'tabs') return setupTabs(run);
  if (MODE === 'likes') return setupLikes(run);
  if (MODE === 'suggestions') return setupSuggestions(run);
  throw new Error(`unknown MODE ${MODE}`);
}

function setupTabs(run) {
  const [author, other, ...viewers] = mintUsers(2 + VIEWERS, 'w3tab');
  for (let i = 0; i < MEDIA_N; i++) markHasMedia(createPost(author, run, `media ${i}`));
  for (let i = 0; i < PLAIN_N; i++) createPost(author, run, `plain ${i}`);
  for (let i = 0; i < REPOST_N; i++) {
    const orig = createPost(other, run, `original ${i}`);
    must(rpcCall(ENG, 'RepostPost', { idempotencyKey: `w3a-rp-${run}-${i}-0123456789`, postId: orig }, author.idToken), 'RepostPost');
  }
  sleep(int('TABS_SETTLE', 65)); // expire every cache the seeding warmed
  return { author, other, viewers };
}

function setupLikes(run) {
  const authorsPerViewer = 3;
  const perAuthor = Math.ceil(LIKES / authorsPerViewer);
  const viewerCount = 2 * PAIRS;
  const authors = mintUsers(viewerCount * authorsPerViewer, 'lka');
  const viewers = mintUsers(viewerCount, 'lkv');
  viewers.forEach((v, vi) => {
    const mine = [];
    authors.slice(vi * authorsPerViewer, (vi + 1) * authorsPerViewer).forEach((a, ai) => {
      for (let p = 0; p < perAuthor && mine.length < LIKES; p++) mine.push(createPost(a, run, `liked ${vi}-${ai}-${p}`));
    });
    mine.forEach((id, i) => must(rpcCall(ENG, 'LikePost', { idempotencyKey: `w3a-lk-${run}-${vi}-${i}-0123456789`, postId: id }, v.idToken), 'LikePost'));
  });
  let capViewer = null;
  if (CAP_LIKES > 0) {
    capViewer = mintUsers(1, 'lkc')[0];
    const capAuthors = mintUsers(Math.ceil(CAP_LIKES / 20), 'lkd');
    let n = 0;
    capAuthors.forEach((a, ai) => {
      for (let p = 0; p < 20 && n < CAP_LIKES; p++, n++) {
        const id = createPost(a, run, `cap ${ai}-${p}`);
        must(rpcCall(ENG, 'LikePost', { idempotencyKey: `w3a-lc-${run}-${n}-0123456789`, postId: id }, capViewer.idToken), 'LikePost cap');
      }
    });
  }
  sleep(SETTLE); // every cache entry the seeding created (posts, profiles, graph, userLikes: CACHE_TTL 60 s) expires
  return { viewers, capViewer, total: LIKES };
}

function setupSuggestions(run) {
  const candidates = mintUsers(CANDIDATES, 'sca');
  const followees = mintUsers(FOLLOWEES, 'sfo');
  // The newest SUGGESTIONS_SAMPLE_FOLLOWEES (30) followees feed the query: they need follow edges to candidates.
  followees.slice(-Math.min(30, followees.length)).forEach((f, fi) => {
    for (let k = 0; k < FOF_PER_FOLLOWEE; k++) follow(f, candidates[(fi * FOF_PER_FOLLOWEE + k) % candidates.length].uid, run, `c${fi}-${k}`);
  });
  const viewers = mintUsers(VIEWERS, 'svi');
  viewers.forEach((v, vi) => followees.forEach((f, fi) => follow(v, f.uid, run, `v${vi}-${fi}`)));
  CURATED_IDS.forEach((uid, i) => mintFixed(uid, `w3cur${i + 1}`));
  const curatedViewers = mintUsers(CURATED_VIEWERS, 'ski'); // follow nobody: the curated list answers
  sleep(int('SUGGESTIONS_SETTLE', 65)); // expire the profile and graph caches the seeding warmed so that call 1 is cold
  return { viewers, curatedViewers };
}

// ---------------------------------------------------------------------------------------------------------------------
function tabCall(viewer, uid, tab, pageSize, pageToken, tag) {
  return call(TL, 'GetUserTimeline', { userId: uid, tab, pageSize, pageToken: pageToken || '' }, viewer, tag, { page_size: String(pageSize) });
}

// tabsSolo runs alone before anything else touches the instance: the fully cold figures of the budget tests.
export function tabsSolo(data) {
  const [v0, v1] = data.viewers;
  tabCall(v0, data.author.uid, MEDIA, 20, '', 'tab_media_p20_cold');
  tabCall(v0, data.author.uid, MEDIA, 20, '', 'tab_media_p20_warm');
  call(GRAPH, 'GetProfileRelationship', { userId: data.other.uid }, v1, 'rel_cold');
  call(GRAPH, 'GetProfileRelationship', { userId: data.other.uid }, v1, 'rel_warm');
}

export function tabsFlow(data) {
  const i = exec.scenario.iterationInTest + 2; // viewers 0 and 1 belong to tabsSolo
  const v = data.viewers[i];
  const a = data.author.uid;
  // The profile-open flow: the header's GetProfile, then its relationship chip, then the tab.
  call(ID, 'GetProfile', { userId: a }, v, 'get_profile');
  call(GRAPH, 'GetProfileRelationship', { userId: a }, v, 'rel_after_profile');
  tabCall(v, a, MEDIA, 20, '', 'tab_media_p20_first');
  tabCall(v, a, MEDIA, 20, '', 'tab_media_p20_warm');
  tabCall(v, a, REPOSTS, 20, '', 'tab_reposts_p20_first');
  tabCall(v, a, REPOSTS, 20, '', 'tab_reposts_p20_warm');
  if (i % 2 === 1) {
    const r = tabCall(v, a, MEDIA, 50, '', 'tab_media_p50');
    const next = r.status === 200 ? r.json('nextPageToken') : '';
    if (next) tabCall(v, a, MEDIA, 50, next, 'tab_media_p50_page2');
  }
}

export function tabsViral(data) {
  const v = data.viewers[Math.floor(Math.random() * data.viewers.length)];
  const res = tabCall(v, data.author.uid, MEDIA, 20, '', 'tab_viral');
  check(res, { 'viral media call answered': (r) => r.status === 200 });
}

// ---------------------------------------------------------------------------------------------------------------------
// pageThrough lists every page of the viewer's likes and returns the rows seen.
function pageThrough(viewer, pageSize, tag) {
  let token = '';
  let rows = 0;
  for (let calls = 0; ; calls++) {
    const res = call(ENG, 'ListLikedPosts', { pageSize, pageToken: token }, viewer, tag, { page_size: String(pageSize) });
    if (res.status !== 200) return rows;
    rows += (res.json('posts') || []).length;
    token = res.json('nextPageToken') || '';
    if (!token) return rows;
    if (calls > 100) throw new Error('paging did not terminate');
  }
}

function expectRows(rows, want, what) {
  if (!check(rows, { [`${what} lists every like once`]: (n) => n === want })) {
    unexpected.add(1);
    console.error(`${what}: rows=${rows} want ${want}`);
  }
}

export function likesRun(data) {
  const i = exec.scenario.iterationInTest;
  if (i < data.viewers.length) {
    const ps = i % 2 === 0 ? 20 : 50; // even viewers page at 20, odd at 50
    expectRows(pageThrough(data.viewers[i], ps, 'likes_cold'), data.total, `viewer ${i} cold`);
    expectRows(pageThrough(data.viewers[i], ps, 'likes_warm'), data.total, `viewer ${i} warm`);
    return;
  }
  // The viewer at the 1,000-like cap scrolls the whole list at page 50 (20 pages); every call is charged to the read budget.
  expectRows(pageThrough(data.capViewer, 50, 'likes_cap'), CAP_LIKES, 'cap viewer');
}

// ---------------------------------------------------------------------------------------------------------------------
export function suggestionsCalls(data) {
  const i = exec.scenario.iterationInTest;
  const suggest = (viewer, tag) => call(GRAPH, 'ListSuggestedUsers', {}, viewer, tag);
  if (i < data.viewers.length) {
    const v = data.viewers[i];
    check(suggest(v, 'sug_fof_cold'), { 'fof suggestions returned': (r) => r.status === 200 && (r.json('users') || []).length > 0 });
    suggest(v, 'sug_fof_warm');
    sleep(SETTLE_WARM);
    suggest(v, 'sug_fof_warm_after_profile_ttl');
    return;
  }
  const v = data.curatedViewers[i - data.viewers.length];
  check(suggest(v, 'sug_curated_cold'), { 'curated suggestions returned': (r) => r.status === 200 && (r.json('users') || []).length > 0 });
  suggest(v, 'sug_curated_warm');
}
