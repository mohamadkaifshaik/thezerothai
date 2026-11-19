// FROZEN: `testdata/mls/vectors-v1.json` is committed once and never regenerated.
//
// State blobs live on users' devices across OpenMLS upgrades. This file holds state written by one build, and this
// test proves that the current build still reads it and gets the same answers. Regenerating it would defeat that.
// A format or library change adds `testdata/mls/vectors-v2.json` beside it (via `dzmls_vectors`), and this test
// replays every `vectors-v*.json` it finds. Web, Android and iOS replay the same files.
//
// OpenMLS checks key package and leaf lifetimes against the wall clock. The key packages in `vectors-v1.json` are valid
// until 2031-11-17 07:11:12 UTC (five years, see `LIFETIME_SECONDS`); after that its join steps fail by design.

use dzmls::{Event, Party};
use serde_json::Value;

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

fn party(v: &Value) -> Party {
    Party {
        user_id: unhex(&v["user_id"]),
        device_keys: unhex_list(&v["device_keys"]),
    }
}

/// `describe`'s members as the JSON the vectors record them in.
fn members_match(group_state: &[u8], expected: &Value) {
    let info = dzmls::describe(group_state).unwrap();
    let want = expected.as_array().expect("members");
    assert_eq!(info.members.len(), want.len());
    for (m, w) in info.members.iter().zip(want) {
        assert_eq!(m.device_id, unhex(&w["device_id"]));
        assert_eq!(m.signature_public_key, unhex(&w["signature_public_key"]));
    }
}

fn replay_process(i: usize, step: &Value) {
    let (input, out) = (&step["in"], &step["out"]);
    let result = dzmls::process(
        &unhex(&input["device_state"]),
        &unhex(&input["group_state"]),
        &unhex(&input["wire"]),
    );
    if let Some(code) = out.get("error") {
        let e = result.expect_err(&format!("step {i}: process must fail"));
        assert_eq!(e.code.as_str(), code.as_str().unwrap(), "step {i}");
        return;
    }
    let p = result.unwrap_or_else(|e| panic!("step {i}: process failed: {e}"));
    match (&p.event, out["event"].as_str().unwrap()) {
        (
            Event::Message {
                plaintext,
                sender_device_id,
            },
            "message",
        ) => {
            assert_eq!(*plaintext, unhex(&out["plaintext"]), "step {i}");
            assert_eq!(
                *sender_device_id,
                unhex(&out["sender_device_id"]),
                "step {i}"
            );
        }
        (
            Event::Commit {
                epoch,
                added,
                removed,
                self_removed,
                ..
            },
            "commit",
        ) => {
            assert_eq!(*epoch, out["epoch"].as_u64().unwrap(), "step {i}");
            assert_eq!(*added, unhex_list(&out["added"]), "step {i}");
            assert_eq!(*removed, unhex_list(&out["removed"]), "step {i}");
            assert_eq!(
                *self_removed,
                out["self_removed"].as_bool().unwrap(),
                "step {i}"
            );
        }
        _ => panic!("step {i}: event kind differs from the recorded one"),
    }
}

fn replay_step(i: usize, step: &Value) {
    let (input, out) = (&step["in"], &step["out"]);
    match step["op"].as_str().expect("op") {
        "join_from_welcome" => {
            let j =
                dzmls::join_from_welcome(&unhex(&input["device_state"]), &unhex(&input["welcome"]))
                    .unwrap_or_else(|e| panic!("step {i}: join failed: {e}"));
            assert_eq!(j.group_id, unhex(&out["group_id"]), "step {i}");
            assert_eq!(j.epoch, out["epoch"].as_u64().unwrap(), "step {i}");
            members_match(&j.group_state, &out["members"]);
        }
        "process" => replay_process(i, step),
        "describe" => {
            let group_state = unhex(&input["group_state"]);
            let info = dzmls::describe(&group_state).unwrap();
            assert_eq!(info.group_id, unhex(&out["group_id"]), "step {i}");
            assert_eq!(info.epoch, out["epoch"].as_u64().unwrap(), "step {i}");
            assert_eq!(
                info.has_pending_commit,
                out["has_pending_commit"].as_bool().unwrap(),
                "step {i}"
            );
            members_match(&group_state, &out["members"]);
        }
        "wire_epoch" => {
            let result = dzmls::wire_epoch(&unhex(&input["wire"]));
            if let Some(code) = out.get("error") {
                let e = result.expect_err(&format!("step {i}: wire_epoch must fail"));
                assert_eq!(e.code.as_str(), code.as_str().unwrap(), "step {i}");
            } else {
                assert_eq!(result.unwrap(), out["epoch"].as_u64().unwrap(), "step {i}");
            }
        }
        "security_code" => {
            let code = dzmls::security_code(&party(&input["a"]), &party(&input["b"])).unwrap();
            assert_eq!(code, out["code"].as_str().unwrap(), "step {i}");
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

#[test]
fn committed_vectors_replay() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../testdata/mls");
    let mut files: Vec<_> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()))
        .map(|e| e.unwrap().path())
        .filter(|p| {
            let name = p.file_name().unwrap().to_string_lossy();
            name.starts_with("vectors-v") && name.ends_with(".json")
        })
        .collect();
    files.sort();
    assert!(
        files.iter().any(|p| p.ends_with("vectors-v1.json")),
        "vectors-v1.json is missing"
    );
    for path in files {
        let doc: Value = serde_json::from_slice(&std::fs::read(&path).unwrap())
            .unwrap_or_else(|e| panic!("{}: not JSON: {e}", path.display()));
        assert!(doc["version"].as_u64().is_some(), "{}", path.display());
        let steps = doc["steps"].as_array().expect("steps");
        for (i, step) in steps.iter().enumerate() {
            replay_step(i, step);
        }
        // The final states of all three devices still decode and say what the script left behind: the group id
        // the script used, alice and carol at epoch 3 with only themselves as members, and bob (removed by the
        // commit that made epoch 3) on his own inactive blob. Every device state still loads.
        let finals = doc["final_states"].as_object().expect("final_states");
        assert_eq!(finals.len(), 3);
        let id = |name: &str| unhex(&doc["device_ids"][name]);
        for (name, want_epoch, want_members) in [
            ("alice", 3, Some(vec![id("alice"), id("carol")])),
            ("carol", 3, Some(vec![id("alice"), id("carol")])),
            ("bob", 3, None),
        ] {
            let st = &finals[name];
            let info = dzmls::describe(&unhex(&st["group_state"])).unwrap();
            assert_eq!(info.group_id, vec![0xab; 32], "{name}");
            assert_eq!(info.epoch, want_epoch, "{name}");
            assert!(!info.has_pending_commit, "{name}");
            if let Some(members) = want_members {
                let ids: Vec<Vec<u8>> = info.members.into_iter().map(|m| m.device_id).collect();
                assert_eq!(ids, members, "{name}");
            }
            let kps = dzmls::generate_key_packages(&unhex(&st["device_state"]), 1, false)
                .unwrap_or_else(|e| panic!("{name}: final device state no longer loads: {e}"));
            assert_eq!(kps.key_packages.len(), 1, "{name}");
        }
    }
}
