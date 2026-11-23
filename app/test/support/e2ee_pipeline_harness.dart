import 'dart:async';
import 'dart:convert';

import 'package:dzeroth/core/crypto/guarded_crypto_engine.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart'
    show ConversationsSnapshot;
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_pipeline.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2ee_pipeline_rig.dart';

// The harness of the E2eePipeline tests (Plan 5a Task 13): the real
// pipeline over a rig device (its session and vault), the rig server, the
// rig key directory and a scripted DeviceKeysService. The rig's own parts
// exist too (RigCrypto builds them) and are not used: the pipeline builds
// its own over the same vault.

/// The rig server's view, with the cache reads and the list-change stream
/// the pipeline uses.
class PipelineMessaging extends RigMessaging {
  PipelineMessaging(RigServer server) : super(server, 'user-a');

  final StreamController<void> changed = StreamController.broadcast();

  /// `cachedConversations(FOLDER_INBOX)`'s rows.
  List<pb.Conversation> inbox = [];

  @override
  Stream<void> get conversationsChanged => changed.stream;

  @override
  Future<ConversationsSnapshot> cachedConversations(Folder folder) async =>
      ConversationsSnapshot(
        conversations: folder == Folder.FOLDER_INBOX ? [...inbox] : const [],
      );
}

/// The device-keys service as the pipeline reads it: a status, the
/// removed-elsewhere fact, and "set up again" as `DeviceReset` drives it.
class FakeDeviceKeys implements DeviceKeysService {
  FakeDeviceKeys(this._rig);

  final RigCrypto _rig;
  final ValueNotifier<DeviceKeysStatus> _status = ValueNotifier(
    DeviceKeysStatus.ready,
  );
  final ValueNotifier<bool> _fact = ValueNotifier(false);
  RemovedElsewhere state = RemovedElsewhere.notRemoved;

  /// The new device id of the last [recreateDevice].
  String? newId;

  @override
  ValueListenable<DeviceKeysStatus> get status => _status;

  set phase(DeviceKeysStatus s) => _status.value = s;

  @override
  ValueListenable<bool> get removedElsewhereFact => _fact;

  @override
  RemovedElsewhere get removedElsewhereState => state;

  @override
  bool get stopsPipeline => state != RemovedElsewhere.notRemoved;

  @override
  bool get removedElsewhere => state == RemovedElsewhere.removed;

  /// The server answered DEVICE_REMOVED (as the real service publishes it).
  void markRemoved() {
    state = RemovedElsewhere.removed;
    _fact.value = true;
    _status.value = DeviceKeysStatus.removedElsewhere;
  }

  /// Two listed answers cleared it (Task 12, security read M5).
  void clearRemoved() {
    state = RemovedElsewhere.notRemoved;
    _fact.value = false;
    _status.value = DeviceKeysStatus.idle;
    _status.value = DeviceKeysStatus.ready;
  }

  bool _latched = false;

  @override
  bool beginSetUpAgain() {
    if (!removedElsewhere && !_latched) return false;
    _latched = true;
    return true;
  }

  @override
  Future<void> recreateDevice() async {
    final id = '${'cd' * 15}01';
    final bytes = Uint8List.fromList(utf8.encode(id));
    final created = await _rig.device.engine.inner.createDevice(bytes);
    await _rig.device.session.runWrite(
      (v) => v.transaction((tx) async {
        await tx.putDevice(bytes, created.deviceState);
        await tx.putSetting(
          kVaultSettingRegisteredOnce,
          Uint8List.fromList(const [1]),
        );
      }),
    );
    newId = id;
    _latched = false;
    state = RemovedElsewhere.notRemoved;
    _fact.value = false;
    _status.value = DeviceKeysStatus.ready;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// One pipeline under test.
class PipelineHarness {
  PipelineHarness._();

  late RigCrypto rig;
  late PipelineMessaging messaging;
  late FakeDeviceKeys deviceKeys;
  late E2eePipeline pipeline;
  late GuardedCryptoEngine guarded;

  /// The pipeline's budget multiplier (see `E2eePipeline.budgetScale`).
  static const int budgetScale = 50;

  /// The signed-in user the pipeline's `ownUserId` answers (a test switches
  /// it to model another account on the same device).
  String? ownUser = 'user-a';

  /// How many times the pipeline asked for the engine.
  int engineAsked = 0;

  /// Every timer the pipeline's parts armed (never run by the harness).
  final List<RigScheduled> scheduled = [];
  final List<Object> reported = [];

  /// Pipeline errors the running test expects (checked by [dispose]).
  List<String> expectedErrors = [];

  /// A rig device whose vault holds its device; [registered]: the vault
  /// says it registered once.
  static Future<PipelineHarness> create({bool registered = true}) async {
    final h = PipelineHarness._();
    h.rig = await RigCrypto.create(
      messaging: (s) => h.messaging = PipelineMessaging(s),
    );
    await h.rig.device.vault.transaction((tx) async {
      await tx.putSetting(
        kVaultSettingDeviceSignatureKey,
        h.rig.device.signatureKey,
      );
      if (registered) {
        await tx.putSetting(
          kVaultSettingRegisteredOnce,
          Uint8List.fromList(const [1]),
        );
      }
    });
    h.deviceKeys = FakeDeviceKeys(h.rig);
    h.guarded = GuardedCryptoEngine(create: () => h.rig.device.engine);
    h.pipeline = h.build();
    return h;
  }

  /// A pipeline over this harness's collaborators.
  E2eePipeline build() => E2eePipeline(
    session: rig.device.session,
    deviceKeys: deviceKeys,
    engine: () {
      engineAsked++;
      return guarded;
    },
    messaging: messaging,
    keys: rig.keys,
    ownUserId: () => ownUser,
    now: rig.clock.now,
    // The rig clock stands still: no call may wait for a real minute.
    budgetScale: budgetScale,
    schedule: (delay, run) {
      final entry = RigScheduled(delay, run);
      scheduled.add(entry);
      return entry.cancel;
    },
    onUnexpectedError: (e, _) => reported.add(e),
  );

  /// The vault-ready hook, then everything it started.
  Future<void> ready() async {
    await pipeline.onVaultReady(rig.device.vault);
    await settle();
  }

  /// Waits until nothing the pipeline started runs.
  Future<void> settle() async {
    for (var i = 0; i < 3; i++) {
      await pipeline.coordinator?.idle();
      if (pipeline.hasParts) {
        await pipeline.runner.idle();
        await pipeline.upkeep.idle();
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Runs every timer armed and not cancelled (once), then settles.
  Future<void> runTimers() async {
    final live = [
      for (final e in scheduled)
        if (!e.cancelled) e,
    ];
    scheduled.clear();
    for (final e in live) {
      e.run();
    }
    await settle();
  }

  /// [c] is offered to this device by [owner] (accepted when [accepted],
  /// with an inbox header naming 'ref-bob').
  Future<RigOffer> offer(
    String c,
    RigPeer owner, {
    bool accepted = true,
  }) async {
    if (accepted) await rig.accept(c);
    rig.header(c, 'ref-bob');
    return rig.offer(c, owner);
  }

  /// The `ListWelcomes` calls so far.
  int get welcomePolls => rig.server.listedFor.length;

  Future<void> dispose() async {
    await settle();
    pipeline.dispose();
    final unexpected = [
      for (final e in reported) e is E2eePipelineError ? e.step : '$e',
    ];
    await rig.dispose();
    expect(unexpected, expectedErrors, reason: 'unexpected pipeline errors');
  }
}

/// A conversation id from [n].
String conv(int n) => n.toRadixString(16).padLeft(32, '0');
