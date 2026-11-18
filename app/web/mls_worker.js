// Web Worker around the MLS core (crypto/dzmls_web, built by scripts/crypto/build-web.sh into mls/).
// Holds no state between requests: every op takes the device/group blobs as arguments and returns new ones.
// Never logs or echoes arguments or results.
//
// Protocol (see crypto/dzmls_web/src/lib.rs for result shapes):
//   first message after load : { ready: true } | { ready: false, message }
//   request                  : { id: number, op: string, args: object }   // byte values are Uint8Array
//   response                 : { id, ok: true, result: object }
//                            | { id, ok: false, code: string, message: string }
// Every Uint8Array in a response is transferred, not copied.
// Ops and their args (see `ops` below): createDevice { deviceId }; generateKeyPackages { deviceState, count,
// lastResort }; createGroup { deviceState, groupId }; commitChange { deviceState, groupState, addKeyPackages,
// removeDeviceIds }; selfUpdate { deviceState, groupState } (same result shape as commitChange, welcome null);
// confirmCommit / discardCommit { deviceState, groupState }; joinFromWelcome { deviceState, welcome };
// encrypt { deviceState, groupState, plaintext }; process { deviceState, groupState, wire }; describe { groupState };
// wireEpoch { wire }; securityCode { a, b }.
'use strict';

importScripts('mls/dzmls_web.js');

// op name -> (args) => result. Argument names are camelCase, one binding function per dzmls function.
const ops = {
  createDevice: (a) => wasm_bindgen.createDevice(a.deviceId),
  generateKeyPackages: (a) =>
    wasm_bindgen.generateKeyPackages(a.deviceState, a.count, a.lastResort),
  createGroup: (a) => wasm_bindgen.createGroup(a.deviceState, a.groupId),
  commitChange: (a) =>
    wasm_bindgen.commitChange(a.deviceState, a.groupState, a.addKeyPackages, a.removeDeviceIds),
  selfUpdate: (a) => wasm_bindgen.selfUpdate(a.deviceState, a.groupState),
  confirmCommit: (a) => wasm_bindgen.confirmCommit(a.deviceState, a.groupState),
  discardCommit: (a) => wasm_bindgen.discardCommit(a.deviceState, a.groupState),
  joinFromWelcome: (a) => wasm_bindgen.joinFromWelcome(a.deviceState, a.welcome),
  encrypt: (a) => wasm_bindgen.encrypt(a.deviceState, a.groupState, a.plaintext),
  process: (a) => wasm_bindgen.process(a.deviceState, a.groupState, a.wire),
  describe: (a) => wasm_bindgen.describe(a.groupState),
  wireEpoch: (a) => wasm_bindgen.wireEpoch(a.wire),
  securityCode: (a) => wasm_bindgen.securityCode(a.a, a.b),
};

// Every Uint8Array reachable from a result, so its buffer can be transferred.
function collectBuffers(value, out) {
  if (value instanceof Uint8Array) {
    out.push(value.buffer);
  } else if (Array.isArray(value)) {
    for (const item of value) collectBuffers(item, out);
  } else if (value !== null && typeof value === 'object') {
    for (const key of Object.keys(value)) collectBuffers(value[key], out);
  }
  return out;
}

const ready = wasm_bindgen({ module_or_path: 'mls/dzmls_web_bg.wasm' }).then(
  () => {
    self.postMessage({ ready: true });
  },
  (e) => {
    self.postMessage({ ready: false, message: String((e && e.message) || e) });
    throw e;
  },
);

function failure(id, e) {
  const hasCode = e !== null && typeof e === 'object' && typeof e.code === 'string';
  return {
    id,
    ok: false,
    code: hasCode ? e.code : 'internal',
    message: String((e && e.message) || 'worker error'),
  };
}

self.onmessage = async (event) => {
  const { id, op, args } = event.data || {};
  try {
    await ready;
  } catch (_) {
    self.postMessage({ id, ok: false, code: 'internal', message: 'mls module failed to load' });
    return;
  }
  const fn = Object.prototype.hasOwnProperty.call(ops, op) ? ops[op] : null;
  if (fn === null) {
    self.postMessage({ id, ok: false, code: 'bad_input', message: 'unknown op' });
    return;
  }
  try {
    const result = fn(args || {});
    self.postMessage({ id, ok: true, result }, collectBuffers(result, []));
  } catch (e) {
    self.postMessage(failure(id, e));
  }
};
