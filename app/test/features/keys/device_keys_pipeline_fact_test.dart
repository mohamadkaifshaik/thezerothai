import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/device_keys_rig.dart';

// Plan 5a Task 12, fix wave 3 (security audit M3): the pipeline's
// removed-elsewhere fact fails CLOSED. It is three-state: unknown until the
// open vault's marker was read once, removed, or not removed. Only a
// marker read that opens and says "not removed" lets the pipeline run; an
// unreadable or malformed marker keeps it stopped; a failed marker write
// is never undone by a later read; only the listed-again clear or
// recreateDevice clears a removed fact.

const _a = 'user-a';
const _hour = Duration(hours: 1);

void main() {
  late DeviceKeysRig rig;

  setUp(() {
    rig = DeviceKeysRig()..launch();
  });

  List<String> steps() => [
    for (final e in rig.reported)
      if (e is DeviceKeysError) e.step,
  ];

  Future<void> removedElsewhere() async {
    await rig.signIn(_a);
    final id = rig.storedId()!;
    rig.devices.remove(id);
    rig.server.removedMarks.add(id);
    rig.advance(_hour);
    await rig.service.ensureReady();
    expect(rig.service.removedElsewhere, isTrue);
  }

  /// The vault closes (the session is lost, the vault kept) and the same
  /// user signs back in.
  Future<void> reopen() async {
    await rig.session.onSessionEnded(_a, SessionEnd.sessionLost);
    await rig.signIn(_a);
  }

  test('the fact is unknown, and stops the pipeline, until the marker was '
      'read', () async {
    final seen = <(RemovedElsewhere, bool)>[];
    void onStatus() {
      if (rig.session.status.value == VaultStatus.ready) {
        seen.add((
          rig.service.removedElsewhereState,
          rig.service.stopsPipeline,
        ));
      }
    }

    rig.session.status.addListener(onStatus);
    await rig.signIn(_a);
    rig.session.status.removeListener(onStatus);

    // Published, its marker not read yet.
    expect(seen.first, (RemovedElsewhere.unknown, true));
    expect(rig.service.removedElsewhereState, RemovedElsewhere.notRemoved);
    expect(rig.service.stopsPipeline, isFalse);
  });

  test('an unreadable marker keeps the pipeline stopped, reported '
      'once', () async {
    await rig.signIn(_a);
    rig.world.settingReadFails.add(kVaultSettingRemovedElsewhere);

    await reopen();
    rig.advance(_hour);
    await rig.service.ensureReady();

    expect(rig.service.removedElsewhereState, RemovedElsewhere.unknown);
    expect(rig.service.stopsPipeline, isTrue);
    expect(rig.service.removedElsewhere, isFalse);
    expect(steps().where((s) => s == 'removedElsewhereMarker'), hasLength(1));
    rig.reported.clear();
  });

  test('a malformed marker keeps the pipeline stopped and the run fails '
      'closed', () async {
    await rig.signIn(_a);
    rig.file()!.rows[kVaultSettingRemovedElsewhere] = '\u0002';
    final calls = rig.server.calls.length;

    await reopen();

    expect(rig.service.removedElsewhereState, RemovedElsewhere.unknown);
    expect(rig.service.stopsPipeline, isTrue);
    expect(rig.service.status.value.localRecordUnusable, isTrue);
    expect(rig.rpcs(calls), isEmpty);
    expect(steps().where((s) => s == 'removedElsewhereMarker'), hasLength(1));
    rig.reported.clear();
  });

  test('a failed marker write is never undone by the next run; that run '
      'writes the marker again', () async {
    rig.world.settingWriteFails.add(kVaultSettingRemovedElsewhere);
    await removedElsewhere();
    expect(rig.setting(kVaultSettingRemovedElsewhere), '');
    expect(steps(), contains('removedElsewhereWrite'));

    rig.advance(_hour);
    final calls = rig.server.calls.length;
    await rig.service.ensureReady();
    expect(rig.service.removedElsewhere, isTrue);
    expect(rig.service.stopsPipeline, isTrue);
    expect(rig.setting(kVaultSettingRemovedElsewhere), '');
    // Still read only: the absent marker cleared nothing, so no Register.
    expect(rig.rpcs(calls), ['list']);

    rig.world.settingWriteFails.clear();
    rig.advance(_hour);
    await rig.service.ensureReady();
    expect(rig.service.removedElsewhere, isTrue);
    expect(rig.setting(kVaultSettingRemovedElsewhere), '\u0001');
    rig.reported.clear();
  });
}
