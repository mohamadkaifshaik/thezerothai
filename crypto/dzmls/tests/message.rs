mod common;

use common::{Dev, device, kp};
use dzmls::{Event, MlsError, Processed};

fn gid(n: u8) -> Vec<u8> {
    vec![n; 32]
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

fn code<T>(r: Result<T, MlsError>) -> &'static str {
    match r {
        Ok(_) => panic!("expected an error"),
        Err(e) => e.code.as_str(),
    }
}

/// The application message carried by `p`: (plaintext, sender device id).
fn message(p: &Processed) -> (&[u8], &[u8]) {
    match &p.event {
        Event::Message {
            plaintext,
            sender_device_id,
        } => (plaintext, sender_device_id),
        Event::Commit { .. } => panic!("expected an application message"),
    }
}

/// The commit carried by `p`: (epoch, added, removed, self_removed).
fn commit(p: &Processed) -> (u64, &[Vec<u8>], &[Vec<u8>], bool) {
    match &p.event {
        Event::Commit {
            epoch,
            added,
            removed,
            self_removed,
        } => (*epoch, added, removed, *self_removed),
        Event::Message { .. } => panic!("expected a commit"),
    }
}

#[test]
fn roundtrip_and_sender_id() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let e = dzmls::encrypt(&alice.state, &s[0], b"hello").unwrap();
    assert_eq!(e.epoch, 1);
    let p = dzmls::process(&bob.state, &s[1], &e.ciphertext).unwrap();
    assert_eq!(message(&p), (&b"hello"[..], &alice.id[..]));
    assert_eq!(dzmls::describe(&p.group_state).unwrap().epoch, 1);
}

#[test]
fn ciphertext_length_hides_plaintext_length() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let len = |n: usize| {
        dzmls::encrypt(&alice.state, &s[0], &vec![b'x'; n])
            .unwrap()
            .ciphertext
            .len()
    };
    assert_eq!(len(1), len(200));
    assert_eq!(len(0), len(255));
    assert!(len(256) > len(200));
}

#[test]
fn plaintext_ending_in_zero_bytes_survives_padding() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let (mut a, mut b) = (s[0].clone(), s[1].clone());
    for plaintext in [&b"a\x00\x00"[..], b"", b"\x80", &[0u8; 255], &[0x80; 256]] {
        let e = dzmls::encrypt(&alice.state, &a, plaintext).unwrap();
        a = e.group_state;
        let p = dzmls::process(&bob.state, &b, &e.ciphertext).unwrap();
        assert_eq!(message(&p).0, plaintext);
        b = p.group_state;
    }
}

#[test]
fn plaintext_over_4096_bytes_is_refused() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    assert_eq!(
        code(dzmls::encrypt(&alice.state, &s[0], &[1; 4097])),
        "bad_input"
    );
    let e = dzmls::encrypt(&alice.state, &s[0], &[1; 4096]).unwrap();
    let p = dzmls::process(&bob.state, &s[1], &e.ciphertext).unwrap();
    assert_eq!(message(&p).0, &[1; 4096][..]);
}

#[test]
fn out_of_order_within_epoch_is_tolerated() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let mut a = s[0].clone();
    let mut wires = Vec::new();
    for m in [b"m1", b"m2", b"m3"] {
        let e = dzmls::encrypt(&alice.state, &a, m).unwrap();
        a = e.group_state;
        wires.push(e.ciphertext);
    }
    let mut b = s[1].clone();
    for (i, want) in [(2, b"m3"), (0, b"m1"), (1, b"m2")] {
        let p = dzmls::process(&bob.state, &b, &wires[i]).unwrap();
        assert_eq!(message(&p).0, want);
        b = p.group_state;
    }
}

#[test]
fn replay_is_duplicate() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let e = dzmls::encrypt(&alice.state, &s[0], b"once").unwrap();
    let p = dzmls::process(&bob.state, &s[1], &e.ciphertext).unwrap();
    assert_eq!(
        code(dzmls::process(&bob.state, &p.group_state, &e.ciphertext)),
        "duplicate"
    );
}

#[test]
fn more_than_50_generations_late_is_duplicate_and_1000_ahead_is_bad_input() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let mut a = s[0].clone();
    let mut wires = Vec::new();
    for _ in 0..1002 {
        let e = dzmls::encrypt(&alice.state, &a, b"x").unwrap();
        a = e.group_state;
        wires.push(e.ciphertext);
    }
    // Generation 1001 is more than 1000 ahead of bob's ratchet at generation 0.
    assert_eq!(
        code(dzmls::process(&bob.state, &s[1], &wires[1001])),
        "bad_input"
    );
    // After generation 51 the ratchet head is at 52, so generations 0 and 1 are more than 50 behind.
    let p = dzmls::process(&bob.state, &s[1], &wires[51]).unwrap();
    assert_eq!(
        code(dzmls::process(&bob.state, &p.group_state, &wires[0])),
        "duplicate"
    );
    assert_eq!(
        code(dzmls::process(&bob.state, &p.group_state, &wires[1])),
        "duplicate"
    );
    // Generation 2 is exactly 50 behind and still decrypts.
    let p = dzmls::process(&bob.state, &p.group_state, &wires[2]).unwrap();
    assert_eq!(message(&p).0, b"x");
}

#[test]
fn own_message_echoed_back_is_duplicate() {
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let e = dzmls::encrypt(&alice.state, &s[0], b"mine").unwrap();
    assert_eq!(
        code(dzmls::process(&alice.state, &e.group_state, &e.ciphertext)),
        "duplicate"
    );
}

#[test]
fn reprocessing_from_the_old_state_succeeds_again() {
    // Review Focus 1: the engine is a pure function, so a crash before the new state is persisted is recovered by
    // processing the same wire against the same old state.
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let e = dzmls::encrypt(&alice.state, &s[0], b"again").unwrap();
    let p1 = dzmls::process(&bob.state, &s[1], &e.ciphertext).unwrap();
    let p2 = dzmls::process(&bob.state, &s[1], &e.ciphertext).unwrap();
    assert_eq!(message(&p1), message(&p2));
    assert_eq!(message(&p1).0, b"again");
    // assert! rather than assert_eq!, so a failure does not print state bytes.
    assert!(p1.group_state == p2.group_state, "group states differ");

    // A commit reprocessed from the old state gives the same event and an equivalent group. The blobs are not
    // byte-equal: OpenMLS stamps the new epoch's message secrets with the wall-clock time of the merge.
    let c = dzmls::commit_change(&alice.state, &e.group_state, &[kp(&mut carol)], &[]).unwrap();
    let a2 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let c1 = dzmls::process(&bob.state, &p1.group_state, &c.commit).unwrap();
    let c2 = dzmls::process(&bob.state, &p1.group_state, &c.commit).unwrap();
    assert_eq!(commit(&c1), commit(&c2));
    let next = dzmls::encrypt(&alice.state, &a2, b"next epoch").unwrap();
    for g in [&c1.group_state, &c2.group_state] {
        let info = dzmls::describe(g).unwrap();
        assert_eq!(info.epoch, 2);
        assert_eq!(info.members.len(), 3);
        let m = dzmls::process(&bob.state, g, &next.ciphertext).unwrap();
        assert_eq!(message(&m), (&b"next epoch"[..], &alice.id[..]));
    }
}

#[test]
fn commit_is_reported_with_added_and_removed() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let mut dave = device(4);
    let s = group_of(&alice, &mut [&mut bob, &mut dave], &gid(1));
    let c = dzmls::commit_change(&alice.state, &s[0], &[kp(&mut carol)], &[]).unwrap();
    let p = dzmls::process(&bob.state, &s[1], &c.commit).unwrap();
    assert_eq!(commit(&p), (2, &[carol.id.clone()][..], &[][..], false));
    assert_eq!(dzmls::describe(&p.group_state).unwrap().epoch, 2);

    // A commit that adds and removes reports both.
    let mut erin = device(5);
    let a2 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let c2 = dzmls::commit_change(&alice.state, &a2, &[kp(&mut erin)], &[dave.id.clone()]).unwrap();
    let p2 = dzmls::process(&bob.state, &p.group_state, &c2.commit).unwrap();
    assert_eq!(
        commit(&p2),
        (3, &[erin.id.clone()][..], &[dave.id.clone()][..], false)
    );
}

#[test]
fn removed_member_gets_self_removed_then_evicted() {
    // Review Focus 5.
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let s = group_of(&alice, &mut [&mut bob, &mut carol], &gid(1));
    let c = dzmls::commit_change(&alice.state, &s[0], &[], &[bob.id.clone()]).unwrap();
    let a2 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let p = dzmls::process(&bob.state, &s[1], &c.commit).unwrap();
    assert_eq!(commit(&p), (2, &[][..], &[bob.id.clone()][..], true));

    let later = dzmls::encrypt(&alice.state, &a2, b"after removal").unwrap();
    assert_eq!(
        code(dzmls::process(
            &bob.state,
            &p.group_state,
            &later.ciphertext
        )),
        "evicted"
    );
    assert_eq!(
        code(dzmls::encrypt(&bob.state, &p.group_state, b"still here?")),
        "evicted"
    );
    // The evicted blob still describes: at the commit's epoch, as last seen by bob.
    let info = dzmls::describe(&p.group_state).unwrap();
    assert_eq!(info.epoch, 2);
    assert!(!info.has_pending_commit);
    // carol, still a member, reads the later message.
    let pc = dzmls::process(&carol.state, &s[2], &c.commit).unwrap();
    assert!(!commit(&pc).3);
    let m = dzmls::process(&carol.state, &pc.group_state, &later.ciphertext).unwrap();
    assert_eq!(message(&m).0, b"after removal");
}

#[test]
fn message_from_before_join_is_wrong_epoch() {
    // Review Focus 5.
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let m = dzmls::encrypt(&alice.state, &s[0], b"before carol").unwrap();
    assert_eq!(m.epoch, 1);
    let c = dzmls::commit_change(&alice.state, &m.group_state, &[kp(&mut carol)], &[]).unwrap();
    dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let j = dzmls::join_from_welcome(&carol.state, &c.welcome.unwrap()).unwrap();
    assert_eq!(j.epoch, 2);
    assert_eq!(
        code(dzmls::process(
            &j.device_state,
            &j.group_state,
            &m.ciphertext
        )),
        "wrong_epoch"
    );
}

#[test]
fn stale_epoch_message_after_commit_is_wrong_epoch() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let m = dzmls::encrypt(&alice.state, &s[0], b"epoch one").unwrap();
    let c = dzmls::commit_change(&alice.state, &m.group_state, &[kp(&mut carol)], &[]).unwrap();
    let a2 = dzmls::confirm_commit(&alice.state, &c.group_state).unwrap();
    let p = dzmls::process(&bob.state, &s[1], &c.commit).unwrap();
    assert_eq!(commit(&p).0, 2);
    assert_eq!(
        code(dzmls::process(&bob.state, &p.group_state, &m.ciphertext)),
        "wrong_epoch"
    );
    // A replayed commit is also from an epoch bob has left.
    assert_eq!(
        code(dzmls::process(&bob.state, &p.group_state, &c.commit)),
        "wrong_epoch"
    );
    // A message from an epoch bob has not reached yet is wrong_epoch too.
    let ahead = dzmls::encrypt(&alice.state, &a2, b"epoch two").unwrap();
    assert_eq!(ahead.epoch, 2);
    assert_eq!(
        code(dzmls::process(&bob.state, &s[1], &ahead.ciphertext)),
        "wrong_epoch"
    );
}

#[test]
fn hostile_wire_is_bad_input_and_changes_nothing() {
    // Review Focus 3.
    let alice = device(1);
    let mut bob = device(2);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    // The same two devices share a second group; its messages must not be accepted against the first.
    let other = group_of(&alice, &mut [&mut bob], &gid(2));
    let foreign = dzmls::encrypt(&alice.state, &other[0], b"other group").unwrap();
    let mut random = vec![0u8; 300];
    let mut x: u32 = 0x9E37_79B9;
    for byte in random.iter_mut() {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        *byte = x.to_le_bytes()[0];
    }
    let valid = dzmls::encrypt(&alice.state, &s[0], b"still fine").unwrap();
    let welcome = {
        let mut carol = device(3);
        dzmls::commit_change(&alice.state, &s[0], &[kp(&mut carol)], &[])
            .unwrap()
            .welcome
            .unwrap()
    };
    for wire in [
        vec![],
        vec![0u8; 7],
        random,
        vec![0u8; 1_048_576],
        foreign.ciphertext,
        welcome,
    ] {
        assert_eq!(code(dzmls::process(&bob.state, &s[1], &wire)), "bad_input");
        // The pure API returned no state, and the old state still processes a valid message.
        let p = dzmls::process(&bob.state, &s[1], &valid.ciphertext).unwrap();
        assert_eq!(message(&p).0, b"still fine");
    }
    // A valid message one byte over the cap is refused before parsing.
    let mut oversized = valid.ciphertext.clone();
    oversized.resize(65_537, 0);
    assert_eq!(
        code(dzmls::process(&bob.state, &s[1], &oversized)),
        "bad_input"
    );
    // Flipping a ciphertext byte fails decryption.
    let mut tampered = valid.ciphertext.clone();
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    assert_eq!(
        code(dzmls::process(&bob.state, &s[1], &tampered)),
        "bad_input"
    );
}

#[test]
fn wire_epoch_reads_header() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let e = dzmls::encrypt(&alice.state, &s[0], b"hi").unwrap();
    assert_eq!(dzmls::wire_epoch(&e.ciphertext).unwrap(), e.epoch);
    let c = dzmls::commit_change(&alice.state, &e.group_state, &[kp(&mut carol)], &[]).unwrap();
    assert_eq!(dzmls::wire_epoch(&c.commit).unwrap(), c.epoch);
    for garbage in [vec![], vec![0u8; 7], vec![0u8; 65_537], c.welcome.unwrap()] {
        assert_eq!(code(dzmls::wire_epoch(&garbage)), "bad_input");
    }
}

#[test]
fn encrypt_with_pending_commit_is_refused() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let c = dzmls::commit_change(&alice.state, &s[0], &[kp(&mut carol)], &[]).unwrap();
    assert_eq!(
        code(dzmls::encrypt(&alice.state, &c.group_state, b"wait")),
        "pending_commit"
    );
}

#[test]
fn messages_process_while_a_commit_is_pending_and_a_winning_commit_clears_it() {
    let alice = device(1);
    let mut bob = device(2);
    let mut carol = device(3);
    let mut dave = device(4);
    let s = group_of(&alice, &mut [&mut bob], &gid(1));
    let cb = dzmls::commit_change(&bob.state, &s[1], &[kp(&mut dave)], &[]).unwrap();
    let e = dzmls::encrypt(&alice.state, &s[0], b"while pending").unwrap();
    let p = dzmls::process(&bob.state, &cb.group_state, &e.ciphertext).unwrap();
    assert_eq!(message(&p).0, b"while pending");
    assert!(dzmls::describe(&p.group_state).unwrap().has_pending_commit);

    // alice's commit for the same epoch won: processing it supersedes bob's pending commit.
    let ca = dzmls::commit_change(&alice.state, &e.group_state, &[kp(&mut carol)], &[]).unwrap();
    let pc = dzmls::process(&bob.state, &p.group_state, &ca.commit).unwrap();
    assert_eq!(commit(&pc).0, 2);
    let info = dzmls::describe(&pc.group_state).unwrap();
    assert_eq!(info.epoch, 2);
    assert!(!info.has_pending_commit);
}
