// engagement_bookmarks_list: ListBookmarks paging smoke (W2-15, docs/plans/ui-w2-engagement-composer-basics.md; ADR-0023).
//
// Budget under test (engagement.proto ListBookmarks, ADR-0023 "Cost impact"): a COLD first page is 43 reads at page
// 20 and 103 at page 50 (interceptor 1 + query page + GetMany page + caller graph 1 + userLikes 1); with the posts in
// the instance cache it is 1 + page (graph and userLikes cached 60 s). A list whose size is an exact multiple of the
// page size ends with one extra EMPTY page (1 read: the sealed token is issued whenever the query came back full).
// Reads are NOT a k6 metric: they come from the API log (`fs_reads`, `read_budget_spent`), see
// loadtest/analyze_bookmarks.js. Latency here is emulator latency, indicative only.
//
// MODE=latency (default)
//   Setup: PAIRS x 2 viewers (default 1 pair) and AUTHORS_PER_VIEWER authors per viewer (default 5), each author creating
//   POSTS_PER_AUTHOR posts (default 20); every viewer bookmarks its own authors' posts (disjoint sets, 100 bookmarks per
//   viewer); then setup sleeps SETTLE seconds (default 75 > CACHE_TTL 60 s) so every instance cache
//   entry the seeding created has expired. Run:
//     cold_pass  even viewers page at page_size 20, odd viewers at 50, a first pass (tag pass:cold) then an immediate second
//                pass (tag pass:warm, posts now cached);
//     warm_load  RATE passes/s (default 2) for DURATION (default 30s) round-robin over the viewers.
//
// MODE=budget
//   One viewer with 100 bookmarks pages at 50 over and over (sequentially) until the server answers RATE_LIMITED
//   limit=read_budget_daily (ADR-0010 D5; default READ_BUDGET_PER_UID_PER_DAY 2000), to show ListBookmarks is charged
//   to the per-uid daily read budget. Each call is logged by the API with `read_budget_spent`.
//
// API requirements (a local `go run ./cmd/api` against the emulators, nothing else; load-testing skill):
//   FEATURE_POSTS=on FEATURE_BOOKMARKS=on FEATURE_ENGAGEMENT=on
//   RATE_LIMIT_PER_IP_PER_MIN and RATE_LIMIT_PRE_AUTH_IP_PER_MIN raised (every VU shares 127.0.0.1)
//   seed only: RATE_LIMIT_POST_CREATE_PER_MIN, QUOTA_NEW_ACCOUNT_POSTS_PER_DAY, RATE_LIMIT_BOOKMARKS_PER_MIN,
//   QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY and QUOTA_BOOKMARKS_PER_DAY raised (new accounts: 20 posts/day, 50 bookmarks/day)
//   MODE=latency: RATE_LIMIT_BOOKMARKS_LIST_PER_MIN (default 10/min/uid) and READ_BUDGET_PER_UID_PER_DAY raised (the
//   load loops one viewer far past 2,000 reads); MODE=budget: only RATE_LIMIT_BOOKMARKS_LIST_PER_MIN raised.
// The exact values used for the recorded run are in docs/reviews/cost-model.md section 11.
//
//   k6 run loadtest/engagement_bookmarks_list.js      # or: make loadtest SCENARIO=engagement_bookmarks_list
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall } from './graph_common.js';

const MODE = __ENV.MODE || 'latency';
// Viewers come in PAIRS (even index lists at page_size 20, odd at 50); each viewer bookmarks the posts of its own
// AUTHORS_PER_VIEWER authors (default 5 x POSTS_PER_AUTHOR 20 = 100 bookmarks), so no viewer warms another's post cache.
const PAIRS = parseInt(__ENV.PAIRS || '1', 10);
const AUTHORS_PER_VIEWER = parseInt(__ENV.AUTHORS_PER_VIEWER || '5', 10);
const POSTS_PER_AUTHOR = parseInt(__ENV.POSTS_PER_AUTHOR || '20', 10);
const SETTLE = parseInt(__ENV.SETTLE || '75', 10);
const MAX_BUDGET_CALLS = parseInt(__ENV.MAX_BUDGET_CALLS || '120', 10);
const POSTS = 'dzeroth.posts.v1.PostService';
const ENG = 'dzeroth.engagement.v1.EngagementService';
const unexpected = new Counter('bookmarks_unexpected_responses');
const budgetRejected = new Counter('bookmarks_read_budget_rejections');

const durationThresholds = {};
for (const pass of ['cold', 'warm']) {
  for (const ps of ['20', '50']) {
    durationThresholds[`http_req_duration{rpc:ListBookmarks,pass:${pass},page_size:${ps}}`] = ['p(95)<400'];
  }
}

export const options =
  MODE === 'budget'
    ? {
        setupTimeout: '300s',
        scenarios: { budget: { executor: 'shared-iterations', exec: 'budgetLoop', vus: 1, iterations: 1, maxDuration: '5m' } },
        thresholds: { bookmarks_unexpected_responses: ['count==0'] },
      }
    : {
        setupTimeout: '300s',
        scenarios: {
          cold_pass: { executor: 'shared-iterations', exec: 'coldPass', vus: 2 * PAIRS, iterations: 2 * PAIRS, maxDuration: '2m' },
          warm_load: {
            executor: 'constant-arrival-rate',
            exec: 'warmLoad',
            startTime: '20s',
            rate: Number(__ENV.RATE || 2),
            timeUnit: '1s',
            duration: __ENV.DURATION || '30s',
            preAllocatedVUs: 10,
            maxVUs: 40,
          },
        },
        thresholds: Object.assign(
          { http_req_failed: ['rate<0.01'], bookmarks_unexpected_responses: ['count==0'] },
          durationThresholds,
        ),
      };

// seedViewer makes `viewer` bookmark every post id in `postIds`, oldest first (so the list shows the last id first).
function seedViewer(viewer, postIds, run, tag) {
  postIds.forEach((id, i) => {
    const res = rpcCall(ENG, 'AddBookmark', { idempotencyKey: `bm-${run}-${tag}-${i}-0123456789`, postId: id }, viewer.idToken);
    if (res.status !== 200) throw new Error(`setup: AddBookmark ${tag} ${i}: status ${res.status}: ${res.body}`);
  });
}

export function setup() {
  const run = Math.floor(Date.now() / 1000).toString(36);
  const viewerCount = MODE === 'budget' ? 1 : 2 * PAIRS;
  const authorCount = viewerCount * AUTHORS_PER_VIEWER;
  const users = mintUsers(authorCount + viewerCount, 'ltbm');
  const authors = users.slice(0, authorCount);
  const viewers = users.slice(authorCount);
  // Posts per author, in creation order.
  const byAuthor = authors.map((a, ai) => {
    const ids = [];
    for (let p = 0; p < POSTS_PER_AUTHOR; p++) {
      const res = rpcCall(
        POSTS,
        'CreatePost',
        { idempotencyKey: `bmp-${run}-${ai}-${p}-0123456789`, text: `bookmark load post ${ai}-${p} ${run}` },
        a.idToken,
      );
      if (res.status !== 200) throw new Error(`setup: CreatePost ${ai}/${p}: status ${res.status}: ${res.body}`);
      ids.push(res.json('post.post.postId'));
    }
    return ids;
  });
  viewers.forEach((v, vi) => {
    const mine = [].concat(...byAuthor.slice(vi * AUTHORS_PER_VIEWER, (vi + 1) * AUTHORS_PER_VIEWER));
    seedViewer(v, mine, run, `v${vi}`);
  });
  // Let every cache entry the seeding created (posts, profiles, graph, userLikes: CACHE_TTL 60 s) expire.
  sleep(SETTLE);
  return { viewers, total: AUTHORS_PER_VIEWER * POSTS_PER_AUTHOR };
}

// pass pages one viewer through the whole list and returns the number of rows seen.
function pass(viewer, pageSize, passTag, expectRows) {
  let token = '';
  let rows = 0;
  let calls = 0;
  for (;;) {
    const res = rpcCall(
      ENG,
      'ListBookmarks',
      { pageSize, pageToken: token },
      viewer.idToken,
      'ListBookmarks',
      { pass: passTag, page_size: String(pageSize) },
    );
    calls++;
    if (res.status !== 200) {
      unexpected.add(1);
      console.error(`ListBookmarks status=${res.status} body=${String(res.body).slice(0, 200)}`);
      return rows;
    }
    rows += (res.json('bookmarks') || []).length;
    token = res.json('nextPageToken') || '';
    if (!token) break;
    if (calls > 200) throw new Error('paging did not terminate');
  }
  const ok = check(rows, { 'every bookmark listed once': (n) => n === expectRows });
  if (!ok) {
    unexpected.add(1);
    console.error(`pass ${passTag} page_size=${pageSize}: rows=${rows} want ${expectRows}`);
  }
  return rows;
}

export function coldPass(data) {
  const i = exec.scenario.iterationInTest; // even viewer index => page_size 20, odd => 50
  const pageSize = i % 2 === 0 ? 20 : 50;
  pass(data.viewers[i], pageSize, 'cold', data.total);
  pass(data.viewers[i], pageSize, 'warm', data.total);
}

export function warmLoad(data) {
  const v = exec.scenario.iterationInTest % data.viewers.length;
  pass(data.viewers[v], v % 2 === 0 ? 20 : 50, 'warm', data.total);
}

// budgetLoop pages at 50 until the per-uid daily read budget rejects (or MAX_BUDGET_CALLS).
export function budgetLoop(data) {
  const viewer = data.viewers[0];
  for (let n = 1; n <= MAX_BUDGET_CALLS; n++) {
    const res = rpcCall(ENG, 'ListBookmarks', { pageSize: 50 }, viewer.idToken, 'ListBookmarks', { pass: n === 1 ? 'cold' : 'warm', page_size: '50' });
    if (res.status === 200) continue;
    let limit = '';
    try {
      limit = JSON.stringify(res.json('details') || res.json('metadata') || '');
    } catch (e) {
      limit = String(res.body).slice(0, 200);
    }
    console.log(`budget: call ${n} -> status ${res.status} code=${res.json('code')} body=${String(res.body).slice(0, 300)} ${limit}`);
    budgetRejected.add(1);
    return;
  }
  unexpected.add(1);
  console.error(`budget: no rejection in ${MAX_BUDGET_CALLS} calls`);
}
