//! Messages: encrypt application plaintext, and process whatever the server delivers (application messages and
//! commits from other members).
//!
//! Both calls are pure over the blobs. A failed call returns no state, so the caller keeps its old blobs; a
//! successful `process` can be repeated from the same old blobs with an equivalent result, which is how a crash
//! between processing and persisting is recovered. The result is byte-identical for application messages; merging
//! a commit stamps wall-clock time into the state, so commit results are equivalent but not byte-identical.
//!
//! **Callers must serialize calls**: one call at a time per device blob and per group blob.

use std::fmt;

use openmls::framing::errors::{MessageDecryptionError, SecretTreeError};
use openmls::prelude::tls_codec::{Deserialize as _, Serialize as _};
use openmls::prelude::{
    MlsGroup, MlsGroupStateError, MlsMessageIn, ProcessMessageError, ProcessedMessageContent,
    ProtocolMessage, StagedCommit, ValidationError, WireFormat,
};
use openmls_rust_crypto::OpenMlsRustCrypto;

use crate::MAX_WIRE_LEN;
use crate::device::load_signer;
use crate::error::{ErrorCode, MlsError};
use crate::group::{device_unchanged, load_group};
use crate::padding;
use crate::state::{self, Partition, with_provider};

/// Largest plaintext `encrypt` accepts, before padding.
pub(crate) const MAX_PLAINTEXT_LEN: usize = 4096;

pub struct Encrypted {
    /// The group blob after sending: the sender ratchet moved on. Persist it before sending `ciphertext`.
    pub group_state: Vec<u8>,
    /// The `MlsMessage` (a private message) to send.
    pub ciphertext: Vec<u8>,
    /// The epoch the message was encrypted in.
    pub epoch: u64,
}

/// Encrypts `plaintext` (at most 4096 bytes) for the group. The plaintext is padded to a multiple of 256 bytes
/// first, so the ciphertext length reveals only which 256-byte block the plaintext length falls in.
///
/// Fails with `pending_commit` while a commit of this device waits for the server, and with `evicted` once this
/// device has been removed.
pub fn encrypt(
    device_state: &[u8],
    group_state: &[u8],
    plaintext: &[u8],
) -> Result<Encrypted, MlsError> {
    if plaintext.len() > MAX_PLAINTEXT_LEN {
        return Err(MlsError::bad_input(format!(
            "plaintext is {} bytes, at most {MAX_PLAINTEXT_LEN}",
            plaintext.len()
        )));
    }
    let padded = padding::pad(plaintext);
    let ((ciphertext, epoch), device_out, group_out) = with_provider(
        device_state,
        Some(group_state),
        Partition::Group,
        |provider, header| {
            let mut group = load_group(provider, header)?;
            if !group.is_active() {
                return Err(evicted());
            }
            if group.pending_commit().is_some() {
                return Err(MlsError::new(
                    ErrorCode::PendingCommit,
                    "a commit is pending; confirm or discard it first",
                ));
            }
            let signer = load_signer(provider, header)?;
            let out = group
                .create_message(provider, &signer, &padded)
                .map_err(|_| MlsError::internal("encrypting the message failed"))?;
            let ciphertext = out
                .tls_serialize_detached()
                .map_err(|_| MlsError::internal("message serialization failed"))?;
            Ok((ciphertext, group.epoch().as_u64()))
        },
    )?;
    device_unchanged(device_state, &device_out)?;
    Ok(Encrypted {
        group_state: group_out.ok_or_else(|| MlsError::internal("group state missing"))?,
        ciphertext,
        epoch,
    })
}

pub enum Event {
    /// An application message from another member.
    Message {
        plaintext: Vec<u8>,
        sender_device_id: Vec<u8>,
    },
    /// Another member's commit, now merged.
    Commit {
        /// The epoch the group is in after the commit.
        epoch: u64,
        /// Device ids added by the commit, in commit order.
        added: Vec<Vec<u8>>,
        /// Device ids removed by the commit, in commit order.
        removed: Vec<Vec<u8>>,
        /// This device was removed. The returned group blob is then inactive: every later `encrypt`, `process` and
        /// `commit_change` on it fails with `evicted`, and the caller should delete it once the event is handled.
        self_removed: bool,
    },
}

pub struct Processed {
    /// The group blob after processing. Persist it, then act on `event`.
    pub group_state: Vec<u8>,
    pub event: Event,
}

/// Processes one message from the server: decrypts an application message, or verifies and merges another
/// member's commit. `wire` is an `MlsMessage` as [`encrypt`] or `commit_change` produced it, at most 65536 bytes.
///
/// Error codes: `wrong_epoch` when the message's epoch is not the group's (older or newer); `evicted` when this
/// device is no longer a member; `duplicate` when the message's generation was already consumed (a replay, this
/// device's own message echoed back); `bad_input` for a message more than 50 generations behind the newest one seen
/// from its sender (its key is gone, so it was never read and cannot be read), and for anything oversized,
/// unparsable, for another group, failing decryption or validation, or of a kind this engine does not take
/// (Welcome, standalone proposal). On any error no state is returned.
///
/// A commit from another member for the epoch this device has a pending commit on means that commit lost:
/// processing it merges the winner and drops the pending commit.
pub fn process(
    device_state: &[u8],
    group_state: &[u8],
    wire: &[u8],
) -> Result<Processed, MlsError> {
    let message = parse_protocol_message(wire)?;
    if message.wire_format() != WireFormat::PrivateMessage {
        return Err(MlsError::bad_input("message is not a private message"));
    }
    let wire_epoch = message.epoch().as_u64();
    let (event, device_out, group_out) = with_provider(
        device_state,
        Some(group_state),
        Partition::Group,
        |provider, header| {
            let group_id = header
                .group_id()
                .ok_or_else(|| MlsError::internal("no group id"))?;
            if message.group_id().as_slice() != group_id.as_slice() {
                return Err(MlsError::bad_input("message is for another group"));
            }
            let mut group = load_group(provider, header)?;
            if !group.is_active() {
                return Err(evicted());
            }
            let epoch = group.epoch().as_u64();
            if wire_epoch != epoch {
                return Err(MlsError::new(
                    ErrorCode::WrongEpoch,
                    if wire_epoch < epoch {
                        "message is from an earlier epoch"
                    } else {
                        "message is from a later epoch"
                    },
                ));
            }
            let processed = group
                .process_message(provider, message)
                .map_err(map_process_error)?;
            let sender_device_id = processed.credential().serialized_content().to_vec();
            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(m) => Ok(Event::Message {
                    plaintext: padding::unpad(&m.into_bytes())?,
                    sender_device_id,
                }),
                ProcessedMessageContent::StagedCommitMessage(staged) => {
                    merge_commit(provider, &mut group, *staged)
                }
                ProcessedMessageContent::OwnPrivateMessage => Err(MlsError::new(
                    ErrorCode::Duplicate,
                    "message was sent by this device",
                )),
                _ => Err(MlsError::bad_input("standalone proposals are not accepted")),
            }
        },
    )?;
    device_unchanged(device_state, &device_out)?;
    Ok(Processed {
        group_state: group_out.ok_or_else(|| MlsError::internal("group state missing"))?,
        event,
    })
}

/// The epoch in a message's header (an application message or a commit), read without any state. Accepts exactly
/// what [`process`] accepts: a private message. A public message is `bad_input`.
pub fn wire_epoch(wire: &[u8]) -> Result<u64, MlsError> {
    let message = parse_protocol_message(wire)?;
    if message.wire_format() != WireFormat::PrivateMessage {
        return Err(MlsError::bad_input("message is not a private message"));
    }
    Ok(message.epoch().as_u64())
}

/// Size cap, then MLS decoding. Only protocol messages (private or public) pass; Welcomes, group infos and key
/// packages are `bad_input`.
fn parse_protocol_message(wire: &[u8]) -> Result<ProtocolMessage, MlsError> {
    if wire.len() > MAX_WIRE_LEN {
        return Err(MlsError::bad_input(format!(
            "message is {} bytes, at most {MAX_WIRE_LEN}",
            wire.len()
        )));
    }
    MlsMessageIn::tls_deserialize_exact(wire)
        .map_err(|_| MlsError::bad_input("message is not an MLS message"))?
        .try_into_protocol_message()
        .map_err(|_| MlsError::bad_input("message is not a protocol message"))
}

/// Reports and merges a verified commit. Every credential the commit brings into the group must carry a 16 to 64
/// byte device id, checked before anything is merged.
fn merge_commit(
    provider: &OpenMlsRustCrypto,
    group: &mut MlsGroup,
    staged: StagedCommit,
) -> Result<Event, MlsError> {
    for credential in staged.credentials_to_verify() {
        let len = credential.serialized_content().len();
        if !state::ID_LEN.contains(&len) {
            return Err(MlsError::bad_input(format!(
                "commit brings in a member identity of {len} bytes"
            )));
        }
    }
    let added = staged
        .add_proposals()
        .map(|q| {
            q.add_proposal()
                .key_package()
                .leaf_node()
                .credential()
                .serialized_content()
                .to_vec()
        })
        .collect();
    let removed = staged
        .remove_proposals()
        .map(|q| {
            group
                .member(q.remove_proposal().removed())
                .map(|c| c.serialized_content().to_vec())
                .ok_or_else(|| MlsError::internal("removed member not in the group"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let epoch = staged.epoch().as_u64();
    let self_removed = staged.self_removed();
    group
        .merge_staged_commit(provider, staged)
        .map_err(|_| MlsError::internal("merging the commit failed"))?;
    Ok(Event::Commit {
        epoch,
        added,
        removed,
        self_removed,
    })
}

fn evicted() -> MlsError {
    MlsError::new(ErrorCode::Evicted, "this device is no longer a member")
}

/// Maps OpenMLS processing failures to stable codes. The epoch and eviction checks in [`process`] run first, so the
/// epoch and eviction arms here are backstops.
fn map_process_error<E>(e: ProcessMessageError<E>) -> MlsError {
    match e {
        ProcessMessageError::LibraryError(_) | ProcessMessageError::StorageError(_) => {
            MlsError::internal("processing the message failed")
        }
        ProcessMessageError::GroupStateError(MlsGroupStateError::UseAfterEviction) => evicted(),
        ProcessMessageError::ValidationError(v) => match v {
            ValidationError::WrongEpoch | ValidationError::NoPastEpochData => {
                MlsError::new(ErrorCode::WrongEpoch, "message is for another epoch")
            }
            ValidationError::UnableToDecrypt(MessageDecryptionError::SecretTreeError(
                SecretTreeError::SecretReuseError,
            )) => MlsError::new(
                ErrorCode::Duplicate,
                "message generation was already consumed",
            ),
            ValidationError::LibraryError(_) => MlsError::internal("processing the message failed"),
            _ => MlsError::bad_input("message failed validation"),
        },
        _ => MlsError::bad_input("message cannot be processed"),
    }
}

// Debug prints sizes and flags only, so a stray `{:?}` can never print plaintext, ids or state.
impl fmt::Debug for Encrypted {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Encrypted")
            .field("group_state_len", &self.group_state.len())
            .field("ciphertext_len", &self.ciphertext.len())
            .field("epoch", &self.epoch)
            .finish()
    }
}

impl fmt::Debug for Event {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Event::Message {
                plaintext,
                sender_device_id,
            } => f
                .debug_struct("Message")
                .field("plaintext_len", &plaintext.len())
                .field("sender_device_id_len", &sender_device_id.len())
                .finish(),
            Event::Commit {
                epoch,
                added,
                removed,
                self_removed,
            } => f
                .debug_struct("Commit")
                .field("epoch", epoch)
                .field("added_count", &added.len())
                .field("removed_count", &removed.len())
                .field("self_removed", self_removed)
                .finish(),
        }
    }
}

impl fmt::Debug for Processed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Processed")
            .field("group_state_len", &self.group_state.len())
            .field("event", &self.event)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls::prelude::{
        BasicCredential, CredentialWithKey, GroupId, KeyPackage, MlsGroupCreateConfig,
        OpenMlsProvider as _, PURE_PLAINTEXT_WIRE_FORMAT_POLICY,
    };
    use openmls_basic_credential::SignatureKeyPair;

    use crate::device::capabilities;
    use crate::{
        CIPHERSUITE, commit_change, confirm_commit, create_device, create_group,
        generate_key_packages, join_from_welcome,
    };

    struct Dev {
        state: Vec<u8>,
    }

    fn device(n: u8) -> Dev {
        Dev {
            state: create_device(&[n; 16]).unwrap().device_state,
        }
    }

    fn kp(dev: &mut Dev) -> Vec<u8> {
        let k = generate_key_packages(&dev.state, 1, false).unwrap();
        dev.state = k.device_state;
        k.key_packages.into_iter().next().unwrap()
    }

    /// A key package whose credential identity is `identity_len` bytes, which `commit_change` would refuse.
    fn hostile_key_package(identity_len: usize) -> KeyPackage {
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
        let credential = CredentialWithKey {
            credential: BasicCredential::new(vec![9; identity_len]).into(),
            signature_key: signer.to_public_vec().into(),
        };
        KeyPackage::builder()
            .leaf_node_capabilities(capabilities())
            .build(CIPHERSUITE, &provider, &signer, credential)
            .unwrap()
            .key_package()
            .clone()
    }

    /// `dev` commits an add of `kp` with raw OpenMLS (bypassing `commit_change`'s checks) and merges it. Returns
    /// the commit message and `dev`'s new group state.
    fn raw_add(dev: &Dev, group_state: &[u8], kp: KeyPackage) -> (Vec<u8>, Vec<u8>) {
        let (commit, _, g) = with_provider(
            &dev.state,
            Some(group_state),
            Partition::Group,
            |provider, header| {
                let mut group = load_group(provider, header)?;
                let signer = load_signer(provider, header)?;
                let bundle = group
                    .commit_builder()
                    .propose_adds(vec![kp])
                    .load_psks(provider.storage())
                    .unwrap()
                    .build(provider.rand(), provider.crypto(), &signer, |_| true)
                    .unwrap()
                    .stage_commit(provider)
                    .unwrap();
                group.merge_pending_commit(provider).unwrap();
                Ok(bundle.commit().tls_serialize_detached().unwrap())
            },
        )
        .unwrap();
        (commit, g.unwrap())
    }

    #[test]
    fn commit_or_welcome_bringing_in_a_bad_identity_is_bad_input() {
        let alice = device(1);
        let mut bob = device(2);
        let mut carol = device(3);
        let g = create_group(&alice.state, &[0xAB; 32]).unwrap();
        let c = commit_change(&alice.state, &g, &[kp(&mut bob)], &[]).unwrap();
        let a1 = confirm_commit(&alice.state, &c.group_state).unwrap();
        let j = join_from_welcome(&bob.state, &c.welcome.unwrap()).unwrap();
        bob.state = j.device_state;

        for len in [15, 65] {
            let (commit, _) = raw_add(&alice, &a1, hostile_key_package(len));
            let r = process(&bob.state, &j.group_state, &commit);
            assert_eq!(r.unwrap_err().code, ErrorCode::BadInput, "len {len}");
        }
        // The same raw path with a valid identity is accepted, so the refusal above is the identity check.
        let (commit, _) = raw_add(&alice, &a1, hostile_key_package(16));
        assert!(process(&bob.state, &j.group_state, &commit).is_ok());

        // A group that already holds a bad identity cannot be joined.
        let (_, a2) = raw_add(&alice, &a1, hostile_key_package(15));
        let c = commit_change(&alice.state, &a2, &[kp(&mut carol)], &[]).unwrap();
        let r = join_from_welcome(&carol.state, &c.welcome.unwrap());
        assert_eq!(r.unwrap_err().code, ErrorCode::BadInput);
    }

    #[test]
    fn debug_prints_sizes_only() {
        let e = Encrypted {
            group_state: vec![0xAB; 3],
            ciphertext: vec![0xAB; 4],
            epoch: 7,
        };
        let p = Processed {
            group_state: vec![0xAB; 3],
            event: Event::Message {
                plaintext: b"secret".to_vec(),
                sender_device_id: vec![0xAB; 16],
            },
        };
        let c = Event::Commit {
            epoch: 2,
            added: vec![vec![0xAB; 16]],
            removed: vec![],
            self_removed: false,
        };
        let printed = format!("{e:?} {p:?} {c:?}");
        assert!(!printed.contains("171"), "bytes leaked: {printed}");
        assert!(!printed.contains("secret"), "plaintext leaked: {printed}");
        assert!(!printed.contains('['), "a byte list leaked: {printed}");
        assert!(printed.contains("plaintext_len: 6"));
    }

    #[test]
    fn wire_epoch_refuses_a_public_message() {
        // The crate only creates private messages, so build a plaintext-policy group with raw OpenMLS and take
        // its self-update commit, which is then a public message.
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
        let credential = CredentialWithKey {
            credential: BasicCredential::new(vec![7; 16]).into(),
            signature_key: signer.to_public_vec().into(),
        };
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .wire_format_policy(PURE_PLAINTEXT_WIRE_FORMAT_POLICY)
            .build();
        let mut group = MlsGroup::new_with_group_id(
            &provider,
            &signer,
            &config,
            GroupId::from_slice(&[9; 32]),
            credential,
        )
        .unwrap();
        let bundle = group
            .self_update(&provider, &signer, Default::default())
            .unwrap();
        let wire = bundle.commit().tls_serialize_detached().unwrap();

        // It parses as a protocol message, so only the wire format check can refuse it.
        assert_eq!(
            parse_protocol_message(&wire).unwrap().wire_format(),
            WireFormat::PublicMessage
        );
        assert_eq!(wire_epoch(&wire).unwrap_err().code, ErrorCode::BadInput);
        let alice = device(1);
        let g = crate::create_group(&alice.state, &[0xAB; 32]).unwrap();
        assert_eq!(
            process(&alice.state, &g, &wire).unwrap_err().code,
            ErrorCode::BadInput
        );
    }
}
