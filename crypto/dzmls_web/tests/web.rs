//! Runs in headless Chrome: `cargo test -p dzmls_web --target wasm32-unknown-unknown` (see crypto/README.md).
//!
//! Replays the frozen `testdata/mls/vectors-v1.json` through the exported JS-facing functions, the same
//! deterministic steps the host replay (`dzmls/tests/vectors.rs`) runs, and checks the error shape.
#![cfg(target_arch = "wasm32")]

use dzmls_web as web;
use js_sys::{Array, Object, Reflect, Uint8Array};
use serde_json::Value;
use wasm_bindgen::{JsCast, JsValue};
use wasm_bindgen_test::*;

wasm_bindgen_test_configure!(run_in_browser);

const VECTORS: &str = include_str!("../../../testdata/mls/vectors-v1.json");

fn unhex(v: &Value) -> Vec<u8> {
    let s = v.as_str().expect("hex string");
    assert!(s.len().is_multiple_of(2), "odd hex length");
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).expect("hex digit"))
        .collect()
}

fn unhex_list(v: &Value) -> Vec<Vec<u8>> {
    v.as_array().expect("array").iter().map(unhex).collect()
}

fn get(v: &JsValue, key: &str) -> JsValue {
    Reflect::get(v, &JsValue::from_str(key)).expect("property")
}

fn js_bytes(v: &JsValue) -> Vec<u8> {
    v.dyn_ref::<Uint8Array>().expect("Uint8Array").to_vec()
}

fn js_bytes_list(v: &JsValue) -> Vec<Vec<u8>> {
    v.dyn_ref::<Array>()
        .expect("Array")
        .iter()
        .map(|i| js_bytes(&i))
        .collect()
}

fn js_u64(v: &JsValue) -> u64 {
    v.as_f64().expect("number") as u64
}

fn to_js_list(items: &[Vec<u8>]) -> JsValue {
    items
        .iter()
        .map(|b| JsValue::from(Uint8Array::from(b.as_slice())))
        .collect::<Array>()
        .into()
}

fn party(v: &Value) -> JsValue {
    let o = Object::new();
    Reflect::set(
        &o,
        &"userId".into(),
        &Uint8Array::from(unhex(&v["user_id"]).as_slice()).into(),
    )
    .unwrap();
    Reflect::set(
        &o,
        &"deviceKeys".into(),
        &to_js_list(&unhex_list(&v["device_keys"])),
    )
    .unwrap();
    o.into()
}

fn err_code(e: &JsValue) -> String {
    get(e, "code").as_string().expect("error.code is a string")
}

/// `describe`'s members against the JSON the vectors record them in.
fn members_match(group_state: &[u8], expected: &Value) {
    let info = web::describe(group_state).unwrap();
    let got = get(&info, "members");
    let got = got.dyn_ref::<Array>().expect("members array").to_vec();
    let want = expected.as_array().expect("members");
    assert_eq!(got.len(), want.len());
    for (m, w) in got.iter().zip(want) {
        assert_eq!(js_bytes(&get(m, "deviceId")), unhex(&w["device_id"]));
        assert_eq!(
            js_bytes(&get(m, "signaturePublicKey")),
            unhex(&w["signature_public_key"])
        );
    }
}

fn replay_process(i: usize, step: &Value) {
    let (input, out) = (&step["in"], &step["out"]);
    let result = web::process(
        &unhex(&input["device_state"]),
        &unhex(&input["group_state"]),
        &unhex(&input["wire"]),
    );
    if let Some(code) = out.get("error") {
        let e = result.expect_err(&format!("step {i}: process must fail"));
        assert_eq!(err_code(&e), code.as_str().unwrap(), "step {i}");
        return;
    }
    let p = result.unwrap_or_else(|e| panic!("step {i}: process failed: {}", err_code(&e)));
    let event = get(&p, "event");
    let kind = get(&event, "kind").as_string().unwrap();
    assert_eq!(kind, out["event"].as_str().unwrap(), "step {i}");
    match kind.as_str() {
        "message" => {
            assert_eq!(
                js_bytes(&get(&event, "plaintext")),
                unhex(&out["plaintext"]),
                "step {i}"
            );
            assert_eq!(
                js_bytes(&get(&event, "senderDeviceId")),
                unhex(&out["sender_device_id"]),
                "step {i}"
            );
        }
        "commit" => {
            assert_eq!(
                js_u64(&get(&event, "epoch")),
                out["epoch"].as_u64().unwrap(),
                "step {i}"
            );
            assert_eq!(
                js_bytes_list(&get(&event, "added")),
                unhex_list(&out["added"]),
                "step {i}"
            );
            assert_eq!(
                js_bytes_list(&get(&event, "removed")),
                unhex_list(&out["removed"]),
                "step {i}"
            );
            assert_eq!(
                get(&event, "selfRemoved").as_bool().unwrap(),
                out["self_removed"].as_bool().unwrap(),
                "step {i}"
            );
        }
        other => panic!("step {i}: unknown event kind {other}"),
    }
}

fn replay_step(i: usize, step: &Value) {
    let (input, out) = (&step["in"], &step["out"]);
    match step["op"].as_str().expect("op") {
        "join_from_welcome" => {
            let j =
                web::join_from_welcome(&unhex(&input["device_state"]), &unhex(&input["welcome"]))
                    .unwrap_or_else(|e| panic!("step {i}: join failed: {}", err_code(&e)));
            assert_eq!(
                js_bytes(&get(&j, "groupId")),
                unhex(&out["group_id"]),
                "step {i}"
            );
            assert_eq!(
                js_u64(&get(&j, "epoch")),
                out["epoch"].as_u64().unwrap(),
                "step {i}"
            );
            members_match(&js_bytes(&get(&j, "groupState")), &out["members"]);
        }
        "process" => replay_process(i, step),
        "describe" => {
            let group_state = unhex(&input["group_state"]);
            let info = web::describe(&group_state).unwrap();
            assert_eq!(
                js_bytes(&get(&info, "groupId")),
                unhex(&out["group_id"]),
                "step {i}"
            );
            assert_eq!(
                js_u64(&get(&info, "epoch")),
                out["epoch"].as_u64().unwrap(),
                "step {i}"
            );
            assert_eq!(
                get(&info, "hasPendingCommit").as_bool().unwrap(),
                out["has_pending_commit"].as_bool().unwrap(),
                "step {i}"
            );
            members_match(&group_state, &out["members"]);
        }
        "wire_epoch" => {
            let result = web::wire_epoch(&unhex(&input["wire"]));
            if let Some(code) = out.get("error") {
                let e = result.expect_err(&format!("step {i}: wire_epoch must fail"));
                assert_eq!(err_code(&e), code.as_str().unwrap(), "step {i}");
            } else {
                let r = result.unwrap();
                assert_eq!(
                    js_u64(&get(&r, "epoch")),
                    out["epoch"].as_u64().unwrap(),
                    "step {i}"
                );
            }
        }
        "security_code" => {
            let r = web::security_code(&party(&input["a"]), &party(&input["b"])).unwrap();
            assert_eq!(
                get(&r, "code").as_string().unwrap(),
                out["code"].as_str().unwrap(),
                "step {i}"
            );
        }
        // Generation-side steps: recorded for reading, not deterministic, so not replayed.
        "create_device"
        | "generate_key_packages"
        | "create_group"
        | "commit_change"
        | "confirm_commit"
        | "encrypt" => {}
        other => panic!("step {i}: unknown op {other}"),
    }
}

#[wasm_bindgen_test]
fn vectors_replay_through_the_exported_functions() {
    let doc: Value = serde_json::from_str(VECTORS).expect("vectors are JSON");
    for (i, step) in doc["steps"].as_array().expect("steps").iter().enumerate() {
        replay_step(i, step);
    }
    // Every final state still decodes, and every final device state still loads.
    for st in doc["final_states"]
        .as_object()
        .expect("final_states")
        .values()
    {
        web::describe(&unhex(&st["group_state"])).unwrap();
        let k = web::generate_key_packages(&unhex(&st["device_state"]), 1, false).unwrap();
        assert_eq!(js_bytes_list(&get(&k, "keyPackages")).len(), 1);
    }
}

#[wasm_bindgen_test]
fn a_thrown_error_carries_a_stable_code() {
    let e = web::wire_epoch(&[0xde, 0xad, 0xbe, 0xef]).expect_err("garbage wire must fail");
    assert_eq!(err_code(&e), "bad_input");
    assert!(get(&e, "message").as_string().is_some());
    let e = web::describe(&[0u8; 8]).expect_err("garbage state must fail");
    assert_eq!(err_code(&e), "corrupt_state");
    // An argument of the wrong JS type is bad_input too.
    let e = web::commit_change(&[], &[], &JsValue::from_str("x"), &to_js_list(&[]))
        .expect_err("not an array");
    assert_eq!(err_code(&e), "bad_input");
}

#[wasm_bindgen_test]
fn fresh_devices_talk_through_the_exported_functions() {
    let alice = web::create_device(&[1u8; 16]).unwrap();
    let bob = web::create_device(&[2u8; 16]).unwrap();
    let alice_dev = js_bytes(&get(&alice, "deviceState"));
    let bob_dev = js_bytes(&get(&bob, "deviceState"));
    assert_eq!(js_bytes(&get(&alice, "signaturePublicKey")).len(), 32);
    let kps = web::generate_key_packages(&bob_dev, 2, true).unwrap();
    let bob_dev = js_bytes(&get(&kps, "deviceState"));
    let kp = js_bytes_list(&get(&kps, "keyPackages"));
    assert_eq!(kp.len(), 3);
    let group = js_bytes(&get(
        &web::create_group(&alice_dev, &[9u8; 16]).unwrap(),
        "groupState",
    ));
    let commit =
        web::commit_change(&alice_dev, &group, &to_js_list(&kp[..1]), &to_js_list(&[])).unwrap();
    let welcome = js_bytes(&get(&commit, "welcome"));
    let group = js_bytes(&get(&commit, "groupState"));
    let group = js_bytes(&get(
        &web::confirm_commit(&alice_dev, &group).unwrap(),
        "groupState",
    ));
    let joined = web::join_from_welcome(&bob_dev, &welcome).unwrap();
    let (bob_dev, bob_group) = (
        js_bytes(&get(&joined, "deviceState")),
        js_bytes(&get(&joined, "groupState")),
    );
    let sent = web::encrypt(&alice_dev, &group, b"hi bob").unwrap();
    let got = web::process(&bob_dev, &bob_group, &js_bytes(&get(&sent, "ciphertext"))).unwrap();
    let event = get(&got, "event");
    assert_eq!(get(&event, "kind").as_string().unwrap(), "message");
    assert_eq!(js_bytes(&get(&event, "plaintext")), b"hi bob");
    // A commit with nothing to do has no welcome to hand back, and says so with null.
    let none = web::commit_change(
        &alice_dev,
        &group,
        &to_js_list(&[]),
        &to_js_list(&[vec![2u8; 16]]),
    )
    .unwrap();
    assert!(get(&none, "welcome").is_null());
}

#[wasm_bindgen_test]
fn self_update_confirms_on_one_side_and_processes_on_the_other() {
    let alice = web::create_device(&[1u8; 16]).unwrap();
    let bob = web::create_device(&[2u8; 16]).unwrap();
    let alice_dev = js_bytes(&get(&alice, "deviceState"));
    let kps = web::generate_key_packages(&js_bytes(&get(&bob, "deviceState")), 1, false).unwrap();
    let bob_dev = js_bytes(&get(&kps, "deviceState"));
    let kp = js_bytes_list(&get(&kps, "keyPackages"));
    let group = js_bytes(&get(
        &web::create_group(&alice_dev, &[9u8; 16]).unwrap(),
        "groupState",
    ));
    let add = web::commit_change(&alice_dev, &group, &to_js_list(&kp), &to_js_list(&[])).unwrap();
    let alice_group = js_bytes(&get(
        &web::confirm_commit(&alice_dev, &js_bytes(&get(&add, "groupState"))).unwrap(),
        "groupState",
    ));
    let joined = web::join_from_welcome(&bob_dev, &js_bytes(&get(&add, "welcome"))).unwrap();
    let (bob_dev, bob_group) = (
        js_bytes(&get(&joined, "deviceState")),
        js_bytes(&get(&joined, "groupState")),
    );

    // Same object shape as commitChange: groupState, commit, welcome (null), epoch.
    let update = web::self_update(&alice_dev, &alice_group).unwrap();
    assert_eq!(js_u64(&get(&update, "epoch")), 1);
    assert!(get(&update, "welcome").is_null());
    let pending = js_bytes(&get(&update, "groupState"));
    assert!(
        get(&web::describe(&pending).unwrap(), "hasPendingCommit")
            .as_bool()
            .unwrap()
    );
    let e = web::self_update(&alice_dev, &pending).expect_err("already pending");
    assert_eq!(err_code(&e), "pending_commit");
    let alice_group = js_bytes(&get(
        &web::confirm_commit(&alice_dev, &pending).unwrap(),
        "groupState",
    ));
    assert_eq!(
        js_u64(&get(&web::describe(&alice_group).unwrap(), "epoch")),
        2
    );

    let p = web::process(&bob_dev, &bob_group, &js_bytes(&get(&update, "commit"))).unwrap();
    let event = get(&p, "event");
    assert_eq!(get(&event, "kind").as_string().unwrap(), "commit");
    assert_eq!(js_u64(&get(&event, "epoch")), 2);
    assert!(js_bytes_list(&get(&event, "added")).is_empty());
    assert!(js_bytes_list(&get(&event, "removed")).is_empty());
    assert!(!get(&event, "selfRemoved").as_bool().unwrap());

    let sent = web::encrypt(&alice_dev, &alice_group, b"renewed").unwrap();
    let got = web::process(
        &bob_dev,
        &js_bytes(&get(&p, "groupState")),
        &js_bytes(&get(&sent, "ciphertext")),
    )
    .unwrap();
    assert_eq!(js_bytes(&get(&get(&got, "event"), "plaintext")), b"renewed");
}

#[wasm_bindgen_test]
fn seal_and_open_round_trip_with_random_key() {
    let key = js_bytes(&get(&web::random_bytes(32).unwrap(), "bytes"));
    assert_eq!(key.len(), 32);
    let other = js_bytes(&get(&web::random_bytes(32).unwrap(), "bytes"));
    assert_ne!(key, other, "the browser CSPRNG gives fresh bytes");
    let sealed = js_bytes(&get(
        &web::seal(&key, b"messages:row-1", b"in the vault").unwrap(),
        "sealed",
    ));
    assert_eq!(sealed.len(), b"in the vault".len() + 28);
    let opened = web::open(&key, b"messages:row-1", &sealed).unwrap();
    assert_eq!(js_bytes(&get(&opened, "plaintext")), b"in the vault");
    let e = web::open(&key, b"messages:row-2", &sealed).expect_err("wrong aad");
    assert_eq!(err_code(&e), "bad_input");
    let e = web::random_bytes(0).expect_err("zero length");
    assert_eq!(err_code(&e), "bad_input");
}
