// search: W4 emulator load smoke (W4-23, docs/plans/ui-w4-discovery-search.md "W4-23"; ADR-0028 "Cost impact"). One file, one timeline of
// phases, all against ONE local API process (one "instance") and the Firebase emulators. Never point it at dzeroth-dev or dzeroth-prod:
// it creates about 2,300 posts and raises every search, post and read-budget cap.
//
//   setup()          Mints NUM_USERS users (default 60: the first AUTHORS (20) are authors, the rest are viewers who have never made a
//                    call), seeds COLD_TAGS (6) tags with TAG_POSTS (40) posts each (tag 3, the MEDIA scan, LONG_TAG_POSTS 70) (every third post gets one image, media + hasMedia, through the
//                    Firestore emulator REST API, as profile_w3_part_a.js does), a HOT tag, and filler posts with trending tags up to
//                    REFRESH_POSTS (default 2,100) posts in all, so the first trends refresh is cut at the 2,000-post cap. Then it idles
//                    COLD_SETTLE s (default 70 > CACHE_TTL 60 s) so no per-instance cache holds anything.
//   cold_calls       t=0, ONE virtual user, serial; every call is preceded by a `W4 STEP <name> <iso time>` marker so the analyzer can
//                    give each request line its case. Cases: SearchPeople at limit 5 and 20 (all cold; same viewer again = all warm;
//                    another viewer = prefix entry warm, viewer cold), a sparse prefix (1 row) and an empty prefix, the rejected
//                    queries (VALIDATION, unsupported; first call of a cold viewer, then the same viewer warm), SearchPosts TOP, LATEST
//                    and MEDIA page 1 on one tag (one entry serves all three), LATEST page_size 50 (skips the entry), a LATEST older
//                    page, a MEDIA older scan, unsupported and invalid post queries.
//   refresh          t=REFRESH_START (default 60): POST /internal/cron/trends-refresh until the backlog is drained (run 1 is cut at
//                    TRENDS_MAX_POSTS_PER_RUN), a second run for the rest, a third and an immediate repeat (skipped "fresh"),
//                    /internal/cron/daily-maintenance (also fresh), then 31 s later (TRENDS_MIN_INTERVAL 30 s) daily-maintenance with
//                    nothing new, then NEW_POSTS (120) new posts over 12 tags, 31 s and a last run, so the list GetTrends serves has 12
//                    tags. ENV=local makes /internal/* unauthenticated. Reads are the trends_refresh / trends_skipped lines.
//   trends           t=TRENDS_START (default 190): GetTrends from a cold viewer (with and without `prefix`), then a herd of TRENDS_RATE
//                    calls/s (default 30) for TRENDS_DURATION s (default 40) from all viewers: one document read per instance per 10 min.
//   typeahead_burst  t=BURST_START (default 250): BURST_N (default 600) SearchPeople limit-5 calls at BURST_RATE/s (default 40). Odd
//                    calls type the progressive prefixes (2 to 7 characters) of one shared handle (the prefix entries are shared by
//                    every viewer); even calls are random 2 character prefixes (diverse, mostly empty).
//   hot_tag          t=HOT_START (default 275): HOT_DURATION s (default 75, longer than the 60 s tag TTL): the hot tag takes 50 new
//                    posts a minute and HOT_RATE (default 8) SearchPosts TOP / LATEST page-1 calls a second from the viewers.
//
// Reads are NOT a k6 metric: they come from the API request log (`fs_reads`, `query_kind`, `tab`, `cache_hit`, `results`, `dropped`),
// see loadtest/analyze_search.js. k6 prints `W4 PHASE <name> <iso>` and `W4 STEP <name> <iso>` lines (stdout/stderr) that the analyzer uses
// to cut the log. Latency is emulator latency, indicative only.
//
// API requirements (a local API against the emulators; load-testing skill): FEATURE_SEARCH=on FEATURE_TRENDS=on FEATURE_POSTS=on
// FEATURE_GRAPH=on, ENV=local, TRENDS_MIN_INTERVAL=30s, and these raised (they are per instance and per user, and every virtual user shares
// 127.0.0.1): RATE_LIMIT_PER_IP_PER_MIN, RATE_LIMIT_PRE_AUTH_IP_PER_MIN, RATE_LIMIT_PER_USER_PER_MIN, RATE_LIMIT_SEARCH_PEOPLE_PER_MIN,
// RATE_LIMIT_SEARCH_POSTS_PER_MIN, SEARCH_CALLS_PER_DAY, READ_BUDGET_PER_UID_PER_DAY, RATE_LIMIT_POST_CREATE_PER_MIN, QUOTA_POSTS_PER_DAY,
// QUOTA_NEW_ACCOUNT_POSTS_PER_DAY. The exact values of the recorded run are in docs/reviews/cost-model.md section 15.
//
//   k6 run loadtest/search.js      # or: make loadtest SCENARIO=search
//   node loadtest/analyze_search.js api.log k6.out
//   node loadtest/search_sizes.js  # response bytes for the egress line
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall, API_URL } from './graph_common.js';

const SEARCH = 'dzeroth.search.v1.SearchService';
const POSTS = 'dzeroth.posts.v1.PostService';
const FS_HOST = __ENV.FIRESTORE_EMULATOR_HOST || 'localhost:8080';
const PROJECT = __ENV.FIREBASE_PROJECT_ID || 'demo-dzeroth-local';

const NUM_USERS = parseInt(__ENV.NUM_USERS || '60', 10);
const AUTHORS = parseInt(__ENV.AUTHORS || '20', 10);
const COLD_TAGS = parseInt(__ENV.COLD_TAGS || '6', 10);
const TAG_POSTS = parseInt(__ENV.TAG_POSTS || '40', 10);
const LONG_TAG_POSTS = parseInt(__ENV.LONG_TAG_POSTS || '70', 10); // tag 3 (the MEDIA scan tag) needs 30 older posts to reach the scan cap
const REFRESH_POSTS = parseInt(__ENV.REFRESH_POSTS || '2100', 10);
const TREND_TAGS = parseInt(__ENV.TREND_TAGS || '40', 10);
const NEW_POSTS = parseInt(__ENV.NEW_POSTS || '120', 10);
const COLD_SETTLE = parseInt(__ENV.COLD_SETTLE || '70', 10);
const REFRESH_START = parseInt(__ENV.REFRESH_START || '60', 10);
const TRENDS_START = parseInt(__ENV.TRENDS_START || '190', 10);
const TRENDS_RATE = parseInt(__ENV.TRENDS_RATE || '30', 10);
const TRENDS_DURATION = parseInt(__ENV.TRENDS_DURATION || '40', 10);
const BURST_START = parseInt(__ENV.BURST_START || '250', 10);
const BURST_N = parseInt(__ENV.BURST_N || '600', 10);
const BURST_RATE = parseInt(__ENV.BURST_RATE || '40', 10);
const HOT_START = parseInt(__ENV.HOT_START || '275', 10);
const HOT_DURATION = parseInt(__ENV.HOT_DURATION || '75', 10);
const HOT_RATE = parseInt(__ENV.HOT_RATE || '8', 10);

const unexpected = new Counter('search_unexpected_responses');

export const options = {
  setupTimeout: '1800s',
  scenarios: {
    cold_calls: { executor: 'shared-iterations', exec: 'coldCalls', vus: 1, iterations: 1, startTime: '0s', maxDuration: '5m' },
    refresh: { executor: 'shared-iterations', exec: 'refreshRuns', vus: 1, iterations: 1, startTime: `${REFRESH_START}s`, maxDuration: '5m' },
    trends: { executor: 'shared-iterations', exec: 'trendsCalls', vus: 1, iterations: 1, startTime: `${TRENDS_START}s`, maxDuration: '5m' },
    trends_herd: {
      executor: 'constant-arrival-rate', exec: 'trendsHerd', rate: TRENDS_RATE, timeUnit: '1s', duration: `${TRENDS_DURATION}s`,
      preAllocatedVUs: 20, maxVUs: 60, startTime: `${TRENDS_START + 10}s`,
    },
    typeahead_burst: {
      executor: 'constant-arrival-rate', exec: 'typeahead', rate: BURST_RATE, timeUnit: '1s', duration: `${Math.ceil(BURST_N / BURST_RATE)}s`,
      preAllocatedVUs: 30, maxVUs: 100, startTime: `${BURST_START}s`,
    },
    hot_posts: {
      executor: 'constant-arrival-rate', exec: 'hotPost', rate: 50, timeUnit: '1m', duration: `${HOT_DURATION}s`,
      preAllocatedVUs: 5, maxVUs: 20, startTime: `${HOT_START}s`,
    },
    hot_search: {
      executor: 'constant-arrival-rate', exec: 'hotSearch', rate: HOT_RATE, timeUnit: '1s', duration: `${HOT_DURATION}s`,
      preAllocatedVUs: 20, maxVUs: 60, startTime: `${HOT_START}s`,
    },
  },
  thresholds: { search_unexpected_responses: ['count==0'] },
};

function must(res, what) {
  if (res.status !== 200) throw new Error(`setup: ${what}: status ${res.status}: ${String(res.body).slice(0, 300)}`);
  return res;
}

const stamp = () => new Date().toISOString();
const phase = (name) => console.log(`W4 PHASE ${name} ${stamp()}`);
const step = (name) => console.log(`W4 STEP ${name} ${stamp()}`);

// Texts of a typical post (30 to 140 characters, mean about 90): the response sizes depend on them.
const WORDS = ['match', 'today', 'launch', 'coffee', 'monsoon', 'startup', 'traffic', 'cricket', 'weekend', 'music', 'review', 'travel', 'recipe', 'update', 'team'];
function sentence(i) {
  const n = 6 + (i % 10);
  const out = [];
  for (let k = 0; k < n; k++) out.push(WORDS[(i * 7 + k * 3) % WORDS.length]);
  return out.join(' ');
}

let seq = 0;
function createPost(user, run, text, check200) {
  seq++;
  const res = rpcCall(POSTS, 'CreatePost', { idempotencyKey: `w4-${run}-${exec.vu.idInTest}-${seq}-0123456789`, text }, user.idToken, 'CreatePost');
  if (res.status === 429) return null;
  return check200 ? must(res, 'CreatePost').json('post.post.postId') : res.json('post.post.postId');
}

// markMedia gives posts/{id} one image (the `media` array SearchPosts MEDIA filters on, len(media) > 0) and hasMedia = true through the
// Firestore emulator's REST API; the upload path (and Cloud Vision) is not run. The URLs have the length of the real GCS public URLs.
function markMedia(postId, i) {
  const url = `https://storage.googleapis.com/dzeroth-prod-media/media/u/${postId}/${i}/full.webp`;
  const str = (v) => ({ stringValue: v });
  const image = { mapValue: { fields: {
    mediaId: str(`m${postId}${i}`), url: str(url), thumbUrl: str(url.replace('full', 'thumb')),
    width: { integerValue: '1080' }, height: { integerValue: '720' }, blurhash: str('LEHV6nWB2yk8pyo0adR*.7kCMdnj'),
  } } };
  must(
    http.patch(
      `http://${FS_HOST}/v1/projects/${PROJECT}/databases/(default)/documents/posts/${postId}?updateMask.fieldPaths=hasMedia&updateMask.fieldPaths=media`,
      JSON.stringify({ fields: { hasMedia: { booleanValue: true }, media: { arrayValue: { values: [image] } } } }),
      { headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' } },
    ),
    'mark media',
  );
}

// ---------------------------------------------------------------------------------------------------------------------
export function setup() {
  const run = Math.floor(Date.now() / 1000).toString(36);
  const users = mintUsers(NUM_USERS, 'sea');
  const authors = users.slice(0, AUTHORS);
  const handlePrefix = `sea${run}_`; // mintUsers: handle = first 3 chars of the prefix + run + _ + index
  const coldTags = [];
  let created = 0;
  let a = 0;
  const post = (text) => {
    const u = authors[a++ % authors.length];
    created++;
    return createPost(u, run, text, true);
  };
  for (let t = 0; t < COLD_TAGS; t++) {
    const tag = `w4c${run}x${t}`;
    coldTags.push(tag);
    for (let p = 0; p < (t === 3 ? LONG_TAG_POSTS : TAG_POSTS); p++) {
      const id = post(`${sentence(created)} #${tag}`);
      if (p % 3 === 0) markMedia(id, p);
    }
  }
  const hotTag = `w4hot${run}`;
  for (let p = 0; p < TAG_POSTS; p++) post(`${sentence(created)} #${hotTag}`);
  while (created < REFRESH_POSTS) {
    const k = created % TREND_TAGS;
    const k2 = (created * 5 + 3) % TREND_TAGS;
    // Tag popularity falls with k (more posts on low k), a second tag on one post in three.
    const kk = Math.floor((k * k) / TREND_TAGS);
    const extra = created % 3 === 0 ? ` #w4t${run}n${k2}` : '';
    post(`${sentence(created)} #w4t${run}n${kk}${extra}`);
  }
  console.log(`W4 SETUP users=${users.length} authors=${authors.length} posts=${created} run=${run}`);
  sleep(COLD_SETTLE);
  return { run, users, handlePrefix, coldTags, hotTag, nUsers: users.length };
}

const viewerOf = (data, i) => data.users[AUTHORS + (i % (data.users.length - AUTHORS))];

function call(method, body, user, tag) {
  const res = rpcCall(SEARCH, method, body, user.idToken, tag);
  if (res.status !== 200) {
    unexpected.add(1);
    console.error(`${method} (${tag}) status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
  return res;
}
// expectReject is a call that must fail with the given status (VALIDATION is 400).
function expectReject(method, body, user, tag, status) {
  const res = rpcCall(SEARCH, method, body, user.idToken, tag);
  if (res.status !== status) {
    unexpected.add(1);
    console.error(`${method} (${tag}) wanted ${status}, got ${res.status}`);
  }
}

const people = (q, limit) => ({ query: q, limit });
const tabName = { top: 'SEARCH_TAB_TOP', latest: 'SEARCH_TAB_LATEST', media: 'SEARCH_TAB_MEDIA' };
const postsReq = (q, tab, pageSize, pageToken) => Object.assign({ query: q, tab: tabName[tab], pageSize }, pageToken ? { pageToken } : {});

// ---------------------------------------------------------------------------------------------------------------------
export function coldCalls(data) {
  phase('cold_calls');
  const v = (i) => viewerOf(data, i);
  const PFX = data.handlePrefix;
  const SPARSE = `${PFX}${data.nUsers - 1}`; // a full handle: exactly one account
  const EMPTY = `zz${data.run}`;
  const P = (name, user, req) => {
    step(name);
    return call('SearchPeople', req, user, name);
  };
  P('people5_cold', v(0), people(PFX, 5));
  P('people5_warm_same_viewer', v(0), people(PFX, 5));
  P('people5_entry_warm_new_viewer', v(1), people(PFX, 5));
  P('people20_cold', v(2), people(PFX, 20));
  P('people20_warm_same_viewer', v(2), people(PFX, 20));
  P('people20_entry_warm_new_viewer', v(3), people(PFX, 20));
  P('people_sparse_cold', v(4), people(SPARSE, 20));
  P('people_sparse_entry_warm_new_viewer', v(5), people(SPARSE, 20));
  P('people_empty_prefix_cold', v(6), people(EMPTY, 20));
  step('reject_people_too_short_cold_viewer');
  expectReject('SearchPeople', people('a', 5), v(7), 'too_short', 400);
  step('reject_people_too_short_warm_viewer');
  expectReject('SearchPeople', people('a', 5), v(7), 'too_short', 400);
  P('unsupported_people_cold_viewer', v(8), people('hello world', 5));
  P('unsupported_people_warm_viewer', v(8), people('#tag', 5));

  const T = data.coldTags;
  const S = (name, user, req) => {
    step(name);
    return call('SearchPosts', req, user, name);
  };
  S('posts_top_cold', v(9), postsReq(`#${T[0]}`, 'top', 20));
  S('posts_latest_entry_warm_same_viewer', v(9), postsReq(`#${T[0]}`, 'latest', 20));
  S('posts_media_entry_warm_same_viewer', v(9), postsReq(`#${T[0]}`, 'media', 20));
  S('posts_top_entry_warm_new_viewer', v(10), postsReq(`#${T[0]}`, 'top', 20));
  S('posts_top_all_warm_repeat', v(10), postsReq(`#${T[0]}`, 'top', 20));
  S('posts_latest_page50_cold', v(11), postsReq(`#${T[1]}`, 'latest', 50));
  S('posts_latest_page50_warm', v(11), postsReq(`#${T[1]}`, 'latest', 50));
  const r1 = S('posts_latest_page20_first_cold', v(12), postsReq(`#${T[2]}`, 'latest', 20));
  const tok1 = r1.json('nextPageToken');
  if (tok1) S('posts_latest_older_page20', v(12), postsReq(`#${T[2]}`, 'latest', 20, tok1));
  const r2 = S('posts_media_page1_cold', v(13), postsReq(`#${T[3]}`, 'media', 20));
  const tok2 = r2.json('nextPageToken');
  if (tok2) S('posts_media_older_scan', v(13), postsReq(`#${T[3]}`, 'media', 20, tok2));
  step('unsupported_posts_cold_viewer');
  call('SearchPosts', postsReq('@someone', 'top', 20), v(14), 'unsupported_at');
  step('unsupported_posts_digits');
  call('SearchPosts', postsReq('#123', 'top', 20), v(14), 'unsupported_digits');
  step('reject_posts_too_long');
  expectReject('SearchPosts', postsReq(`#${'a'.repeat(60)}`, 'top', 20), v(14), 'too_long', 400);
  step('end');
}

// ---------------------------------------------------------------------------------------------------------------------
function internal(path) {
  return http.post(`${API_URL}${path}`, '', { headers: { 'Content-Type': 'application/json' }, tags: { rpc: path }, responseCallback: http.expectedStatuses(200, 204, 500) });
}

export function refreshRuns(data) {
  phase('refresh');
  const authors = data.users.slice(0, AUTHORS);
  for (let i = 1; i <= 3; i++) {
    step(`refresh_run_${i}`);
    const r = internal('/internal/cron/trends-refresh');
    check(r, { 'refresh 204': (x) => x.status === 204 });
  }
  step('refresh_immediate_repeat_fresh');
  internal('/internal/cron/trends-refresh');
  step('daily_maintenance_fresh');
  internal('/internal/cron/daily-maintenance');
  sleep(31);
  step('daily_maintenance_after_interval_nothing_new');
  internal('/internal/cron/daily-maintenance');
  for (let i = 0; i < NEW_POSTS; i++) createPost(authors[i % authors.length], data.run, `${sentence(i + 5000)} #w4n${data.run}x${i % 12}`, false);
  sleep(31);
  step('refresh_after_new_posts');
  internal('/internal/cron/trends-refresh');
  step('end');
}

// ---------------------------------------------------------------------------------------------------------------------
export function trendsCalls(data) {
  phase('trends');
  const v = (i) => viewerOf(data, 20 + i);
  step('trends_cold_instance_cold_viewer');
  call('GetTrends', { limit: 10 }, v(0), 'trends_cold');
  step('trends_warm_same_viewer');
  call('GetTrends', { limit: 10 }, v(0), 'trends_warm');
  step('trends_new_viewer');
  call('GetTrends', { limit: 30 }, v(1), 'trends_new_viewer');
  step('trends_prefix');
  call('GetTrends', { limit: 10, prefix: `w4n${data.run}x1` }, v(1), 'trends_prefix');
  step('end');
}

export function trendsHerd(data) {
  if (exec.scenario.iterationInTest === 0) phase('trends_herd');
  const u = viewerOf(data, exec.scenario.iterationInTest);
  call('GetTrends', { limit: 10 }, u, 'trends_herd');
}

// ---------------------------------------------------------------------------------------------------------------------
const ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789_';
export function typeahead(data) {
  const i = exec.scenario.iterationInTest;
  if (i === 0) phase('typeahead_burst');
  const u = viewerOf(data, i);
  let q;
  if (i % 2 === 1) {
    const handle = `${data.handlePrefix}7`;
    q = handle.slice(0, 2 + (Math.floor(i / 2) % 6)); // 2 to 7 characters
  } else {
    q = ALPHABET[Math.floor(Math.random() * ALPHABET.length)] + ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  }
  call('SearchPeople', people(q, 5), u, 'typeahead');
}

// ---------------------------------------------------------------------------------------------------------------------
export function hotPost(data) {
  const i = exec.scenario.iterationInTest;
  if (i === 0) phase('hot_tag');
  const u = data.users[i % AUTHORS];
  createPost(u, data.run, `${sentence(i + 9000)} #${data.hotTag}`, false);
}

export function hotSearch(data) {
  const i = exec.scenario.iterationInTest;
  const u = viewerOf(data, i);
  call('SearchPosts', postsReq(`#${data.hotTag}`, i % 2 ? 'latest' : 'top', 20), u, 'hot_search');
}
