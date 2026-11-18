//! dzmls: the Dzeroth MLS (RFC 9420) core, a thin wrapper over the official `openmls` crate.
//!
//! Every function is pure over opaque state blobs: it takes the device blob (and, for group calls, the group
//! blob) and returns the new blobs, which the caller persists encrypted at rest. Nothing is kept in memory
//! between calls.
//!
//! **Callers must serialize calls.** Two concurrent calls on the same blob both succeed and one result is lost.
//! Every call that takes or returns a device state runs one at a time per device, and every call on a group state
//! one at a time per group.

use openmls::prelude::Ciphersuite;

mod code;
mod device;
mod error;
mod group;
mod message;
mod padding;
mod seal;
mod state;

pub use code::{Party, security_code};
pub use device::{DeviceCreated, KeyPackages, create_device, generate_key_packages};
pub use error::{ErrorCode, MlsError};
pub use group::{
    Commit, GroupInfo, Joined, Member, commit_change, confirm_commit, create_group, describe,
    discard_commit, join_from_welcome, self_update,
};
pub use message::{Encrypted, Event, Processed, encrypt, process, wire_epoch};
pub use seal::{MAX_SEAL_PLAINTEXT, SEAL_KEY_BYTES, SEAL_NONCE_BYTES, open, random_bytes, seal};

/// The one cipher suite this engine speaks.
pub(crate) const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Lifetime of every key package and of a group creator's leaf: five years (365-day years), in seconds.
///
/// OpenMLS checks a leaf's lifetime against the wall clock whenever a Welcome is joined (every leaf that never
/// updated, i.e. still carries its key package lifetime) and whenever a commit adds a key package. Add-only commits
/// carry no update path, so a leaf keeps its key package lifetime until its device commits with one ([`self_update`]
/// does; calling it periodically is a later plan). OpenMLS sets `not_before` one hour before the moment of creation,
/// so device clocks more than an hour behind the creator's refuse the package (`not valid yet`) when joining or
/// adding. OpenMLS 0.9.2 never enforces a maximum lifetime range (`Lifetime::has_acceptable_range` has no caller), so five years is accepted everywhere.
pub(crate) const LIFETIME_SECONDS: u64 = 157_680_000;

/// Largest wire input (key package, Welcome, message) accepted before parsing.
pub(crate) const MAX_WIRE_LEN: usize = 65536;
