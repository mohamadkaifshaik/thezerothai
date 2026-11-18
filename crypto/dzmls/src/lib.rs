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

mod device;
mod error;
mod group;
mod state;

pub use device::{DeviceCreated, KeyPackages, create_device, generate_key_packages};
pub use error::{ErrorCode, MlsError};
pub use group::{
    Commit, GroupInfo, Joined, Member, commit_change, confirm_commit, create_group, describe,
    discard_commit, join_from_welcome,
};

/// The one cipher suite this engine speaks.
pub(crate) const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Largest wire input (key package, Welcome, message) accepted before parsing.
pub(crate) const MAX_WIRE_LEN: usize = 65536;
