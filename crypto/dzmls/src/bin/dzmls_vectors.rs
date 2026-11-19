//! Generates the cross-platform test vectors: `cargo run -p dzmls --bin dzmls_vectors -- <out.json>`.
//!
//! One scripted run (alice creates a group and adds bob, bob joins, a message each way, alice adds carol, a message,
//! alice removes bob, a message), recorded as JSON with every binary value hex-encoded. Keys are random, so every
//! run writes a different file. `testdata/mls/vectors-v1.json` is frozen: never regenerate it (see
//! `tests/vectors.rs`).
//!
//! The consumer replays only the deterministic operations (`join_from_welcome`, `process`, `describe`,
//! `wire_epoch`, `security_code`). Steps that produced the wires (`create_device`, `create_group`,
//! `commit_change`, `encrypt`, ...) are recorded for reading and are skipped by the replay.

use std::fmt::Write as _;
use std::process::ExitCode;

use dzmls::{Event, Party};
use serde_json::{Value, json};

fn hex(b: &[u8]) -> String {
    b.iter().fold(String::new(), |mut s, x| {
        let _ = write!(s, "{x:02x}");
        s
    })
}

fn hexes(items: &[Vec<u8>]) -> Vec<String> {
    items.iter().map(|i| hex(i)).collect()
}

struct Dev {
    name: &'static str,
    id: Vec<u8>,
    state: Vec<u8>,
    signature_public_key: Vec<u8>,
    group: Vec<u8>,
}

struct Script {
    steps: Vec<Value>,
}

impl Script {
    fn push(&mut self, op: &str, input: Value, out: Value) {
        self.steps
            .push(json!({ "op": op, "in": input, "out": out }));
    }

    fn new_device(&mut self, name: &'static str, n: u8) -> Dev {
        let id = vec![n; 16];
        let d = dzmls::create_device(&id).expect("create_device");
        self.push(
            "create_device",
            json!({ "device": name, "device_id": hex(&id) }),
            json!({ "signature_public_key": hex(&d.signature_public_key) }),
        );
        Dev {
            name,
            id,
            state: d.device_state,
            signature_public_key: d.signature_public_key,
            group: Vec::new(),
        }
    }

    fn key_package(&mut self, dev: &mut Dev) -> Vec<u8> {
        let k = dzmls::generate_key_packages(&dev.state, 1, false).expect("generate_key_packages");
        dev.state = k.device_state;
        let kp = k.key_packages.into_iter().next().expect("one key package");
        self.push(
            "generate_key_packages",
            json!({ "device": dev.name }),
            json!({ "key_package": hex(&kp) }),
        );
        kp
    }

    fn join(&mut self, dev: &mut Dev, welcome: &[u8]) {
        let j = dzmls::join_from_welcome(&dev.state, welcome).expect("join_from_welcome");
        self.push(
            "join_from_welcome",
            json!({ "device": dev.name, "device_state": hex(&dev.state), "welcome": hex(welcome) }),
            json!({
                "group_id": hex(&j.group_id),
                "epoch": j.epoch,
                "members": members(&j.group_state),
            }),
        );
        dev.state = j.device_state;
        dev.group = j.group_state;
        self.describe(dev);
    }

    fn describe(&mut self, dev: &Dev) {
        let info = dzmls::describe(&dev.group).expect("describe");
        self.push(
            "describe",
            json!({ "device": dev.name, "group_state": hex(&dev.group) }),
            json!({
                "group_id": hex(&info.group_id),
                "epoch": info.epoch,
                "members": members(&dev.group),
                "has_pending_commit": info.has_pending_commit,
            }),
        );
    }

    /// `sender` encrypts `text`; every device in `receivers` processes it, and `wire_epoch` is recorded. Returns
    /// the wire bytes.
    fn message(&mut self, sender: &mut Dev, receivers: &mut [&mut Dev], text: &[u8]) -> Vec<u8> {
        let e = dzmls::encrypt(&sender.state, &sender.group, text).expect("encrypt");
        sender.group = e.group_state;
        self.push(
            "encrypt",
            json!({ "device": sender.name, "plaintext": hex(text) }),
            json!({ "wire": hex(&e.ciphertext), "epoch": e.epoch }),
        );
        self.wire_epoch(&e.ciphertext, e.epoch);
        for r in receivers.iter_mut() {
            self.process(r, &e.ciphertext);
        }
        e.ciphertext
    }

    fn wire_epoch(&mut self, wire: &[u8], epoch: u64) {
        self.push(
            "wire_epoch",
            json!({ "wire": hex(wire) }),
            json!({ "epoch": epoch }),
        );
    }

    /// `dev` processes `wire`, recording the full input blobs and the expected event, then moves to the new state.
    fn process(&mut self, dev: &mut Dev, wire: &[u8]) {
        let p = dzmls::process(&dev.state, &dev.group, wire).expect("process");
        let out = match &p.event {
            Event::Message {
                plaintext,
                sender_device_id,
            } => json!({
                "event": "message",
                "plaintext": hex(plaintext),
                "sender_device_id": hex(sender_device_id),
            }),
            Event::Commit {
                epoch,
                added,
                removed,
                self_removed,
                ..
            } => json!({
                "event": "commit",
                "epoch": epoch,
                "added": hexes(added),
                "removed": hexes(removed),
                "self_removed": self_removed,
            }),
        };
        self.push("process", process_input(dev, wire), out);
        dev.group = p.group_state;
    }

    /// A `process` call that must fail with `code`.
    fn process_error(&mut self, dev: &Dev, wire: &[u8], code: &str) {
        let e = dzmls::process(&dev.state, &dev.group, wire).expect_err("process must fail");
        assert_eq!(e.code.as_str(), code, "unexpected error code");
        self.push(
            "process",
            process_input(dev, wire),
            json!({ "error": code }),
        );
    }

    /// `committer` commits the change and confirms it; every device in `others` processes the commit. Returns the
    /// welcome, if the commit adds anyone.
    fn commit(
        &mut self,
        committer: &mut Dev,
        add: &[Vec<u8>],
        remove: &[Vec<u8>],
        others: &mut [&mut Dev],
    ) -> Option<Vec<u8>> {
        let c = dzmls::commit_change(&committer.state, &committer.group, add, remove)
            .expect("commit_change");
        self.push(
            "commit_change",
            json!({
                "device": committer.name,
                "add_key_packages": hexes(add),
                "remove_device_ids": hexes(remove),
            }),
            json!({
                "commit": hex(&c.commit),
                "welcome": c.welcome.as_deref().map(hex),
                "epoch": c.epoch,
            }),
        );
        committer.group = dzmls::confirm_commit(&committer.state, &c.group_state).expect("confirm");
        self.push(
            "confirm_commit",
            json!({ "device": committer.name }),
            json!({ "epoch": c.epoch }),
        );
        self.wire_epoch(&c.commit, c.epoch);
        for o in others.iter_mut() {
            self.process(o, &c.commit);
        }
        c.welcome
    }
}

fn process_input(dev: &Dev, wire: &[u8]) -> Value {
    json!({
        "device": dev.name,
        "device_state": hex(&dev.state),
        "group_state": hex(&dev.group),
        "wire": hex(wire),
    })
}

fn members(group_state: &[u8]) -> Value {
    let info = dzmls::describe(group_state).expect("describe");
    Value::Array(
        info.members
            .iter()
            .map(|m| {
                json!({
                    "device_id": hex(&m.device_id),
                    "signature_public_key": hex(&m.signature_public_key),
                })
            })
            .collect(),
    )
}

fn party_json(p: &Party) -> Value {
    json!({ "user_id": hex(&p.user_id), "device_keys": hexes(&p.device_keys) })
}

fn build() -> Value {
    let mut s = Script { steps: Vec::new() };
    let mut alice = s.new_device("alice", 1);
    let mut bob = s.new_device("bob", 2);
    let mut carol = s.new_device("carol", 3);

    let group_id = vec![0xAB; 32];
    alice.group = dzmls::create_group(&alice.state, &group_id).expect("create_group");
    s.push(
        "create_group",
        json!({ "device": "alice", "group_id": hex(&group_id) }),
        json!({}),
    );

    // Epoch 1: alice adds bob, then a message each way.
    let bob_kp = s.key_package(&mut bob);
    let welcome = s
        .commit(&mut alice, &[bob_kp], &[], &mut [])
        .expect("welcome for bob");
    s.join(&mut bob, &welcome);
    s.message(&mut alice, &mut [&mut bob], b"hello bob");
    s.message(&mut bob, &mut [&mut alice], b"hello alice");

    // Epoch 2: alice adds carol; bob processes the commit; one message to both.
    let carol_kp = s.key_package(&mut carol);
    let welcome = s
        .commit(&mut alice, &[carol_kp], &[], &mut [&mut bob])
        .expect("welcome for carol");
    s.join(&mut carol, &welcome);
    let wire = s.message(&mut alice, &mut [&mut bob, &mut carol], b"hello everyone");

    // Negative steps against bob's state, which has consumed `wire`: a replay, and garbage.
    s.process_error(&bob, &wire, "duplicate");
    s.process_error(&bob, &[0xde, 0xad, 0xbe, 0xef], "bad_input");
    s.push(
        "wire_epoch",
        json!({ "wire": hex(&[0xde, 0xad, 0xbe, 0xef]) }),
        json!({ "error": "bad_input" }),
    );

    // Epoch 3: alice removes bob. Carol sees it; bob learns he is out. One more message.
    let bob_id = bob.id.clone();
    s.commit(&mut alice, &[], &[bob_id], &mut [&mut carol, &mut bob]);
    s.message(&mut alice, &mut [&mut carol], b"bob is gone");

    s.describe(&alice);
    s.describe(&carol);

    let alice_pk = alice.signature_public_key.clone();
    let bob_pk = bob.signature_public_key.clone();
    let carol_pk = carol.signature_public_key.clone();
    let cases = [
        (
            Party {
                user_id: b"alice".to_vec(),
                device_keys: vec![alice_pk.clone()],
            },
            Party {
                user_id: b"bob".to_vec(),
                device_keys: vec![bob_pk.clone()],
            },
        ),
        // Unordered keys with a repeat on one side, a different pair of users.
        (
            Party {
                user_id: b"carol".to_vec(),
                device_keys: vec![carol_pk.clone(), alice_pk, carol_pk],
            },
            Party {
                user_id: b"bob".to_vec(),
                device_keys: vec![bob_pk],
            },
        ),
    ];
    for (a, b) in &cases {
        let code = dzmls::security_code(a, b).expect("security_code");
        s.push(
            "security_code",
            json!({ "a": party_json(a), "b": party_json(b) }),
            json!({ "code": code }),
        );
    }

    let final_states: serde_json::Map<String, Value> = [&alice, &bob, &carol]
        .into_iter()
        .map(|d| {
            (
                d.name.to_string(),
                json!({ "device_state": hex(&d.state), "group_state": hex(&d.group) }),
            )
        })
        .collect();

    json!({
        "version": 1,
        "device_ids": { "alice": hex(&alice.id), "bob": hex(&bob.id), "carol": hex(&carol.id) },
        "steps": s.steps,
        "final_states": final_states,
    })
}

fn main() -> ExitCode {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: dzmls_vectors <out.json>");
        return ExitCode::from(2);
    };
    let mut text = serde_json::to_string_pretty(&build()).expect("serialize");
    text.push('\n');
    match std::fs::write(&path, text) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cannot write {path}: {e}");
            ExitCode::FAILURE
        }
    }
}
