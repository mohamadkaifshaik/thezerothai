//! Hand-written, single-threaded wasm-bindgen binding over `dzmls`: one exported free function per `dzmls`
//! function, nothing else. No state lives here; the worker (`app/web/mls_worker.js`) holds none either.
//!
//! Bytes cross as `Uint8Array`. Results are plain JS objects whose field names are the Rust struct fields in
//! camelCase; `u64` epochs are JS numbers (exact below 2^53). A failure is thrown as a plain object
//! `{ code, message }`, where `code` is `ErrorCode::as_str()`. Messages carry codes and sizes only.
//!
//! Callers must serialize calls: see `dzmls`.

use dzmls::{Event, MlsError, Party};
use js_sys::{Array, Object, Reflect, Uint8Array};
use wasm_bindgen::prelude::*;

fn bytes(b: &[u8]) -> JsValue {
    Uint8Array::from(b).into()
}

fn bytes_list(items: &[Vec<u8>]) -> JsValue {
    items.iter().map(|b| bytes(b)).collect::<Array>().into()
}

fn num(n: u64) -> JsValue {
    JsValue::from_f64(n as f64)
}

fn object(fields: &[(&str, JsValue)]) -> JsValue {
    let o = Object::new();
    for (k, v) in fields {
        // Setting a data property on a fresh plain object cannot fail.
        let _ = Reflect::set(&o, &JsValue::from_str(k), v);
    }
    o.into()
}

fn js_error(code: &str, message: &str) -> JsValue {
    object(&[
        ("code", JsValue::from_str(code)),
        ("message", JsValue::from_str(message)),
    ])
}

fn fail(e: MlsError) -> JsValue {
    js_error(e.code.as_str(), &e.message)
}

fn bad_input(message: &str) -> JsValue {
    js_error("bad_input", message)
}

fn field(v: &JsValue, name: &str) -> Result<JsValue, JsValue> {
    Reflect::get(v, &JsValue::from_str(name)).map_err(|_| bad_input("argument is not an object"))
}

fn to_bytes(v: &JsValue) -> Result<Vec<u8>, JsValue> {
    v.dyn_ref::<Uint8Array>()
        .map(Uint8Array::to_vec)
        .ok_or_else(|| bad_input("expected a Uint8Array"))
}

fn to_bytes_list(v: &JsValue) -> Result<Vec<Vec<u8>>, JsValue> {
    let array = v
        .dyn_ref::<Array>()
        .ok_or_else(|| bad_input("expected an array of Uint8Array"))?;
    array.iter().map(|item| to_bytes(&item)).collect()
}

fn party(v: &JsValue) -> Result<Party, JsValue> {
    Ok(Party {
        user_id: to_bytes(&field(v, "userId")?)?,
        device_keys: to_bytes_list(&field(v, "deviceKeys")?)?,
    })
}

fn members(list: &[dzmls::Member]) -> JsValue {
    list.iter()
        .map(|m| {
            object(&[
                ("deviceId", bytes(&m.device_id)),
                ("signaturePublicKey", bytes(&m.signature_public_key)),
            ])
        })
        .collect::<Array>()
        .into()
}

/// `{ deviceState, signaturePublicKey }`
#[wasm_bindgen(js_name = createDevice)]
pub fn create_device(device_id: &[u8]) -> Result<JsValue, JsValue> {
    let d = dzmls::create_device(device_id).map_err(fail)?;
    Ok(object(&[
        ("deviceState", bytes(&d.device_state)),
        ("signaturePublicKey", bytes(&d.signature_public_key)),
    ]))
}

/// `{ deviceState, keyPackages: Uint8Array[] }`
#[wasm_bindgen(js_name = generateKeyPackages)]
pub fn generate_key_packages(
    device_state: &[u8],
    count: u32,
    last_resort: bool,
) -> Result<JsValue, JsValue> {
    let k = dzmls::generate_key_packages(device_state, count, last_resort).map_err(fail)?;
    Ok(object(&[
        ("deviceState", bytes(&k.device_state)),
        ("keyPackages", bytes_list(&k.key_packages)),
    ]))
}

/// `{ groupState }`
#[wasm_bindgen(js_name = createGroup)]
pub fn create_group(device_state: &[u8], group_id: &[u8]) -> Result<JsValue, JsValue> {
    let g = dzmls::create_group(device_state, group_id).map_err(fail)?;
    Ok(object(&[("groupState", bytes(&g))]))
}

/// `{ groupState, commit, welcome: Uint8Array | null, epoch }`
#[wasm_bindgen(js_name = commitChange)]
pub fn commit_change(
    device_state: &[u8],
    group_state: &[u8],
    add_key_packages: &JsValue,
    remove_device_ids: &JsValue,
) -> Result<JsValue, JsValue> {
    let adds = to_bytes_list(add_key_packages)?;
    let removes = to_bytes_list(remove_device_ids)?;
    let c = dzmls::commit_change(device_state, group_state, &adds, &removes).map_err(fail)?;
    Ok(commit_object(&c))
}

/// `{ groupState, commit, welcome: null, epoch }`, the same shape as `commitChange`.
#[wasm_bindgen(js_name = selfUpdate)]
pub fn self_update(device_state: &[u8], group_state: &[u8]) -> Result<JsValue, JsValue> {
    let c = dzmls::self_update(device_state, group_state).map_err(fail)?;
    Ok(commit_object(&c))
}

fn commit_object(c: &dzmls::Commit) -> JsValue {
    object(&[
        ("groupState", bytes(&c.group_state)),
        ("commit", bytes(&c.commit)),
        ("welcome", c.welcome.as_deref().map_or(JsValue::NULL, bytes)),
        ("epoch", num(c.epoch)),
    ])
}

/// `{ groupState }`
#[wasm_bindgen(js_name = confirmCommit)]
pub fn confirm_commit(device_state: &[u8], group_state: &[u8]) -> Result<JsValue, JsValue> {
    let g = dzmls::confirm_commit(device_state, group_state).map_err(fail)?;
    Ok(object(&[("groupState", bytes(&g))]))
}

/// `{ groupState }`
#[wasm_bindgen(js_name = discardCommit)]
pub fn discard_commit(device_state: &[u8], group_state: &[u8]) -> Result<JsValue, JsValue> {
    let g = dzmls::discard_commit(device_state, group_state).map_err(fail)?;
    Ok(object(&[("groupState", bytes(&g))]))
}

/// `{ deviceState, groupState, groupId, epoch }`
#[wasm_bindgen(js_name = joinFromWelcome)]
pub fn join_from_welcome(device_state: &[u8], welcome: &[u8]) -> Result<JsValue, JsValue> {
    let j = dzmls::join_from_welcome(device_state, welcome).map_err(fail)?;
    Ok(object(&[
        ("deviceState", bytes(&j.device_state)),
        ("groupState", bytes(&j.group_state)),
        ("groupId", bytes(&j.group_id)),
        ("epoch", num(j.epoch)),
    ]))
}

/// `{ groupState, ciphertext, epoch }`
#[wasm_bindgen]
pub fn encrypt(
    device_state: &[u8],
    group_state: &[u8],
    plaintext: &[u8],
) -> Result<JsValue, JsValue> {
    let e = dzmls::encrypt(device_state, group_state, plaintext).map_err(fail)?;
    Ok(object(&[
        ("groupState", bytes(&e.group_state)),
        ("ciphertext", bytes(&e.ciphertext)),
        ("epoch", num(e.epoch)),
    ]))
}

/// `{ groupState, event }` where `event` is `{ kind: "message", plaintext, senderDeviceId }` or
/// `{ kind: "commit", epoch, added, removed, selfRemoved }`.
#[wasm_bindgen]
pub fn process(device_state: &[u8], group_state: &[u8], wire: &[u8]) -> Result<JsValue, JsValue> {
    let p = dzmls::process(device_state, group_state, wire).map_err(fail)?;
    let event = match &p.event {
        Event::Message {
            plaintext,
            sender_device_id,
        } => object(&[
            ("kind", JsValue::from_str("message")),
            ("plaintext", bytes(plaintext)),
            ("senderDeviceId", bytes(sender_device_id)),
        ]),
        Event::Commit {
            epoch,
            added,
            removed,
            self_removed,
        } => object(&[
            ("kind", JsValue::from_str("commit")),
            ("epoch", num(*epoch)),
            ("added", bytes_list(added)),
            ("removed", bytes_list(removed)),
            ("selfRemoved", JsValue::from_bool(*self_removed)),
        ]),
    };
    Ok(object(&[
        ("groupState", bytes(&p.group_state)),
        ("event", event),
    ]))
}

/// `{ groupId, epoch, members: { deviceId, signaturePublicKey }[], hasPendingCommit }`
#[wasm_bindgen]
pub fn describe(group_state: &[u8]) -> Result<JsValue, JsValue> {
    let g = dzmls::describe(group_state).map_err(fail)?;
    Ok(object(&[
        ("groupId", bytes(&g.group_id)),
        ("epoch", num(g.epoch)),
        ("members", members(&g.members)),
        ("hasPendingCommit", JsValue::from_bool(g.has_pending_commit)),
    ]))
}

/// `{ epoch }`
#[wasm_bindgen(js_name = wireEpoch)]
pub fn wire_epoch(wire: &[u8]) -> Result<JsValue, JsValue> {
    let epoch = dzmls::wire_epoch(wire).map_err(fail)?;
    Ok(object(&[("epoch", num(epoch))]))
}

/// `a` and `b` are `{ userId: Uint8Array, deviceKeys: Uint8Array[] }`. Returns `{ code }`.
#[wasm_bindgen(js_name = securityCode)]
pub fn security_code(a: &JsValue, b: &JsValue) -> Result<JsValue, JsValue> {
    let code = dzmls::security_code(&party(a)?, &party(b)?).map_err(fail)?;
    Ok(object(&[("code", JsValue::from_str(&code))]))
}

/// `{ sealed }`: `nonce (12) || ciphertext || tag (16)` under a 32-byte key (AES-256-GCM, local storage).
#[wasm_bindgen]
pub fn seal(key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<JsValue, JsValue> {
    let sealed = dzmls::seal(key, aad, plaintext).map_err(fail)?;
    Ok(object(&[("sealed", bytes(&sealed))]))
}

/// `{ plaintext }`. A wrong key, wrong aad or altered bytes throw `bad_input`.
#[wasm_bindgen]
pub fn open(key: &[u8], aad: &[u8], sealed: &[u8]) -> Result<JsValue, JsValue> {
    let plaintext = dzmls::open(key, aad, sealed).map_err(fail)?;
    Ok(object(&[("plaintext", bytes(&plaintext))]))
}

/// `{ bytes }`: `length` (1 to 64) random bytes.
#[wasm_bindgen(js_name = randomBytes)]
pub fn random_bytes(length: u32) -> Result<JsValue, JsValue> {
    let b = dzmls::random_bytes(length).map_err(fail)?;
    Ok(object(&[("bytes", bytes(&b))]))
}
