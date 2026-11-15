// location_nearby: ListNearbyBeacons reads with paging (docs/plans/location-p1-p2-design-2026-11-15.md, PR 7).
//
// Acceptance: ListNearbyBeacons at limit PAGE_SIZE (default 20) at RATE iterations/s (default 5) for DURATION
// (default 2 min), p95 < 400 ms, 0 unexpected responses. One iteration is a first page in AREA scope on the caller's
// stored area (no area_id: the 1-read stored-area path) and then a CITY-scope walk of up to PAGES pages (default 3)
// that follows next_page_token. Indicative only: the emulators, not Firestore.
//
// Data: NUM_ORGANISERS (default 8) each create BEACONS_PER (default 5, the BEACONS_MAX_OPEN_PER_USER default) public
// plans an hour ahead, round-robin over four Ahmedabad areas (Vastrapur, Bodakdev, Satellite, Prahlad Nagar), so the
// city holds 40 plans: more than two pages of 20. NUM_USERS (default 40) callers each store one of the four areas
// with consent (SetArea) before the run. The seeding stays inside RATE_LIMIT_BEACONS_WRITE_PER_MIN (10) and
// BEACONS_CREATED_PER_DAY (10) at the defaults. Callers rotate, so each one makes about RATE * (1 + PAGES) / NUM_USERS
// * 60 reads a minute, under the shared beacons read limiter (RATE_LIMIT_BEACONS_READ_PER_MIN, 30, not raised);
// setup() refuses a shape that would not be.
//
// Reads per page: the design budget (section 4.4) is about 46 reads at limit 20 (query up to 20 docs, one count on the
// first page, participant states up to 20, directory and graph on a cache miss, quick-join up to 2). k6 cannot see
// Firestore reads and the request log does not carry a read count, so this scenario does not assert the budget; it is
// covered by the repo-level tests in internal/beacons. Server latency per page: node loadtest/analyze_logs.js api.log ListNearbyBeacons
//
// The API needs FEATURE_BEACONS=on and FEATURE_LOCATION=on (both for every caller) and, because every caller shares
// 127.0.0.1, RATE_LIMIT_PER_IP_PER_MIN and RATE_LIMIT_PRE_AUTH_IP_PER_MIN raised (e.g. 100000); nothing else is raised.
// Optional: BEACONS_SEEDED_AREAS to use other catalogue ids (comma separated).
//
//   k6 run loadtest/location_nearby.js      # or: make loadtest SCENARIO=location_nearby
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall } from './graph_common.js';

const NUM_USERS = parseInt(__ENV.NUM_USERS || '40', 10);
const NUM_ORGANISERS = parseInt(__ENV.NUM_ORGANISERS || '8', 10);
const BEACONS_PER = parseInt(__ENV.BEACONS_PER || '5', 10);
const PAGE_SIZE = parseInt(__ENV.PAGE_SIZE || '20', 10);
const PAGES = parseInt(__ENV.PAGES || '3', 10);
const RATE = Number(__ENV.RATE || 5);
const DURATION = __ENV.DURATION || '2m';
const READ_LIMIT_PER_MIN = 30; // RATE_LIMIT_BEACONS_READ_PER_MIN default, not raised for the run
const AREAS = (__ENV.BEACONS_SEEDED_AREAS || 'in.amd.vastrapur,in.amd.bodakdev,in.amd.satellite,in.amd.prahlad-nagar').split(',');
const unexpected = new Counter('location_unexpected_responses');

export const options = {
  setupTimeout: '600s',
  scenarios: {
    nearby: {
      executor: 'constant-arrival-rate',
      exec: 'nearby',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Number(__ENV.VUS || 20),
      maxVUs: Number(__ENV.MAX_VUS || 60),
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{rpc:ListNearbyBeacons}': ['p(95)<400'],
    location_unexpected_responses: ['count==0'],
  },
};

function beaconsCall(method, body, idToken, rpcTag) {
  return rpcCall('dzeroth.beacons.v1.BeaconService', method, body, idToken, rpcTag);
}

function locationCall(method, body, idToken, rpcTag) {
  return rpcCall('dzeroth.location.v1.LocationService', method, body, idToken, rpcTag);
}

export function setup() {
  const callsPerIteration = 1 + PAGES;
  const perUserPerMin = (RATE * callsPerIteration * 60) / NUM_USERS;
  if (perUserPerMin > READ_LIMIT_PER_MIN) {
    throw new Error(
      `setup: ${RATE * callsPerIteration} reads/s over ${NUM_USERS} users is ${perUserPerMin.toFixed(1)}/min per user, above the ${READ_LIMIT_PER_MIN}/min beacons read limiter; raise NUM_USERS or lower RATE/PAGES`,
    );
  }
  if (NUM_ORGANISERS > NUM_USERS) throw new Error('setup: NUM_ORGANISERS must be <= NUM_USERS');
  if (BEACONS_PER > 5) throw new Error('setup: BEACONS_PER above 5 passes BEACONS_MAX_OPEN_PER_USER (5)');
  const users = mintUsers(NUM_USERS, 'ltloc');

  // Every caller stores an area, spread over the seeded ones, with consent at the current copy version.
  const settings = locationCall('GetLocationSettings', {}, users[0].idToken, 'SeedGetLocationSettings');
  if (settings.status !== 200) {
    throw new Error(`setup: GetLocationSettings: status ${settings.status}: ${settings.body} (is FEATURE_LOCATION=on?)`);
  }
  const copyVersion = settings.json('settings.currentCopyVersion');
  const run = Date.now();
  for (let i = 0; i < users.length; i++) {
    const res = locationCall(
      'SetArea',
      { idempotencyKey: `ltl-set-${i}-${run}`, areaId: AREAS[i % AREAS.length], consent: { copyVersion, adultConfirmed: true } },
      users[i].idToken,
      'SeedSetArea',
    );
    if (res.status !== 200) throw new Error(`setup: SetArea ${i}: status ${res.status}: ${res.body}`);
  }

  const startAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  let n = 0;
  for (let o = 0; o < NUM_ORGANISERS; o++) {
    for (let b = 0; b < BEACONS_PER; b++, n++) {
      const res = beaconsCall(
        'CreateBeacon',
        {
          idempotencyKey: `ltl-seed-${o}-${b}-${run}`,
          public: true,
          activity: 'BEACON_ACTIVITY_COFFEE',
          title: `Load nearby ${o}-${b}`,
          venue: 'Food court',
          startAt,
          durationMinutes: 30,
          openSpots: 3,
          cost: 'BEACON_COST_FREE',
          chatPreference: 'CHAT_PREFERENCE_QUIET',
          areaId: AREAS[n % AREAS.length],
        },
        users[o].idToken,
        'SeedCreateBeacon',
      );
      if (res.status !== 200) throw new Error(`setup: seed CreateBeacon ${o}-${b}: status ${res.status}: ${res.body}`);
    }
  }
  return { users, plans: NUM_ORGANISERS * BEACONS_PER };
}

function nearbyOK(res, name) {
  const ok = check(res, {
    [`${name} 200`]: (r) => r.status === 200,
    [`${name} has items`]: (r) => {
      try {
        return r.json('items').length > 0;
      } catch (e) {
        return false;
      }
    },
  });
  if (!ok) {
    unexpected.add(1);
    console.error(`ListNearbyBeacons ${name} status=${res.status} body=${String(res.body).slice(0, 200)}`);
  }
  return ok;
}

export function nearby(data) {
  const i = exec.scenario.iterationInTest;
  const caller = data.users[i % data.users.length];

  // First page in AREA scope on the stored area.
  nearbyOK(beaconsCall('ListNearbyBeacons', { scope: 'NEARBY_SCOPE_AREA', limit: PAGE_SIZE }, caller.idToken), 'area');

  // CITY walk: follow next_page_token for up to PAGES pages.
  let token = '';
  for (let p = 0; p < PAGES; p++) {
    const res = beaconsCall('ListNearbyBeacons', { scope: 'NEARBY_SCOPE_CITY', limit: PAGE_SIZE, pageToken: token }, caller.idToken);
    if (!nearbyOK(res, `city page ${p + 1}`)) return;
    try {
      token = res.json('nextPageToken') || '';
    } catch (e) {
      token = '';
    }
    if (!token) break;
  }
}
