import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_derivations.dart' show mlsGroupId;
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_key_history.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_reset.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/former_pins.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart'
    show kConversationCopyStale;
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 12 (R17): "set up again" for a device removed elsewhere.
// The device-keys side (recreateDevice) is tested in
// test/features/keys/device_keys_removed_elsewhere_test.dart; here a fake
// stands in for it and makes the new device row as recreateDevice does.

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

/// The device-keys service as `DeviceReset` sees it.
class _FakeDeviceKeys implements DeviceKeysService {
  _FakeDeviceKeys(this.rig);

  final RigCrypto rig;
  bool removed = true;
  int recreated = 0;
  String? newId;

  @override
  bool get removedElsewhere => removed;

  /// Awaited before the new device row is written (a race in between).
  Future<void> Function()? beforeRecreate;

  @override
  Future<void> recreateDevice() async {
    await beforeRecreate?.call();
    recreated++;
    final id = '${'ab' * 15}${recreated.toString().padLeft(2, '0')}';
    final bytes = Uint8List.fromList(utf8.encode(id));
    final created = await rig.device.engine.inner.createDevice(bytes);
    await rig.device.session.runWrite(
      (v) => v.transaction((tx) => tx.putDevice(bytes, created.deviceState)),
    );
    newId = id;
    removed = false;
    rig.removedElsewhere = false;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late _FakeDeviceKeys keys;
  late DeviceReset reset;
  final offers = <String, RigOffer>{};

  setUp(() async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    keys = _FakeDeviceKeys(rig);
    // The vault's own signature key, as DeviceKeysService stores it.
    await rig.device.vault.transaction(
      (tx) => tx.putSetting(
        kVaultSettingDeviceSignatureKey,
        rig.device.signatureKey,
      ),
    );
    reset = DeviceReset(
      session: rig.device.session,
      deviceKeys: keys,
      contexts: rig.contexts,
      keyHistory: rig.crypto.keyHistory,
      known: rig.known,
    );
    offers.clear();
  });

  tearDown(() async {
    final errors = rig.keyHistoryErrors;
    await rig.dispose();
    expect(errors, isEmpty, reason: 'unreadable key histories');
  });

  Uint8List ownId() =>
      Uint8List.fromList(utf8.encode(rig.device.deviceIdString));

  Future<void> join(String c) async {
    await rig.accept(c);
    rig.header(c, 'ref-bob');
    offers[c] = await rig.offer(c, bob);
    expect(await rig.crypto.processWelcomes(), [c]);
    expect(await rig.crypto.catchUp(c), CatchUpResult.current);
  }

  /// A stored message, a sent-log row and an encrypted outbox row of [c].
  Future<void> traffic(String c) => rig.device.vault.transaction((tx) async {
    await tx.putMessage(
      StoredMessage(
        conversationId: c,
        messageId: 'm-$c',
        createdAtMicros: 1,
        mine: false,
        state: StoredMessageState.visible,
        generation: 1,
        epoch: 1,
        content: Uint8List.fromList([7]),
      ),
    );
    await tx.addSent(c, const MlsPair(1, 1), 'ab' * 32);
    await tx.putOutbox(
      OutboxItem(
        idempotencyKey: 'key-$c',
        localId: 'local-$c',
        expectedMessageId: 'expected-$c',
        conversationId: c,
        generation: 1,
        epoch: 1,
        ciphertext: Uint8List.fromList([1, 2, 3]),
        reportCommitment: Uint8List.fromList(List.filled(32, 4)),
        content: Uint8List.fromList([5]),
        createdAtMicros: 2,
      ),
    );
  });

  test('setUpAgain deletes every group, pin and sent row, keeps every '
      'message and mark, and returns encrypted rows to plain', () async {
    await join(_c1);
    await join(_c2);
    await traffic(_c1);
    await traffic(_c2);
    final v = rig.device.vault;
    final records = {
      for (final c in [_c1, _c2]) c: await v.conversation(c),
    };
    expect(await v.members(_c1), isNotEmpty);
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    expect(keys.recreated, 1);
    for (final c in [_c1, _c2]) {
      expect(await v.groups(c), isEmpty, reason: c);
      expect(await v.members(c), isEmpty, reason: c);
      expect(await v.hasSent(c, const MlsPair(1, 1), 'ab' * 32), isFalse);
      expect(await v.message(c, 'm-$c'), isNotNull, reason: c);
      final record = await v.conversation(c);
      expect(record!.afterPair, records[c]!.afterPair);
      expect(record.joinHighWater, records[c]!.joinHighWater);
      expect(record.sync.requestAccepted, isTrue);
      expect(rig.known.contains(c), isTrue);
      final state = await rig.crypto.describeState(c);
      expect(state.phase, ConversationPhase.waitingForWelcome);
    }
    final rows = (await v.outbox()).items;
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.stage, OutboxStage.plain);
      expect(row.ciphertext, isEmpty);
      expect(row.init, isNull);
      expect(row.generation, 0);
      expect(row.idempotencyKey, 'key-${row.conversationId}');
    }
  });

  test('setUpAgain throws StateError when not removed elsewhere and '
      'FeatureDisabledException when the flag is not on', () async {
    await join(_c1);
    keys.removed = false;
    final before = await rig.dump();
    await expectLater(reset.setUpAgain(), throwsStateError);
    expect(await rig.dump(), before);

    keys.removed = true;
    await rig.device.session.onFlagChanged(E2eeFlag.off, uid: rig.device.uid);
    expect(rig.device.session.mayStart, isFalse);
    await expectLater(
      reset.setUpAgain(),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(await rig.dump(), before);
    expect(keys.recreated, 0);
  });

  test('nothing is deleted before the user chooses', () async {
    await join(_c1);
    await traffic(_c1);
    final before = await rig.dump();
    // Removed elsewhere: every trigger runs, nothing is deleted.
    rig.removedElsewhere = true;
    await rig.crypto.processWelcomes();
    await rig.crypto.catchUp(_c1);
    await rig.receiver.pullLive(_c1, priority: BudgetPriority.user);
    await rig.upkeep.reconcile(_c1);
    await rig.sender.drain(_c1);

    expect(await rig.dump(), before);
    expect(keys.recreated, 0);
  });

  test('after setUpAgain a replayed old welcome is still refused by the '
      'marks', () async {
    await join(_c1);
    rig.removedElsewhere = true;
    await reset.setUpAgain();
    final fresh = keys.newId!;
    // The server hands the old welcome to the new device id.
    final again = rig.server.addWelcome(
      fresh,
      _c1,
      const MlsPair(1, 0),
      offers[_c1]!.add.welcome,
    );
    rig.device.engine.calls.clear();

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
    expect(await rig.device.vault.groups(_c1), isEmpty);
    expect(rig.server.acks.expand((a) => a.ids), contains(again));
  });

  test('a join already in flight when setUpAgain runs stores nothing; the '
      'conversation waits for a welcome (fix round 1, I2)', () async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob);
    // The poll took its sync unit and its ListWelcomes is on the wire for
    // the OLD device id when the device is found removed and set up again.
    // The join's body runs after the reset's transaction and before the
    // new device row is written (the old device state still opens it).
    // The pipeline's own removed-elsewhere gates are left open here on
    // purpose (its fact is not set): what must stop the join is the
    // device generation the reset bumped, which no unit-take can miss.
    final newRow = Completer<void>();
    keys.beforeRecreate = () => newRow.future;
    Future<void>? setUp;
    rig.server.onCall = (call) async {
      if (call != 'listWelcomes' || setUp != null) return;
      keys.removed = true;
      setUp = reset.setUpAgain();
    };

    final joined = await rig.crypto.processWelcomes();
    rig.server.onCall = null;
    newRow.complete();
    await setUp;

    expect(keys.recreated, 1);
    expect(joined, isEmpty);
    expect(await rig.device.vault.groups(_c1), isEmpty);
    expect(await rig.device.vault.members(_c1), isEmpty);
    final state = await rig.crypto.describeState(_c1);
    expect(state.phase, ConversationPhase.waitingForWelcome);
  });

  test('a start whose device id read straddles setUpAgain makes no call and '
      'stores nothing (fix wave 4, generation read before the first '
      'await)', () async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob);
    // The poll's start holds in its device id read (the OLD id).
    final hold = Completer<void>();
    final holding = Completer<void>();
    rig.device.onDeviceId = () async {
      if (holding.isCompleted) return;
      holding.complete();
      await hold.future;
    };
    // The reset's transaction runs; its new device row waits.
    final cleared = Completer<void>();
    final newRow = Completer<void>();
    keys.beforeRecreate = () {
      cleared.complete();
      return newRow.future;
    };
    final calls = rig.server.calls.length;

    final poll = rig.crypto.processWelcomes();
    await holding.future;
    final setUp = reset.setUpAgain();
    await cleared.future;
    hold.complete();
    final joined = await poll;
    newRow.complete();
    await setUp;
    rig.device.onDeviceId = null;

    expect(joined, isEmpty);
    expect(rig.server.calls.sublist(calls), isEmpty);
    expect(await rig.device.vault.groups(_c1), isEmpty);
  });

  test('an operation stopped by setUpAgain sends no further call (fix wave '
      '4, live compares the generation)', () async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob);
    final newRow = Completer<void>();
    keys.beforeRecreate = () => newRow.future;
    Future<void>? setUp;
    var after = -1;
    rig.server.onCall = (call) async {
      if (call != 'listWelcomes' || setUp != null) return;
      setUp = reset.setUpAgain();
      after = rig.server.calls.length;
    };

    await rig.crypto.processWelcomes();
    rig.server.onCall = null;
    final later = rig.server.calls.sublist(after);
    newRow.complete();
    await setUp;

    expect(later, isEmpty);
    expect(await rig.device.vault.groups(_c1), isEmpty);
  });

  test('a known conversation waiting for a welcome, with no group, gets its '
      'first sighting cleared too (fix wave 5, CR Minor B)', () async {
    await join(_c1);
    final v = rig.device.vault;
    // c2: accepted and known (it was joined once), no group left now.
    await rig.accept(_c2);
    await rig.known.add(_c2);
    final seen = rig.clock.now().subtract(const Duration(hours: 25));
    final sync = (await v.conversation(_c2))!.sync;
    await v.transaction(
      (tx) => tx.putConversationSync(
        _c2,
        sync.copyWith(
          firstSawGeneration: 1,
          firstSawGenerationAtMicros: seen.microsecondsSinceEpoch,
        ),
      ),
    );
    expect(await v.groups(_c2), isEmpty);
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    final after = (await v.conversation(_c2))!.sync;
    expect(after.firstSawGeneration, isNull);
    expect(after.firstSawGenerationAtMicros, isNull);
    expect(after.requestAccepted, isTrue);
    final state = await rig.crypto.describeState(_c2);
    expect(state.canReset, isFalse);
  });

  test('after setUpAgain the first-saw times start again, so no manual '
      'reset is offered at once (fix round 1, M1)', () async {
    await join(_c1);
    final v = rig.device.vault;
    // This generation was first seen more than a day ago.
    final sync = (await v.conversation(_c1))!.sync;
    final seen = rig.clock.now().subtract(const Duration(hours: 25));
    await v.transaction(
      (tx) => tx.putConversationSync(
        _c1,
        sync.copyWith(
          firstSawGeneration: 1,
          firstSawGenerationAtMicros: seen.microsecondsSinceEpoch,
        ),
      ),
    );
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    final after = (await v.conversation(_c1))!.sync;
    expect(after.firstSawGeneration, isNull);
    expect(after.firstSawGenerationAtMicros, isNull);
    expect(after.requestAccepted, isTrue);
    final state = await rig.crypto.describeState(_c1);
    expect(state.phase, ConversationPhase.waitingForWelcome);
    expect(state.canReset, isFalse);
  });

  test('a history closed at its allowance holds the old own pin, which is '
      'kept unattributed (fix round 1, N3)', () async {
    await join(_c1);
    final v = rig.device.vault;
    final oldHex = vaultDeviceIdHex(ownId());
    final own = (await v.members(_c1))
        .singleWhere((m) => vaultDeviceIdHex(m.deviceId) == oldHex);
    expect(own.side, isNot(MemberSide.unattributed));
    // Bob is recorded; the history is closed, so the old own id can only
    // be held (unrecorded), never recorded.
    await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)], closed: true);
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    final former = await const FormerPins().of(v, _c1);
    final kept = former.singleWhere(
      (m) => vaultDeviceIdHex(m.deviceId) == oldHex,
    );
    expect(kept.side, MemberSide.unattributed);
    expect(base64Encode(kept.signatureKey), base64Encode(own.signatureKey));
    final bobKept = former.singleWhere((m) => rigEq(m.deviceId, bob.id));
    expect(bobKept.side, MemberSide.theirs);
    // The old id is not recorded (held only), and the history still reads.
    expect(await rig.keyHistoryIds(_c1), isNot(contains(oldHex)));
    expect(
      (await rig.keyHistoryHeld(_c1))[oldHex],
      base64Encode(own.signatureKey),
    );
  });

  test('a welcome that brings the old (id, key) back pins it unattributed '
      'and raises the unknown-device path (fix wave 1, SA M1)', () async {
    await join(_c1);
    final v = rig.device.vault;
    final oldHex = vaultDeviceIdHex(ownId());
    // A key package of the OLD device (its state, its key), kept by whoever
    // holds a copy of the old vault.
    final oldPackage = await rigKeyPackage(rig.device);
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    final kept = (await const FormerPins().of(
      v,
      _c1,
    )).singleWhere((m) => vaultDeviceIdHex(m.deviceId) == oldHex);
    expect(kept.side, MemberSide.unattributed);
    // The account removed the old id: no own list shows it any more.
    rig.keys.own.removeWhere((d) => d.deviceId == rig.device.deviceIdString);
    // Bob welcomes the NEW id at generation 2, with the old leaf in it.
    final newPackage = await rigKeyPackage(rig.device);
    final add = await rigCreateAndAdd(bob, mlsGroupId(_c1, 2), [
      newPackage,
      oldPackage,
    ]);
    const at = MlsPair(2, 0);
    rig.server.addCommit(_c1, at, add.commit, fromUser: 'user-b');
    rig.server.addWelcome(keys.newId!, _c1, at, add.welcome);

    expect(await rig.crypto.processWelcomes(), [_c1]);

    final pin = (await v.members(_c1))
        .singleWhere((m) => vaultDeviceIdHex(m.deviceId) == oldHex);
    expect(pin.side, MemberSide.unattributed);
    // Once a fetch counts, the old device is an unknown device.
    rig.clock.advance(kConversationCopyStale + const Duration(seconds: 1));
    await rig.crypto.attributeMembers(_c1, priority: BudgetPriority.user);
    expect(
      (await v.members(_c1))
          .singleWhere((m) => vaultDeviceIdHex(m.deviceId) == oldHex)
          .side,
      MemberSide.unattributed,
    );
    expect(rig.contexts.of(_c1).unknownDevices, contains(oldHex));
  });

  test('an own pin whose key is not the vault key is never recorded as the '
      'old self (fix wave 1, SA M1)', () async {
    await join(_c1);
    final v = rig.device.vault;
    final oldHex = vaultDeviceIdHex(ownId());
    final other = Uint8List.fromList(List.filled(32, 9));
    await v.transaction(
      (tx) => tx.putSetting(kVaultSettingDeviceSignatureKey, other),
    );
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    final ids = await rig.keyHistoryIds(_c1);
    expect(ids[oldHex], base64Encode(other));
    expect(
      (await const FormerPins().of(
        v,
        _c1,
      )).where((m) => vaultDeviceIdHex(m.deviceId) == oldHex),
      isEmpty,
    );
  });

  test("setUpAgain keeps every conversation's pins as former pins", () async {
    await join(_c1);
    await join(_c2);
    final v = rig.device.vault;
    final oldHex = vaultDeviceIdHex(ownId());
    // Every pin keeps its key and side, except the old own pin: the account
    // removed it, so it is kept unattributed (fix wave 1, SA M1).
    final pinned = {
      for (final c in [_c1, _c2])
        c: {
          for (final m in await v.members(c))
            vaultDeviceIdHex(m.deviceId): (
              base64Encode(m.signatureKey),
              vaultDeviceIdHex(m.deviceId) == oldHex
                  ? MemberSide.unattributed
                  : m.side,
            ),
        },
    };
    expect(pinned[_c1]!.keys, contains(vaultDeviceIdHex(bob.id)));
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    for (final c in [_c1, _c2]) {
      final former = await const FormerPins().of(v, c);
      expect(
        {
          for (final m in former)
            vaultDeviceIdHex(m.deviceId): (
              base64Encode(m.signatureKey),
              m.side,
            ),
        },
        pinned[c],
        reason: c,
      );
    }
  });

  test('set up again with a new device id keeps every key history '
      'readable', () async {
    await join(_c1);
    await join(_c2);
    final v = rig.device.vault;
    final old = ownId();
    final oldHex = vaultDeviceIdHex(old);
    final oldKey = rig.device.signatureKey;
    expect(
      (await v.members(_c1)).any((m) => vaultDeviceIdHex(m.deviceId) == oldHex),
      isTrue,
      reason: 'this device is pinned in its own group',
    );
    final before = {
      for (final c in [_c1, _c2]) c: await rig.keyHistoryIds(c),
    };
    rig.removedElsewhere = true;

    await reset.setUpAgain();

    expect(vaultDeviceIdHex((await v.deviceId())!), isNot(oldHex));
    final history = DeviceKeyHistory();
    for (final c in [_c1, _c2]) {
      final read = await history.of(
        v,
        c,
        currentPins: await v.members(c),
        formerPins: await const FormerPins().of(v, c),
      );
      expect(read.unreadable, isFalse, reason: c);
      // Nothing dropped; the old own pair recorded with its key.
      final ids = await rig.keyHistoryIds(c);
      expect(ids, {...before[c]!, oldHex: base64Encode(oldKey)}, reason: c);
      expect(read.refusal(oldHex, oldKey), KeyRefusal.none, reason: c);
      expect(await rig.keyHistoryChanged(c), isEmpty, reason: c);
    }
  });
}
