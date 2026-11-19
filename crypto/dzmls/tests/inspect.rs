mod common;

use common::{device, kp, last_resort_kp};
use dzmls::{ErrorCode, MlsError};

fn code<T>(r: Result<T, MlsError>) -> ErrorCode {
    match r {
        Ok(_) => panic!("expected an error"),
        Err(e) => e.code,
    }
}

#[test]
fn inspects_one_time_and_last_resort_packages() {
    let mut alice = device(1);
    for package in [kp(&mut alice), last_resort_kp(&mut alice)] {
        let info = dzmls::inspect_key_package(&package).unwrap();
        assert_eq!(info.device_id, alice.id);
        assert_eq!(info.signature_public_key, alice.signature_public_key);
    }
}

#[test]
fn rejects_a_flipped_byte() {
    let mut alice = device(1);
    let package = kp(&mut alice);
    // The last bytes are the signature over everything before them.
    let mut bad = package.clone();
    *bad.last_mut().unwrap() ^= 0x01;
    assert_eq!(code(dzmls::inspect_key_package(&bad)), ErrorCode::BadInput);
    // A byte in the middle (key material or lengths) also fails, one way or another.
    let mut bad = package;
    let mid = bad.len() / 2;
    bad[mid] ^= 0x01;
    assert_eq!(code(dzmls::inspect_key_package(&bad)), ErrorCode::BadInput);
}

#[test]
fn rejects_oversize() {
    assert_eq!(
        code(dzmls::inspect_key_package(&vec![0u8; 65537])),
        ErrorCode::BadInput
    );
}

#[test]
fn rejects_a_welcome_and_garbage() {
    let alice = device(1);
    let mut bob = device(2);
    let g = dzmls::create_group(&alice.state, &[7; 32]).unwrap();
    let c = dzmls::commit_change(&alice.state, &g, &[kp(&mut bob)], &[]).unwrap();
    let welcome = c.welcome.unwrap();
    assert_eq!(
        code(dzmls::inspect_key_package(&welcome)),
        ErrorCode::BadInput
    );
    assert_eq!(
        code(dzmls::inspect_key_package(&[1, 2, 3])),
        ErrorCode::BadInput
    );
    assert_eq!(code(dzmls::inspect_key_package(&[])), ErrorCode::BadInput);
}

#[test]
fn inspection_changes_no_state() {
    // There is no state argument. A package inspected twice still joins.
    let alice = device(1);
    let mut bob = device(2);
    let package = kp(&mut bob);
    let first = dzmls::inspect_key_package(&package).unwrap();
    let second = dzmls::inspect_key_package(&package).unwrap();
    assert_eq!(first.device_id, second.device_id);
    assert_eq!(first.signature_public_key, second.signature_public_key);
    let g = dzmls::create_group(&alice.state, &[8; 32]).unwrap();
    let c = dzmls::commit_change(&alice.state, &g, &[package], &[]).unwrap();
    let j = dzmls::join_from_welcome(&bob.state, &c.welcome.unwrap()).unwrap();
    assert_eq!(j.epoch, 1);
}
