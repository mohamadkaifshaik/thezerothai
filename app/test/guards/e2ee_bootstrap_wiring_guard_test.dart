// Guard for the E2EE pipeline's bootstrap wiring (Plan 5a Task 13 step
// 13-ii). The helpers it calls are unit-tested in test/app/e2ee_wiring_test
// .dart; no test can build the real bootstrap, so this scan keeps the lines
// that connect them:
//
// - the pipeline's vault-ready hook is registered AFTER the device keys'
//   (gate item 21: the device exists first), exactly once;
// - the repository's three hints reach the pipeline (item 43);
// - message pushes are forwarded (item 67);
// - the resume order goes through `resumeE2ee` with the session's retry and
//   the pipeline last (items 35-37), and a pause reaches the pipeline;
// - the flag listener starts the pipeline after the device (item 29);
// - the notes are tagged with the authenticated uid (r1-I2), `public_ids`
//   off means KNOWN off (item 9), and sign-out forgets the notes.
//
// Limits: a text scan of one file with `//` comments removed. It proves the
// lines are present in code and in this textual order, not that bootstrap
// runs them at runtime.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _bootstrap = 'lib/app/bootstrap.dart';

final _deviceHook = RegExp(
  r'addVaultReadyHook\(\s*deviceKeys\.onVaultReady\s*\)',
);
final _pipelineHook = RegExp(
  r'addVaultReadyHook\(\s*pipeline\.onVaultReady\s*\)',
);

final _required = <String, RegExp>{
  'onEncryptedConversation = pipeline.noteEncrypted': RegExp(
    r'\.\.onEncryptedConversation\s*=\s*pipeline\.noteEncrypted\b',
  ),
  'onRequestAccepted = pipeline.noteAccepted': RegExp(
    r'\.\.onRequestAccepted\s*=\s*pipeline\.noteAccepted\b',
  ),
  'onConversationDeleted = pipeline.noteDeleted': RegExp(
    r'\.\.onConversationDeleted\s*=\s*pipeline\.noteDeleted\b',
  ),
  'forwardMessagePushes(... onPush: pipeline.onPush)': RegExp(
    r'forwardMessagePushes\([^;]*?\bonPush:\s*pipeline\.onPush\b',
  ),
  'resumeE2ee(... retryVault: vaultSession.retry ... pipelineResumed: '
      'e2eePipeline?.onAppResumed)': RegExp(
    r'resumeE2ee\([^;]*?\bengineResumed:\s*cryptoEngine\.onAppResumed\s*,'
    r'[^;]*?\bretryVault:\s*vaultSession\.retry\s*,'
    r'[^;]*?\bdeviceKeysResumed:\s*deviceKeys\.onAppResumed\s*,'
    r'[^;]*?\bpipelineResumed:\s*e2eePipeline\?\.onAppResumed\s*,'
    r'[^;]*?\bthrottle:\s*resumeThrottle\s*,'
    r'[^;]*?\bvaultStatus:\s*\(\)\s*=>\s*vaultSession\.status\.value\b',
  ),
  'the resume throttle sees every vault status': RegExp(
    r'vaultSession\.status\.addListener\(\s*\(\)\s*=>\s*'
    r'resumeThrottle\.noteStatus\(\s*vaultSession\.status\.value\s*\)',
  ),
  'onPause: resumeThrottle.notePaused(); e2eePipeline?.onAppPaused()': RegExp(
    r'onPause:\s*\(\)\s*\{\s*resumeThrottle\.notePaused\(\);\s*'
    r'e2eePipeline\?\.onAppPaused\(\);\s*\}',
  ),
  'flagTurnedOnWithOpenVault(ensureDeviceReady: deviceKeys.ensureReady, '
      'startPipeline: e2eePipeline?.start)': RegExp(
    r'flagTurnedOnWithOpenVault\(\s*ensureDeviceReady:\s*deviceKeys\.ensureReady'
    r'\s*,\s*startPipeline:\s*e2eePipeline\?\.start\b',
  ),
  'currentUid: () => authBloc.state.user?.uid (in E2eePipeline)': RegExp(
    r'E2eePipeline\([^;]*?\bcurrentUid:\s*\(\)\s*=>\s*authBloc\.state\.user\?\.uid\b',
  ),
  'publicIdsOff: () => publicIdsKnownOff(...) (in E2eePipeline)': RegExp(
    r'E2eePipeline\([^;]*?\bpublicIdsOff:\s*\(\)\s*=>\s*publicIdsKnownOff\(',
  ),
  'onSignedOut: () => e2eePipeline?.forgetNotes()': RegExp(
    r'onSignedOut:\s*\(\)\s*=>\s*e2eePipeline\?\.forgetNotes\(\)',
  ),
};

/// [source] with every `//` comment removed (line and doc comments).
String _code(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

/// The missing or misordered pieces of the wiring in [source] (empty when
/// complete).
List<String> missingE2eeWiring(String source) {
  final code = _code(source);
  final missing = <String>[];
  final device = _deviceHook.allMatches(code).toList();
  final pipeline = _pipelineHook.allMatches(code).toList();
  if (device.length != 1) missing.add('one deviceKeys.onVaultReady hook');
  if (pipeline.length != 1) missing.add('one pipeline.onVaultReady hook');
  if (device.length == 1 &&
      pipeline.length == 1 &&
      pipeline.single.start < device.single.start) {
    missing.add('the pipeline hook AFTER the device keys hook');
  }
  for (final e in _required.entries) {
    if (!e.value.hasMatch(code)) missing.add(e.key);
  }
  return missing;
}

void main() {
  test('bootstrap wires the E2EE pipeline (hook order, hints, pushes, '
      'resume, pause, flag, uid tag, sign-out)', () {
    final source = File(_bootstrap).readAsStringSync();
    expect(missingE2eeWiring(source), isEmpty);
  });

  group('self-test', () {
    // LF only, so the edits below match on a CRLF checkout too.
    final source = File(_bootstrap).readAsStringSync().replaceAll('\r\n', '\n');

    test('the pipeline hook moved before the device keys hook is seen', () {
      const device = 'addVaultReadyHook(deviceKeys.onVaultReady)';
      const pipeline = 'addVaultReadyHook(pipeline.onVaultReady)';
      expect(source, contains(device));
      expect(source, contains(pipeline));
      final swapped = source
          .replaceFirst(device, '@@D@@')
          .replaceFirst(pipeline, device)
          .replaceFirst('@@D@@', pipeline);
      expect(
        missingE2eeWiring(swapped),
        contains('the pipeline hook AFTER the device keys hook'),
      );
    });

    test('a commented-out hook does not count', () {
      final cut = source.replaceFirst(
        'vaultSession.addVaultReadyHook(pipeline.onVaultReady);',
        '// vaultSession.addVaultReadyHook(pipeline.onVaultReady);',
      );
      expect(
        missingE2eeWiring(cut),
        contains('one pipeline.onVaultReady hook'),
      );
    });

    test('a resume without the vault retry is seen', () {
      final cut = source.replaceFirst(
        'retryVault: vaultSession.retry,',
        'retryVault: ({required bool allowConfirmedWipe}) async {},',
      );
      expect(missingE2eeWiring(cut), hasLength(1));
    });

    test('notes tagged with the GetMe id instead of the uid are seen', () {
      final cut = source.replaceFirst(
        'currentUid: () => authBloc.state.user?.uid,\n          publicIdsOff',
        'currentUid: () => onboardingBloc.state.myUserId,\n          '
            'publicIdsOff',
      );
      expect(cut, isNot(source));
      expect(missingE2eeWiring(cut), hasLength(1));
    });

    test('a missing repository hint or sign-out forget is seen', () {
      expect(
        missingE2eeWiring(
          source.replaceFirst(
            '..onConversationDeleted = pipeline.noteDeleted',
            '',
          ),
        ),
        ['onConversationDeleted = pipeline.noteDeleted'],
      );
      expect(
        missingE2eeWiring(
          source.replaceFirst(
            'onSignedOut: () => e2eePipeline?.forgetNotes(),',
            '',
          ),
        ),
        ['onSignedOut: () => e2eePipeline?.forgetNotes()'],
      );
    });
  });
}
