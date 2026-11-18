//! The security code two users compare out of band to verify they see each other's real devices.
//!
//! The algorithm is fixed; the Dart implementation must match it byte for byte:
//!
//! ```text
//! half(p)  = SHA-256( "dz-security-code-v1" || u32be(len(p.user_id)) || p.user_id
//!                     || for each key in sort_bytewise(dedupe(p.device_keys)): u32be(len(key)) || key )
//! digits(h) = for i in 0..6: zero-pad-5( u40be(h[5i .. 5i+5]) mod 100000 )        // 30 digits per half
//! code     = digits(half(lo)) ++ digits(half(hi))   where lo, hi = a, b ordered bytewise by user_id
//! ```
//!
//! The result is 60 digits as 12 groups of 5, separated by single spaces.

use std::collections::BTreeSet;

use openmls::prelude::{HashType, OpenMlsCrypto as _, OpenMlsProvider as _};
use openmls_rust_crypto::OpenMlsRustCrypto;

use crate::error::MlsError;

const DOMAIN: &[u8] = b"dz-security-code-v1";

/// One side of a comparison: a user and the signature public keys of all their devices.
pub struct Party {
    pub user_id: Vec<u8>,
    pub device_keys: Vec<Vec<u8>>,
}

/// The security code for the pair `a`, `b`. Symmetric, and independent of the order and repetition of device keys.
///
/// `bad_input` for an empty user id, equal user ids, or a party with no device keys.
pub fn security_code(a: &Party, b: &Party) -> Result<String, MlsError> {
    for p in [a, b] {
        if p.user_id.is_empty() {
            return Err(MlsError::bad_input("user id is empty"));
        }
        if p.device_keys.is_empty() {
            return Err(MlsError::bad_input("a party has no device keys"));
        }
    }
    if a.user_id == b.user_id {
        return Err(MlsError::bad_input("both parties have the same user id"));
    }
    let (lo, hi) = if a.user_id < b.user_id {
        (a, b)
    } else {
        (b, a)
    };
    let provider = OpenMlsRustCrypto::default();
    let mut all = digits(&half(&provider, lo)?);
    all.push_str(&digits(&half(&provider, hi)?));
    let groups: Vec<&str> = (0..12).map(|i| &all[i * 5..i * 5 + 5]).collect();
    Ok(groups.join(" "))
}

fn half(provider: &OpenMlsRustCrypto, p: &Party) -> Result<Vec<u8>, MlsError> {
    let mut input = Vec::new();
    input.extend_from_slice(DOMAIN);
    push_field(&mut input, &p.user_id)?;
    let keys: BTreeSet<&Vec<u8>> = p.device_keys.iter().collect();
    for key in keys {
        push_field(&mut input, key)?;
    }
    provider
        .crypto()
        .hash(HashType::Sha2_256, &input)
        .map_err(|_| MlsError::internal("hashing failed"))
}

fn push_field(out: &mut Vec<u8>, field: &[u8]) -> Result<(), MlsError> {
    let len = u32::try_from(field.len()).map_err(|_| MlsError::bad_input("field too long"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(field);
    Ok(())
}

/// 30 decimal digits from a 32-byte hash: six 5-byte big-endian numbers, each mod 100000, zero-padded to 5.
fn digits(h: &[u8]) -> String {
    (0..6)
        .map(|i| {
            let n = h[5 * i..5 * i + 5]
                .iter()
                .fold(0u64, |acc, b| (acc << 8) | u64::from(*b));
            format!("{:05}", n % 100_000)
        })
        .collect()
}
