// identity_getme: load test for IdentityService.GetMe (load-testing skill §1 "Local (default, $0)").
//
// GetMe is the highest-frequency identity call (cost-model.md: 4 calls/DAU/day, every app open/resume)
// and its budget is documented as 2 reads worst case / 1 typical (proto: identity.proto GetMe comment).
// This scenario drives a pool of already-signed-up users repeatedly calling GetMe against a warm instance
// cache, to check the "typical" (mostly cache-hit) path holds its latency and error-rate targets.
//
// Run against the emulators + a local API instance (`make loadtest` never touches Cloud Run/Firestore):
//   make emulators                                   # terminal 1 (or: firebase emulators:start ...)
//   PORT=8081 FIRESTORE_EMULATOR_HOST=localhost:8080 \
//     FIREBASE_AUTH_EMULATOR_HOST=localhost:9099 PUBSUB_EMULATOR_HOST=localhost:8085 \
//     FIREBASE_PROJECT_ID=demo-dzeroth-local \
//     go run ./backend/cmd/api                        # terminal 2 (PORT must not be 8080: the Firestore
//                                                       # emulator already owns that port)
//   make loadtest SCENARIO=identity_getme             # terminal 3
//
// See loadtest/README.md for prerequisites, environment variables and how to read the results.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const API_URL = __ENV.API_URL || 'http://localhost:8081';
const AUTH_EMULATOR_HOST = __ENV.AUTH_EMULATOR_HOST || 'localhost:9099';
const NUM_USERS = parseInt(__ENV.NUM_USERS || '20', 10);

const profileRequiredErrors = new Counter('profile_required_errors');

export const options = {
  scenarios: {
    // Matches the load-testing skill's example shape: fixed request rate, not fixed VU count, so the
    // result is directly comparable to the cost-model's "calls/DAU/day" figures.
    getme: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: Number(__ENV.VUS || 20),
      maxVUs: Number(__ENV.MAX_VUS || 50),
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    // Emulator latency is indicative only (load-testing skill §1); this mirrors the Stage 0 pass
    // criterion (warm p95 < 400ms) so a regression is still visible locally before it reaches dev.
    http_req_duration: ['p(95)<400'],
    profile_required_errors: ['count==0'],
  },
};

// setup() runs once, outside the timed scenario: mint NUM_USERS real Firebase Auth emulator ID tokens and
// give each one a profile via CreateProfile, so the timed requests below exercise GetMe's steady-state,
// mostly-cache-hit path (cost-model.md assumes ~50% instance cache hit rate at Stage 0) rather than
// paying every VU's first-ever PROFILE_REQUIRED/CreateProfile cost inside the measured window.
export function setup() {
  const idTokens = [];
  for (let i = 0; i < NUM_USERS; i++) {
    const signUpRes = http.post(
      `http://${AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
      JSON.stringify({ returnSecureToken: true }),
      { headers: { 'Content-Type': 'application/json' } },
    );
    if (signUpRes.status !== 200) {
      throw new Error(`setup: mint id token ${i}: status ${signUpRes.status}: ${signUpRes.body}`);
    }
    const idToken = signUpRes.json('idToken');

    const createRes = http.post(
      `${API_URL}/dzeroth.identity.v1.IdentityService/CreateProfile`,
      JSON.stringify({
        idempotencyKey: `loadtest-identity-getme-${i}-0123456789`,
        handle: `ltgetme${i}`,
        displayName: `Load Test User ${i}`,
      }),
      { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${idToken}` } },
    );
    if (createRes.status !== 200) {
      throw new Error(`setup: CreateProfile ${i}: status ${createRes.status}: ${createRes.body}`);
    }
    idTokens.push(idToken);
  }
  return { idTokens };
}

export default function (data) {
  const idToken = data.idTokens[Math.floor(Math.random() * data.idTokens.length)];
  const res = http.post(`${API_URL}/dzeroth.identity.v1.IdentityService/GetMe`, '{}', {
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${idToken}` },
  });

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'has a profile': (r) => {
      try {
        return !!r.json('profile');
      } catch (e) {
        return false;
      }
    },
  });
  if (!ok) {
    profileRequiredErrors.add(1);
  }
}
