#[test]
fn create_device_returns_state_and_32_byte_ed25519_key() {
    let d = dzmls::create_device(&[7u8; 16]).unwrap();
    assert_eq!(d.signature_public_key.len(), 32);
    assert_eq!(&d.device_state[..5], b"DZS1D");
}

#[test]
fn device_id_length_is_enforced() {
    assert_eq!(
        dzmls::create_device(&[1u8; 15]).unwrap_err().code.as_str(),
        "bad_input"
    );
    assert_eq!(
        dzmls::create_device(&[1u8; 65]).unwrap_err().code.as_str(),
        "bad_input"
    );
}

#[test]
fn key_packages_are_distinct_and_state_grows() {
    let d = dzmls::create_device(&[7u8; 16]).unwrap();
    let k = dzmls::generate_key_packages(&d.device_state, 3, true).unwrap();
    assert_eq!(k.key_packages.len(), 4); // 3 one-time + 1 last-resort, last-resort is the final element
    assert!(k.device_state.len() > d.device_state.len());
    let unique: std::collections::HashSet<_> = k.key_packages.iter().collect();
    assert_eq!(unique.len(), 4);
}

#[test]
fn key_package_count_is_capped() {
    let d = dzmls::create_device(&[7u8; 16]).unwrap();
    assert_eq!(
        dzmls::generate_key_packages(&d.device_state, 101, false)
            .unwrap_err()
            .code
            .as_str(),
        "bad_input"
    );
}

#[test]
fn corrupt_state_is_an_error_not_a_panic() {
    // Review Focus 2
    let d = dzmls::create_device(&[7u8; 16]).unwrap();
    for cut in [0, 3, 5, d.device_state.len() / 2, d.device_state.len() - 1] {
        let e = dzmls::generate_key_packages(&d.device_state[..cut], 1, false).unwrap_err();
        assert_eq!(e.code.as_str(), "corrupt_state");
    }
    let mut flipped = d.device_state.clone();
    flipped[0] ^= 0xff;
    assert_eq!(
        dzmls::generate_key_packages(&flipped, 1, false)
            .unwrap_err()
            .code
            .as_str(),
        "corrupt_state"
    );
}
