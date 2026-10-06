// graph_common: shared setup helpers for graph_follow.js and graph_lists.js (T18, docs/plans/graph.md).
// Mints real Firebase Auth emulator ID tokens and creates profiles via IdentityService.CreateProfile, so the
// timed scenarios only exercise GraphService. Never points at anything but the URLs given by env vars
// (defaults are the local emulator + local API; see loadtest/README.md).
import http from 'k6/http';

export const API_URL = __ENV.API_URL || 'http://localhost:8081';
export const AUTH_EMULATOR_HOST = __ENV.AUTH_EMULATOR_HOST || 'localhost:9099';

const JSON_HDR = { 'Content-Type': 'application/json' };

export function authHeaders(idToken) {
  return { 'Content-Type': 'application/json', Authorization: `Bearer ${idToken}` };
}

// mintUsers signs up `n` anonymous users in the Auth emulator and gives each a profile (handle prefix +
// index). Returns [{uid, idToken}].
export function mintUsers(n, handlePrefix) {
  // Unique per run: handles and idempotency keys persist in the emulator across k6 runs.
  const run = Math.floor(Date.now() / 1000).toString(36);
  const users = [];
  for (let i = 0; i < n; i++) {
    const signUp = http.post(
      `http://${AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
      JSON.stringify({ returnSecureToken: true }),
      { headers: JSON_HDR },
    );
    if (signUp.status !== 200) {
      throw new Error(`setup: mint user ${i}: status ${signUp.status}: ${signUp.body}`);
    }
    const idToken = signUp.json('idToken');
    const uid = signUp.json('localId');
    const create = http.post(
      `${API_URL}/dzeroth.identity.v1.IdentityService/CreateProfile`,
      JSON.stringify({
        idempotencyKey: `${handlePrefix}-${run}-create-${i}`,
        handle: `${handlePrefix.slice(0, 3)}${run}_${i}`,
        displayName: `Graph Load ${handlePrefix} ${i}`,
      }),
      { headers: authHeaders(idToken) },
    );
    if (create.status !== 200) {
      throw new Error(`setup: CreateProfile ${i}: status ${create.status}: ${create.body}`);
    }
    users.push({ uid, idToken });
  }
  return users;
}

// rpcCall posts a Connect JSON unary call to any service (T22 reuses it for PostService/TimelineService).
export function rpcCall(service, method, body, idToken, rpcTag) {
  return http.post(`${API_URL}/${service}/${method}`, JSON.stringify(body), {
    headers: authHeaders(idToken),
    tags: { rpc: rpcTag || method },
  });
}

export function graphCall(method, body, idToken, rpcTag) {
  return rpcCall('dzeroth.graph.v1.GraphService', method, body, idToken, rpcTag);
}
