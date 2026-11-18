//! Opaque, versioned state blobs and the provider they are loaded into.
//!
//! Layout (all integers big-endian):
//!
//! ```text
//! "DZS1" | kind: u8 ('D' device, 'G' group) | header | entry_count: u32 | entries
//! device header: device_id_len: u8 (16..=64) | device_id | pk_len: u8 (= 32) | signature_public_key
//! group header:  group_id_len: u8 (16..=64)  | group_id
//! entry:         key_len: u32 | key | value_len: u32 | value
//! ```
//!
//! Entries are the OpenMLS memory-storage key/value pairs, in strictly ascending key order, so two equal states are
//! byte-equal. The entry count makes truncation at any offset detectable, and trailing bytes are refused.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use openmls::prelude::OpenMlsProvider as _;
use openmls_rust_crypto::OpenMlsRustCrypto;

use crate::error::MlsError;

const MAGIC: &[u8; 4] = b"DZS1";
const KIND_DEVICE: u8 = b'D';
const KIND_GROUP: u8 = b'G';

/// Device ids and group ids are 16 to 64 bytes.
pub(crate) const ID_LEN: std::ops::RangeInclusive<usize> = 16..=64;
/// Ed25519 public keys are 32 bytes.
pub(crate) const SIGNATURE_PUBLIC_KEY_LEN: usize = 32;

type Entries = BTreeMap<Vec<u8>, Vec<u8>>;

/// Which blob receives the storage entries a [`with_provider`] closure creates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Partition {
    Device,
    Group,
}

/// What the blobs say about themselves, handed to the [`with_provider`] closure.
pub(crate) struct Header {
    device_id: Vec<u8>,
    signature_public_key: Vec<u8>,
    group_id: RefCell<Option<Vec<u8>>>,
}

impl Header {
    /// The MLS credential identity of this device.
    pub(crate) fn device_id(&self) -> &[u8] {
        &self.device_id
    }

    /// The device's Ed25519 public key; the private half lives in the device blob's OpenMLS storage.
    pub(crate) fn signature_public_key(&self) -> &[u8] {
        &self.signature_public_key
    }

    /// The group id from the group blob, or the one set by [`Header::set_group_id`].
    pub(crate) fn group_id(&self) -> Option<Vec<u8>> {
        self.group_id.borrow().clone()
    }

    /// Names the group whose blob this call produces. Needed when the call starts without a group blob (create,
    /// join), since the new group blob's header must carry its id. Write-once: setting a different id than the one
    /// already present is an internal error.
    pub(crate) fn set_group_id(&self, group_id: &[u8]) -> Result<(), MlsError> {
        if !ID_LEN.contains(&group_id.len()) {
            return Err(MlsError::bad_input(format!(
                "group id must be 16 to 64 bytes, got {}",
                group_id.len()
            )));
        }
        let mut slot = self.group_id.borrow_mut();
        match slot.as_deref() {
            Some(existing) if existing != group_id => {
                Err(MlsError::internal("group id already set"))
            }
            Some(_) => Ok(()),
            None => {
                *slot = Some(group_id.to_vec());
                Ok(())
            }
        }
    }
}

// Debug prints lengths only: the crate never puts ids or keys in Debug output.
impl fmt::Debug for Header {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Header")
            .field("device_id_len", &self.device_id.len())
            .field("signature_public_key_len", &self.signature_public_key.len())
            .field(
                "group_id_len",
                &self.group_id.borrow().as_ref().map(Vec::len),
            )
            .finish()
    }
}

/// Loads the entries of both blobs into one OpenMLS memory storage, runs `f`, then splits the result: an entry
/// that came from a blob stays in that blob; an entry `f` created goes to `new_entries`; a deleted entry is dropped.
///
/// Returns `f`'s value, the new device blob, and the group blob: `Some` when a group blob was passed in or `f`
/// called [`Header::set_group_id`], otherwise `None`. If `f` fails, no blob is returned, so the caller keeps its
/// old state and nothing half-applied can be persisted.
///
/// Callers must serialize calls: two concurrent calls on the same blob both succeed and one result is lost.
// The return type is spelled out on purpose: it is the contract Tasks 2 and 3 build on.
#[allow(clippy::type_complexity)]
pub(crate) fn with_provider<T>(
    device_state: &[u8],
    group_state: Option<&[u8]>,
    new_entries: Partition,
    f: impl FnOnce(&OpenMlsRustCrypto, &Header) -> Result<T, MlsError>,
) -> Result<(T, Vec<u8>, Option<Vec<u8>>), MlsError> {
    let device = decode_device(device_state)?;
    let group = group_state.map(decode_group).transpose()?;

    let device_keys: BTreeSet<Vec<u8>> = device.entries.keys().cloned().collect();
    let mut group_keys = BTreeSet::new();
    let provider = OpenMlsRustCrypto::default();
    {
        let mut values = provider
            .storage()
            .values
            .write()
            .map_err(|_| MlsError::internal("storage lock poisoned"))?;
        values.extend(device.entries);
        if let Some(group) = &group {
            for (key, value) in &group.entries {
                if device_keys.contains(key) {
                    return Err(MlsError::corrupt_state(
                        "an entry is in both the device and the group state",
                    ));
                }
                group_keys.insert(key.clone());
                values.insert(key.clone(), value.clone());
            }
        }
    }

    let header = Header {
        device_id: device.device_id,
        signature_public_key: device.signature_public_key,
        group_id: RefCell::new(group.map(|g| g.group_id)),
    };
    let value = f(&provider, &header)?;

    let values = std::mem::take(
        &mut *provider
            .storage()
            .values
            .write()
            .map_err(|_| MlsError::internal("storage lock poisoned"))?,
    );
    let mut device_out = Entries::new();
    let mut group_out = Entries::new();
    for (key, entry) in values {
        let target = if device_keys.contains(&key) {
            Partition::Device
        } else if group_keys.contains(&key) {
            Partition::Group
        } else {
            new_entries
        };
        match target {
            Partition::Device => device_out.insert(key, entry),
            Partition::Group => group_out.insert(key, entry),
        };
    }

    let group_blob = match header.group_id.into_inner() {
        Some(group_id) => Some(encode_group(&group_id, &group_out)?),
        None if group_out.is_empty() => None,
        None => {
            return Err(MlsError::internal(
                "group entries created without a group id",
            ));
        }
    };
    let device_blob = encode_device(&header.device_id, &header.signature_public_key, &device_out)?;
    Ok((value, device_blob, group_blob))
}

/// Loads a group blob alone into a fresh OpenMLS memory storage and runs `f` with the storage and the blob's group
/// id. Read-only: whatever `f` writes is thrown away, and no blob is returned. For calls that need no device key,
/// such as `describe`.
pub(crate) fn with_group_storage<T>(
    group_state: &[u8],
    f: impl FnOnce(&OpenMlsRustCrypto, &[u8]) -> Result<T, MlsError>,
) -> Result<T, MlsError> {
    let group = decode_group(group_state)?;
    let provider = OpenMlsRustCrypto::default();
    provider
        .storage()
        .values
        .write()
        .map_err(|_| MlsError::internal("storage lock poisoned"))?
        .extend(group.entries);
    f(&provider, &group.group_id)
}

/// A device blob with no storage entries yet, the starting point of `create_device`.
pub(crate) fn empty_device_state(
    device_id: &[u8],
    signature_public_key: &[u8],
) -> Result<Vec<u8>, MlsError> {
    encode_device(device_id, signature_public_key, &Entries::new())
}

struct DeviceBlob {
    device_id: Vec<u8>,
    signature_public_key: Vec<u8>,
    entries: Entries,
}

struct GroupBlob {
    group_id: Vec<u8>,
    entries: Entries,
}

fn encode_device(
    device_id: &[u8],
    signature_public_key: &[u8],
    entries: &Entries,
) -> Result<Vec<u8>, MlsError> {
    let mut out = start(KIND_DEVICE);
    put_short(&mut out, device_id)?;
    put_short(&mut out, signature_public_key)?;
    put_entries(&mut out, entries)?;
    Ok(out)
}

fn encode_group(group_id: &[u8], entries: &Entries) -> Result<Vec<u8>, MlsError> {
    let mut out = start(KIND_GROUP);
    put_short(&mut out, group_id)?;
    put_entries(&mut out, entries)?;
    Ok(out)
}

fn decode_device(blob: &[u8]) -> Result<DeviceBlob, MlsError> {
    let mut r = Reader::open(blob, KIND_DEVICE)?;
    let device_id = r.id()?;
    let signature_public_key = r.short()?;
    if signature_public_key.len() != SIGNATURE_PUBLIC_KEY_LEN {
        return Err(MlsError::corrupt_state(format!(
            "signature public key is {} bytes",
            signature_public_key.len()
        )));
    }
    let entries = r.entries()?;
    Ok(DeviceBlob {
        device_id,
        signature_public_key,
        entries,
    })
}

fn decode_group(blob: &[u8]) -> Result<GroupBlob, MlsError> {
    let mut r = Reader::open(blob, KIND_GROUP)?;
    let group_id = r.id()?;
    let entries = r.entries()?;
    Ok(GroupBlob { group_id, entries })
}

fn start(kind: u8) -> Vec<u8> {
    let mut out = Vec::with_capacity(256);
    out.extend_from_slice(MAGIC);
    out.push(kind);
    out
}

fn put_short(out: &mut Vec<u8>, bytes: &[u8]) -> Result<(), MlsError> {
    let len = u8::try_from(bytes.len()).map_err(|_| MlsError::internal("header field too long"))?;
    out.push(len);
    out.extend_from_slice(bytes);
    Ok(())
}

fn put_long(out: &mut Vec<u8>, bytes: &[u8]) -> Result<(), MlsError> {
    put_u32(out, bytes.len())?;
    out.extend_from_slice(bytes);
    Ok(())
}

fn put_u32(out: &mut Vec<u8>, n: usize) -> Result<(), MlsError> {
    let n = u32::try_from(n).map_err(|_| MlsError::internal("state entry too large"))?;
    out.extend_from_slice(&n.to_be_bytes());
    Ok(())
}

fn put_entries(out: &mut Vec<u8>, entries: &Entries) -> Result<(), MlsError> {
    put_u32(out, entries.len())?;
    for (key, value) in entries {
        put_long(out, key)?;
        put_long(out, value)?;
    }
    Ok(())
}

/// A bounds-checked cursor: every length is checked against the bytes left before anything is read or allocated.
struct Reader<'a> {
    rest: &'a [u8],
}

impl<'a> Reader<'a> {
    fn open(blob: &'a [u8], kind: u8) -> Result<Self, MlsError> {
        let mut r = Reader { rest: blob };
        if r.take(MAGIC.len())? != MAGIC {
            return Err(MlsError::corrupt_state("not a DZS1 state blob"));
        }
        if r.take(1)?[0] != kind {
            return Err(MlsError::corrupt_state("wrong state blob kind"));
        }
        Ok(r)
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], MlsError> {
        if n > self.rest.len() {
            return Err(MlsError::corrupt_state(format!(
                "state blob truncated: need {n} bytes, {} left",
                self.rest.len()
            )));
        }
        let (head, tail) = self.rest.split_at(n);
        self.rest = tail;
        Ok(head)
    }

    fn short(&mut self) -> Result<Vec<u8>, MlsError> {
        let len = self.take(1)?[0] as usize;
        Ok(self.take(len)?.to_vec())
    }

    fn id(&mut self) -> Result<Vec<u8>, MlsError> {
        let id = self.short()?;
        if !ID_LEN.contains(&id.len()) {
            return Err(MlsError::corrupt_state(format!(
                "header id is {} bytes",
                id.len()
            )));
        }
        Ok(id)
    }

    fn u32(&mut self) -> Result<usize, MlsError> {
        let bytes: [u8; 4] = self
            .take(4)?
            .try_into()
            .map_err(|_| MlsError::internal("length read failed"))?;
        usize::try_from(u32::from_be_bytes(bytes))
            .map_err(|_| MlsError::corrupt_state("length overflows usize"))
    }

    fn long(&mut self) -> Result<&'a [u8], MlsError> {
        let len = self.u32()?;
        self.take(len)
    }

    /// Reads the counted entries and requires the blob to end right after them.
    fn entries(mut self) -> Result<Entries, MlsError> {
        let count = self.u32()?;
        let mut entries = Entries::new();
        let mut previous: Option<&[u8]> = None;
        for _ in 0..count {
            let key = self.long()?;
            let value = self.long()?;
            if previous.is_some_and(|p| p >= key) {
                return Err(MlsError::corrupt_state("state entries out of order"));
            }
            previous = Some(key);
            entries.insert(key.to_vec(), value.to_vec());
        }
        if !self.rest.is_empty() {
            return Err(MlsError::corrupt_state(format!(
                "{} trailing bytes after state entries",
                self.rest.len()
            )));
        }
        Ok(entries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    const DEVICE_ID: [u8; 16] = [7; 16];
    const PK: [u8; 32] = [9; 32];
    const GROUP_ID: [u8; 20] = [3; 20];

    fn entries(pairs: &[(&[u8], &[u8])]) -> Entries {
        pairs
            .iter()
            .map(|(k, v)| (k.to_vec(), v.to_vec()))
            .collect()
    }

    fn device_blob(pairs: &[(&[u8], &[u8])]) -> Vec<u8> {
        encode_device(&DEVICE_ID, &PK, &entries(pairs)).unwrap()
    }

    fn group_blob(pairs: &[(&[u8], &[u8])]) -> Vec<u8> {
        encode_group(&GROUP_ID, &entries(pairs)).unwrap()
    }

    fn put(provider: &OpenMlsRustCrypto, key: &[u8], value: &[u8]) {
        provider
            .storage()
            .values
            .write()
            .unwrap()
            .insert(key.to_vec(), value.to_vec());
    }

    fn remove(provider: &OpenMlsRustCrypto, key: &[u8]) {
        provider.storage().values.write().unwrap().remove(key);
    }

    // No Debug bound: the blob types deliberately do not implement Debug, so state bytes cannot be printed.
    fn code<T>(r: Result<T, MlsError>) -> ErrorCode {
        match r {
            Ok(_) => panic!("expected an error"),
            Err(e) => e.code,
        }
    }

    #[test]
    fn blobs_round_trip() {
        let d = decode_device(&device_blob(&[(b"a", b"1"), (b"b", b"")])).unwrap();
        assert_eq!(d.device_id, DEVICE_ID);
        assert_eq!(d.signature_public_key, PK);
        assert_eq!(d.entries, entries(&[(b"a", b"1"), (b"b", b"")]));
        let g = decode_group(&group_blob(&[(b"x", b"2")])).unwrap();
        assert_eq!(g.group_id, GROUP_ID);
        assert_eq!(g.entries, entries(&[(b"x", b"2")]));
    }

    #[test]
    fn noop_call_returns_byte_identical_blobs() {
        let device = device_blob(&[(b"a", b"1"), (b"c", b"3")]);
        let group = group_blob(&[(b"b", b"2")]);
        let ((), d, g) =
            with_provider(&device, Some(&group), Partition::Group, |_, _| Ok(())).unwrap();
        assert_eq!(d, device);
        assert_eq!(g, Some(group));
    }

    #[test]
    fn entries_stay_in_their_blob_new_ones_follow_the_partition_deleted_ones_drop() {
        let device = device_blob(&[(b"d1", b"old"), (b"d2", b"gone")]);
        let group = group_blob(&[(b"g1", b"old")]);
        for (partition, new_in_device) in [(Partition::Device, true), (Partition::Group, false)] {
            let ((), d, g) = with_provider(&device, Some(&group), partition, |p, _| {
                put(p, b"d1", b"new");
                put(p, b"g1", b"new");
                remove(p, b"d2");
                put(p, b"n1", b"created");
                Ok(())
            })
            .unwrap();
            let d = decode_device(&d).unwrap().entries;
            let g = decode_group(&g.unwrap()).unwrap().entries;
            let created: &[(&[u8], &[u8])] = &[(b"n1", b"created")];
            let mut want_d = entries(&[(b"d1", b"new")]);
            let mut want_g = entries(&[(b"g1", b"new")]);
            if new_in_device {
                want_d.extend(entries(created));
            } else {
                want_g.extend(entries(created));
            }
            assert_eq!(d, want_d);
            assert_eq!(g, want_g);
        }
    }

    #[test]
    fn closure_sees_the_header() {
        let device = device_blob(&[]);
        let group = group_blob(&[]);
        let (seen, _, _) = with_provider(&device, Some(&group), Partition::Group, |_, h| {
            Ok((
                h.device_id().to_vec(),
                h.signature_public_key().to_vec(),
                h.group_id(),
            ))
        })
        .unwrap();
        assert_eq!(
            seen,
            (DEVICE_ID.to_vec(), PK.to_vec(), Some(GROUP_ID.to_vec()))
        );
    }

    #[test]
    fn group_storage_alone_sees_the_group_entries_and_id() {
        let group = group_blob(&[(b"g", b"2")]);
        let (id, value) = with_group_storage(&group, |p, id| {
            let value = p.storage().values.read().unwrap().get(&b"g"[..]).cloned();
            Ok((id.to_vec(), value))
        })
        .unwrap();
        assert_eq!(id, GROUP_ID);
        assert_eq!(value, Some(b"2".to_vec()));
        assert_eq!(
            code(with_group_storage(&device_blob(&[]), |_, _| Ok(()))),
            ErrorCode::CorruptState
        );
    }

    #[test]
    fn header_debug_prints_lengths_only() {
        let (printed, _, _) = with_provider(
            &device_blob(&[]),
            Some(&group_blob(&[])),
            Partition::Group,
            |_, h| Ok(format!("{h:?}")),
        )
        .unwrap();
        assert_eq!(
            printed,
            "Header { device_id_len: 16, signature_public_key_len: 32, group_id_len: Some(20) }"
        );
    }

    #[test]
    fn set_group_id_creates_the_group_blob() {
        let device = device_blob(&[(b"d", b"1")]);
        let ((), d, g) = with_provider(&device, None, Partition::Group, |p, h| {
            h.set_group_id(&GROUP_ID)?;
            put(p, b"g", b"2");
            Ok(())
        })
        .unwrap();
        assert_eq!(d, device);
        assert_eq!(g, Some(group_blob(&[(b"g", b"2")])));
    }

    #[test]
    fn group_entries_without_a_group_id_are_an_internal_error() {
        let device = device_blob(&[]);
        let r = with_provider(&device, None, Partition::Group, |p, _| {
            put(p, b"g", b"2");
            Ok(())
        });
        assert_eq!(code(r), ErrorCode::Internal);
    }

    #[test]
    fn set_group_id_is_write_once_and_length_checked() {
        let device = device_blob(&[]);
        let group = group_blob(&[]);
        let r = with_provider(&device, Some(&group), Partition::Group, |_, h| {
            h.set_group_id(&[4; 20])
        });
        assert_eq!(code(r), ErrorCode::Internal);
        let r = with_provider(&device, Some(&group), Partition::Group, |_, h| {
            h.set_group_id(&GROUP_ID)
        });
        assert!(r.is_ok());
        let r = with_provider(&device, None, Partition::Group, |_, h| {
            h.set_group_id(&[4; 15])
        });
        assert_eq!(code(r), ErrorCode::BadInput);
    }

    #[test]
    fn closure_error_is_returned_unchanged() {
        let device = device_blob(&[]);
        let r: Result<((), _, _), _> = with_provider(&device, None, Partition::Device, |_, _| {
            Err(MlsError::bad_input("nope"))
        });
        assert_eq!(r.unwrap_err(), MlsError::bad_input("nope"));
    }

    #[test]
    fn same_key_in_both_blobs_is_corrupt() {
        let device = device_blob(&[(b"k", b"1")]);
        let group = group_blob(&[(b"k", b"2")]);
        let r = with_provider(&device, Some(&group), Partition::Group, |_, _| Ok(()));
        assert_eq!(code(r), ErrorCode::CorruptState);
    }

    #[test]
    fn every_truncation_is_corrupt() {
        let device = device_blob(&[(b"a", b"1"), (b"b", b"22")]);
        for cut in 0..device.len() {
            assert_eq!(
                code(decode_device(&device[..cut])),
                ErrorCode::CorruptState,
                "cut at {cut}"
            );
        }
        let group = group_blob(&[(b"a", b"1")]);
        for cut in 0..group.len() {
            assert_eq!(
                code(decode_group(&group[..cut])),
                ErrorCode::CorruptState,
                "cut at {cut}"
            );
        }
    }

    #[test]
    fn malformed_blobs_are_corrupt() {
        let device = device_blob(&[(b"a", b"1")]);
        let mut trailing = device.clone();
        trailing.push(0);
        assert_eq!(code(decode_device(&trailing)), ErrorCode::CorruptState);
        assert_eq!(
            code(decode_device(&group_blob(&[]))),
            ErrorCode::CorruptState
        );
        assert_eq!(code(decode_group(&device)), ErrorCode::CorruptState);

        // Same key twice, and keys out of order.
        let mut dup = start(KIND_GROUP);
        put_short(&mut dup, &GROUP_ID).unwrap();
        put_u32(&mut dup, 2).unwrap();
        for key in [b"k", b"k"] {
            put_long(&mut dup, key).unwrap();
            put_long(&mut dup, b"v").unwrap();
        }
        assert_eq!(code(decode_group(&dup)), ErrorCode::CorruptState);
        let mut unsorted = start(KIND_GROUP);
        put_short(&mut unsorted, &GROUP_ID).unwrap();
        put_u32(&mut unsorted, 2).unwrap();
        for key in [b"b", b"a"] {
            put_long(&mut unsorted, key).unwrap();
            put_long(&mut unsorted, b"v").unwrap();
        }
        assert_eq!(code(decode_group(&unsorted)), ErrorCode::CorruptState);

        // A huge declared length must fail on bounds, not try to allocate.
        let mut huge = start(KIND_GROUP);
        put_short(&mut huge, &GROUP_ID).unwrap();
        put_u32(&mut huge, 1).unwrap();
        huge.extend_from_slice(&u32::MAX.to_be_bytes());
        assert_eq!(code(decode_group(&huge)), ErrorCode::CorruptState);

        // Header ids outside 16..=64 and a public key that is not 32 bytes.
        let bad_id = encode_device(&[1; 15], &PK, &Entries::new()).unwrap();
        assert_eq!(code(decode_device(&bad_id)), ErrorCode::CorruptState);
        let bad_pk = encode_device(&DEVICE_ID, &[1; 31], &Entries::new()).unwrap();
        assert_eq!(code(decode_device(&bad_pk)), ErrorCode::CorruptState);
    }
}
