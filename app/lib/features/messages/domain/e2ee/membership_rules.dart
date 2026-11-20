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

String _sideName(ClaimSide side) =>
    side == ClaimSide.mine ? MemberSide.mine : MemberSide.theirs;

/// Keeps a claimed package only when ALL hold: the engine's inspection of it
/// (`inspected[i]`, null when it failed or is missing) names the claimed
/// device id and signature key; the directory list the claim was made for is
/// readable and lists that id with that key, not inactive; the device is not
/// [thisDeviceId], not already in [members] (skipped for [forNewGroup]), and
/// not repeated among the claims (every copy is dropped); its key is not
/// pinned in [members] to the other side or to another device id; for
/// [ClaimSide.theirs] the id is not in [ownList] and [ownList] is readable
/// (an unknown own list cannot show that a device is not ours).
/// Claims without a package go to `emptyFor` (device ids) and nowhere else.
({List<UsableClaim> usable, List<Uint8List> emptyFor}) checkClaims({
  required ClaimSide side,
  required List<pb.ClaimedKeyPackage> claimed,
  required List<KeyPackageInfo?> inspected,
  required DeviceList directory,
  required DeviceList ownList,
  required List<MemberRecord> members,
  required Uint8List thisDeviceId,
  bool forNewGroup = false,
}) {
  final usable = <UsableClaim>[];
  final emptyFor = <Uint8List>[];
  final counts = <String, int>{};
  for (final c in claimed) {
    counts.update(
      _hex(utf8.encode(c.deviceId)),
      (n) => n + 1,
      ifAbsent: () => 1,
    );
  }
  final sideName = _sideName(side);
  for (var i = 0; i < claimed.length; i++) {
    final c = claimed[i];
    final id = Uint8List.fromList(utf8.encode(c.deviceId));
    if (!c.hasKeyPackage_4) {
      emptyFor.add(id);
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
    if (counts[_hex(id)]! > 1) continue;
    if (!forNewGroup && members.any((m) => _bytesEqual(m.deviceId, id))) {
      continue;
    }
    final pinnedElsewhere = members.any(
      (m) =>
          _bytesEqual(m.signatureKey, key) &&
          (m.side != sideName || !_bytesEqual(m.deviceId, id)),
    );
    if (pinnedElsewhere) continue;
    if (side == ClaimSide.theirs) {
      if (!ownList.readable) continue;
      if (_entry(ownList, id) != null) continue;
    }
    usable.add(
      UsableClaim(
        deviceId: id,
        signatureKey: key,
        keyPackage: Uint8List.fromList(c.keyPackage),
        side: side,
      ),
    );
  }
  return (usable: usable, emptyFor: emptyFor);
}

// --- R5 -----------------------------------------------------------------

enum WelcomeVerdict { accept, permanent }

/// Permanent (acknowledge, counts as none) unless ALL hold: the joined group id
/// is `mlsGroupId(conversationId, label.generation)`; the joined epoch is
/// `label.epoch + 1`; the label is above both marks (an absent mark is below
/// everything); 1 to [kMaxGroupMembers] members; no signature key repeated; at
/// least one member that is not an own device.
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
    (m) => !ownDeviceIdsHex.contains(_hex(m.deviceId)),
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
/// id and key keeps its side, without any list; any other is attributed with
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
        _bytesEqual(m.signatureKey, signatureKey)) {
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
/// member ([theirMemberCount] counts the member itself).
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
/// devices are listed, so they are kept). One list decides (stated limit L7).
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
/// at least [kUnattributedRecheck] before the later of the two fetches.
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
  final later = own.isAfter(peer) ? own : peer;
  return later.difference(firstSeenUnattributedAt) >= kUnattributedRecheck;
}

// --- M1 -----------------------------------------------------------------

/// Devices to add: listed and not inactive in a readable list, not a member,
/// not this device, not listed twice (own side wins); own side first; never
/// more than [kMaxGroupMembers] minus the current members.
List<({Uint8List deviceId, ClaimSide side})> devicesToAdd({
  required DeviceList ownList,
  required DeviceList peerList,
  required List<MemberRecord> members,
  required Uint8List thisDeviceId,
}) {
  final room = kMaxGroupMembers - members.length;
  final out = <({Uint8List deviceId, ClaimSide side})>[];
  if (room <= 0) return out;
  final taken = <String>{};
  void collect(DeviceList list, ClaimSide side) {
    if (!list.readable) return;
    for (final d in list.devices) {
      if (out.length >= room) return;
      if (d.inactive) continue;
      if (_bytesEqual(d.deviceId, thisDeviceId)) continue;
      if (members.any((m) => _bytesEqual(m.deviceId, d.deviceId))) continue;
      if (!taken.add(_hex(d.deviceId))) continue;
      out.add((deviceId: d.deviceId, side: side));
    }
  }

  collect(ownList, ClaimSide.mine);
  collect(peerList, ClaimSide.theirs);
  return out;
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
