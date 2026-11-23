import 'dart:typed_data';

import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../keys/domain/device_keys_service.dart';
import 'conversation_context.dart';
import 'device_key_history.dart';
import 'former_pins.dart';
import 'known_conversations.dart';
import 'pipeline_support.dart' show bumpDeviceGeneration;

/// The highest pair the vault takes (2^53 - 1 in both parts): the sent log
/// cleared "before" it is the whole sent log.
const MlsPair _kEndOfLog = MlsPair(9007199254740991, 9007199254740991);

const FormerPins _formerPins = FormerPins();

/// Plan 5a Task 12 (R17): the user's choice "set up again" for a device the
/// account removed from another device.
///
/// **What goes.** In ONE `runWrite` body and ONE transaction, for every
/// conversation with group state or pins: every group state (every
/// generation, provisional ones and their pending commits included), every
/// pin and the sent log; every stage-`encrypted` outbox row returns to stage
/// `plain` (same idempotency key, never put on the wire for a plain row;
/// same addressing; no ciphertext, no init: whoever encrypts it makes a new
/// idempotency key, as after a provisional discard).
///
/// **What stays.** Every stored message (owner choice), the marks (after
/// pairs, join high-water marks: a replayed old welcome is still refused),
/// the sync records (accepted, cleared_at, the commit counts; only the
/// first-saw pair is cleared, so the next catch-up records a new sighting
/// and the 24 h wait before a manual reset starts again), the known set
/// and peer
/// refs, the removal queue and the daily ledger.
///
/// **The pins are kept as former pins (security read H2).** Each
/// conversation's current pins are merged into its former pins in the same
/// transaction, so the rejoin is compared with them, never with a fresh
/// baseline: R17 deletes group states, not the memory of who was in them.
///
/// **The key history (device-key-history design section 7; carryovers from
/// Task 5).** No entry is dropped or reset. The one change: this device's
/// OLD id is admitted with the vault's STORED own key
/// ([KeyHistory.admitFormerSelf]), so the cross-check then holds the old id
/// to that key like any other id. The old own pin is kept as a former pin
/// only when it carries that key, and always `unattributed` (fix wave 1, SA
/// M1): the account removed that device, so a welcome bringing it back is
/// attributed from the lists, never `mine` from memory. An unreadable
/// history stays as it is (never overwritten).
///
/// **Then** [DeviceKeysService.recreateDevice]: a new device id, state and
/// key (its own transaction), and a normal run registers it. The device
/// then waits to be added: every conversation reads `waitingForWelcome`.
///
/// Uses the pipeline's ONE [DeviceKeyHistory] (pass
/// `ConversationCrypto.keyHistory`; never construct a second one) and its
/// ONE [KnownConversations] (every known conversation's first sighting is
/// cleared, also one with no group left).
///
/// Not wired here (Task 13): who calls it (the port's `setUpDeviceAgain`),
/// forgetting the commit runner's and the crypto's memory of own commits
/// (`CommitRunner.reset`), and the triggers after it.
class DeviceReset {
  DeviceReset({
    required VaultSession session,
    required DeviceKeysService deviceKeys,
    required ConversationContexts contexts,
    required DeviceKeyHistory keyHistory,
    required KnownConversations known,
  }) : _session = session,
       _deviceKeys = deviceKeys,
       _contexts = contexts,
       _keyHistory = keyHistory,
       _known = known;

  final VaultSession _session;
  final DeviceKeysService _deviceKeys;
  final ConversationContexts _contexts;
  final DeviceKeyHistory _keyHistory;
  final KnownConversations _known;

  /// Refused unless removed elsewhere ([StateError]) and the flag is on
  /// ([FeatureDisabledException]: the only choice is then to sign out);
  /// nothing is written then. A [StateError] when no vault is open or it
  /// changed meanwhile. Errors of the vault and of [recreateDevice]
  /// propagate: when the first transaction committed and the new device
  /// could not be made, the call may be made again (the transaction finds
  /// nothing left to delete and changes no history again).
  Future<void> setUpAgain() async {
    if (!_session.mayStart) {
      if (!_deviceKeys.removedElsewhere) {
        throw StateError('This device is not removed elsewhere.');
      }
      throw const FeatureDisabledException(
        'Setting this device up again is not available.',
        feature: 'e2ee_dm',
      );
    }
    // Fix wave 6 (CR Minor C): the latch holds back a listed-again clear
    // until the new device exists, and keeps a failed set-up retryable.
    if (!_deviceKeys.beginSetUpAgain()) {
      throw StateError('This device is not removed elsewhere.');
    }
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    final cleared = await _session.runWrite((v) async {
      if (!identical(v, vault)) throw StateError('The vault changed.');
      // Fix round 1, I2: every operation that started before this body
      // (a join of a welcome for the old id, a listing in flight) finds
      // the generation changed in its own body and writes nothing.
      bumpDeviceGeneration(v);
      return _clearIn(v);
    });
    for (final id in cleared) {
      _contexts.of(id)
        ..stuck = false
        ..syncedSinceStart = false
        ..attributionPending = false
        ..attributionConcluded = false
        ..serverPairFresh = false
        ..catchUpDueAt = null
        ..fruitlessCatchUpAt = null
        ..unknownDevices.clear()
        ..firstSeenUnattributed.clear()
        ..firstMiss.clear();
    }
    await _deviceKeys.recreateDevice();
  }

  /// The one transaction; answers the conversations it cleared.
  Future<Set<String>> _clearIn(SecureVault v) async {
    final ownId = await v.deviceId();
    final ownHex = ownId == null ? null : vaultDeviceIdHex(ownId);
    // Fix wave 1 (SA M1): the old self is admitted with the vault's STORED
    // own key, never with a pin's key (a welcome could have pinned this id
    // under another key).
    final storedKey = await v.setting(kVaultSettingDeviceSignatureKey);
    final ownKey = storedKey != null && storedKey.length == 32
        ? storedKey
        : null;
    final outbox = await v.outbox();
    final ids = <String>{...await v.groupConversationIds()};
    for (final item in outbox.items) {
      final c = item.conversationId;
      if (c != null && item.stage == OutboxStage.encrypted) ids.add(c);
    }
    // Final round 1 (SA M4): a known conversation whose own removal this
    // device already applied holds no group and no pin, but its former
    // pins hold the old own pin (`mine`). Under the new id that pin would
    // make its key history unreadable, so it is rewritten too.
    if (!_known.isLoadedFor(v)) await _known.load(v);
    if (ownHex != null) {
      for (final id in _known.ids) {
        if (ids.contains(id)) continue;
        final former = await _formerPins.of(v, id);
        if (former.any((m) => vaultDeviceIdHex(m.deviceId) == ownHex)) {
          ids.add(id);
        }
      }
    }
    // Every read first (the history and the former pins read fresh with
    // this body's vault), then one transaction.
    final plans = <_Clear>[];
    for (final id in ids) {
      final pins = await v.members(id);
      final former = await _formerPins.of(v, id);
      final history = await _keyHistory.of(
        v,
        id,
        currentPins: pins,
        formerPins: former,
      );
      plans.add(
        _Clear(
          id,
          await v.groups(id),
          pins,
          former,
          history,
          (await v.conversation(id))?.sync,
        ),
      );
    }
    // Fix wave 5 (CR Minor B): every known conversation's first sighting
    // goes too, also one with no group left (waiting for a welcome), so no
    // manual reset is offered at once for the new id.
    final sightings = <String, ConversationSync>{};
    for (final id in _known.ids) {
      if (ids.contains(id)) continue;
      final sync = (await v.conversation(id))?.sync;
      if (sync != null && _hasSighting(sync)) sightings[id] = sync;
    }
    await v.transaction((tx) async {
      for (final p in plans) {
        final kept = <String, MemberRecord>{};
        var ownFormer = false;
        // The former pins first, then the current ones over them; the old
        // own pin of either is rewritten (final round 1, SA M4: also one
        // only the former pins hold).
        for (final m in [...p.former, ...p.pins]) {
          final hex = vaultDeviceIdHex(m.deviceId);
          if (hex != ownHex) {
            kept[hex] = m;
            continue;
          }
          ownFormer = true;
          // Fix wave 1 (SA M1): the old own pin is the device the account
          // removed. Its former pin never keeps a side, so a welcome or
          // commit that brings the old (id, key) back is attributed from
          // the lists like any new device (unknown while no list shows
          // it), never `mine` from memory.
          if (ownKey != null) p.history.admitFormerSelf(hex, ownKey);
          if (ownKey == null || !_sameBytes(m.signatureKey, ownKey)) {
            // A pin under another key than the vault's (or no readable
            // vault key): nothing of it is recorded and it is not kept. A
            // former pin on a key the history does not hold for the id
            // would make the history unreadable; the id itself is held to
            // the vault key above.
            kept.remove(hex);
            continue;
          }
          // Recorded or held (closed at its allowance): unattributed passes
          // the cross-check either way.
          kept[hex] = MemberRecord(
            conversationId: m.conversationId,
            deviceId: m.deviceId,
            signatureKey: m.signatureKey,
            side: MemberSide.unattributed,
            since: m.since,
          );
        }
        if (p.pins.isNotEmpty || ownFormer) {
          await _formerPins.putIn(tx, v, p.id, kept.values.toList());
        }
        for (final g in p.groups) {
          await tx.deleteGroup(p.id, g.generation);
        }
        for (final m in p.pins) {
          await tx.deleteMember(p.id, m.deviceId);
        }
        await tx.clearSentBefore(p.id, _kEndOfLog);
        // Fix round 1, M1 (plan: "first-saw times are recorded as new
        // sightings"): the new device id gets the same welcome window as
        // any new device; the next catch-up records a fresh sighting, so
        // the 24 h wait before a manual reset starts again.
        final sync = p.sync;
        if (sync != null && _hasSighting(sync)) {
          await tx.putConversationSync(p.id, _withoutSighting(sync));
        }
        await _keyHistory.writeIn(tx, p.id, p.history);
      }
      for (final e in sightings.entries) {
        await tx.putConversationSync(e.key, _withoutSighting(e.value));
      }
      for (final item in outbox.items) {
        if (item.stage != OutboxStage.encrypted) continue;
        await tx.putOutbox(
          OutboxItem(
            idempotencyKey: item.idempotencyKey,
            localId: item.localId,
            expectedMessageId: item.expectedMessageId,
            conversationId: item.conversationId,
            recipientUserId: item.recipientUserId,
            generation: 0,
            epoch: 0,
            ciphertext: Uint8List(0),
            reportCommitment: Uint8List(0),
            content: item.content,
            createdAtMicros: item.createdAtMicros,
            stage: OutboxStage.plain,
            attempts: item.attempts,
            lastError: item.lastError,
          ),
        );
      }
    });
    return {...ids, ...sightings.keys};
  }
}

bool _hasSighting(ConversationSync s) =>
    s.firstSawGeneration != null || s.firstSawGenerationAtMicros != null;

ConversationSync _withoutSighting(ConversationSync s) =>
    s.copyWith(firstSawGeneration: null, firstSawGenerationAtMicros: null);

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// One conversation's reads for the transaction. No `toString` (it holds
/// device ids).
class _Clear {
  _Clear(this.id, this.groups, this.pins, this.former, this.history, this.sync);

  final String id;
  final List<GroupRecord> groups;
  final List<MemberRecord> pins;
  final List<MemberRecord> former;
  final KeyHistory history;
  final ConversationSync? sync;
}
