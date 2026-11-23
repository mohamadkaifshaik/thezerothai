// Guard for the E2EE pipeline's bootstrap wiring (Plan 5a Task 13 step
// 13-ii, fix wave ruling 11). The helpers it calls are unit-tested in
// test/app/e2ee_wiring_test.dart; no test can build the real bootstrap, so
// this scan keeps the lines that connect them:
//
// - the pipeline's vault-ready hook is registered on the vault session AFTER
//   the device keys' (gate item 21: the device exists first), exactly once;
// - the repository's three hints reach the pipeline (item 43);
// - message pushes are forwarded (item 67);
// - the resume goes through `resumeE2ee` with the session's retry, the
//   pipeline last and the throttle (items 35-37, ruling 3), the throttle
//   sees every vault status, and a pause reaches both;
// - the flag listener starts the pipeline after the device (item 29);
// - the notes are tagged with the authenticated uid (r1-I2), `public_ids`
//   off means KNOWN off (item 9), and every session end forgets the notes
//   with its reason (ruling 7);
// - N1: the `late final` pipeline is assigned with no `await` between its
//   declaration and its one assignment, so no closure can read it unset.
//
// Limits: a text scan of one file with `//` and `/* */` comments removed. It
// proves the lines are present in code and in this textual order, not that
// bootstrap runs them at runtime.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _bootstrap = 'lib/app/bootstrap.dart';

final _deviceHook = RegExp(
  r'\bvaultSession\s*\.{1,2}addVaultReadyHook\(\s*deviceKeys\.onVaultReady\s*\)',
);
final _pipelineHook = RegExp(
  r'\bvaultSession\s*\.{1,2}addVaultReadyHook\(\s*pipeline\.onVaultReady\s*\)',
);
final _anyPipelineHook = RegExp(r'addVaultReadyHook\(\s*\w*\.?onVaultReady');

/// The repository cascade up to [hint] (each earlier entry a pipeline hint).
RegExp _hint(String hint, String target) => RegExp(
  r'\bmessagingRepository\s*(?:\.\.\w+\s*=\s*pipeline\.\w+\s*)*'
  '\\.\\.$hint\\s*=\\s*pipeline\\.$target\\b',
);

final _required = <String, RegExp>{
  'onEncryptedConversation = pipeline.noteEncrypted': _hint(
    'onEncryptedConversation',
    'noteEncrypted',
  ),
  'onRequestAccepted = pipeline.noteAccepted': _hint(
    'onRequestAccepted',
    'noteAccepted',
  ),
  'onConversationDeleted = pipeline.noteDeleted': _hint(
    'onConversationDeleted',
    'noteDeleted',
  ),
  'forwardMessagePushes(states: pushCubit.stream, ... onPush: pipeline.onPush)':
      RegExp(
        r'forwardMessagePushes\(\s*states:\s*pushCubit\.stream\s*,'
        r'\s*initial:\s*pushCubit\.state\s*,\s*onPush:\s*pipeline\.onPush\b',
      ),
  'resumeE2ee(... retryVault: vaultSession.retry ... pipelineResumed: '
      'e2eePipeline?.onAppResumed, throttle, vaultStatus)': RegExp(
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
  'the resume throttle is built for this platform': RegExp(
    r'final\s+resumeThrottle\s*=\s*E2eeResumeThrottle\(\s*isWeb:\s*kIsWeb\s*\)',
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
  'e2eePipeline = e2eeVaultSupported ? E2eePipeline(': RegExp(
    r'\be2eePipeline\s*=\s*e2eeVaultSupported\s*\?\s*E2eePipeline\(',
  ),
  'supported: e2eeVaultSupported (the vault session)': RegExp(
    r'VaultSession\([^;]*?\bsupported:\s*e2eeVaultSupported\b',
  ),
  'currentUid: () => authBloc.state.user?.uid (in E2eePipeline)': RegExp(
    r'E2eePipeline\([^;]*?\bcurrentUid:\s*\(\)\s*=>\s*authBloc\.state\.user\?\.uid\b',
  ),
  'publicIdsOff: () => publicIdsKnownOff(onboardingBloc.state) (in '
      'E2eePipeline)': RegExp(
    r'E2eePipeline\([^;]*?\bpublicIdsOff:\s*\(\)\s*=>\s*'
    r'publicIdsKnownOff\(\s*onboardingBloc\.state\s*\)',
  ),
  'onSessionEnd: (end) => e2eePipeline?.forgetNotes(end)': RegExp(
    r'onSessionEnd:\s*\((\w+)\)\s*=>\s*e2eePipeline\?\.forgetNotes\(\s*\1\s*\)',
  ),
  // Plan 5a Task 13b (controller ruling 1): the port, one for the app's
  // lifetime, over the pipeline (null where the pipeline is not built).
  'final encryptedMessaging = encryptedMessagingOver(e2eePipeline)': RegExp(
    r'final\s+encryptedMessaging\s*=\s*encryptedMessagingOver\(\s*e2eePipeline\s*\)',
  ),
};

/// Plan 5a Task 13b (controller ruling 1): the port is NOT handed to the
/// widget tree here; 5b's Task 14 does that.
final _portInAppWidget = RegExp(r'AppWidget\([^;]*\bencryptedMessaging\b');

final _declaration = RegExp(
  r'late\s+final\s+E2eePipeline\?\s+e2eePipeline\s*;',
);
final _assignment = RegExp(r'\be2eePipeline\s*=[^=]');

/// [source] with every comment removed: `/* */` blocks first, then `//`.
String _code(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
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
  if (pipeline.length != 1 || _anyPipelineHook.allMatches(code).length != 2) {
    missing.add('one pipeline.onVaultReady hook');
  }
  if (device.length == 1 &&
      pipeline.length == 1 &&
      pipeline.single.start < device.single.start) {
    missing.add('the pipeline hook AFTER the device keys hook');
  }
  for (final e in _required.entries) {
    if (!e.value.hasMatch(code)) missing.add(e.key);
  }
  if (_portInAppWidget.hasMatch(code)) {
    missing.add('the port is not passed to AppWidget (5b Task 14)');
  }
  // N1: nothing awaits between the declaration and the one assignment.
  final declared = _declaration.allMatches(code).toList();
  final assigned = _assignment.allMatches(code).toList();
  if (declared.length != 1 || assigned.length != 1) {
    missing.add('one late final e2eePipeline, assigned once');
  } else if (code
      .substring(declared.single.end, assigned.single.start)
      .contains(RegExp(r'\bawait\b'))) {
    missing.add('no await between the pipeline declaration and assignment');
  }
  return missing;
}

void main() {
  test('bootstrap wires the E2EE pipeline (hook order, hints, pushes, '
      'resume, pause, flag, uid tag, sign-out, no await before the '
      'assignment)', () {
    final source = File(_bootstrap).readAsStringSync();
    expect(missingE2eeWiring(source), isEmpty);
  });

  group('self-test', () {
    // LF only, so the edits below match on a CRLF checkout too.
    final source = File(_bootstrap).readAsStringSync().replaceAll('\r\n', '\n');
    final code = _code(source);

    test('each required line, removed, is seen', () {
      for (final e in _required.entries) {
        final match = e.value.firstMatch(code);
        expect(match, isNotNull, reason: e.key);
        final cut = code.replaceRange(match!.start, match.end, '');
        expect(missingE2eeWiring(cut), contains(e.key), reason: e.key);
      }
    });

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

    test('a hook on another receiver is seen', () {
      final cut = source.replaceFirst(
        'vaultSession.addVaultReadyHook(pipeline.onVaultReady);',
        'otherSession.addVaultReadyHook(pipeline.onVaultReady);',
      );
      expect(
        missingE2eeWiring(cut),
        contains('one pipeline.onVaultReady hook'),
      );
    });

    test('a line or block comment hides a hook', () {
      for (final cut in [
        source.replaceFirst(
          'vaultSession.addVaultReadyHook(pipeline.onVaultReady);',
          '// vaultSession.addVaultReadyHook(pipeline.onVaultReady);',
        ),
        source.replaceFirst(
          'vaultSession.addVaultReadyHook(pipeline.onVaultReady);',
          '/* vaultSession.addVaultReadyHook(pipeline.onVaultReady); */',
        ),
      ]) {
        expect(
          missingE2eeWiring(cut),
          contains('one pipeline.onVaultReady hook'),
        );
      }
    });

    test('notes tagged with the GetMe id instead of the uid are seen', () {
      final cut = source.replaceFirst(
        'currentUid: () => authBloc.state.user?.uid,\n          publicIdsOff',
        'currentUid: () => onboardingBloc.state.myUserId,\n          '
            'publicIdsOff',
      );
      expect(cut, isNot(source));
      expect(missingE2eeWiring(cut), [
        'currentUid: () => authBloc.state.user?.uid (in E2eePipeline)',
      ]);
    });

    test('a forget that ignores the end is seen', () {
      expect(
        missingE2eeWiring(
          source.replaceFirst(
            'onSessionEnd: (end) => e2eePipeline?.forgetNotes(end),',
            'onSessionEnd: (end) => '
                'e2eePipeline?.forgetNotes(SessionEnd.sessionLost),',
          ),
        ),
        ['onSessionEnd: (end) => e2eePipeline?.forgetNotes(end)'],
      );
    });

    test('the port handed to AppWidget is seen', () {
      final cut = source.replaceFirst(
        'AppWidget(',
        'AppWidget(encryptedMessaging: encryptedMessaging, ',
      );
      expect(cut, isNot(source));
      expect(
        missingE2eeWiring(cut),
        contains('the port is not passed to AppWidget (5b Task 14)'),
      );
    });

    test('N1: an await between the declaration and the assignment is seen', () {
      const declaration = 'late final E2eePipeline? e2eePipeline;';
      expect(source, contains(declaration));
      final cut = source.replaceFirst(
        declaration,
        '$declaration\n  await Future<void>.value();',
      );
      expect(
        missingE2eeWiring(cut),
        contains('no await between the pipeline declaration and assignment'),
      );
    });
  });
}
