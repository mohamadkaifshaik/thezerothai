//! Groups: create, change membership through a pending commit the server then accepts or refuses, join from a
//! Welcome, and describe.
//!
//! A commit is two-phase. `commit_change` stages it: the group blob then holds OpenMLS's pending-commit state and
//! the group stays at its old epoch. When the server accepts the commit, `confirm_commit` merges it (epoch + 1);
//! when the server refuses it, `discard_commit` drops it and the group is exactly as usable as before.
//!
//! Group calls never change the device blob except `join_from_welcome`, which may consume a one-time key package.
//! The other calls check this and fail with `internal` rather than lose a device write.

use std::collections::BTreeSet;
use std::fmt;

use openmls::group::PURE_CIPHERTEXT_WIRE_FORMAT_POLICY;
use openmls::prelude::OpenMlsProvider as _;
use openmls::prelude::tls_codec::{Deserialize as _, Serialize as _};
use openmls::prelude::{
    CreateCommitError, GroupId, KeyPackage, KeyPackageIn, LeafNodeIndex, MlsGroup,
    MlsGroupCreateConfig, MlsMessageBodyIn, MlsMessageIn, ProtocolVersion,
    SenderRatchetConfiguration, StagedWelcome, WelcomeError,
};
use openmls_rust_crypto::OpenMlsRustCrypto;

use crate::device::{self, MAX_KEY_PACKAGES, credential, load_signer};
use crate::error::{ErrorCode, MlsError};
use crate::state::{self, Header, Partition, with_group_storage, with_provider};
use crate::{CIPHERSUITE, MAX_WIRE_LEN};

/// Sender ratchet: how far out of order a message may arrive within an epoch, and how far ahead of the last seen
/// generation a message may be.
const OUT_OF_ORDER_TOLERANCE: u32 = 50;
const MAXIMUM_FORWARD_DISTANCE: u32 = 1000;

/// The one OpenMLS group configuration, used to create groups and (through its join part) to join them, so creator
/// and joiners run identical settings. `past_epoch_deletion_policy` and padding stay at OpenMLS's defaults
/// (`MaxEpochs(0)`, none; dzmls pads plaintext itself). The creator's leaf gets the same five-year lifetime as a key
/// package ([`crate::LIFETIME_SECONDS`]), since OpenMLS checks it whenever someone joins.
fn create_config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(CIPHERSUITE)
        .capabilities(device::capabilities())
        .lifetime(device::lifetime())
        .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .use_ratchet_tree_extension(true)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(
            OUT_OF_ORDER_TOLERANCE,
            MAXIMUM_FORWARD_DISTANCE,
        ))
        .build()
}

/// Creates a group with this device as its only member, at epoch 0. `group_id` is 16 to 64 bytes.
pub fn create_group(device_state: &[u8], group_id: &[u8]) -> Result<Vec<u8>, MlsError> {
    let ((), device_out, group_out) =
        with_provider(device_state, None, Partition::Group, |provider, header| {
            header.set_group_id(group_id)?;
            let signer = load_signer(provider, header)?;
            MlsGroup::new_with_group_id(
                provider,
                &signer,
                &create_config(),
                GroupId::from_slice(group_id),
                credential(header),
            )
            .map_err(|_| MlsError::internal("group creation failed"))?;
            Ok(())
        })?;
    device_unchanged(device_state, &device_out)?;
    group_out.ok_or_else(|| MlsError::internal("group creation produced no group state"))
}

pub struct Commit {
    /// The group blob holding the pending commit. Persist it, then send `commit` (and `welcome`) to the server.
    pub group_state: Vec<u8>,
    /// The commit as an `MlsMessage` (a private message), for the existing members.
    pub commit: Vec<u8>,
    /// The Welcome as an `MlsMessage`, for the added devices; `None` when nothing is added.
    pub welcome: Option<Vec<u8>>,
    /// The epoch the commit is built on; confirming it moves the group to `epoch + 1`.
    pub epoch: u64,
}

/// Stages one commit that adds the devices behind `add_key_packages` (TLS-serialized `KeyPackage`s, at most 100)
/// and removes `remove_device_ids`. The group keeps its epoch until [`confirm_commit`] or [`discard_commit`].
///
/// A device id cannot be removed and re-added in the same commit (adding a current member is `bad_input`): a
/// device that lost its state returns under a new device id.
pub fn commit_change(
    device_state: &[u8],
    group_state: &[u8],
    add_key_packages: &[Vec<u8>],
    remove_device_ids: &[Vec<u8>],
) -> Result<Commit, MlsError> {
    if add_key_packages.is_empty() && remove_device_ids.is_empty() {
        return Err(MlsError::bad_input("nothing to commit"));
    }
    if add_key_packages.len() > MAX_KEY_PACKAGES as usize {
        return Err(MlsError::bad_input(format!(
            "at most {MAX_KEY_PACKAGES} key packages per commit, got {}",
            add_key_packages.len()
        )));
    }
    if remove_device_ids.len() > MAX_KEY_PACKAGES as usize {
        return Err(MlsError::bad_input(format!(
            "at most {MAX_KEY_PACKAGES} removals per commit, got {}",
            remove_device_ids.len()
        )));
    }
    let ((bundle, epoch), device_out, group_out) = with_provider(
        device_state,
        Some(group_state),
        Partition::Group,
        |provider, header| {
            let mut group = load_group(provider, header)?;
            if group.pending_commit().is_some() {
                return Err(MlsError::new(
                    ErrorCode::PendingCommit,
                    "a commit is already pending",
                ));
            }
            if !group.is_active() {
                return Err(MlsError::new(
                    ErrorCode::Evicted,
                    "this device is no longer a member",
                ));
            }
            let adds = add_key_packages
                .iter()
                .map(|kp| parse_key_package(provider, kp))
                .collect::<Result<Vec<_>, _>>()?;
            check_adds(&group, &adds)?;
            let removals = removal_indexes(&group, header, remove_device_ids)?;
            let epoch = group.epoch().as_u64();
            let signer = load_signer(provider, header)?;
            let bundle = group
                .commit_builder()
                .consume_proposal_store(false)
                .propose_adds(adds)
                .propose_removals(removals)
                .load_psks(provider.storage())
                .map_err(map_commit_error)?
                .build(provider.rand(), provider.crypto(), &signer, |_| true)
                .map_err(map_commit_error)?
                .stage_commit(provider)
                .map_err(|_| MlsError::internal("staging the commit failed"))?;
            Ok((bundle, epoch))
        },
    )?;
    device_unchanged(device_state, &device_out)?;
    let commit = bundle
        .commit()
        .tls_serialize_detached()
        .map_err(|_| MlsError::internal("commit serialization failed"))?;
    let welcome = bundle
        .to_welcome_msg()
        .map(|w| {
            w.tls_serialize_detached()
                .map_err(|_| MlsError::internal("welcome serialization failed"))
        })
        .transpose()?;
    Ok(Commit {
        group_state: group_out.ok_or_else(|| MlsError::internal("group state missing"))?,
        commit,
        welcome,
        epoch,
    })
}

/// The server accepted the pending commit: merge it, moving the group to the next epoch.
pub fn confirm_commit(device_state: &[u8], group_state: &[u8]) -> Result<Vec<u8>, MlsError> {
    resolve_pending(device_state, group_state, |provider, group| {
        group
            .merge_pending_commit(provider)
            .map_err(|_| MlsError::internal("merging the pending commit failed"))
    })
}

/// The server refused the pending commit: drop it. The group is back at its pre-commit epoch and members, and can
/// commit, encrypt and process again.
pub fn discard_commit(device_state: &[u8], group_state: &[u8]) -> Result<Vec<u8>, MlsError> {
    resolve_pending(device_state, group_state, |provider, group| {
        group
            .clear_pending_commit(provider.storage())
            .map_err(|_| MlsError::internal("clearing the pending commit failed"))
    })
}

fn resolve_pending(
    device_state: &[u8],
    group_state: &[u8],
    f: impl FnOnce(&OpenMlsRustCrypto, &mut MlsGroup) -> Result<(), MlsError>,
) -> Result<Vec<u8>, MlsError> {
    let ((), device_out, group_out) = with_provider(
        device_state,
        Some(group_state),
        Partition::Group,
        |provider, header| {
            let mut group = load_group(provider, header)?;
            if group.pending_commit().is_none() {
                return Err(MlsError::new(
                    ErrorCode::NoPendingCommit,
                    "no commit is pending",
                ));
            }
            f(provider, &mut group)?;
            if group.pending_commit().is_some() {
                return Err(MlsError::internal("the pending commit is still pending"));
            }
            Ok(())
        },
    )?;
    device_unchanged(device_state, &device_out)?;
    group_out.ok_or_else(|| MlsError::internal("group state missing"))
}

pub struct Joined {
    /// The device blob after the join: a one-time key package's private part is gone. Persist it.
    pub device_state: Vec<u8>,
    /// The new group blob.
    pub group_state: Vec<u8>,
    pub group_id: Vec<u8>,
    pub epoch: u64,
}

/// Joins a group from a Welcome (an `MlsMessage`, as [`Commit::welcome`] produces it). A one-time key package is
/// consumed, so joining twice with it fails with `bad_input`; a last-resort package stays.
pub fn join_from_welcome(device_state: &[u8], welcome: &[u8]) -> Result<Joined, MlsError> {
    if welcome.len() > MAX_WIRE_LEN {
        return Err(MlsError::bad_input(format!(
            "welcome is {} bytes, at most {MAX_WIRE_LEN}",
            welcome.len()
        )));
    }
    let message = MlsMessageIn::tls_deserialize_exact(welcome)
        .map_err(|_| MlsError::bad_input("welcome is not an MLS message"))?;
    let MlsMessageBodyIn::Welcome(welcome) = message.extract() else {
        return Err(MlsError::bad_input("message is not a Welcome"));
    };
    if welcome.ciphersuite() != CIPHERSUITE {
        return Err(MlsError::bad_input("welcome uses another cipher suite"));
    }
    let ((group_id, epoch), device_out, group_out) =
        with_provider(device_state, None, Partition::Group, |provider, header| {
            let config = create_config();
            let staged =
                StagedWelcome::new_from_welcome(provider, config.join_config(), welcome, None)
                    .map_err(map_welcome_error)?;
            check_member_identities(&staged)?;
            let group_id = staged.group_context().group_id().as_slice().to_vec();
            header.set_group_id(&group_id)?;
            let group = staged.into_group(provider).map_err(map_welcome_error)?;
            Ok((group_id, group.epoch().as_u64()))
        })?;
    Ok(Joined {
        device_state: device_out,
        group_state: group_out.ok_or_else(|| MlsError::internal("group state missing"))?,
        group_id,
        epoch,
    })
}

pub struct Member {
    /// The member's MLS credential identity: its device id.
    pub device_id: Vec<u8>,
    /// The member's raw 32-byte Ed25519 public key.
    pub signature_public_key: Vec<u8>,
}

pub struct GroupInfo {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    /// Sorted by device id.
    pub members: Vec<Member>,
    pub has_pending_commit: bool,
}

/// Reads a group blob: id, epoch, members (sorted by device id) and whether a commit is pending. Needs no device
/// state.
pub fn describe(group_state: &[u8]) -> Result<GroupInfo, MlsError> {
    with_group_storage(group_state, |provider, group_id| {
        let group = MlsGroup::load(provider.storage(), &GroupId::from_slice(group_id))
            .map_err(|_| MlsError::corrupt_state("group state does not decode"))?
            .ok_or_else(|| MlsError::corrupt_state("group missing from group state"))?;
        let mut members: Vec<Member> = group
            .members()
            .map(|m| Member {
                device_id: m.credential.serialized_content().to_vec(),
                signature_public_key: m.signature_key,
            })
            .collect();
        members.sort_by(|a, b| a.device_id.cmp(&b.device_id));
        Ok(GroupInfo {
            group_id: group_id.to_vec(),
            epoch: group.epoch().as_u64(),
            members,
            has_pending_commit: group.pending_commit().is_some(),
        })
    })
}

/// The group named by the group blob's header, loaded from the provider's storage, and bound to the device blob:
/// the group's own leaf must carry the device's id and signature key, or the pair is `corrupt_state` (two blobs of
/// different devices). Every call that takes both blobs loads the group here, so the check runs before anything is
/// mutated or signed.
///
/// An inactive (evicted) group has a blank own leaf and nothing to bind to; it is returned unchecked, and every
/// caller refuses it with `evicted` before using it.
pub(crate) fn load_group(
    provider: &OpenMlsRustCrypto,
    header: &Header,
) -> Result<MlsGroup, MlsError> {
    let group_id = header
        .group_id()
        .ok_or_else(|| MlsError::internal("no group id"))?;
    let group = MlsGroup::load(provider.storage(), &GroupId::from_slice(&group_id))
        .map_err(|_| MlsError::corrupt_state("group state does not decode"))?
        .ok_or_else(|| MlsError::corrupt_state("group missing from group state"))?;
    if group.is_active() {
        let leaf = group
            .own_leaf_node()
            .ok_or_else(|| MlsError::corrupt_state("group state has no own leaf"))?;
        if leaf.credential().serialized_content() != header.device_id()
            || leaf.signature_key().as_slice() != header.signature_public_key()
        {
            return Err(MlsError::corrupt_state(
                "group state belongs to another device",
            ));
        }
    }
    Ok(group)
}

/// Only `join_from_welcome` may change the device blob. Every other group call checks that it did not, so a device
/// write can never be silently dropped.
pub(crate) fn device_unchanged(before: &[u8], after: &[u8]) -> Result<(), MlsError> {
    if before == after {
        Ok(())
    } else {
        Err(MlsError::internal("a group call changed the device state"))
    }
}

fn parse_key_package(provider: &OpenMlsRustCrypto, bytes: &[u8]) -> Result<KeyPackage, MlsError> {
    if bytes.len() > MAX_WIRE_LEN {
        return Err(MlsError::bad_input(format!(
            "key package is {} bytes, at most {MAX_WIRE_LEN}",
            bytes.len()
        )));
    }
    let kp = KeyPackageIn::tls_deserialize_exact(bytes)
        .map_err(|_| MlsError::bad_input("key package does not decode"))?
        .validate(provider.crypto(), ProtocolVersion::Mls10)
        .map_err(|_| MlsError::bad_input("key package is invalid"))?;
    if kp.ciphersuite() != CIPHERSUITE {
        return Err(MlsError::bad_input("key package uses another cipher suite"));
    }
    let identity_len = kp.leaf_node().credential().serialized_content().len();
    if !state::ID_LEN.contains(&identity_len) {
        return Err(MlsError::bad_input(format!(
            "key package identity is {identity_len} bytes"
        )));
    }
    Ok(kp)
}

/// Every member of a group being joined carries a 16 to 64 byte device id, and no device id appears twice;
/// otherwise the Welcome is refused before the group is accepted.
fn check_member_identities(staged: &StagedWelcome) -> Result<(), MlsError> {
    let mut seen = BTreeSet::new();
    for member in staged.members() {
        let id = member.credential.serialized_content().to_vec();
        if !state::ID_LEN.contains(&id.len()) {
            return Err(MlsError::bad_input(format!(
                "welcome has a member identity of {} bytes",
                id.len()
            )));
        }
        if !seen.insert(id) {
            return Err(MlsError::bad_input("welcome lists a device id twice"));
        }
    }
    Ok(())
}

/// Each added device appears once and is not already a member. OpenMLS would silently drop a duplicate add.
fn check_adds(group: &MlsGroup, adds: &[KeyPackage]) -> Result<(), MlsError> {
    let mut seen = BTreeSet::new();
    for kp in adds {
        let id = kp.leaf_node().credential().serialized_content();
        if !seen.insert(id) {
            return Err(MlsError::bad_input("device added twice"));
        }
        if group
            .members()
            .any(|m| m.credential.serialized_content() == id)
        {
            return Err(MlsError::bad_input("device is already a member"));
        }
    }
    Ok(())
}

/// Leaf indexes of the devices to remove. Unknown ids, duplicates and the caller's own id are `bad_input`.
fn removal_indexes(
    group: &MlsGroup,
    header: &Header,
    remove_device_ids: &[Vec<u8>],
) -> Result<Vec<LeafNodeIndex>, MlsError> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::with_capacity(remove_device_ids.len());
    for id in remove_device_ids {
        if !state::ID_LEN.contains(&id.len()) {
            return Err(MlsError::bad_input(format!(
                "device id must be 16 to 64 bytes, got {}",
                id.len()
            )));
        }
        if id.as_slice() == header.device_id() {
            return Err(MlsError::bad_input("cannot remove own device"));
        }
        if !seen.insert(id.as_slice()) {
            return Err(MlsError::bad_input("device id listed twice"));
        }
        let index = group
            .members()
            .find(|m| m.credential.serialized_content() == id.as_slice())
            .map(|m| m.index)
            .ok_or_else(|| MlsError::bad_input("device is not a member"))?;
        out.push(index);
    }
    Ok(out)
}

/// Failures the caller's key packages or removals cause are `bad_input`; the rest are internal.
fn map_commit_error(e: CreateCommitError) -> MlsError {
    match e {
        CreateCommitError::LibraryError(_)
        | CreateCommitError::SignatureError(_)
        | CreateCommitError::OwnKeyNotFound
        | CreateCommitError::MissingCredential
        | CreateCommitError::PskError(_) => MlsError::internal("building the commit failed"),
        _ => MlsError::bad_input("the requested change is invalid"),
    }
}

/// A Welcome that does not decrypt, match a key package or validate is `bad_input`; storage and library failures
/// are internal.
fn map_welcome_error<E>(e: WelcomeError<E>) -> MlsError {
    match e {
        WelcomeError::LibraryError(_) | WelcomeError::StorageError(_) => {
            MlsError::internal("joining the group failed")
        }
        _ => MlsError::bad_input("the welcome cannot be used"),
    }
}

// Debug prints sizes and counts only, so a stray `{:?}` can never print ids, keys or state.
impl fmt::Debug for Commit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Commit")
            .field("group_state_len", &self.group_state.len())
            .field("commit_len", &self.commit.len())
            .field("welcome_len", &self.welcome.as_ref().map(Vec::len))
            .field("epoch", &self.epoch)
            .finish()
    }
}

impl fmt::Debug for Joined {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Joined")
            .field("device_state_len", &self.device_state.len())
            .field("group_state_len", &self.group_state.len())
            .field("group_id_len", &self.group_id.len())
            .field("epoch", &self.epoch)
            .finish()
    }
}

impl fmt::Debug for Member {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Member")
            .field("device_id_len", &self.device_id.len())
            .field("signature_public_key_len", &self.signature_public_key.len())
            .finish()
    }
}

impl fmt::Debug for GroupInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupInfo")
            .field("group_id_len", &self.group_id.len())
            .field("epoch", &self.epoch)
            .field("member_count", &self.members.len())
            .field("has_pending_commit", &self.has_pending_commit)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls::prelude::{
        BasicCredential, CredentialWithKey, ProcessedMessageContent, ProtocolMessage,
    };
    use openmls::treesync::LeafNodeSource;
    use openmls_basic_credential::SignatureKeyPair;

    use crate::{create_device, generate_key_packages};

    struct Dev {
        id: Vec<u8>,
        state: Vec<u8>,
    }

    fn device(n: u8) -> Dev {
        let id = vec![n; 16];
        let state = create_device(&id).unwrap().device_state;
        Dev { id, state }
    }

    fn kp(dev: &mut Dev) -> Vec<u8> {
        let k = generate_key_packages(&dev.state, 1, false).unwrap();
        dev.state = k.device_state;
        k.key_packages.into_iter().next().unwrap()
    }

    /// alice creates a group and adds bob; both end at epoch 1. Returns (alice's, bob's) group states.
    fn pair(alice: &Dev, bob: &mut Dev) -> (Vec<u8>, Vec<u8>) {
        let g = create_group(&alice.state, &[0xAB; 32]).unwrap();
        let c = commit_change(&alice.state, &g, &[kp(bob)], &[]).unwrap();
        let a = confirm_commit(&alice.state, &c.group_state).unwrap();
        let j = join_from_welcome(&bob.state, &c.welcome.unwrap()).unwrap();
        bob.state = j.device_state;
        (a, j.group_state)
    }

    /// Runs `f` on the loaded group with raw OpenMLS and returns its value and the new group blob.
    fn on_group<T>(
        dev: &Dev,
        group_state: &[u8],
        f: impl FnOnce(&OpenMlsRustCrypto, &Header, &mut MlsGroup) -> T,
    ) -> (T, Vec<u8>) {
        let (value, _, g) = with_provider(
            &dev.state,
            Some(group_state),
            Partition::Group,
            |provider, header| {
                let mut group = load_group(provider, header)?;
                Ok(f(provider, header, &mut group))
            },
        )
        .unwrap();
        (value, g.unwrap())
    }

    fn send(dev: &Dev, group_state: &[u8], plaintext: &[u8]) -> (Vec<u8>, Vec<u8>) {
        on_group(dev, group_state, |provider, header, group| {
            let signer = load_signer(provider, header).unwrap();
            group
                .create_message(provider, &signer, plaintext)
                .unwrap()
                .tls_serialize_detached()
                .unwrap()
        })
    }

    /// Processes `wire`, merging a commit. Returns the application plaintext, or `None` for a commit.
    fn receive(dev: &Dev, group_state: &[u8], wire: &[u8]) -> (Option<Vec<u8>>, Vec<u8>) {
        on_group(dev, group_state, |provider, _, group| {
            let message: ProtocolMessage = MlsMessageIn::tls_deserialize_exact(wire)
                .unwrap()
                .try_into_protocol_message()
                .unwrap();
            match group
                .process_message(provider, message)
                .unwrap()
                .into_content()
            {
                ProcessedMessageContent::ApplicationMessage(m) => Some(m.into_bytes()),
                ProcessedMessageContent::StagedCommitMessage(staged) => {
                    group.merge_staged_commit(provider, *staged).unwrap();
                    None
                }
                _ => panic!("unexpected message content"),
            }
        })
    }

    #[test]
    fn create_and_join_run_the_one_configuration() {
        let config = create_config();
        let join = config.join_config();
        assert_eq!(
            join.wire_format_policy(),
            PURE_CIPHERTEXT_WIRE_FORMAT_POLICY
        );
        assert_eq!(
            join.sender_ratchet_configuration(),
            &SenderRatchetConfiguration::new(50, 1000)
        );
        assert_eq!(join.padding_size(), 0);
        assert_eq!(config.ciphersuite(), CIPHERSUITE);
        assert!(config.use_ratchet_tree_extension());
        assert_eq!(config.max_past_epochs(), Some(0));

        let alice = device(1);
        let mut bob = device(2);
        let (a, b) = pair(&alice, &mut bob);
        for (dev, g) in [(&alice, &a), (&bob, &b)] {
            let (stored, _) = on_group(dev, g, |_, _, group| group.configuration().clone());
            assert_eq!(&stored, join);
        }
    }

    #[test]
    fn the_creator_leaf_lives_five_years() {
        let alice = device(1);
        let g = create_group(&alice.state, &[0xAB; 32]).unwrap();
        let (source, _) = on_group(&alice, &g, |_, _, group| {
            group.own_leaf_node().unwrap().leaf_node_source().clone()
        });
        let LeafNodeSource::KeyPackage(lifetime) = source else {
            panic!("the creator leaf carries no lifetime");
        };
        // OpenMLS backdates `not_before` by one hour for skewed clocks.
        assert_eq!(
            lifetime.not_after() - lifetime.not_before(),
            crate::LIFETIME_SECONDS + 60 * 60
        );
    }

    #[test]
    fn discarded_group_still_encrypts_to_the_other_member() {
        let alice = device(1);
        let mut bob = device(2);
        let mut carol = device(3);
        let (a, b) = pair(&alice, &mut bob);
        let c = commit_change(&alice.state, &a, &[kp(&mut carol)], &[]).unwrap();
        let g = discard_commit(&alice.state, &c.group_state).unwrap();
        let (wire, _) = send(&alice, &g, b"after discard");
        let (plaintext, _) = receive(&bob, &b, &wire);
        assert_eq!(plaintext.as_deref(), Some(&b"after discard"[..]));
    }

    #[test]
    fn racing_loser_discards_and_merges_the_winner_with_raw_openmls() {
        // The group half of tests/group.rs `racing_commits_loser_recovers`, with raw OpenMLS standing in for
        // Task 3's `process`.
        let alice = device(1);
        let mut bob = device(2);
        let mut carol = device(3);
        let mut dave = device(4);
        let (a, b) = pair(&alice, &mut bob);
        let ca = commit_change(&alice.state, &a, &[kp(&mut carol)], &[]).unwrap();
        let dave_kp = kp(&mut dave);
        let cb = commit_change(&bob.state, &b, std::slice::from_ref(&dave_kp), &[]).unwrap();
        assert_eq!((ca.epoch, cb.epoch), (1, 1));
        let a2 = confirm_commit(&alice.state, &ca.group_state).unwrap();
        let b1 = discard_commit(&bob.state, &cb.group_state).unwrap();
        let (_, b2) = receive(&bob, &b1, &ca.commit);
        assert_eq!(describe(&b2).unwrap().epoch, 2);
        assert_eq!(describe(&a2).unwrap().epoch, 2);
        let retry = commit_change(&bob.state, &b2, &[dave_kp], &[]).unwrap();
        assert_eq!(retry.epoch, 2);
    }

    #[test]
    fn peer_follows_a_commit_made_after_a_discard() {
        // The discarded commit burned a handshake-ratchet generation; the next commit must still decrypt for bob.
        let alice = device(1);
        let mut bob = device(2);
        let mut carol = device(3);
        let mut dave = device(4);
        let (a, b) = pair(&alice, &mut bob);
        let c = commit_change(&alice.state, &a, &[kp(&mut carol)], &[]).unwrap();
        let g = discard_commit(&alice.state, &c.group_state).unwrap();
        let second = commit_change(&alice.state, &g, &[kp(&mut dave)], &[]).unwrap();
        let a2 = confirm_commit(&alice.state, &second.group_state).unwrap();
        let (_, b2) = receive(&bob, &b, &second.commit);
        assert_eq!(describe(&b2).unwrap().epoch, 2);
        let ids = |g: &[u8]| -> Vec<Vec<u8>> {
            describe(g)
                .unwrap()
                .members
                .into_iter()
                .map(|m| m.device_id)
                .collect()
        };
        assert_eq!(ids(&b2), ids(&a2));
        assert_eq!(ids(&a2), [alice.id, bob.id, dave.id]);
    }

    #[test]
    fn remove_only_commit_has_no_welcome() {
        let alice = device(1);
        let mut bob = device(2);
        let (a, _) = pair(&alice, &mut bob);
        let c = commit_change(&alice.state, &a, &[], &[bob.id.clone()]).unwrap();
        assert!(c.welcome.is_none());
        let a2 = confirm_commit(&alice.state, &c.group_state).unwrap();
        let info = describe(&a2).unwrap();
        assert_eq!(info.epoch, 2);
        assert_eq!(info.members.len(), 1);
        assert_eq!(info.members[0].device_id, alice.id);
    }

    #[test]
    fn device_guard_refuses_a_changed_device_state() {
        // Every public group call but join runs through device_unchanged; the integration tests show it never
        // fires on the normal paths, and this shows it does fire.
        assert!(device_unchanged(b"same", b"same").is_ok());
        assert_eq!(
            device_unchanged(b"before", b"after").unwrap_err().code,
            ErrorCode::Internal
        );
    }

    #[test]
    fn duplicate_removal_and_duplicate_add_are_bad_input() {
        let alice = device(1);
        let mut bob = device(2);
        let mut carol = device(3);
        let (a, _) = pair(&alice, &mut bob);
        let r = commit_change(&alice.state, &a, &[], &[bob.id.clone(), bob.id.clone()]);
        assert_eq!(r.unwrap_err().code, ErrorCode::BadInput);
        let carol_kp = kp(&mut carol);
        let r = commit_change(&alice.state, &a, &[carol_kp.clone(), carol_kp], &[]);
        assert_eq!(r.unwrap_err().code, ErrorCode::BadInput);
        let r = commit_change(&alice.state, &a, &[kp(&mut bob)], &[]);
        assert_eq!(r.unwrap_err().code, ErrorCode::BadInput);
    }

    #[test]
    fn a_group_state_refuses_any_device_but_its_own() {
        let alice = device(1);
        let mut bob = device(2);
        let mut carol = device(3);
        let (a, b) = pair(&alice, &mut bob);
        // Bob is a member, but this is alice's group blob; carol is not a member at all. Same device id with
        // another key (a device recreated under its old id) is refused too.
        let impostor = Dev {
            id: alice.id.clone(),
            state: create_device(&alice.id).unwrap().device_state,
        };
        let pending = commit_change(&alice.state, &a, &[kp(&mut carol)], &[])
            .unwrap()
            .group_state;
        let wire = crate::encrypt(&bob.state, &b, b"to alice")
            .unwrap()
            .ciphertext;
        for other in [&bob, &carol, &impostor] {
            let corrupt =
                |r: Result<(), MlsError>| assert_eq!(r.unwrap_err().code, ErrorCode::CorruptState);
            corrupt(crate::encrypt(&other.state, &a, b"x").map(|_| ()));
            corrupt(commit_change(&other.state, &a, &[], &[bob.id.clone()]).map(|_| ()));
            corrupt(crate::process(&other.state, &a, &wire).map(|_| ()));
            corrupt(confirm_commit(&other.state, &pending).map(|_| ()));
            corrupt(discard_commit(&other.state, &pending).map(|_| ()));
            // A wrong device is refused before the pending-commit rule.
            corrupt(commit_change(&other.state, &pending, &[], &[bob.id.clone()]).map(|_| ()));
        }
        // The owner still works.
        crate::process(&alice.state, &a, &wire).unwrap();
    }

    #[test]
    fn an_evicted_group_state_answers_evicted() {
        // After eviction the own leaf is blank, so there is nothing to bind to; every call refuses the inactive
        // group with `evicted` instead, whichever device blob comes with it.
        let alice = device(1);
        let mut bob = device(2);
        let mut carol = device(3);
        let (a, b) = pair(&alice, &mut bob);
        let c = commit_change(&alice.state, &a, &[], &[bob.id.clone()]).unwrap();
        let (_, gone) = receive(&bob, &b, &c.commit);
        let carol_kp = kp(&mut carol);
        for dev in [&bob, &carol] {
            let r = crate::encrypt(&dev.state, &gone, b"x");
            assert_eq!(r.unwrap_err().code, ErrorCode::Evicted);
            let r = commit_change(&dev.state, &gone, std::slice::from_ref(&carol_kp), &[]);
            assert_eq!(r.unwrap_err().code, ErrorCode::Evicted);
        }
    }

    /// Another suite with the same signature scheme, so only the suite check can refuse it.
    const OTHER_SUITE: openmls::prelude::Ciphersuite =
        openmls::prelude::Ciphersuite::MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519;

    /// A raw OpenMLS key package in [`OTHER_SUITE`], with its private parts in `provider`.
    fn other_suite_key_package(provider: &OpenMlsRustCrypto, identity: u8) -> KeyPackage {
        let signer = SignatureKeyPair::new(OTHER_SUITE.signature_algorithm()).unwrap();
        let credential = CredentialWithKey {
            credential: BasicCredential::new(vec![identity; 16]).into(),
            signature_key: signer.to_public_vec().into(),
        };
        KeyPackage::builder()
            .build(OTHER_SUITE, provider, &signer, credential)
            .unwrap()
            .key_package()
            .clone()
    }

    #[test]
    fn a_key_package_in_another_suite_is_refused() {
        let alice = device(1);
        let g = create_group(&alice.state, &[0xAB; 32]).unwrap();
        let kp = other_suite_key_package(&OpenMlsRustCrypto::default(), 2)
            .tls_serialize_detached()
            .unwrap();
        let e = commit_change(&alice.state, &g, &[kp], &[]).unwrap_err();
        assert_eq!(e.code, ErrorCode::BadInput);
        assert_eq!(e.message, "key package uses another cipher suite");
    }

    #[test]
    fn a_welcome_in_another_suite_is_refused() {
        // A whole raw OpenMLS group in the other suite welcomes a device; dzmls refuses the Welcome on its suite.
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(OTHER_SUITE.signature_algorithm()).unwrap();
        let credential = CredentialWithKey {
            credential: BasicCredential::new(vec![1; 16]).into(),
            signature_key: signer.to_public_vec().into(),
        };
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(OTHER_SUITE)
            .use_ratchet_tree_extension(true)
            .build();
        let mut group = MlsGroup::new(&provider, &signer, &config, credential).unwrap();
        let joiner = OpenMlsRustCrypto::default();
        let (_, welcome, _) = group
            .add_members(&provider, &signer, &[other_suite_key_package(&joiner, 2)])
            .unwrap();
        let welcome = welcome.tls_serialize_detached().unwrap();
        let bob = device(2);
        let e = join_from_welcome(&bob.state, &welcome).unwrap_err();
        assert_eq!(e.code, ErrorCode::BadInput);
        assert_eq!(e.message, "welcome uses another cipher suite");
    }

    #[test]
    fn more_than_100_adds_or_removals_are_refused() {
        // The batch limits are checked before anything is parsed, so placeholders suffice.
        let alice = device(1);
        let g = create_group(&alice.state, &[0xAB; 32]).unwrap();
        let e = commit_change(&alice.state, &g, &vec![vec![0u8]; 101], &[]).unwrap_err();
        assert_eq!(e.code, ErrorCode::BadInput);
        assert_eq!(e.message, "at most 100 key packages per commit, got 101");
        let e = commit_change(&alice.state, &g, &[], &vec![vec![7u8; 16]; 101]).unwrap_err();
        assert_eq!(e.code, ErrorCode::BadInput);
        assert_eq!(e.message, "at most 100 removals per commit, got 101");
    }

    #[test]
    fn describe_refuses_a_device_blob_and_garbage() {
        let alice = device(1);
        for blob in [alice.state.clone(), vec![], b"DZS1G".to_vec()] {
            assert_eq!(describe(&blob).unwrap_err().code, ErrorCode::CorruptState);
        }
    }

    #[test]
    fn debug_prints_sizes_only() {
        let alice = device(1);
        let mut bob = device(2);
        let g = create_group(&alice.state, &[0xAB; 32]).unwrap();
        let c = commit_change(&alice.state, &g, &[kp(&mut bob)], &[]).unwrap();
        let info = describe(&c.group_state).unwrap();
        let printed = format!("{c:?} {info:?} {:?}", info.members[0]);
        assert!(!printed.contains("171"), "group id bytes leaked: {printed}");
        assert!(!printed.contains('['), "a byte list leaked: {printed}");
        assert!(printed.contains("member_count: 1"));
    }
}
