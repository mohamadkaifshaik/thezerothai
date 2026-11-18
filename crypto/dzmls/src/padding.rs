//! Plaintext padding, so a ciphertext's length shows only which 256-byte block its plaintext falls in.
//!
//! `pad` appends `0x80` and then `0x00` until the length is a multiple of [`BLOCK`]; `unpad` strips the trailing
//! zeros and the `0x80`. The marker is always present, so a plaintext that itself ends in zeros (or in `0x80`)
//! survives exactly. A plaintext of `n` bytes pads to `(n / 256 + 1) * 256` bytes.

use crate::error::MlsError;

/// The padding block size in bytes.
pub(crate) const BLOCK: usize = 256;
const MARKER: u8 = 0x80;

pub(crate) fn pad(plaintext: &[u8]) -> Vec<u8> {
    let len = (plaintext.len() / BLOCK + 1) * BLOCK;
    let mut out = Vec::with_capacity(len);
    out.extend_from_slice(plaintext);
    out.push(MARKER);
    out.resize(len, 0);
    out
}

pub(crate) fn unpad(padded: &[u8]) -> Result<Vec<u8>, MlsError> {
    match padded.iter().rposition(|&b| b != 0) {
        Some(i) if padded[i] == MARKER => Ok(padded[..i].to_vec()),
        _ => Err(MlsError::bad_input("message padding is malformed")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    #[test]
    fn pads_to_the_next_block_and_round_trips() {
        for n in [0, 1, 200, 255, 256, 257, 511, 512, 4096] {
            let plaintext: Vec<u8> = (0..n).map(|i| (i % 7) as u8).collect();
            let padded = pad(&plaintext);
            assert_eq!(padded.len(), (n / BLOCK + 1) * BLOCK, "n = {n}");
            assert_eq!(unpad(&padded).unwrap(), plaintext, "n = {n}");
        }
    }

    #[test]
    fn trailing_zeros_and_markers_survive() {
        for plaintext in [&b"a\x00\x00"[..], b"\x80", b"\x80\x00", &[0; 255]] {
            assert_eq!(unpad(&pad(plaintext)).unwrap(), plaintext);
        }
    }

    #[test]
    fn missing_marker_is_bad_input() {
        for padded in [&b""[..], &[0; 256], b"abc", b"\x80\x01"] {
            assert_eq!(unpad(padded).unwrap_err().code, ErrorCode::BadInput);
        }
    }
}
