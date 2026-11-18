//! Shared helpers for the integration tests. Each test file uses a different subset.
#![allow(dead_code)]

/// A test device: its id, its current device blob and its signature public key.
pub struct Dev {
    pub id: Vec<u8>,
    pub state: Vec<u8>,
    pub signature_public_key: Vec<u8>,
}

/// Device `n` has the id `[n; 16]`, so devices sort by `n`.
pub fn device(n: u8) -> Dev {
    let id = vec![n; 16];
    let d = dzmls::create_device(&id).unwrap();
    Dev {
        id,
        state: d.device_state,
        signature_public_key: d.signature_public_key,
    }
}

/// One fresh one-time key package; the device's state is updated to hold its private part.
pub fn kp(dev: &mut Dev) -> Vec<u8> {
    let k = dzmls::generate_key_packages(&dev.state, 1, false).unwrap();
    dev.state = k.device_state;
    k.key_packages.into_iter().next().unwrap()
}

/// One fresh last-resort key package; the device's state is updated to hold its private part.
pub fn last_resort_kp(dev: &mut Dev) -> Vec<u8> {
    let k = dzmls::generate_key_packages(&dev.state, 0, true).unwrap();
    dev.state = k.device_state;
    k.key_packages.into_iter().next().unwrap()
}
