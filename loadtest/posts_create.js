// posts_create: CreatePost at 20 rps for 2 min (T22, docs/plans/posts-and-timeline.md; ADR-0010).
//
// Budget under test (posts.proto CreatePost): reads 14 cold / 2 warm / 2.5 planning, writes 4 (idempotency, post,
// users.postsCount, quotas). Acceptance: CreatePost p95 < 500 ms (emulator, note the machine), mean fs_reads per
// call <= 2.5, 0 ERROR log lines. fs_reads/fs_writes come from the API log, not k6:
//   node loadtest/analyze_logs.js api.log CreatePost
//
// Limits respected (defaults): 10 CreatePost/min/uid and the NEW-account quota of 20 posts/day/uid (users minted
// here are new). 20 rps x 2 min = 2,400 posts need >= 120 users at 20 posts each, so NUM_USERS defaults to 150:
// 16 posts per user, ~8/min each (round-robin, evenly spaced). Raise RATE/DURATION only together with NUM_USERS
// (NUM_USERS >= RATE*seconds/19 and NUM_USERS >= RATE*6.5). Every idempotency key is unique (run id + iteration),
// so every call is a real create, never a replay. Only the per-IP limiters need raising for the run (all VUs share
// 127.0.0.1) and FEATURE_POSTS=on; see README.
//
//   k6 run loadtest/posts_create.js      # or: make loadtest SCENARIO=posts_create
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall } from './graph_common.js';

const NUM_USERS = parseInt(__ENV.NUM_USERS || '150', 10);
const unexpected = new Counter('posts_unexpected_responses');

export const options = {
  setupTimeout: '300s',
  scenarios: {
    create: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '2m',
      preAllocatedVUs: Number(__ENV.VUS || 30),
      maxVUs: Number(__ENV.MAX_VUS || 100),
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{rpc:CreatePost}': ['p(95)<500'],
    posts_unexpected_responses: ['count==0'],
  },
};

export function setup() {
  // Unique per run: idempotency keys persist in the emulator across k6 runs.
  return { users: mintUsers(NUM_USERS, 'ltpost'), run: Math.floor(Date.now() / 1000).toString(36) };
}

export default function (data) {
  const i = exec.scenario.iterationInTest;
  const caller = data.users[i % data.users.length];
  const res = rpcCall(
    'dzeroth.posts.v1.PostService',
    'CreatePost',
    { idempotencyKey: `ltp-${data.run}-${i}-0123456789`, text: `load test post ${i} ${data.run}` },
    caller.idToken,
  );
  const ok = check(res, { 'CreatePost 200': (r) => r.status === 200 });
  if (!ok) {
    unexpected.add(1);
    console.error(`CreatePost i=${i} status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
}
