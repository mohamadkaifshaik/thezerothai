//! Devices: the signature key pair and the key packages others use to add this device to a group.

use std::fmt;

use openmls::prelude::OpenMlsProvider as _;
use openmls::prelude::tls_codec::Serialize as _;
use openmls::prelude::{
    BasicCredential, Capabilities, CredentialWithKey, ExtensionType, KeyPackage, Lifetime,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

use crate::error::MlsError;
use crate::state::{self, Header, Partition, with_provider};
use crate::{CIPHERSUITE, LIFETIME_SECONDS};

/// Most one-time key packages one call may generate (the last-resort package is extra).
pub(crate) const MAX_KEY_PACKAGES: u32 = 100;

pub struct DeviceCreated {
    /// The new device blob; persist it encrypted at rest.
    pub device_state: Vec<u8>,
    /// The raw 32-byte Ed25519 public key to register in the key directory.
    pub signature_public_key: Vec<u8>,
}

/// Creates a device: a fresh Ed25519 signature key pair, stored in the device blob's OpenMLS storage.
/// `device_id` (16 to 64 bytes) becomes the MLS credential identity.
pub fn create_device(device_id: &[u8]) -> Result<DeviceCreated, MlsError> {
    if !state::ID_LEN.contains(&device_id.len()) {
        return Err(MlsError::bad_input(format!(
            "device id must be 16 to 64 bytes, got {}",
            device_id.len()
        )));
    }
    let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
        .map_err(|_| MlsError::internal("signature key generation failed"))?;
    let signature_public_key = signer.to_public_vec();
    if signature_public_key.len() != state::SIGNATURE_PUBLIC_KEY_LEN {
        return Err(MlsError::internal(format!(
            "signature public key is {} bytes",
            signature_public_key.len()
        )));
    }
    let empty = state::empty_device_state(device_id, &signature_public_key)?;
    let ((), device_state, _) = with_provider(&empty, None, Partition::Device, |provider, _| {
        signer
            .store(provider.storage())
            .map_err(|_| MlsError::internal("storing the signature key failed"))
    })?;
    Ok(DeviceCreated {
        device_state,
        signature_public_key,
    })
}

pub struct KeyPackages {
    /// The device blob, now also holding the private parts of the new key packages.
    pub device_state: Vec<u8>,
    /// TLS-serialized `KeyPackage`s (not wrapped in an `MlsMessage`). One-time packages first; when requested, the
    /// last-resort package is the final element.
    pub key_packages: Vec<Vec<u8>>,
}

// Debug prints sizes only, so a stray `{:?}` can never print state or key bytes.
impl fmt::Debug for DeviceCreated {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeviceCreated")
            .field("device_state_len", &self.device_state.len())
            .field("signature_public_key_len", &self.signature_public_key.len())
            .finish()
    }
}

impl fmt::Debug for KeyPackages {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeyPackages")
            .field("device_state_len", &self.device_state.len())
            .field("key_package_count", &self.key_packages.len())
            .finish()
    }
}

/// Generates `count` (at most 100) one-time key packages, plus one last-resort package when `last_resort` is set.
/// The last-resort package carries OpenMLS's last-resort extension, so joining with it does not delete it.
pub fn generate_key_packages(
    device_state: &[u8],
    count: u32,
    last_resort: bool,
) -> Result<KeyPackages, MlsError> {
    if count > MAX_KEY_PACKAGES {
        return Err(MlsError::bad_input(format!(
            "at most {MAX_KEY_PACKAGES} key packages per call, got {count}"
        )));
    }
    if count == 0 && !last_resort {
        return Err(MlsError::bad_input("no key packages requested"));
    }
    let (key_packages, device_state, _) =
        with_provider(device_state, None, Partition::Device, |provider, header| {
            let signer = load_signer(provider, header)?;
            let credential = credential(header);
            let mut out = Vec::new();
            for _ in 0..count {
                out.push(build_key_package(provider, &signer, &credential, false)?);
            }
            if last_resort {
                out.push(build_key_package(provider, &signer, &credential, true)?);
            }
            Ok(out)
        })?;
    Ok(KeyPackages {
        device_state,
        key_packages,
    })
}

/// The device's signature key pair, read back from the device blob's storage.
pub(crate) fn load_signer(
    provider: &OpenMlsRustCrypto,
    header: &Header,
) -> Result<SignatureKeyPair, MlsError> {
    SignatureKeyPair::read(
        provider.storage(),
        header.signature_public_key(),
        CIPHERSUITE.signature_algorithm(),
    )
    .ok_or_else(|| MlsError::corrupt_state("signature key missing from device state"))
}

/// The device's MLS credential: a basic credential whose identity is the device id only.
pub(crate) fn credential(header: &Header) -> CredentialWithKey {
    CredentialWithKey {
        credential: BasicCredential::new(header.device_id().to_vec()).into(),
        signature_key: header.signature_public_key().to_vec().into(),
    }
}

/// The leaf capabilities every key package of this device advertises: our one cipher suite, and the last-resort
/// extension, which RFC 9420 requires a leaf to list before a key package may carry it (receivers refuse the
/// package otherwise).
// One-time and last-resort packages, and every group leaf, share these capabilities on purpose.
pub(crate) fn capabilities() -> Capabilities {
    Capabilities::builder()
        .ciphersuites(vec![CIPHERSUITE])
        .extensions(vec![ExtensionType::LastResort])
        .build()
}

/// A fresh [`LIFETIME_SECONDS`] lifetime starting now (OpenMLS backdates `not_before` by one hour). Built per call,
/// since it stamps the current time.
pub(crate) fn lifetime() -> Lifetime {
    Lifetime::new(LIFETIME_SECONDS)
}

fn build_key_package(
    provider: &OpenMlsRustCrypto,
    signer: &SignatureKeyPair,
    credential: &CredentialWithKey,
    last_resort: bool,
) -> Result<Vec<u8>, MlsError> {
    let mut builder = KeyPackage::builder()
        .leaf_node_capabilities(capabilities())
        .key_package_lifetime(lifetime());
    if last_resort {
        builder = builder.mark_as_last_resort();
    }
    let bundle = builder
        .build(CIPHERSUITE, provider, signer, credential.clone())
        .map_err(|_| MlsError::internal("key package generation failed"))?;
    bundle
        .key_package()
        .tls_serialize_detached()
        .map_err(|_| MlsError::internal("key package serialization failed"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls::prelude::tls_codec::Deserialize as _;
    use openmls::prelude::{KeyPackageIn, ProtocolVersion};

    fn parse(bytes: &[u8]) -> KeyPackage {
        let provider = OpenMlsRustCrypto::default();
        KeyPackageIn::tls_deserialize_exact(bytes)
            .unwrap()
            .validate(provider.crypto(), ProtocolVersion::Mls10)
            .unwrap()
    }

    #[test]
    fn only_the_final_package_is_last_resort() {
        let d = create_device(&[7u8; 16]).unwrap();
        let k = generate_key_packages(&d.device_state, 2, true).unwrap();
        let flags: Vec<bool> = k
            .key_packages
            .iter()
            .map(|kp| parse(kp).last_resort())
            .collect();
        assert_eq!(flags, [false, false, true]);
    }

    #[test]
    fn key_packages_carry_the_device_credential_and_suite() {
        let d = create_device(&[5u8; 40]).unwrap();
        let k = generate_key_packages(&d.device_state, 1, false).unwrap();
        let kp = parse(&k.key_packages[0]);
        assert_eq!(kp.ciphersuite(), CIPHERSUITE);
        let leaf = kp.leaf_node();
        assert_eq!(leaf.credential().serialized_content(), [5u8; 40]);
        assert_eq!(
            leaf.signature_key().as_slice(),
            d.signature_public_key.as_slice()
        );
    }

    /// OpenMLS sets `not_before` this far before the moment of creation, to allow for skewed clocks.
    const OPENMLS_NOT_BEFORE_MARGIN_SECONDS: u64 = 60 * 60;

    #[test]
    fn key_packages_live_five_years_one_time_and_last_resort() {
        assert_eq!(LIFETIME_SECONDS, 5 * 365 * 24 * 60 * 60);
        let d = create_device(&[7u8; 16]).unwrap();
        let k = generate_key_packages(&d.device_state, 1, true).unwrap();
        for bytes in &k.key_packages {
            let lifetime = *parse(bytes).life_time();
            assert_eq!(
                lifetime.not_after() - lifetime.not_before(),
                LIFETIME_SECONDS + OPENMLS_NOT_BEFORE_MARGIN_SECONDS
            );
        }
    }

    #[test]
    fn last_resort_alone_and_empty_request() {
        let d = create_device(&[7u8; 16]).unwrap();
        assert_eq!(
            generate_key_packages(&d.device_state, 0, true)
                .unwrap()
                .key_packages
                .len(),
            1
        );
        assert_eq!(
            generate_key_packages(&d.device_state, 0, false)
                .unwrap_err()
                .code
                .as_str(),
            "bad_input"
        );
        assert_eq!(
            generate_key_packages(&d.device_state, 100, false)
                .unwrap()
                .key_packages
                .len(),
            100
        );
    }

    #[test]
    fn a_device_state_without_its_signer_is_corrupt() {
        let d = create_device(&[7u8; 16]).unwrap();
        let ((), stripped, _) = with_provider(&d.device_state, None, Partition::Device, |p, _| {
            p.storage().values.write().unwrap().clear();
            Ok(())
        })
        .unwrap();
        assert_eq!(
            generate_key_packages(&stripped, 1, false)
                .unwrap_err()
                .code
                .as_str(),
            "corrupt_state"
        );
    }
}
