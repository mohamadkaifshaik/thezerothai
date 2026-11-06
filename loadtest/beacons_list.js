// beacons_list: the public Plans list (ListBeacons) with GetBeacon alongside (docs/beacons-plan.md PR 8).
//
// Acceptance: ListBeacons (public, limit 20) at RATE (default 10 rps) for DURATION (default 2 min), p95 < 400 ms,
// 0 unexpected responses. GetBeacon runs alongside at GET_RATE (default 3 rps) with the same p95 threshold but is not
// the acceptance driver. Indicative only: the emulators, not Firestore.
//
// Data: NUM_USERS (default 40) callers; the first NUM_ORGANISERS (default 5) each create BEACONS_PER (default 4)
// public plans an hour ahead (20 plans: one full page of 20). Every caller lists in turn, so at 10 rps x 2 min each
// of the 40 callers makes 30 list calls (15/min) plus about 9 gets, under the per-user read limiter
// (RATE_LIMIT_BEACONS_READ_PER_MIN, 30) and the general one (RATE_LIMIT_PER_USER_PER_MIN, 60); setup() refuses a
// shape that would not be. Each organiser creates BEACONS_PER plans in a burst, inside RATE_LIMIT_BEACONS_WRITE_PER_MIN
// (10) and BEACONS_CREATED_PER_DAY (10) at the default BEACONS_PER.
//
// The API needs FEATURE_BEACONS=on and, because every caller shares 127.0.0.1, RATE_LIMIT_PER_IP_PER_MIN and
// RATE_LIMIT_PRE_AUTH_IP_PER_MIN raised (e.g. 100000); nothing else is raised.
//
//   k6 run loadtest/beacons_list.js      # or: make loadtest SCENARIO=beacons_list
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall } from './graph_common.js';

const NUM_USERS = parseInt(__ENV.NUM_USERS || '40', 10);
const NUM_ORGANISERS = parseInt(__ENV.NUM_ORGANISERS || '5', 10);
const BEACONS_PER = parseInt(__ENV.BEACONS_PER || '4', 10);
const PAGE_SIZE = parseInt(__ENV.PAGE_SIZE || '20', 10);
const RATE = Number(__ENV.RATE || 10);
const GET_RATE = Number(__ENV.GET_RATE || 3);
const DURATION = __ENV.DURATION || '2m';
const READ_LIMIT_PER_MIN = 30; // RATE_LIMIT_BEACONS_READ_PER_MIN default, not raised for the run
const unexpected = new Counter('beacons_unexpected_responses');

export const options = {
  setupTimeout: '600s',
  scenarios: {
    list_public: {
      executor: 'constant-arrival-rate',
      exec: 'listPublic',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Number(__ENV.VUS || 20),
      maxVUs: Number(__ENV.MAX_VUS || 60),
    },
    get_beacon: {
      executor: 'constant-arrival-rate',
      exec: 'getBeacon',
      rate: GET_RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 5,
      maxVUs: 20,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{rpc:ListBeacons}': ['p(95)<400'],
    'http_req_duration{rpc:GetBeacon}': ['p(95)<400'],
    beacons_unexpected_responses: ['count==0'],
  },
};

function beaconsCall(method, body, idToken, rpcTag) {
  return rpcCall('dzeroth.beacons.v1.BeaconService', method, body, idToken, rpcTag);
}

// durationSeconds parses a k6 duration like "30s", "2m" or "1h" (one unit, as this scenario is run).
function durationSeconds(d) {
  const m = /^(\d+(?:\.\d+)?)(s|m|h)$/.exec(d);
  if (!m) throw new Error(`DURATION ${d}: use <n>s, <n>m or <n>h`);
  return Number(m[1]) * { s: 1, m: 60, h: 3600 }[m[2]];
}

export function setup() {
  // Review Focus 5: the per-user read limiter is not raised for the run, so the callers must absorb the rate.
  const perUserPerMin = ((RATE + GET_RATE) * 60) / NUM_USERS;
  if (perUserPerMin > READ_LIMIT_PER_MIN) {
    throw new Error(
      `setup: ${RATE + GET_RATE} reads/s over ${NUM_USERS} users is ${perUserPerMin.toFixed(1)}/min per user, above the ${READ_LIMIT_PER_MIN}/min beacons read limiter; raise NUM_USERS or lower RATE`,
    );
  }
  if (NUM_ORGANISERS > NUM_USERS) throw new Error('setup: NUM_ORGANISERS must be <= NUM_USERS');
  const seconds = durationSeconds(DURATION);
  const users = mintUsers(NUM_USERS, 'ltbcn');
  const startAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  const beaconIds = [];
  for (let o = 0; o < NUM_ORGANISERS; o++) {
    for (let b = 0; b < BEACONS_PER; b++) {
      const res = beaconsCall(
        'CreateBeacon',
        {
          idempotencyKey: `ltb-seed-${o}-${b}-${Date.now()}`,
          public: true,
          activity: 'BEACON_ACTIVITY_COFFEE',
          title: `Load coffee ${o}-${b}`,
          venue: 'Food court',
          startAt,
          durationMinutes: 30,
          openSpots: 3,
          cost: 'BEACON_COST_FREE',
          chatPreference: 'CHAT_PREFERENCE_QUIET',
        },
        users[o].idToken,
        'SeedCreateBeacon',
      );
      if (res.status !== 200) {
        throw new Error(`setup: seed CreateBeacon ${o}-${b}: status ${res.status}: ${res.body}`);
      }
      beaconIds.push(res.json('view.beacon.beaconId'));
    }
  }
  return { users, beaconIds, seconds };
}

export function listPublic(data) {
  const i = exec.scenario.iterationInTest;
  const caller = data.users[i % data.users.length];
  const res = beaconsCall('ListBeacons', { public: true, limit: PAGE_SIZE }, caller.idToken);
  const ok = check(res, {
    'ListBeacons 200': (r) => r.status === 200,
    'page is full': (r) => {
      try {
        return r.json('views').length === Math.min(PAGE_SIZE, data.beaconIds.length);
      } catch (e) {
        return false;
      }
    },
  });
  if (!ok) {
    unexpected.add(1);
    console.error(`ListBeacons status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
}

export function getBeacon(data) {
  const i = exec.scenario.iterationInTest;
  // Offset the caller so the same user is not also the one listing at this instant.
  const caller = data.users[(i * 7 + 3) % data.users.length];
  const id = data.beaconIds[i % data.beaconIds.length];
  const res = beaconsCall('GetBeacon', { beaconId: id }, caller.idToken);
  const ok = check(res, {
    'GetBeacon 200': (r) => r.status === 200,
    'is the plan': (r) => {
      try {
        return r.json('view.beacon.beaconId') === id;
      } catch (e) {
        return false;
      }
    },
  });
  if (!ok) {
    unexpected.add(1);
    console.error(`GetBeacon status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
}
