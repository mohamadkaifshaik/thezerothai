//! The functions and types flutter_rust_bridge exposes to Dart: one function per `dzmls` function, nothing else.
//!
//! Every function is a plain (synchronous) Rust function; the bridge runs each call on its worker thread pool and
//! completes a Dart `Future`, so nothing runs on the UI isolate. A failure is returned as [`MlsError`] (the code is
//! `dzmls::ErrorCode::as_str()`), which Dart receives as a thrown exception. Messages carry codes and sizes only.
//! Nothing here logs.
//!
//! Callers must serialize calls: see `dzmls`.

use flutter_rust_bridge::frb;

/// A failed call: `code` is one of the stable `dzmls` error codes.
pub struct MlsError {
    pub code: String,
    pub message: String,
}

impl From<dzmls::MlsError> for MlsError {
    fn from(e: dzmls::MlsError) -> Self {
        MlsError {
            code: e.code.as_str().to_owned(),
            message: e.message,
        }
    }
}

pub struct DeviceCreated {
    pub device_state: Vec<u8>,
    pub signature_public_key: Vec<u8>,
}

pub struct KeyPackages {
    pub device_state: Vec<u8>,
    pub key_packages: Vec<Vec<u8>>,
}

pub struct Commit {
    pub group_state: Vec<u8>,
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub epoch: u64,
}

impl From<dzmls::Commit> for Commit {
    fn from(c: dzmls::Commit) -> Self {
        Commit {
            group_state: c.group_state,
            commit: c.commit,
            welcome: c.welcome,
            epoch: c.epoch,
        }
    }
}

pub struct Joined {
    pub device_state: Vec<u8>,
    pub group_state: Vec<u8>,
    pub group_id: Vec<u8>,
    pub epoch: u64,
}

pub struct Encrypted {
    pub group_state: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub epoch: u64,
}

/// An application message from another member.
pub struct MessageEvent {
    pub plaintext: Vec<u8>,
    pub sender_device_id: Vec<u8>,
}

/// Another member's commit, now merged.
pub struct CommitEvent {
    pub epoch: u64,
    pub added: Vec<Vec<u8>>,
    pub removed: Vec<Vec<u8>>,
    pub self_removed: bool,
}

/// Exactly one of `message` and `commit` is set. (A plain struct rather than an enum with data, which the bridge
/// would generate as a freezed class.)
pub struct Processed {
    pub group_state: Vec<u8>,
    pub message: Option<MessageEvent>,
    pub commit: Option<CommitEvent>,
}

pub struct Member {
    pub device_id: Vec<u8>,
    pub signature_public_key: Vec<u8>,
}

pub struct GroupInfo {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub members: Vec<Member>,
    pub has_pending_commit: bool,
}

pub struct Party {
    pub user_id: Vec<u8>,
    pub device_keys: Vec<Vec<u8>>,
}

/// Runs once when Dart initialises the library. Replaces the default panic hook, which would print the panic
/// message to stderr, with a silent one: a panic still unwinds and the bridge still reports it to Dart as an error.
#[frb(init)]
pub fn init_app() {
    std::panic::set_hook(Box::new(|_| {}));
}

pub fn create_device(device_id: Vec<u8>) -> Result<DeviceCreated, MlsError> {
    let d = dzmls::create_device(&device_id)?;
    Ok(DeviceCreated {
        device_state: d.device_state,
        signature_public_key: d.signature_public_key,
    })
}

pub fn generate_key_packages(
    device_state: Vec<u8>,
    count: u32,
    last_resort: bool,
) -> Result<KeyPackages, MlsError> {
    let k = dzmls::generate_key_packages(&device_state, count, last_resort)?;
    Ok(KeyPackages {
        device_state: k.device_state,
        key_packages: k.key_packages,
    })
}

pub fn create_group(device_state: Vec<u8>, group_id: Vec<u8>) -> Result<Vec<u8>, MlsError> {
    Ok(dzmls::create_group(&device_state, &group_id)?)
}

pub fn commit_change(
    device_state: Vec<u8>,
    group_state: Vec<u8>,
    add_key_packages: Vec<Vec<u8>>,
    remove_device_ids: Vec<Vec<u8>>,
) -> Result<Commit, MlsError> {
    Ok(dzmls::commit_change(
        &device_state,
        &group_state,
        &add_key_packages,
        &remove_device_ids,
    )?
    .into())
}

pub fn self_update(device_state: Vec<u8>, group_state: Vec<u8>) -> Result<Commit, MlsError> {
    Ok(dzmls::self_update(&device_state, &group_state)?.into())
}

pub fn confirm_commit(device_state: Vec<u8>, group_state: Vec<u8>) -> Result<Vec<u8>, MlsError> {
    Ok(dzmls::confirm_commit(&device_state, &group_state)?)
}

pub fn discard_commit(device_state: Vec<u8>, group_state: Vec<u8>) -> Result<Vec<u8>, MlsError> {
    Ok(dzmls::discard_commit(&device_state, &group_state)?)
}

pub fn join_from_welcome(device_state: Vec<u8>, welcome: Vec<u8>) -> Result<Joined, MlsError> {
    let j = dzmls::join_from_welcome(&device_state, &welcome)?;
    Ok(Joined {
        device_state: j.device_state,
        group_state: j.group_state,
        group_id: j.group_id,
        epoch: j.epoch,
    })
}

pub fn encrypt(
    device_state: Vec<u8>,
    group_state: Vec<u8>,
    plaintext: Vec<u8>,
) -> Result<Encrypted, MlsError> {
    let e = dzmls::encrypt(&device_state, &group_state, &plaintext)?;
    Ok(Encrypted {
        group_state: e.group_state,
        ciphertext: e.ciphertext,
        epoch: e.epoch,
    })
}

pub fn process(
    device_state: Vec<u8>,
    group_state: Vec<u8>,
    wire: Vec<u8>,
) -> Result<Processed, MlsError> {
    let p = dzmls::process(&device_state, &group_state, &wire)?;
    let (message, commit) = match p.event {
        dzmls::Event::Message {
            plaintext,
            sender_device_id,
        } => (
            Some(MessageEvent {
                plaintext,
                sender_device_id,
            }),
            None,
        ),
        dzmls::Event::Commit {
            epoch,
            added,
            removed,
            self_removed,
        } => (
            None,
            Some(CommitEvent {
                epoch,
                added,
                removed,
                self_removed,
            }),
        ),
    };
    Ok(Processed {
        group_state: p.group_state,
        message,
        commit,
    })
}

pub fn describe(group_state: Vec<u8>) -> Result<GroupInfo, MlsError> {
    let g = dzmls::describe(&group_state)?;
    Ok(GroupInfo {
        group_id: g.group_id,
        epoch: g.epoch,
        members: g
            .members
            .into_iter()
            .map(|m| Member {
                device_id: m.device_id,
                signature_public_key: m.signature_public_key,
            })
            .collect(),
        has_pending_commit: g.has_pending_commit,
    })
}

pub fn wire_epoch(wire: Vec<u8>) -> Result<u64, MlsError> {
    Ok(dzmls::wire_epoch(&wire)?)
}

pub fn security_code(a: Party, b: Party) -> Result<String, MlsError> {
    let party = |p: Party| dzmls::Party {
        user_id: p.user_id,
        device_keys: p.device_keys,
    };
    Ok(dzmls::security_code(&party(a), &party(b))?)
}
