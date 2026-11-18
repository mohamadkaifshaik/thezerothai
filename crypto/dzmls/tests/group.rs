mod common;

use common::{Dev, device, kp, last_resort_kp};

fn gid(n: u8) -> Vec<u8> {
    vec![n; 32]
}

/// Device ids of the group's members, in `describe` order.
fn member_ids(group_state: &[u8]) -> Vec<Vec<u8>> {
    dzmls::describe(group_state)
        .unwrap()
        .members
        .into_iter()
        .map(|m| m.device_id)
        .collect()
}

/// Members as (device id, signature public key) pairs, in `describe` order.
fn members(group_state: &[u8]) -> Vec<(Vec<u8>, Vec<u8>)> {
    dzmls::describe(group_state)
        .unwrap()
        .members
        .into_iter()
        .map(|m| (m.device_id, m.signature_public_key))
        .collect()
}

/// `creator` creates a group and adds `others` in one commit; everyone joins. Returns each member's group state,
/// creator first, all at epoch 1.
fn group_of(creator: &Dev, others: &mut [&mut Dev], group_id: &[u8]) -> Vec<Vec<u8>> {
    let g = dzmls::create_group(&creator.state, group_id).unwrap();
    let kps: Vec<Vec<u8>> = others.iter_mut().map(|d| kp(d)).collect();
    let c = dzmls::commit_change(&creator.state, &g, &kps, &[]).unwrap();
    let welcome = c.welcome.unwrap();
    let mut states = vec![dzmls::confirm_commit(&creator.state, &c.group_state).unwrap()];
    for d in others.iter_mut() {
        let j = dzmls::join_from_welcome(&d.state, &welcome).unwrap();
        d.state = j.device_state;
        states.push(j.group_state);
    }
    states
}

#[test]
fn create_then_describe() {
    let alice = device(1);
    let g = dzmls::create_group(&alice.state, &gid(1)).unwrap();
    let info = dzmls::describe(&g).unwrap();
    assert_eq!(info.group_id, gid(1));
    assert_eq!(info.epoch, 0);
    assert_eq!(
        members(&g),
        [(alice.id.clone(), alice.signature_public_key.clone())]
    );
    assert!(!info.has_pending_commit);
}

#[test]
fn group_id_length_is_enforced() {
    let alice = device(1);
    for len in [15, 65] {
        assert_eq!(
            dzmls::create_group(&alice.state, &vec![1; len])
                .unwrap_err()
                .code
                .as_str(),
            "bad_input"
        );
    }
}

#[test]
fn add_confirm_join_agree_on_epoch_and_members() {
    let alice = device(1);
    let mut bob = device(2);
    let g = dzmls::create_group(&alice.state, &gid(1)).unwrap();
    let c = dzmls::commit_change(&alice.state, &g, &[kp(&mut bob)], &[]).unwrap();
    assert_eq!(c.epoch, 0);
    assert!(c.welcome.is_some());
    assert!(dzmls::describe(&c.group_state).unwrap().has_pending_commit);

    let a1 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let alice_info = dzmls::describe(&a1).unwrap();
    assert_eq!(alice_info.epoch, 1);
    assert!(!alice_info.has_pending_commit);

    let j = dzmls::join_from_welcome(&bob.state, c.welcome.as_ref().unwrap()).unwrap();
    assert_eq!(j.epoch, 1);
    assert_eq!(j.group_id, gid(1));
    assert_eq!(dzmls::describe(&j.group_state).unwrap().group_id, gid(1));
    let both = vec![
        (alice.id.clone(), alice.signature_public_key.clone()),
        (bob.id.clone(), bob.signature_public_key.clone()),
    ];
    assert_eq!(members(&a1), both);
    assert_eq!(members(&j.group_state), both);
}

#[test]
fn join_consumes_one_time_key_package_but_not_last_resort() {
    let alice = device(1);
    let mut bob = device(2);
    let g = dzmls::create_group(&alice.state, &gid(1)).unwrap();
    let c = dzmls::commit_change(&alice.state, &g, &[kp(&mut bob)], &[]).unwrap();
    let welcome = c.welcome.unwrap();
    let j1 = dzmls::join_from_welcome(&bob.state, &welcome).unwrap();
    // The second join uses the device state the first one returned, which no longer holds the one-time package.
    assert_eq!(
        dzmls::join_from_welcome(&j1.device_state, &welcome)
            .unwrap_err()
            .code
            .as_str(),
        "bad_input"
    );

    let mut carol = device(3);
    let g = dzmls::create_group(&alice.state, &gid(2)).unwrap();
    let c = dzmls::commit_change(&alice.state, &g, &[last_resort_kp(&mut carol)], &[]).unwrap();
    let welcome = c.welcome.unwrap();
    let j1 = dzmls::join_from_welcome(&carol.state, &welcome).unwrap();
    let j2 = dzmls::join_from_welcome(&j1.device_state, &welcome).unwrap();
    assert_eq!(j1.epoch, 1);
    assert_eq!(j2.epoch, 1);
}

#[test]
fn add_and_remove_in_one_commit() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let mut dave = device(4);
    let states = group_of(&alice, &mut [&mut bob, &mut carol], &gid(1));
    assert_eq!(
        member_ids(&states[0]),
        [alice.id.clone(), bob.id.clone(), carol.id.clone()]
    );

    let c = dzmls::commit_change(
        &alice.state,
        &states[0],
        &[kp(&mut dave)],
        &[bob.id.clone()],
    )
    .unwrap();
    assert_eq!(c.epoch, 1);
    let a2 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    assert_eq!(dzmls::describe(&a2).unwrap().epoch, 2);
    assert_eq!(member_ids(&a2), [alice.id, carol.id, dave.id.clone()]);
    let j = dzmls::join_from_welcome(&dave.state, &c.welcome.unwrap()).unwrap();
    assert_eq!(j.epoch, 2);
    assert_eq!(member_ids(&j.group_state), member_ids(&a2));
}

#[test]
fn second_commit_while_pending_is_refused() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let g = dzmls::create_group(&alice.state, &gid(1)).unwrap();
    let c = dzmls::commit_change(&alice.state, &g, &[kp(&mut bob)], &[]).unwrap();
    assert_eq!(
        dzmls::commit_change(&alice.state, &c.group_state, &[kp(&mut carol)], &[])
            .unwrap_err()
            .code
            .as_str(),
        "pending_commit"
    );
}

#[test]
fn confirm_and_discard_need_a_pending_commit() {
    let alice = device(1);
    let g = dzmls::create_group(&alice.state, &gid(1)).unwrap();
    assert_eq!(
        dzmls::confirm_commit(&alice.state, &g)
            .unwrap_err()
            .code
            .as_str(),
        "no_pending_commit"
    );
    assert_eq!(
        dzmls::discard_commit(&alice.state, &g)
            .unwrap_err()
            .code
            .as_str(),
        "no_pending_commit"
    );
}

#[test]
fn discard_restores_a_usable_pre_commit_group() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let mut dave = device(4);
    let states = group_of(&alice, &mut [&mut bob], &gid(1));
    let before = dzmls::describe(&states[0]).unwrap();

    let c = dzmls::commit_change(&alice.state, &states[0], &[kp(&mut carol)], &[]).unwrap();
    let g = dzmls::discard_commit(&alice.state, &c.group_state).unwrap();
    let after = dzmls::describe(&g).unwrap();
    assert_eq!(after.epoch, before.epoch);
    assert_eq!(members(&g), members(&states[0]));
    assert!(!after.has_pending_commit);

    let fresh = dzmls::commit_change(&alice.state, &g, &[kp(&mut dave)], &[]).unwrap();
    assert_eq!(fresh.epoch, before.epoch);

    // encrypt on g succeeds and the other member decrypts it.
    let e = dzmls::encrypt(&alice.state, &g, b"after discard").unwrap();
    let p = dzmls::process(&bob.state, &states[1], &e.ciphertext).unwrap();
    match p.event {
        dzmls::Event::Message {
            plaintext,
            sender_device_id,
        } => {
            assert_eq!(plaintext, b"after discard");
            assert_eq!(sender_device_id, alice.id);
        }
        _ => panic!("expected an application message"),
    }
}

#[test]
fn bad_removals_are_refused() {
    let alice = device(1);
    let mut bob = device(2);
    let states = group_of(&alice, &mut [&mut bob], &gid(1));
    let stranger = device(9);
    for remove in [stranger.id, alice.id.clone()] {
        assert_eq!(
            dzmls::commit_change(&alice.state, &states[0], &[], &[remove])
                .unwrap_err()
                .code
                .as_str(),
            "bad_input"
        );
    }
}

#[test]
fn empty_commit_is_refused() {
    let alice = device(1);
    let g = dzmls::create_group(&alice.state, &gid(1)).unwrap();
    assert_eq!(
        dzmls::commit_change(&alice.state, &g, &[], &[])
            .unwrap_err()
            .code
            .as_str(),
        "bad_input"
    );
}

#[test]
fn garbage_key_package_and_welcome_are_bad_input() {
    let alice = device(1);
    let g = dzmls::create_group(&alice.state, &gid(1)).unwrap();
    for garbage in [vec![], vec![0u8; 7], vec![0u8; 65_537]] {
        assert_eq!(
            dzmls::commit_change(&alice.state, &g, std::slice::from_ref(&garbage), &[])
                .unwrap_err()
                .code
                .as_str(),
            "bad_input"
        );
        assert_eq!(
            dzmls::join_from_welcome(&alice.state, &garbage)
                .unwrap_err()
                .code
                .as_str(),
            "bad_input"
        );
    }
}

#[test]
fn racing_commits_loser_recovers() {
    // Review Focus 4.
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let mut dave = device(4);
    let states = group_of(&alice, &mut [&mut bob], &gid(1));
    assert_eq!(dzmls::describe(&states[0]).unwrap().epoch, 1);
    assert_eq!(dzmls::describe(&states[1]).unwrap().epoch, 1);

    // Both commit on epoch 1.
    let ca = dzmls::commit_change(&alice.state, &states[0], &[kp(&mut carol)], &[]).unwrap();
    let dave_kp = kp(&mut dave);
    let cb =
        dzmls::commit_change(&bob.state, &states[1], std::slice::from_ref(&dave_kp), &[]).unwrap();
    assert_eq!(ca.epoch, 1);
    assert_eq!(cb.epoch, 1);

    // The "server" accepts alice's commit and refuses bob's.
    let a2 = dzmls::confirm_commit(&alice.state, &ca.group_state).unwrap();
    assert_eq!(dzmls::describe(&a2).unwrap().epoch, 2);
    let b1 = dzmls::discard_commit(&bob.state, &cb.group_state).unwrap();
    let p = dzmls::process(&bob.state, &b1, &ca.commit).unwrap();
    assert_eq!(dzmls::describe(&p.group_state).unwrap().epoch, 2);

    // Bob retries his add on epoch 2.
    let retry = dzmls::commit_change(&bob.state, &p.group_state, &[dave_kp], &[]).unwrap();
    assert_eq!(retry.epoch, 2);
}
