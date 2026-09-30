// graph_lists: ListFollowers pages + GetRelationships (T18, docs/plans/graph.md; ADR-0008).
//
// Budget under test (ADR-0008 A2 table): ListFollowers page 20 = ~30 planning reads (102 cold / 50 warm at page
// 50); GetRelationships = 1 cold / 0 warm / 0.5 planning. Acceptance: ListFollowers 20 rps for 2 min, p95 < 400 ms,
// mean fs_reads per call <= 30, 0 ERROR log lines. GetRelationships runs alongside at GR_RATE (default 5 rps) so
// its reads land in the same log; it has its own p95 threshold (same 400 ms Stage 0 target) but is not the
// acceptance driver.
//
// Data: NUM_USERS (default 100) callers, of which the first NUM_TARGETS (default 5) are "targets". Setup makes
// every other user follow every target, so each target has NUM_USERS-1 followers (more than one page of 20).
// 100 callers keep each below the per-user list limiter (20/min) and LIST_CALLS_PER_DAY (100) at 20 rps x 2 min
// (~24 calls each, ~12/min). Only the per-IP limiters are raised for the run; see README.
//
//   k6 run loadtest/graph_lists.js      # or: make loadtest SCENARIO=graph_lists
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, graphCall } from './graph_common.js';

const NUM_USERS = parseInt(__ENV.NUM_USERS || '100', 10);
const NUM_TARGETS = parseInt(__ENV.NUM_TARGETS || '5', 10);
const PAGE_SIZE = parseInt(__ENV.PAGE_SIZE || '20', 10);
const unexpected = new Counter('graph_unexpected_responses');

export const options = {
  setupTimeout: '600s',
  scenarios: {
    list_followers: {
      executor: 'constant-arrival-rate',
      exec: 'listFollowers',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '2m',
      preAllocatedVUs: Number(__ENV.VUS || 30),
      maxVUs: Number(__ENV.MAX_VUS || 100),
    },
    get_relationships: {
      executor: 'constant-arrival-rate',
      exec: 'getRelationships',
      rate: Number(__ENV.GR_RATE || 5),
      timeUnit: '1s',
      duration: __ENV.DURATION || '2m',
      preAllocatedVUs: 10,
      maxVUs: 40,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{rpc:ListFollowers}': ['p(95)<400'],
    'http_req_duration{rpc:GetRelationships}': ['p(95)<400'],
    graph_unexpected_responses: ['count==0'],
  },
};

export function setup() {
  const users = mintUsers(NUM_USERS, 'ltlist');
  for (let f = 0; f < users.length; f++) {
    for (let t = 0; t < NUM_TARGETS; t++) {
      if (f === t) continue;
      const res = graphCall(
        'Follow',
        { idempotencyKey: `ltl-seed-${f}-${t}-0123456789`, userId: users[t].uid },
        users[f].idToken,
        'SeedFollow',
      );
      if (res.status !== 200) {
        throw new Error(`setup: seed Follow ${f}->${t}: status ${res.status}: ${res.body}`);
      }
    }
  }
  return { users };
}

export function listFollowers(data) {
  const i = exec.scenario.iterationInTest;
  const caller = data.users[i % data.users.length];
  const target = data.users[Math.floor(i / data.users.length + i) % NUM_TARGETS];
  const res = graphCall('ListFollowers', { userId: target.uid, pageSize: PAGE_SIZE }, caller.idToken);
  const ok = check(res, {
    'ListFollowers 200': (r) => r.status === 200,
    'page is full': (r) => {
      try {
        return r.json('users').length === PAGE_SIZE;
      } catch (e) {
        return false;
      }
    },
  });
  if (!ok) {
    unexpected.add(1);
    console.error(`ListFollowers status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
}

export function getRelationships(data) {
  const i = exec.scenario.iterationInTest;
  const caller = data.users[(i * 7) % data.users.length];
  const ids = [];
  for (let k = 0; k < 20; k++) ids.push(data.users[(i + k * 3) % data.users.length].uid);
  const res = graphCall('GetRelationships', { userIds: ids }, caller.idToken);
  const ok = check(res, { 'GetRelationships 200': (r) => r.status === 200 });
  if (!ok) {
    unexpected.add(1);
    console.error(`GetRelationships status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
}
