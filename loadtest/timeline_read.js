// timeline_read: GetHomeTimeline (refresh with since_token, older page) + GetUserTimeline (T22,
// docs/plans/posts-and-timeline.md; ADR-0004/0010).
//
// Budget under test (timeline.proto): home refresh planning 4 + new posts (F=60), older page / cold open ~30
// (page 20); GetUserTimeline planning 11 (3 + 20 cold / 0 warm). Acceptance: home refresh p95 < 400 ms warm
// (emulator, note the machine), 0 ERROR lines. Reads per call are NOT a k6 metric: take mean fs_reads per rpc from
// the API log (also the since_clamped rate and interceptor cold share, see README):
//   node loadtest/analyze_logs.js api.log GetHomeTimeline GetUserTimeline
//
// Data (setup, outside the timed window): NUM_USERS (default 200) users; the first NUM_AUTHORS (60) are authors
// who each post POSTS_PER_AUTHOR (5) posts. User u follows F_u accounts, F spread linearly over MIN_F..MAX_F
// (default 10..45; the ticket's 10-300 needs QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY and QUOTA_FOLLOWS_PER_DAY raised on
// the API, plus RATE_LIMIT_GRAPH_FOLLOW_PER_MIN; setup retries on 429 either way). Each user then does one cold
// open, whose since_token and next_page_token seed the timed calls.
//
// k6 `rpc` tags are the scenario names (home_refresh, home_older, user_timeline, new_post); server-side rpc names
// in the log are the real method names.
//
// Timed (arrival-rate, all inside per-user limits: home 6/min/uid, user timeline 30/min/uid, post create 10/min):
//   home_refresh  REFRESH_RATE=14/s  GetHomeTimeline{since_token}; the token is advanced per VU when the VU has
//                                    seen the user, else the setup token is used
//   home_older    OLDER_RATE=2/s     GetHomeTimeline{page_token} (older page)
//   user_timeline USER_RATE=4/s      GetUserTimeline of an author, first page
//   new_posts     NEW_POST_RATE=1 per NEW_POST_EVERY=10 s  authors keep posting, so refreshes have new posts to read.
//                                    (the old default was 1 post/s; it was not the cause of the high refresh gap rate, see T22)
// Home totals 16 rps / 200 users = 4.8 calls/min/uid, plus gap fills, which can exceed the 6/min/uid home limit:
// raise RATE_LIMIT_TIMELINE_PER_MIN on the API too. FEATURE_POSTS=on.
//
//   k6 run loadtest/timeline_read.js      # or: make loadtest SCENARIO=timeline_read
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall, graphCall } from './graph_common.js';

const NUM_USERS = parseInt(__ENV.NUM_USERS || '200', 10);
const NUM_AUTHORS = parseInt(__ENV.NUM_AUTHORS || '60', 10);
const POSTS_PER_AUTHOR = parseInt(__ENV.POSTS_PER_AUTHOR || '5', 10);
const MIN_F = parseInt(__ENV.MIN_F || '10', 10);
const MAX_F = parseInt(__ENV.MAX_F || '45', 10);
const DURATION = __ENV.DURATION || '2m';
const POSTS = 'dzeroth.posts.v1.PostService';
const TIMELINE = 'dzeroth.timeline.v1.TimelineService';
const unexpected = new Counter('timeline_unexpected_responses');

// NEW_POST_EVERY_S stretches the background poster's time unit: k6 arrival rates are integers per time unit, so
// "1 post per 10 s" is rate 1 over a 10 s unit. Default 10 (a lighter write mix than 1 post/s).
const NEW_POST_EVERY_S = parseInt(__ENV.NEW_POST_EVERY || '10', 10);

function scenario(exec_, rate, vus, maxVus, timeUnit = '1s') {
  return {
    executor: 'constant-arrival-rate',
    exec: exec_,
    rate,
    timeUnit,
    duration: DURATION,
    preAllocatedVUs: vus,
    maxVUs: maxVus,
  };
}

export const options = {
  setupTimeout: '900s',
  scenarios: {
    home_refresh: scenario('homeRefresh', Number(__ENV.REFRESH_RATE || 14), 30, 100),
    home_older: scenario('homeOlder', Number(__ENV.OLDER_RATE || 2), 10, 40),
    user_timeline: scenario('userTimeline', Number(__ENV.USER_RATE || 4), 10, 40),
    new_posts: scenario('newPosts', Number(__ENV.NEW_POST_RATE || 1), 5, 20, `${NEW_POST_EVERY_S}s`),
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    // Ticket targets: home refresh p95 < 400 ms warm; user timeline held to the same Stage 0 target.
    'http_req_duration{rpc:home_refresh}': ['p(95)<400'],
    'http_req_duration{rpc:home_older}': ['p(95)<400'],
    'http_req_duration{rpc:user_timeline}': ['p(95)<400'],
    // CreatePost target p95 < 500 ms (the background poster; posts_create.js is the acceptance driver).
    'http_req_duration{rpc:new_post}': ['p(95)<500'],
    timeline_unexpected_responses: ['count==0'],
  },
};

// Setup-only: retry once the per-user limiter (HTTP 429) refills.
function retry(fn, what) {
  for (let attempt = 0; attempt < 40; attempt++) {
    const res = fn();
    if (res.status === 200) return res;
    if (res.status !== 429) throw new Error(`setup: ${what}: status ${res.status}: ${res.body}`);
    sleep(2);
  }
  throw new Error(`setup: ${what}: still rate limited`);
}

export function setup() {
  const users = mintUsers(NUM_USERS, 'lttl');
  const run = Math.floor(Date.now() / 1000).toString(36);
  const authors = Math.min(NUM_AUTHORS, users.length);
  for (let a = 0; a < authors; a++) {
    for (let p = 0; p < POSTS_PER_AUTHOR; p++) {
      retry(
        () =>
          rpcCall(POSTS, 'CreatePost', { idempotencyKey: `ltt-seed-${run}-${a}-${p}-0123456789`, text: `seed ${a} ${p} ${run}` }, users[a].idToken, 'SeedPost'),
        `seed post ${a}/${p}`,
      );
    }
  }
  const state = [];
  for (let u = 0; u < users.length; u++) {
    const f = MIN_F + Math.floor(((MAX_F - MIN_F) * u) / Math.max(1, users.length - 1));
    for (let j = 0; j < f; j++) {
      const target = users[(u + 1 + j) % users.length];
      retry(
        () => graphCall('Follow', { idempotencyKey: `ltt-f-${run}-${u}-${j}-0123456789`, userId: target.uid }, users[u].idToken, 'SeedFollow'),
        `seed follow ${u}->${j}`,
      );
    }
    const cold = retry(
      () => rpcCall(TIMELINE, 'GetHomeTimeline', { pageSize: 20 }, users[u].idToken, 'SeedColdOpen'),
      `cold open ${u}`,
    );
    state.push({ since: cold.json('sinceToken') || '', older: cold.json('nextPageToken') || '' });
  }
  return { users, state, authors, run };
}

const sinceByUser = {}; // per VU: newest since_token seen for a user

function expect(res, name, i) {
  const ok = check(res, { [`${name} 200`]: (r) => r.status === 200 });
  if (!ok) {
    unexpected.add(1);
    console.error(`${name} i=${i} status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
  return ok;
}

export function homeRefresh(data) {
  const i = exec.scenario.iterationInTest;
  const u = i % data.users.length;
  const since = sinceByUser[u] || data.state[u].since;
  const res = rpcCall(TIMELINE, 'GetHomeTimeline', { sinceToken: since }, data.users[u].idToken, 'home_refresh');
  if (expect(res, 'home_refresh', i)) {
    const next = res.json('sinceToken');
    if (next) sinceByUser[u] = next;
    // A real client fills a refresh gap with page_token = gap_page_token (timeline.proto); bounded so one VU
    // cannot loop. Gap fills are tagged home_gap so they do not count toward the refresh latency threshold.
    let gap = res.json('gapPageToken');
    for (let g = 0; gap && g < 5; g++) {
      const gres = rpcCall(TIMELINE, 'GetHomeTimeline', { pageToken: gap, pageSize: 20 }, data.users[u].idToken, 'home_gap');
      if (!expect(gres, 'home_gap', i)) break;
      gap = gres.json('nextPageToken');
    }
  }
}

export function homeOlder(data) {
  const i = exec.scenario.iterationInTest;
  const u = (i * 7 + 3) % data.users.length;
  const token = data.state[u].older;
  if (!token) return; // fewer posts than one page: nothing older to fetch
  const res = rpcCall(TIMELINE, 'GetHomeTimeline', { pageToken: token, pageSize: 20 }, data.users[u].idToken, 'home_older');
  expect(res, 'home_older', i);
}

export function userTimeline(data) {
  const i = exec.scenario.iterationInTest;
  const u = (i * 11 + 5) % data.users.length;
  const author = data.users[i % data.authors];
  const res = rpcCall(TIMELINE, 'GetUserTimeline', { userId: author.uid, pageSize: 20 }, data.users[u].idToken, 'user_timeline');
  expect(res, 'user_timeline', i);
}

export function newPosts(data) {
  const i = exec.scenario.iterationInTest;
  const a = i % data.authors;
  const res = rpcCall(
    POSTS,
    'CreatePost',
    { idempotencyKey: `ltt-new-${data.run}-${i}-0123456789`, text: `new ${i} ${data.run}` },
    data.users[a].idToken,
    'new_post',
  );
  expect(res, 'new_post', i);
}
