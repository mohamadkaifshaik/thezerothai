//! AES-256-GCM sealing for local storage: `nonce (12) || ciphertext || tag (16)`, aad not stored.

use dzmls::{
    ErrorCode, MAX_SEAL_PLAINTEXT, MlsError, SEAL_KEY_BYTES, SEAL_NONCE_BYTES, open, random_bytes,
    seal,
};

const TAG_BYTES: usize = 16;
const OVERHEAD: usize = SEAL_NONCE_BYTES + TAG_BYTES;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).expect("hex digit"))
        .collect()
}

fn code<T: std::fmt::Debug>(r: Result<T, MlsError>) -> ErrorCode {
    r.unwrap_err().code
}

const KEY: [u8; 32] = [7u8; 32];
const AAD: &[u8] = b"messages:row-1";

#[test]
fn constants_are_the_documented_ones() {
    assert_eq!(SEAL_KEY_BYTES, 32);
    assert_eq!(SEAL_NONCE_BYTES, 12);
    assert_eq!(MAX_SEAL_PLAINTEXT, 1_048_576);
}

#[test]
fn round_trips_and_adds_exactly_nonce_and_tag() {
    for plaintext in [&b""[..], b"x", b"hello vault", &[0u8; 4096]] {
        let sealed = seal(&KEY, AAD, plaintext).unwrap();
        assert_eq!(sealed.len(), plaintext.len() + OVERHEAD);
        assert_eq!(open(&KEY, AAD, &sealed).unwrap(), plaintext);
    }
}

#[test]
fn empty_aad_round_trips() {
    let sealed = seal(&KEY, b"", b"no aad").unwrap();
    assert_eq!(open(&KEY, b"", &sealed).unwrap(), b"no aad");
}

#[test]
fn two_seals_of_the_same_input_differ_in_nonce_and_bytes() {
    let a = seal(&KEY, AAD, b"same").unwrap();
    let b = seal(&KEY, AAD, b"same").unwrap();
    assert_ne!(a, b);
    assert_ne!(a[..SEAL_NONCE_BYTES], b[..SEAL_NONCE_BYTES]);
}

#[test]
fn wrong_key_is_bad_input() {
    let sealed = seal(&KEY, AAD, b"secret").unwrap();
    assert_eq!(code(open(&[8u8; 32], AAD, &sealed)), ErrorCode::BadInput);
}

#[test]
fn wrong_aad_is_bad_input() {
    let sealed = seal(&KEY, AAD, b"secret").unwrap();
    assert_eq!(
        code(open(&KEY, b"messages:row-2", &sealed)),
        ErrorCode::BadInput
    );
    assert_eq!(code(open(&KEY, b"", &sealed)), ErrorCode::BadInput);
}

#[test]
fn a_flipped_byte_anywhere_is_bad_input() {
    let sealed = seal(&KEY, AAD, b"secret").unwrap();
    // In the nonce, the ciphertext and the tag.
    for i in [0, SEAL_NONCE_BYTES - 1, SEAL_NONCE_BYTES, sealed.len() - 1] {
        let mut bad = sealed.clone();
        bad[i] ^= 0x01;
        assert_eq!(code(open(&KEY, AAD, &bad)), ErrorCode::BadInput, "i = {i}");
    }
}

#[test]
fn truncated_or_extended_values_are_bad_input() {
    let sealed = seal(&KEY, AAD, b"secret").unwrap();
    for n in [0, 1, SEAL_NONCE_BYTES, OVERHEAD - 1, sealed.len() - 1] {
        assert_eq!(
            code(open(&KEY, AAD, &sealed[..n])),
            ErrorCode::BadInput,
            "n = {n}"
        );
    }
    let mut longer = sealed.clone();
    longer.push(0);
    assert_eq!(code(open(&KEY, AAD, &longer)), ErrorCode::BadInput);
}

#[test]
fn exactly_the_overhead_is_a_well_formed_value_that_fails_authentication() {
    // 28 bytes is the size of a sealed empty plaintext: it is parsed, then refused by the tag check.
    assert_eq!(code(open(&KEY, AAD, &[0u8; OVERHEAD])), ErrorCode::BadInput);
    let sealed = seal(&KEY, AAD, b"").unwrap();
    assert_eq!(sealed.len(), OVERHEAD);
    assert_eq!(open(&KEY, AAD, &sealed).unwrap(), b"");
}

#[test]
fn key_of_any_other_length_is_bad_input() {
    let sealed = seal(&KEY, AAD, b"secret").unwrap();
    for n in [0, 1, 16, 24, 31, 33, 64] {
        let key = vec![7u8; n];
        assert_eq!(
            code(seal(&key, AAD, b"secret")),
            ErrorCode::BadInput,
            "n = {n}"
        );
        assert_eq!(
            code(open(&key, AAD, &sealed)),
            ErrorCode::BadInput,
            "n = {n}"
        );
    }
}

#[test]
fn plaintext_cap_is_inclusive() {
    let at_cap = vec![0x5au8; MAX_SEAL_PLAINTEXT];
    let sealed = seal(&KEY, AAD, &at_cap).unwrap();
    assert_eq!(sealed.len(), MAX_SEAL_PLAINTEXT + OVERHEAD);
    assert_eq!(open(&KEY, AAD, &sealed).unwrap(), at_cap);

    let over = vec![0x5au8; MAX_SEAL_PLAINTEXT + 1];
    assert_eq!(code(seal(&KEY, AAD, &over)), ErrorCode::BadInput);
    // A sealed value longer than any seal can produce is refused before decryption.
    let too_long = vec![0u8; MAX_SEAL_PLAINTEXT + OVERHEAD + 1];
    assert_eq!(code(open(&KEY, AAD, &too_long)), ErrorCode::BadInput);
}

#[test]
fn errors_carry_no_input_bytes() {
    let sealed = seal(&KEY, AAD, b"top-secret-plaintext").unwrap();
    for e in [
        open(&[9u8; 32], AAD, &sealed).unwrap_err(),
        open(&KEY, b"other", &sealed).unwrap_err(),
        seal(&[1u8; 5], AAD, b"top-secret-plaintext").unwrap_err(),
    ] {
        let shown = format!("{e} {e:?}");
        assert!(!shown.contains("top-secret"), "{shown}");
        assert!(!shown.contains("messages:row"), "{shown}");
    }
}

/// Built independently with Node 24's `crypto` (OpenSSL 3.5.9), `aes-256-gcm`, nonce `a0..ab`: pins the format
/// `nonce || ciphertext || tag` against another implementation.
#[test]
fn opens_a_value_sealed_by_another_implementation() {
    let key = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    let aad = unhex("647a76313a6d657373616765733a726f772d3432"); // "dzv1:messages:row-42"
    let sealed = unhex(
        "a0a1a2a3a4a5a6a7a8a9aaab957d1d4120af22d90d17a7a76f1fe0a811d935644bdeda484ce25b8360a64f1b39e51a84",
    );
    let plaintext = unhex("7365616c656420666f7220746865207661756c74"); // "sealed for the vault"
    assert_eq!(open(&key, &aad, &sealed).unwrap(), plaintext);
}

#[test]
fn random_bytes_has_the_asked_length_within_1_to_64() {
    for n in [1u32, 12, 32, 64] {
        assert_eq!(random_bytes(n).unwrap().len(), n as usize);
    }
    assert_ne!(random_bytes(32).unwrap(), random_bytes(32).unwrap());
    for n in [0u32, 65, u32::MAX] {
        assert_eq!(code(random_bytes(n)), ErrorCode::BadInput, "n = {n}");
    }
}
