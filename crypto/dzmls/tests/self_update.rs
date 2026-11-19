mod common;

use common::{Dev, device, kp};

/// Members as (device id, signature public key) pairs, in `describe` order.
fn members(group_state: &[u8]) -> Vec<(Vec<u8>, Vec<u8>)> {
    dzmls::describe(group_state)
        .unwrap()
        .members
        .into_iter()
        .map(|m| (m.device_id, m.signature_public_key))
        .collect()
}

fn epoch(group_state: &[u8]) -> u64 {
    dzmls::describe(group_state).unwrap().epoch
}

fn code<T>(r: Result<T, dzmls::MlsError>) -> &'static str {
    match r {
        Ok(_) => panic!("expected an error"),
        Err(e) => e.code.as_str(),
    }
}

/// alice creates a group and adds bob; both end at epoch 1. Returns (alice's, bob's) group states.
fn pair(alice: &Dev, bob: &mut Dev) -> (Vec<u8>, Vec<u8>) {
    let g = dzmls::create_group(&alice.state, &[0xAB; 32]).unwrap();
    let c = dzmls::commit_change(&alice.state, &g, &[kp(bob)], &[]).unwrap();
    let a = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let j = dzmls::join_from_welcome(&bob.state, &c.welcome.unwrap()).unwrap();
    bob.state = j.device_state;
    (a, j.group_state)
}

/// `from` encrypts `text` on `from_group`; `to` decrypts it on `to_group`. Returns both new group states.
fn exchange(
    from: &Dev,
    from_group: &[u8],
    to: &Dev,
    to_group: &[u8],
    text: &[u8],
) -> (Vec<u8>, Vec<u8>) {
    let e = dzmls::encrypt(&from.state, from_group, text).unwrap();
    let p = dzmls::process(&to.state, to_group, &e.ciphertext).unwrap();
    match p.event {
        dzmls::Event::Message {
            plaintext,
            sender_device_id,
        } => {
            assert_eq!(plaintext, text);
            assert_eq!(sender_device_id, from.id);
        }
        dzmls::Event::Commit { .. } => panic!("expected an application message"),
    }
    (e.group_state, p.group_state)
}

/// Processes a commit and asserts it is an empty one (no adds, no removes) moving to `want_epoch`.
fn process_empty_commit(dev: &Dev, group_state: &[u8], commit: &[u8], want_epoch: u64) -> Vec<u8> {
    let p = dzmls::process(&dev.state, group_state, commit).unwrap();
    match p.event {
        dzmls::Event::Commit {
            epoch,
            added,
            removed,
            self_removed,
            ..
        } => {
            assert_eq!(epoch, want_epoch);
            assert!(added.is_empty());
            assert!(removed.is_empty());
            assert!(!self_removed);
        }
        dzmls::Event::Message { .. } => panic!("expected a commit"),
    }
    p.group_state
}

#[test]
fn self_update_is_pending_then_confirms_to_the_next_epoch() {
    let alice = device(1);
    let mut bob = device(2);
    let (a, _) = pair(&alice, &mut bob);
    let before = members(&a);
    assert_eq!(
        before,
        [
            (alice.id.clone(), alice.signature_public_key.clone()),
            (bob.id.clone(), bob.signature_public_key.clone()),
        ]
    );

    let c = dzmls::self_update(&alice.state, &a).unwrap();
    assert_eq!(c.epoch, 1);
    assert!(c.welcome.is_none());
    let pending = dzmls::describe(&c.group_state).unwrap();
    assert!(pending.has_pending_commit);
    assert_eq!(pending.epoch, 1);

    let a2 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let info = dzmls::describe(&a2).unwrap();
    assert_eq!(info.epoch, 2);
    assert!(!info.has_pending_commit);
    // Same device ids and the same signature keys: only the leaf encryption key changed.
    assert_eq!(members(&a2), before);
}

#[test]
fn the_own_self_update_commit_is_own_leaf() {
    let alice = device(1);
    let mut bob = device(2);
    let (a, _) = pair(&alice, &mut bob);
    let c = dzmls::self_update(&alice.state, &a).unwrap();
    assert_eq!(
        code(dzmls::process(&alice.state, &c.group_state, &c.commit)),
        "own_leaf"
    );
}

#[test]
fn receivers_see_an_empty_commit_and_keep_talking() {
    let alice = device(1);
    let mut bob = device(2);
    let (a, b) = pair(&alice, &mut bob);
    let c = dzmls::self_update(&alice.state, &a).unwrap();
    let a2 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let b2 = process_empty_commit(&bob, &b, &c.commit, 2);
    assert_eq!(members(&b2), members(&a2));

    let (a3, b3) = exchange(&alice, &a2, &bob, &b2, b"after alice's update");
    let (b4, a4) = exchange(&bob, &b3, &alice, &a3, b"bob answers");
    assert_eq!((epoch(&a4), epoch(&b4)), (2, 2));
}

#[test]
fn self_update_follows_the_commit_rules() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let (a, b) = pair(&alice, &mut bob);
    let c = dzmls::self_update(&alice.state, &a).unwrap();

    // While pending: no second commit of either kind, no encrypt.
    assert_eq!(
        code(dzmls::self_update(&alice.state, &c.group_state)),
        "pending_commit"
    );
    assert_eq!(
        code(dzmls::commit_change(
            &alice.state,
            &c.group_state,
            &[kp(&mut carol)],
            &[]
        )),
        "pending_commit"
    );
    assert_eq!(
        code(dzmls::encrypt(&alice.state, &c.group_state, b"x")),
        "pending_commit"
    );

    // Discarded: back at epoch 1, same members, and the group still works both ways.
    let g = dzmls::discard_commit(&alice.state, &c.group_state).unwrap();
    let info = dzmls::describe(&g).unwrap();
    assert_eq!(info.epoch, 1);
    assert!(!info.has_pending_commit);
    assert_eq!(members(&g), members(&a));
    let (g, b) = exchange(&alice, &g, &bob, &b, b"after discard");
    let (b, g) = exchange(&bob, &b, &alice, &g, b"still here");
    // And it can self-update again, which bob follows.
    let again = dzmls::self_update(&alice.state, &g).unwrap();
    assert_eq!(again.epoch, 1);
    dzmls::confirm_commit(&alice.state, &again.group_state).unwrap();
    process_empty_commit(&bob, &b, &again.commit, 2);

    // Wrong device blob: refused on the binding, before the pending-commit rule.
    for other in [&bob, &carol] {
        assert_eq!(code(dzmls::self_update(&other.state, &a)), "corrupt_state");
        assert_eq!(
            code(dzmls::self_update(&other.state, &c.group_state)),
            "corrupt_state"
        );
    }

    // Evicted: alice removes bob; bob's processed group refuses a self-update, whichever device blob comes with it.
    let r = dzmls::commit_change(&alice.state, &a, &[], &[bob.id.clone()]).unwrap();
    let gone = dzmls::process(&bob.state, &b, &r.commit)
        .unwrap()
        .group_state;
    for dev in [&bob, &carol] {
        assert_eq!(code(dzmls::self_update(&dev.state, &gone)), "evicted");
    }
}

#[test]
fn racing_self_updates_loser_recovers() {
    let alice = device(1);
    let mut bob = device(2);
    let (a, b) = pair(&alice, &mut bob);
    let ca = dzmls::self_update(&alice.state, &a).unwrap();
    let cb = dzmls::self_update(&bob.state, &b).unwrap();
    assert_eq!((ca.epoch, cb.epoch), (1, 1));

    // The server accepts alice's commit. Bob processes it on his pending state: his own commit lost and is dropped.
    let a2 = dzmls::confirm_commit(&alice.state, &ca.group_state).unwrap();
    let b2 = process_empty_commit(&bob, &cb.group_state, &ca.commit, 2);
    assert!(!dzmls::describe(&b2).unwrap().has_pending_commit);

    // Bob self-updates again on epoch 2; alice follows.
    let retry = dzmls::self_update(&bob.state, &b2).unwrap();
    assert_eq!(retry.epoch, 2);
    let b3 = dzmls::confirm_commit(&bob.state, &retry.group_state).unwrap();
    let a3 = process_empty_commit(&alice, &a2, &retry.commit, 3);
    assert_eq!(members(&a3), members(&b3));
    exchange(&bob, &b3, &alice, &a3, b"recovered");
}

#[test]
fn a_new_member_can_join_after_everyone_self_updated() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let (a, b) = pair(&alice, &mut bob);

    let ca = dzmls::self_update(&alice.state, &a).unwrap();
    let a = dzmls::confirm_commit(&alice.state, &ca.group_state).unwrap();
    let b = process_empty_commit(&bob, &b, &ca.commit, 2);
    let cb = dzmls::self_update(&bob.state, &b).unwrap();
    let b = dzmls::confirm_commit(&bob.state, &cb.group_state).unwrap();
    let a = process_empty_commit(&alice, &a, &cb.commit, 3);

    let add = dzmls::commit_change(&alice.state, &a, &[kp(&mut carol)], &[]).unwrap();
    let a = dzmls::confirm_commit(&alice.state, &add.group_state).unwrap();
    let p = dzmls::process(&bob.state, &b, &add.commit).unwrap();
    let b = p.group_state;
    let j = dzmls::join_from_welcome(&carol.state, &add.welcome.unwrap()).unwrap();
    carol.state = j.device_state;
    let c = j.group_state;
    assert_eq!(j.epoch, 4);
    assert_eq!(members(&c), members(&a));
    assert_eq!(members(&b), members(&a));

    // Everyone sends one message; the other two read it.
    let mut groups = [a, b, c];
    let devs = [&alice, &bob, &carol];
    for sender in 0..3 {
        let text = format!("hello from {sender}");
        let e = dzmls::encrypt(&devs[sender].state, &groups[sender], text.as_bytes()).unwrap();
        groups[sender] = e.group_state;
        for reader in (0..3).filter(|&r| r != sender) {
            let p = dzmls::process(&devs[reader].state, &groups[reader], &e.ciphertext).unwrap();
            let dzmls::Event::Message { plaintext, .. } = p.event else {
                panic!("expected an application message");
            };
            assert_eq!(plaintext, text.as_bytes());
            groups[reader] = p.group_state;
        }
    }
}
