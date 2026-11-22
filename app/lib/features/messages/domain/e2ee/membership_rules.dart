import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/crypto_types.dart';
import '../../../../core/crypto/mls_derivations.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/vault/vault_records.dart';
import '../../../../gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import 'device_directory.dart';

// Pure rules of the encrypted-message pipeline: claimed key packages (R3),
// welcomes (R5), attribution of devices to a side (M2), removals (M3, M4) and
// the parties of a security code (R4). No engine, no vault, no network, no
// clock read: times are parameters. The result types define no `toString`.
//
// A device list that is not `readable` (unreadable or deferred) is UNKNOWN,
// never "empty": every rule below reads it as "no match" for attribution and
// as "no decision" for removals and claims.

/// The newest conversation copy the server may have used to decide "accepted"
/// when it answered `GetKeyDevices` (up to 60 s stale).
const Duration kConversationCopyStale = Duration(seconds: 60);

/// Two counting fetches that lacked a peer device must be this far apart (M4).
const Duration kPeerRemovalFetchGap = Duration(minutes: 2);

/// A member must have been unattributed this long before it is removed (M2).
const Duration kUnattributedRecheck = Duration(minutes: 2);

/// The most members a group holds (R5).
const int kMaxGroupMembers = 10;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Lower-case hex of a device id. Callers must build every `ownDeviceIdsHex`
/// set (and any other hex form of a device id compared here) with this
/// function.
String deviceIdHex(Uint8List deviceId) => _hex(deviceId);

/// Constant-time equality of two byte lists (the length is not secret).
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

DirectoryDevice? _entry(DeviceList list, Uint8List deviceId) {
  for (final d in list.devices) {
    if (_bytesEqual(d.deviceId, deviceId)) return d;
  }
  return null;
}

bool _listsPair(DeviceList list, Uint8List deviceId, Uint8List key) {
  if (!list.readable) return false;
  final d = _entry(list, deviceId);
  return d != null && _bytesEqual(d.signatureKey, key);
}

// --- R3 -----------------------------------------------------------------

enum ClaimSide { mine, theirs }

/// A claimed key package that passed [checkClaims]. No `toString`.
class UsableClaim {
  const UsableClaim({
    required this.deviceId,
    required this.signatureKey,
    required this.keyPackage,
    required this.side,
  });

  final Uint8List deviceId;
  final Uint8List signatureKey;
  final Uint8List keyPackage;
  final ClaimSide side;
}

/// What [checkClaims] decided. A class, not a record: a record's built-in
/// `toString` would print the device ids. No `toString`.
class ClaimCheck {
  const ClaimCheck({required this.usable, required this.emptyFor});

  final List<UsableClaim> usable;

  /// Device ids whose claim carried no package (for `kEmptyClaimRetry`).
  final List<Uint8List> emptyFor;
}

String _sideName(ClaimSide side) =>
    side == ClaimSide.mine ? MemberSide.mine : MemberSide.theirs;

/// Keeps a claimed package only when ALL hold: the engine's inspection of it
/// (`inspected[i]`, null when it failed or is missing) names the claimed
/// device id and signature key; the directory list the claim was made for is
/// readable and lists that id with that key, not inactive; the device is not
/// [thisDeviceId], not already in [members] (skipped for [forNewGroup]), and
/// not repeated among the claims (every copy is dropped); its key is not
/// repeated under two ids in the claims (every claim with it is dropped); its
/// key is not pinned in [members] to the OTHER attributed side or to another
/// device id (a pin that is unattributed, same id and same key, does not
/// refuse: a reset must be able to reclaim it); its id is not pinned in
/// [members] with ANOTHER key, on any side, [forNewGroup] included (a known
/// id never changes key); for [ClaimSide.theirs] the id
/// is not in [ownList] and [ownList] is readable (an unknown own list cannot
/// show that a device is not ours); and, when [admissible] is given (the
/// conversation's device key history, `KeyHistory.admissible`, with the id
/// as [deviceIdHex]), it answers true for the pair: a device the history
/// would refuse is never added.
/// Claims without a package go to `emptyFor` (device ids) and nowhere else,
/// and only when the directory is readable, lists the id as active and the id
/// is not repeated in the claims.
ClaimCheck checkClaims({
  required ClaimSide side,
  required List<pb.ClaimedKeyPackage> claimed,
  required List<KeyPackageInfo?> inspected,
  required DeviceList directory,
  required DeviceList ownList,
  required List<MemberRecord> members,
  required Uint8List thisDeviceId,
  bool forNewGroup = false,
  bool Function(String deviceIdHex, Uint8List signatureKey)? admissible,
}) {
  final usable = <UsableClaim>[];
  final emptyFor = <Uint8List>[];
  final counts = <String, int>{};
  final keyCounts = <String, int>{};
  for (final c in claimed) {
    counts.update(
      deviceIdHex(Uint8List.fromList(utf8.encode(c.deviceId))),
      (n) => n + 1,
      ifAbsent: () => 1,
    );
    if (c.signaturePublicKey.isNotEmpty) {
      keyCounts.update(
        _hex(c.signaturePublicKey),
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
  }
  final sideName = _sideName(side);
  for (var i = 0; i < claimed.length; i++) {
    final c = claimed[i];
    final id = Uint8List.fromList(utf8.encode(c.deviceId));
    if (!c.hasKeyPackage_4) {
      final listed = directory.readable ? _entry(directory, id) : null;
      if (listed != null && !listed.inactive && counts[deviceIdHex(id)]! == 1) {
        emptyFor.add(id);
      }
      continue;
    }
    final info = i < inspected.length ? inspected[i] : null;
    if (info == null || c.keyPackage.isEmpty) continue;
    final key = Uint8List.fromList(c.signaturePublicKey);
    if (!_bytesEqual(info.deviceId, id)) continue;
    if (!_bytesEqual(info.signaturePublicKey, key)) continue;
    if (!directory.readable) continue;
    final entry = _entry(directory, id);
    if (entry == null || entry.inactive) continue;
    if (!_bytesEqual(entry.signatureKey, key)) continue;
    if (_bytesEqual(id, thisDeviceId)) continue;
    if (counts[deviceIdHex(id)]! > 1) continue;
    if (keyCounts[_hex(key)]! > 1) continue;
    // A known device id never changes key (the contract refuses it): the same
    // id pinned with another key, on any side and for a new group too, is a
    // server hiding a new key behind a known id.
    if (members.any(
      (m) => _bytesEqual(m.deviceId, id) && !_bytesEqual(m.signatureKey, key),
    )) {
      continue;
    }
    if (!forNewGroup && members.any((m) => _bytesEqual(m.deviceId, id))) {
      continue;
    }
    final pinnedElsewhere = members.any(
      (m) =>
          _bytesEqual(m.signatureKey, key) &&
          (!_bytesEqual(m.deviceId, id) ||
              (m.side != MemberSide.unattributed && m.side != sideName)),
    );
    if (pinnedElsewhere) continue;
    if (side == ClaimSide.theirs) {
      if (!ownList.readable) continue;
      if (_entry(ownList, id) != null) continue;
    }
    if (admissible != null && !admissible(deviceIdHex(id), key)) continue;
    usable.add(
      UsableClaim(
        deviceId: id,
        signatureKey: key,
        keyPackage: Uint8List.fromList(c.keyPackage),
        side: side,
      ),
    );
  }
  return ClaimCheck(usable: usable, emptyFor: emptyFor);
}

// --- R5 -----------------------------------------------------------------

enum WelcomeVerdict { accept, permanent }

/// Permanent (acknowledge, counts as none) unless ALL hold: the joined group id
/// is `mlsGroupId(conversationId, label.generation)`; the joined epoch is
/// `label.epoch + 1`; the label is above both marks (an absent mark is below
/// everything); 1 to [kMaxGroupMembers] members; no signature key repeated; at
/// least one member that is not an own device. [ownDeviceIdsHex] must be built
/// with [deviceIdHex].
WelcomeVerdict checkWelcome({
  required String conversationId,
  required MlsPair label,
  required Uint8List joinedGroupId,
  required int joinedEpoch,
  required List<GroupMember> members,
  required MlsPair? afterPair,
  required MlsPair? joinHighWater,
  required Set<String> ownDeviceIdsHex,
}) {
  if (!_bytesEqual(
    joinedGroupId,
    mlsGroupId(conversationId, label.generation),
  )) {
    return WelcomeVerdict.permanent;
  }
  if (joinedEpoch != label.epoch + 1) return WelcomeVerdict.permanent;
  if (!MlsPair.above(label, afterPair) ||
      !MlsPair.above(label, joinHighWater)) {
    return WelcomeVerdict.permanent;
  }
  if (members.isEmpty || members.length > kMaxGroupMembers) {
    return WelcomeVerdict.permanent;
  }
  final keys = <String>{};
  for (final m in members) {
    if (!keys.add(_hex(m.signaturePublicKey))) return WelcomeVerdict.permanent;
  }
  final foreign = members.any(
    (m) => !ownDeviceIdsHex.contains(deviceIdHex(m.deviceId)),
  );
  return foreign ? WelcomeVerdict.accept : WelcomeVerdict.permanent;
}

// --- M2 -----------------------------------------------------------------

/// A [MemberSide] value. The own list wins when both lists have the device
/// with this key; a list that is not readable contributes no match; the
/// device id with another key matches nothing.
String attribute({
  required Uint8List deviceId,
  required Uint8List signatureKey,
  required DeviceList ownList,
  required DeviceList peerList,
}) {
  if (_listsPair(ownList, deviceId, signatureKey)) return MemberSide.mine;
  if (_listsPair(peerList, deviceId, signatureKey)) return MemberSide.theirs;
  return MemberSide.unattributed;
}

/// R6 step 5 for generation g+1: a member pinned at the end of g with the same
/// id and key and an attributed side keeps that side, without any list; any
/// other (including one pinned unattributed) is attributed from the lists with
/// [attribute].
String attributeAfterReset({
  required Uint8List deviceId,
  required Uint8List signatureKey,
  required List<MemberRecord> pinnedAtEndOfPrevious,
  required DeviceList ownList,
  required DeviceList peerList,
}) {
  for (final m in pinnedAtEndOfPrevious) {
    if (_bytesEqual(m.deviceId, deviceId) &&
        _bytesEqual(m.signatureKey, signatureKey) &&
        m.side != MemberSide.unattributed) {
      return m.side;
    }
  }
  return attribute(
    deviceId: deviceId,
    signatureKey: signatureKey,
    ownList: ownList,
    peerList: peerList,
  );
}

// --- the removal clock --------------------------------------------------

/// What this run knows toward a peer-side removal. Memory only; no `toString`.
class RemovalEvidence {
  const RemovalEvidence({this.acceptedSeenAt, this.firstMissAt});

  /// When this run first knew the conversation accepted.
  final DateTime? acceptedSeenAt;

  /// `fetchedAt` of the first counting fetch that lacked the device.
  final DateTime? firstMissAt;
}

/// True when [fetchedAt] may count toward a removal: the conversation is known
/// accepted and the fetch was made at least [kConversationCopyStale] after.
bool fetchCounts({
  required DateTime fetchedAt,
  required DateTime? acceptedSeenAt,
}) =>
    acceptedSeenAt != null &&
    !fetchedAt.isBefore(acceptedSeenAt.add(kConversationCopyStale));

/// M4. True only when ALL hold: the member is a peer-side one; the peer list is
/// readable, non-empty, lacks the device id, and its fetch counts; an earlier
/// counting fetch ([RemovalEvidence.firstMissAt]) lacked it at least
/// [kPeerRemovalFetchGap] before; and removing it leaves another peer-side
/// member ([theirMemberCount] counts the member itself). "Lacks" is by device
/// id only: an id never legitimately changes key, so a listed id with another
/// key is kept (conservative for removal; attribution stays pair-strict).
/// [theirMemberCount] is per call: a caller deciding several removals in one
/// pass must lower it after each removal it decides.
bool mayRemovePeerDevice({
  required MemberRecord member,
  required DeviceList peerList,
  required RemovalEvidence evidence,
  required int theirMemberCount,
}) {
  if (member.side != MemberSide.theirs) return false;
  if (!peerList.readableNonEmpty) return false;
  final fetchedAt = peerList.fetchedAt;
  final first = evidence.firstMissAt;
  if (fetchedAt == null || first == null) return false;
  final accepted = evidence.acceptedSeenAt;
  if (!fetchCounts(fetchedAt: fetchedAt, acceptedSeenAt: accepted)) {
    return false;
  }
  if (!fetchCounts(fetchedAt: first, acceptedSeenAt: accepted)) return false;
  if (_entry(peerList, member.deviceId) != null) return false;
  if (fetchedAt.difference(first) < kPeerRemovalFetchGap) return false;
  return theirMemberCount >= 2;
}

/// M3. True only when the member is an own-side one other than this device and
/// the own list is readable, non-empty and lacks the device id (inactive
/// devices are listed, so they are kept; matching is by id only, so a listed id
/// with another key is kept too). One list decides (stated limit L7).
bool mayRemoveOwnDevice({
  required MemberRecord member,
  required DeviceList ownList,
  required Uint8List thisDeviceId,
}) {
  if (member.side != MemberSide.mine) return false;
  if (_bytesEqual(member.deviceId, thisDeviceId)) return false;
  if (!ownList.readableNonEmpty) return false;
  return _entry(ownList, member.deviceId) == null;
}

/// M2. True only when the member is unattributed against both lists (each
/// readable, non-empty, with a counting fetch) and was first seen unattributed
/// at least [kUnattributedRecheck] before the EARLIER of the two fetches: both
/// lists must come from the re-check, so a device registered in the gap and
/// missing from a list read at first sight is never removed as a ghost.
bool mayRemoveUnattributed({
  required MemberRecord member,
  required DeviceList ownList,
  required DeviceList peerList,
  required DateTime firstSeenUnattributedAt,
  required DateTime? acceptedSeenAt,
}) {
  if (member.side != MemberSide.unattributed) return false;
  if (!ownList.readableNonEmpty || !peerList.readableNonEmpty) return false;
  final own = ownList.fetchedAt;
  final peer = peerList.fetchedAt;
  if (own == null || peer == null) return false;
  if (!fetchCounts(fetchedAt: own, acceptedSeenAt: acceptedSeenAt) ||
      !fetchCounts(fetchedAt: peer, acceptedSeenAt: acceptedSeenAt)) {
    return false;
  }
  final attributed =
      attribute(
        deviceId: member.deviceId,
        signatureKey: member.signatureKey,
        ownList: ownList,
        peerList: peerList,
      ) !=
      MemberSide.unattributed;
  if (attributed) return false;
  final earlier = own.isBefore(peer) ? own : peer;
  return earlier.difference(firstSeenUnattributedAt) >= kUnattributedRecheck;
}

// --- M1 -----------------------------------------------------------------

/// Devices to add: listed and not inactive in a readable list, not a member,
/// not this device, not listed twice (own side wins: every id of the own list,
/// inactive ones too, is withheld from the peer side); own side first; no peer
/// device at all unless the own list is readable; never more than
/// [kMaxGroupMembers] minus the current members.
List<DeviceToAdd> devicesToAdd({
  required DeviceList ownList,
  required DeviceList peerList,
  required List<MemberRecord> members,
  required Uint8List thisDeviceId,
}) {
  final room = kMaxGroupMembers - members.length;
  final out = <DeviceToAdd>[];
  if (room <= 0) return out;
  final taken = <String>{
    if (ownList.readable)
      for (final d in ownList.devices) deviceIdHex(d.deviceId),
  };
  void collect(DeviceList list, ClaimSide side) {
    if (!list.readable) return;
    for (final d in list.devices) {
      if (out.length >= room) return;
      if (d.inactive) continue;
      if (_bytesEqual(d.deviceId, thisDeviceId)) continue;
      if (members.any((m) => _bytesEqual(m.deviceId, d.deviceId))) continue;
      if (side == ClaimSide.mine) {
        if (out.any((e) => _bytesEqual(e.deviceId, d.deviceId))) continue;
      } else if (!taken.add(deviceIdHex(d.deviceId))) {
        continue;
      }
      out.add(DeviceToAdd(deviceId: d.deviceId, side: side));
    }
  }

  collect(ownList, ClaimSide.mine);
  // checkClaims drops every peer claim while the own list is not readable
  // (it cannot show the device is not ours): claiming one would only burn a
  // one-time key package and the per-target daily cap.
  if (ownList.readable) collect(peerList, ClaimSide.theirs);
  return out;
}

/// One device [devicesToAdd] returns. A class, not a record: a record's
/// built-in `toString` would print the device id. No `toString`.
class DeviceToAdd {
  const DeviceToAdd({required this.deviceId, required this.side});

  final Uint8List deviceId;
  final ClaimSide side;
}

// --- R4 -----------------------------------------------------------------

/// null while any member is unattributed (or a side has no key). Otherwise the
/// two parties for `CryptoEngine.securityCode`: user id =
/// utf8(`partyId(conversationId, keys of that side)`), device keys = that
/// side's keys.
({SecurityParty mine, SecurityParty theirs})? codeParties(
  String conversationId,
  List<MemberRecord> members,
) {
  final mine = <Uint8List>[];
  final theirs = <Uint8List>[];
  for (final m in members) {
    if (m.side == MemberSide.mine) {
      mine.add(m.signatureKey);
    } else if (m.side == MemberSide.theirs) {
      theirs.add(m.signatureKey);
    } else {
      return null;
    }
  }
  if (mine.isEmpty || theirs.isEmpty) return null;
  SecurityParty party(List<Uint8List> keys) => SecurityParty(
    userId: Uint8List.fromList(utf8.encode(partyId(conversationId, keys))),
    deviceKeys: keys,
  );
  return (mine: party(mine), theirs: party(theirs));
}
