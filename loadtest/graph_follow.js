// graph_follow: Follow/Unfollow churn across NUM_USERS (default 50) users (T18, docs/plans/graph.md; ADR-0008).
//
// Budget under test (ADR-0008 A2 table): Follow created = reads 4 cold / 2 warm / 3 planning, writes 5;
// Unfollow = 0 reads, 3 writes, 1 delete. Acceptance: 20 rps for 2 min, Follow p95 < 500 ms, mean fs_reads per
// Follow <= 3 (planning/typical), 0 ERROR log lines (read fs_reads/ERROR from the API log, see README).
//
// Churn design: iteration i (global, ordered) picks user u = i % N and round r = floor(i / N). Even rounds Follow,
// odd rounds Unfollow the SAME target, so half of all calls are Follow and every Follow is a real create (never a
// replay) and every Unfollow removes a real edge. Consecutive rounds of one user are N/RATE = 2.5 s apart at the
// defaults, so no two calls for one user race. Each user makes RATE*DURATION/N = 48 calls (24 Follow, 24
// Unfollow), inside every per-user cap at defaults (30/min follow limiter, 50 new-account follows/day, 500
// graph mutations/day). Only the per-IP limiters are raised for the run (all VUs share 127.0.0.1); see README.
//
//   k6 run loadtest/graph_follow.js      # MODE=follow_only for the no-Unfollow variant; or: make loadtest SCENARIO=graph_follow
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, graphCall } from './graph_common.js';

const NUM_USERS = parseInt(__ENV.NUM_USERS || '50', 10);
// MODE=churn (default): alternate Follow/Unfollow of the same target. MODE=follow_only: every call is a Follow of a
// fresh target (no Unfollow in between), the shape closest to the ADR-0008 A2 "planning" assumption. It needs
// RATE*DURATION/NUM_USERS <= 49 follows per user (48 at the defaults; the new-account quota is 50/day).
const MODE = __ENV.MODE || 'churn';
const unexpected = new Counter('graph_unexpected_responses');

export const options = {
  setupTimeout: '300s',
  scenarios: {
    churn: {
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
    'http_req_duration{rpc:Follow}': ['p(95)<500'],
    graph_unexpected_responses: ['count==0'],
  },
};

export function setup() {
  return { users: mintUsers(NUM_USERS, 'ltfollow') };
}

export default function (data) {
  const n = data.users.length;
  const i = exec.scenario.iterationInTest;
  const u = i % n;
  const round = Math.floor(i / n);
  const pair = MODE === 'follow_only' ? round : Math.floor(round / 2);
  const targetIdx = (u + 1 + (pair % (n - 1))) % n;
  const isFollow = MODE === 'follow_only' || round % 2 === 0;
  const caller = data.users[u];
  const target = data.users[targetIdx];

  const method = isFollow ? 'Follow' : 'Unfollow';
  const res = graphCall(
    method,
    { idempotencyKey: `ltf-${i}-${caller.uid}-0123456789`.slice(0, 64), userId: target.uid },
    caller.idToken,
  );
  const ok = check(res, { [`${method} 200`]: (r) => r.status === 200 });
  if (!ok) {
    unexpected.add(1);
    console.error(`${method} u=${u} round=${round} status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
}
