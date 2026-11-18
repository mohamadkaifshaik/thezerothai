//! AES-256-GCM sealing for values the app stores locally, and random bytes for keys.
//!
//! A sealed value is `nonce (12 bytes) || ciphertext || tag (16 bytes)`. The nonce is fresh from the provider's
//! CSPRNG on every call, never derived from the input. The associated data is authenticated but not stored: the
//! caller passes the same bytes (for example the table and row key) to [`open`], so a value moved elsewhere fails.
//!
//! Every failure to open (wrong key, wrong associated data, altered or truncated bytes) is the same `bad_input`
//! with the same message. Messages carry sizes only, never keys, associated data or plaintext.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use openmls::prelude::{OpenMlsProvider as _, OpenMlsRand as _};
use openmls_rust_crypto::OpenMlsRustCrypto;

use crate::error::MlsError;

/// Key size: AES-256.
pub const SEAL_KEY_BYTES: usize = 32;
/// Nonce size, stored in front of the ciphertext.
pub const SEAL_NONCE_BYTES: usize = 12;
/// Largest plaintext [`seal`] accepts (1 MiB).
pub const MAX_SEAL_PLAINTEXT: usize = 1_048_576;

const TAG_BYTES: usize = 16;
const OVERHEAD: usize = SEAL_NONCE_BYTES + TAG_BYTES;
const MAX_RANDOM_BYTES: u32 = 64;

fn cipher(key: &[u8]) -> Result<Aes256Gcm, MlsError> {
    if key.len() != SEAL_KEY_BYTES {
        return Err(MlsError::bad_input(format!(
            "seal key is {} bytes, expected {SEAL_KEY_BYTES}",
            key.len()
        )));
    }
    Aes256Gcm::new_from_slice(key).map_err(|_| MlsError::bad_input("seal key is malformed"))
}

fn random(len: usize) -> Result<Vec<u8>, MlsError> {
    OpenMlsRustCrypto::default()
        .rand()
        .random_vec(len)
        .map_err(|_| MlsError::internal("the random source failed"))
}

/// Encrypts `plaintext` (at most [`MAX_SEAL_PLAINTEXT`] bytes) under a 32-byte `key`, authenticating `aad`.
/// Returns `nonce || ciphertext || tag`, 28 bytes longer than the plaintext.
pub fn seal(key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, MlsError> {
    let cipher = cipher(key)?;
    if plaintext.len() > MAX_SEAL_PLAINTEXT {
        return Err(MlsError::bad_input(format!(
            "plaintext is {} bytes, at most {MAX_SEAL_PLAINTEXT}",
            plaintext.len()
        )));
    }
    let nonce = random(SEAL_NONCE_BYTES)?;
    if nonce.len() != SEAL_NONCE_BYTES {
        return Err(MlsError::internal(
            "the random source returned a short nonce",
        ));
    }
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| MlsError::internal("sealing failed"))?;
    let mut out = Vec::with_capacity(OVERHEAD + plaintext.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// Decrypts a value made by [`seal`] with the same `key` and `aad`. A wrong key, wrong `aad`, or altered,
/// truncated or extended bytes are all `bad_input`.
pub fn open(key: &[u8], aad: &[u8], sealed: &[u8]) -> Result<Vec<u8>, MlsError> {
    let cipher = cipher(key)?;
    if sealed.len() < OVERHEAD || sealed.len() > MAX_SEAL_PLAINTEXT + OVERHEAD {
        return Err(MlsError::bad_input(format!(
            "sealed value is {} bytes, expected {OVERHEAD} to {}",
            sealed.len(),
            MAX_SEAL_PLAINTEXT + OVERHEAD
        )));
    }
    let (nonce, ciphertext) = sealed.split_at(SEAL_NONCE_BYTES);
    cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| MlsError::bad_input("sealed value does not open"))
}

/// `len` (1 to 64) bytes from the provider's CSPRNG.
pub fn random_bytes(len: u32) -> Result<Vec<u8>, MlsError> {
    if !(1..=MAX_RANDOM_BYTES).contains(&len) {
        return Err(MlsError::bad_input(format!(
            "random length is {len}, expected 1 to {MAX_RANDOM_BYTES}"
        )));
    }
    random(len as usize)
}
