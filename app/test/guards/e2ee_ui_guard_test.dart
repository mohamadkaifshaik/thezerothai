import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'vault_scan.dart';

/// Guards for the encrypted messaging screens (plan 5b, Task 15): the code
/// that shows decrypted content must not print it, log it, put it in a URL,
/// reach the crypto layer, or quietly grow a scanner. Each rule has a
/// self-test that plants a violation in an in-memory copy of the source and
/// proves the scan flags it, so a guard cannot pass by scanning nothing.
///
/// What is NOT here, because another guard already makes the same check for
/// the same files (do not duplicate):
/// - `BlocObserver` / `Bloc.observer` (all of lib/): `pipeline_guard_test.dart`.
/// - The `pb.Message(` scan incl. `message_search_panel.dart` with its one
///   id-only construction, `encrypted_search_results.dart` and the search
///   cubit, and the `MessageSearchState` `toStringOverride: false` pin:
///   `pipeline_guard_test.dart`.
/// - `resetByUser` referenced only by `reset_encryption_screen.dart`, exactly
///   once: `vault_guard_test.dart` ("who may end or reset the vault session").
/// - `toString` anywhere under `domain/e2ee/` (the port file included) and on
///   the port's types: `vault_guard_test.dart`.
///
/// Run from app/ (like the other guards).

const String _port =
    'lib/features/messages/domain/e2ee/encrypted_messaging.dart';
const String _device =
    'lib/features/messages/domain/e2ee/encryption_device.dart';
const String _presentationE2ee = 'lib/features/messages/presentation/e2ee/';
const String _statusFile =
    'lib/features/messages/presentation/e2ee/encryption_status.dart';
const String _settingsPresentation = 'lib/features/settings/presentation/';
const String _messageSearchState =
    'lib/features/messages/presentation/bloc/message_search_state.dart';
const String _messageSearch =
    'lib/features/messages/domain/message_search.dart';

/// The cubits that handle decrypted content on the thread, inbox and search
/// screens.
const Set<String> _contentCubits = {
  'lib/features/messages/presentation/bloc/thread_cubit.dart',
  'lib/features/messages/presentation/bloc/message_composer_cubit.dart',
  'lib/features/messages/presentation/bloc/conversations_cubit.dart',
  'lib/features/messages/presentation/bloc/message_search_cubit.dart',
};

/// The search UI: it holds the typed query and shows decrypted hits.
const Set<String> _searchFiles = {
  'lib/features/messages/presentation/widgets/message_search_panel.dart',
  _messageSearchState,
  _messageSearch,
};

Map<String, String> _lib() => handWrittenLib();

/// The encrypted screens: everything under presentation/e2ee/, and the
/// Settings files for encryption (a new `encryption_*` / `*_encryption_*`
/// file there is covered without a list change).
bool _isScreenFile(String path) {
  if (path.startsWith(_presentationE2ee)) return true;
  if (!path.startsWith(_settingsPresentation)) return false;
  return path.split('/').last.contains('encryption');
}

Map<String, String> _screens() => {
  for (final e in _lib().entries)
    if (_isScreenFile(e.key)) e.key: e.value,
};

/// Screens, the content cubits, the search UI: where a query or a decrypted
/// text is held or shown.
Map<String, String> _contentScope() => {
  for (final e in _lib().entries)
    if (_isScreenFile(e.key) ||
        _contentCubits.contains(e.key) ||
        _searchFiles.contains(e.key))
      e.key: e.value,
};

/// [_contentScope] plus the port file and the device facts (they import the
/// status types, so their imports are pinned too).
Map<String, String> _importScope() => {
  ..._contentScope(),
  for (final p in [_port, _device]) p: _lib()[p]!,
};

// ---------------------------------------------------------------------------
// No printable content.

final RegExp _freezedPart = RegExp(
  r'''^\s*part\s+['"][^'"]*\.freezed\.dart['"]''',
  multiLine: true,
);

/// A `toString` declaration or a `part '*.freezed.dart'` in [source].
List<String> _printableViolations(String source) => [
  ...codeMatches(source, toStringDeclaration).map((m) => 'toString: $m'),
  for (final m in _freezedPart.allMatches(
    stripSource(source, keepStrings: true),
  ))
    'freezed: ${m.group(0)!.trim()}',
];

/// The port file's only freezed check (its toString is pinned by
/// `vault_guard_test.dart`).
List<String> _freezedOnly(String source) => [
  for (final m in _freezedPart.allMatches(
    stripSource(source, keepStrings: true),
  ))
    'freezed: ${m.group(0)!.trim()}',
];

/// The decrypted-hit types, which no state or search-domain file may name
/// (security read M7): a freezed state would carry them to a log.
final RegExp _encryptedHitNames = RegExp(
  r'(?<![\w$])(?:EncryptedSearchHit|EncryptedHitGroups?|DecryptedMessage)\b',
);

// ---------------------------------------------------------------------------
// No crypto in the screens.

bool _cryptoTarget(String t) =>
    t.startsWith('lib/core/crypto/') ||
    t.endsWith('/secure_vault.dart') ||
    t.endsWith('/vault_records.dart') ||
    t.endsWith('/keys_repository.dart') ||
    t.endsWith('/device_keys_service.dart');

/// The two files that may import the keys feature's status types, each with
/// the one target it may reach.
const Map<String, String> _statusTypeImporters = {
  _device: 'lib/features/keys/domain/device_keys_service.dart',
  _statusFile: 'lib/features/keys/domain/device_keys_service.dart',
};

/// The status types `encryption_status.dart` may take from that library.
const Set<String> _statusTypes = {'DeviceKeysPhase', 'DeviceKeysStatus'};

List<String> _cryptoImportViolations(String path, String source) => [
  for (final t in importTargets(path, source))
    if (_cryptoTarget(t) && _statusTypeImporters[path] != t) t,
];

/// For a file that may import `device_keys_service.dart`: the service class
/// itself is never named (only status types), and [showOnly] says whether the
/// import must carry a `show` clause naming [_statusTypes] only.
List<String> _statusImportViolations(String source, {required bool showOnly}) {
  final bad = <String>[
    ...codeMatches(
      source,
      RegExp(r'(?<![\w$])DeviceKeys(?:Service|Repository)\b'),
    ),
  ];
  if (showOnly) {
    final kept = stripSource(source, keepStrings: true);
    for (final d in RegExp(
      r'\bimport\s[^;]*device_keys_service\.dart[^;]*;',
    ).allMatches(kept)) {
      final show = RegExp(r'\bshow\s+([^;]*);').firstMatch(d.group(0)!);
      final names = show == null
          ? <String>{}
          : {
              for (final n in show.group(1)!.split(','))
                if (n.trim().isNotEmpty) n.trim(),
            };
      if (names.isEmpty || !_statusTypes.containsAll(names)) {
        bad.add('import without a show of the status types only');
      }
    }
  }
  return bad;
}

// ---------------------------------------------------------------------------
// No logging of content, nothing in a URL.

/// Names (lower case, leading `_` dropped) that hold what the user typed or
/// what was decrypted. `.text` / `.code` members count: a token is read per
/// identifier.
const Set<String> _logNames = {
  'text',
  'digits',
  'code',
  'preview',
  'query',
  'payload',
  'ref',
  'conversationid',
  'messageid',
};

/// The subset a URL, a route's `extra` or a `Uri` may never carry.
const Set<String> _urlNames = {'text', 'digits', 'preview', 'payload', 'ref'};

/// A call that writes somewhere: print / debugPrint, `dart:developer`'s
/// `log(`, a logger variable (`log.info(`, `_logger.severe(`, `appLog.i(`),
/// `Logger(`, and the error reporters (`reportUnexpectedError(`, any
/// `_report...(`, the injected `onUnexpectedError`).
final RegExp _logCallee = RegExp(
  r'(?<![\w$.])(?:debugPrint|print|log|Logger|reportUnexpectedError'
  r'|_report\w*)\s*\('
  r'|(?<![\w$])_?onUnexpectedError\s*[?!]?\s*(?:\.\s*call\s*)?\('
  r'|(?<![\w$])_?(?:log|logger|\w+Log|\w+Logger)\s*\??\s*\.\s*\w+\s*\(',
);

/// A navigation or URL construction: `x.go(`, `x.push<T>(`, `.pushNamed(`,
/// `.replace(`, `GoRouter.of(context).go(`, `Uri(`, `Uri.parse(`.
final RegExp _urlCallee = RegExp(
  r'(?<![\w$.])(?:[\w$]+(?:\s*\([^()]*\))?\s*[?!]?\s*\.\s*)+'
  r'(?:go|push|pushReplacement|replace|goNamed|pushNamed|pushReplacementNamed'
  r'|replaceNamed)\s*(?:<[^()]*?>)?\s*\('
  r'|(?<![\w$.])Uri\s*(?:\.\s*\w+\s*)?\(',
);

/// Identifiers in [arg] (string text dropped, interpolated code kept) whose
/// name, lower-cased with leading `_` removed, is in [names].
List<String> _namedIn(String arg, Set<String> names) => [
  for (final m in RegExp(
    r'[A-Za-z_$][\w$]*',
  ).allMatches(stripSource(arg, keepStrings: false)))
    if (names.contains(
      m.group(0)!.replaceFirst(RegExp(r'^_+'), '').toLowerCase(),
    ))
      m.group(0)!,
];

List<String> _namedArgumentViolations(
  String source,
  RegExp callee,
  Set<String> names,
) => [
  for (final args in callArguments(source, callee))
    for (final a in args)
      for (final n in _namedIn(a, names)) '$n in ${_oneLine(a)}',
];

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

List<String> _loggingViolations(String source) =>
    _namedArgumentViolations(source, _logCallee, _logNames);

/// A `.extra` read (`GoRouterState.extra`, `state.extra`) or an `extra:`
/// argument: a route's payload never travels that way for these screens.
final RegExp _extraUse = RegExp(r'(?<![\w$])extra\s*:|\.\s*extra\b');

List<String> _urlViolations(String source) => [
  ..._namedArgumentViolations(source, _urlCallee, _urlNames),
  ...codeMatches(source, _extraUse).map((m) => 'route extra: $m'),
];

// ---------------------------------------------------------------------------
// Dependencies and pinned tests.

/// Dependency names in a pubspec's dependency sections (a 2-space-indented
/// `name:` key under `dependencies`, `dev_dependencies` or
/// `dependency_overrides`) that name a QR, barcode or scanner package.
List<String> _scannerDependencies(String pubspec) {
  final bad = <String>[];
  var inDeps = false;
  for (final line in pubspec.split('\n')) {
    if (RegExp(r'^\S').hasMatch(line)) {
      inDeps = RegExp(
        r'^(?:dependencies|dev_dependencies|dependency_overrides)\s*:',
      ).hasMatch(line);
      continue;
    }
    if (!inDeps) continue;
    final m = RegExp(r'^  ([A-Za-z0-9_]+)\s*:').firstMatch(line);
    if (m == null) continue;
    final name = m.group(1)!.toLowerCase();
    if (name.contains('qr') ||
        name.contains('barcode') ||
        name.contains('scanner')) {
      bad.add(m.group(1)!);
    }
  }
  return bad;
}

/// Whether [source] (a test file) declares `test(` / `testWidgets(` with the
/// literal name [name] (adjacent string pieces joined).
bool _declaresTest(String source, String name) {
  final joined = source.replaceAll(RegExp(r'''(['"])\s+\1'''), '');
  return RegExp(
    r'''\b(?:test|testWidgets)\(\s*['"]''' + RegExp.escape(name) + r'''['"]''',
  ).hasMatch(joined);
}

const String _notEncryptedDeclaration =
    "const kMessagesNotEncryptedText = 'Messages are not end-to-end "
    "encrypted.';";

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('the scan sees the encrypted screens, cubits and search files', () {
    final screens = _screens().keys.toSet();
    expect(
      screens,
      containsAll([
        'lib/features/messages/presentation/e2ee/encrypted_search_results.dart',
        'lib/features/messages/presentation/e2ee/encryption_status.dart',
        'lib/features/messages/presentation/e2ee/conversation_encryption_panel.dart',
        'lib/features/messages/presentation/e2ee/widgets/thread_status_banner.dart',
        'lib/features/settings/presentation/encryption_settings_screen.dart',
        'lib/features/settings/presentation/reset_encryption_screen.dart',
        'lib/features/settings/presentation/bloc/encryption_devices_cubit.dart',
      ]),
    );
    expect(
      _contentScope().keys,
      containsAll([..._contentCubits, ..._searchFiles]),
    );
    expect(_importScope().keys, containsAll([_port, _device]));
  });

  group('no printable content', () {
    test('no toString and no freezed part in the encrypted screens, the '
        'Settings encryption files or the devices cubit', () {
      final bad = <String>[
        for (final e in _screens().entries)
          for (final v in _printableViolations(e.value)) '${e.key}: $v',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'These types hold decrypted text, codes or queries. A toString '
            'or a freezed class prints every field.\n${bad.join('\n')}',
      );
    });

    test('the port file declares no freezed part', () {
      expect(_freezedOnly(_lib()[_port]!), isEmpty);
    });

    test('the search state and the search domain never name a decrypted hit '
        'type (they stay free of decrypted content)', () {
      final bad = <String>[
        for (final p in [_messageSearchState, _messageSearch])
          for (final m in codeMatches(_lib()[p]!, _encryptedHitNames)) '$p: $m',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'Decrypted hits live in EncryptedHitGroups (a plain class), '
            'never in the freezed MessageSearchState.\n${bad.join('\n')}',
      );
    });

    test('self-test: a planted toString, freezed part or hit field is seen; '
        'comments and strings are not', () {
      final real =
          _lib()['lib/features/settings/presentation/'
              'reset_encryption_screen.dart']!;
      expect(_printableViolations(real), isEmpty);
      expect(
        _printableViolations(
          "$real\nclass X {\n  @override\n  String toString() => 'x \$y';\n}\n",
        ),
        isNotEmpty,
      );
      expect(
        _printableViolations(
          "part 'reset_encryption_screen.freezed.dart';\n$real",
        ),
        isNotEmpty,
      );
      expect(
        _printableViolations("$real\nclass Y { toString() => 'y'; }"),
        isNotEmpty,
      );
      for (final ok in [
        '// String toString() => x;',
        "final s = 'String toString()';",
        'final t = state.toString();',
        "// part 'x.freezed.dart';",
        "final p = \"part 'x.freezed.dart';\";",
      ]) {
        expect(_printableViolations(ok), isEmpty, reason: ok);
      }
      expect(_freezedOnly("part 'p.freezed.dart';"), isNotEmpty);

      final state = _lib()[_messageSearchState]!;
      expect(codeMatches(state, _encryptedHitNames), isEmpty);
      final planted = state.replaceFirst(
        'const factory MessageSearchState({',
        'const factory MessageSearchState({\n'
            '    @Default(<EncryptedSearchHit>[]) List<EncryptedSearchHit> hits,',
      );
      expect(planted, isNot(state), reason: 'the plant found its anchor');
      expect(codeMatches(planted, _encryptedHitNames), isNotEmpty);
      for (final bad in [
        'final EncryptedHitGroups groups;',
        'final EncryptedHitGroup g;',
        'List<DecryptedMessage> m;',
      ]) {
        expect(codeMatches(bad, _encryptedHitNames), isNotEmpty, reason: bad);
      }
      expect(codeMatches('// EncryptedSearchHit', _encryptedHitNames), isEmpty);
    });
  });

  group('no crypto in the screens', () {
    test('the screens, content cubits, search files, port file and device '
        'facts import nothing from core/crypto, the vault records, the keys '
        'repository or the device-keys service, but the two pinned status '
        'imports', () {
      final bad = <String>[
        for (final e in _importScope().entries)
          for (final t in _cryptoImportViolations(e.key, e.value))
            '${e.key}: $t',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'Screens read the port (EncryptedMessaging, EncryptionDevice); '
            'they never reach the crypto engine or the vault.\n'
            '${bad.join('\n')}',
      );
    });

    test('the two pinned status imports still exist and take the status '
        'types only', () {
      for (final e in _statusTypeImporters.entries) {
        final src = _lib()[e.key]!;
        expect(
          importTargets(e.key, src),
          contains(e.value),
          reason: '${e.key}: the pin is stale, remove it',
        );
      }
      expect(
        _statusImportViolations(_lib()[_statusFile]!, showOnly: true),
        isEmpty,
      );
      expect(
        _statusImportViolations(_lib()[_device]!, showOnly: false),
        isEmpty,
        reason:
            'encryption_device.dart names the status types, never the '
            'service',
      );
    });

    test('self-test: each forbidden import form is flagged in a copy of a '
        'real screen; the pinned exceptions are not', () {
      const path =
          'lib/features/messages/presentation/e2ee/'
          'conversation_encryption_panel.dart';
      final real = _lib()[path]!;
      expect(_cryptoImportViolations(path, real), isEmpty);
      for (final imp in [
        "import '../../../../core/crypto/mls_engine.dart';",
        "import 'package:dzeroth/core/crypto/crypto_types.dart';",
        "import '../../../../core/vault/secure_vault.dart';",
        "import '../../../../core/vault/vault_records.dart';",
        "import '../../../keys/data/keys_repository.dart';",
        "import '../../../keys/domain/device_keys_service.dart';",
        "import '../../../keys/domain/device_keys_service.dart' show X;",
        "import 'a.dart'\n    if (dart.library.io) "
            "'../../../../core/crypto/b.dart';",
      ]) {
        expect(
          _cryptoImportViolations(path, '$imp\n$real'),
          isNotEmpty,
          reason: imp,
        );
      }
      expect(
        _cryptoImportViolations(path, "// import 'core/crypto/x.dart';"),
        isEmpty,
      );
      // The exception is by file: the same import in another file is flagged.
      const status = _statusFile;
      const imp =
          "import '../../../keys/domain/device_keys_service.dart' "
          'show DeviceKeysPhase;';
      expect(_cryptoImportViolations(status, imp), isEmpty);
      expect(_cryptoImportViolations(path, imp), isNotEmpty);
      // The show clause and the service class are pinned.
      expect(_statusImportViolations(imp, showOnly: true), isEmpty);
      expect(
        _statusImportViolations(
          "import '../../../keys/domain/device_keys_service.dart';",
          showOnly: true,
        ),
        isNotEmpty,
      );
      expect(
        _statusImportViolations(
          "import '../../../keys/domain/device_keys_service.dart' "
          'show DeviceKeysService;',
          showOnly: true,
        ),
        isNotEmpty,
      );
      expect(
        _statusImportViolations('final DeviceKeysService s;', showOnly: false),
        isNotEmpty,
      );
    });
  });

  group('no logging of content', () {
    test('no print, log, Logger or error report in the screens, cubits and '
        'search files names text, digits, code, preview, query, payload, '
        'ref, conversationId or messageId', () {
      final bad = <String>[
        for (final e in _contentScope().entries)
          for (final v in _loggingViolations(e.value)) '${e.key}: $v',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'A log line or error report must not carry decrypted text, a '
            'security code, a query or an id.\n${bad.join('\n')}',
      );
    });

    test('self-test: each sink form with each content name is flagged; '
        'fixed strings, declarations and unrelated calls are not', () {
      for (final name in _logNames) {
        final id = name == 'conversationid'
            ? 'conversationId'
            : name == 'messageid'
            ? 'messageId'
            : name;
        for (final sink in [
          'debugPrint($id);',
          'print($id);',
          'log.info($id);',
          '_log.warning("x", $id);',
          'logger.severe(widget.$id);',
          "reportUnexpectedError(e, st, '\$$id');",
          'Logger($id);',
          'log($id);',
          '_reportBug(s, $id);',
          'onUnexpectedError?.call(e, $id);',
          'appLog.fine("x \${state.$id}");',
        ]) {
          expect(_loggingViolations(sink), isNotEmpty, reason: sink);
        }
      }
      for (final ok in [
        "debugPrint('opened');",
        "log.info('step');",
        "// debugPrint(text);",
        'final s = text; use(s);',
        'Future<void> _report(String step) async {}',
        'void log(String text) {}',
        'dialog.show(text);',
        'reportUnexpectedError(e, st);',
        "print('the text field');",
      ]) {
        expect(_loggingViolations(ok), isEmpty, reason: ok);
      }
      // Planted in a copy of a real screen.
      final real =
          _lib()['lib/features/settings/presentation/'
              'reset_encryption_screen.dart']!;
      expect(_loggingViolations(real), isEmpty);
      expect(
        _loggingViolations('$real\nvoid f(String query) { print(query); }'),
        isNotEmpty,
      );
    });
  });

  group('nothing in a URL', () {
    test('no navigation, Uri or route extra in the screens, cubits and '
        'search files takes text, digits, preview, payload or ref', () {
      final bad = <String>[
        for (final e in _contentScope().entries)
          for (final v in _urlViolations(e.value)) '${e.key}: $v',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'A URL, a route parameter or a route extra is logged and '
            'persisted by the browser; decrypted content never goes there.\n'
            '${bad.join('\n')}',
      );
    });

    test('self-test: each navigation form with each name, and a route extra, '
        'is flagged; constant paths and unrelated calls are not', () {
      for (final name in _urlNames) {
        for (final call in [
          'context.go($name);',
          'context.go(\'/x/\$$name\');',
          'context.push<void>($name);',
          'unawaited(context.push(\'/x/\${hit.$name}\'));',
          'await context.pushNamed(\'x\', pathParameters: {\'k\': $name});',
          'context.pushReplacement(Uri(path: \'/x\', queryParameters: {\'k\': $name}).toString());',
          'GoRouter.of(context).go($name);',
          'final u = Uri.parse(\'/x?q=\$$name\');',
          'return Uri(path: $name);',
        ]) {
          expect(_urlViolations(call), isNotEmpty, reason: call);
        }
      }
      for (final bad in [
        'final e = GoRouterState.of(context).extra;',
        'final e = state.extra;',
        'context.go(\'/x\', extra: m);',
      ]) {
        expect(_urlViolations(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        'context.push(AppRouter.encryptionSettingsPath);',
        'context.go(AppRouter.encryptionSettingsPath);',
        "unawaited(context.push('/settings/encryption'));",
        '// context.go(text);',
        "final s = 'context.go(text)';",
        'final extraLarge = 1;',
        'void go(String text) {}',
        'x.replaceAll(text, y);',
      ]) {
        expect(_urlViolations(ok), isEmpty, reason: ok);
      }
      final real =
          _lib()['lib/features/settings/presentation/'
              'reset_encryption_screen.dart']!;
      expect(_urlViolations(real), isEmpty);
      expect(
        _urlViolations('$real\nvoid f(String text) { context.go(text); }'),
        isNotEmpty,
      );
    });
  });

  group('copy is pinned', () {
    test('the copy test still has "the fixed strings are verbatim"', () {
      const path =
          'test/features/messages/presentation/e2ee/encryption_copy_test.dart';
      expect(File(path).existsSync(), isTrue, reason: path);
      expect(
        _declaresTest(_read(path), 'the fixed strings are verbatim'),
        isTrue,
        reason: 'Restore the fixed-copy test in $path.',
      );
    });

    test('kMessagesNotEncryptedText is unchanged', () {
      final src = stripSource(
        _read(
          'lib/features/messages/presentation/widgets/'
          'not_encrypted_note.dart',
        ),
        keepStrings: true,
      );
      expect(
        src.replaceAll(RegExp(r'''(['"])\s+\1'''), ''),
        contains(_notEncryptedDeclaration),
        reason: 'The not-encrypted line is pinned word for word.',
      );
    });

    test('self-test: a renamed test and a changed constant are seen', () {
      const real = "test('the fixed strings are verbatim', () {});";
      expect(_declaresTest(real, 'the fixed strings are verbatim'), isTrue);
      expect(
        _declaresTest(
          "test('the fixed strings are roughly right', () {});",
          'the fixed strings are verbatim',
        ),
        isFalse,
      );
      expect(
        _declaresTest(
          "// test('the fixed strings are verbatim', () {});\n",
          'the fixed strings are verbatim',
        ),
        isTrue,
        reason: 'known gap: a commented-out test still matches',
      );
      expect(
        _declaresTest("testWidgets('a '\n    'b', (t) async {});", 'a b'),
        isTrue,
      );
      final decl = stripSource(
        "const kMessagesNotEncryptedText = 'Messages are not end-to-end '\n"
        "    'encrypted.';",
        keepStrings: true,
      ).replaceAll(RegExp(r'''(['"])\s+\1'''), '');
      expect(decl, contains(_notEncryptedDeclaration));
      expect(
        "const kMessagesNotEncryptedText = 'Messages are end-to-end encrypted.';",
        isNot(contains(_notEncryptedDeclaration)),
      );
    });
  });

  group('no new dependency', () {
    test('pubspec.yaml has no qr, barcode or scanner package', () {
      expect(
        _scannerDependencies(_read('pubspec.yaml')),
        isEmpty,
        reason:
            'The security code is compared by eye (Plan 5b); no camera or '
            'QR dependency.',
      );
    });

    test('self-test: each name form is flagged in a copy of the real '
        'pubspec; comments, other sections and unrelated names are not', () {
      final real = _read('pubspec.yaml');
      expect(real, contains('dependencies:'));
      for (final name in [
        'qr_flutter',
        'mobile_scanner',
        'flutter_barcode_scanner',
        'qr_code_scanner_plus',
        'Barcode_Widget',
      ]) {
        final planted = real.replaceFirst(
          RegExp(r'^dependencies:\s*$', multiLine: true),
          'dependencies:\n  $name: ^1.0.0',
        );
        expect(planted, isNot(real), reason: 'the plant found its anchor');
        expect(_scannerDependencies(planted), [name], reason: name);
        final dev = real.replaceFirst(
          RegExp(r'^dev_dependencies:\s*$', multiLine: true),
          'dev_dependencies:\n  $name:\n    path: ../x',
        );
        expect(_scannerDependencies(dev), [name], reason: 'dev: $name');
      }
      for (final ok in [
        'dependencies:\n  # qr_flutter: ^1.0.0\n  http: ^1.0.0\n',
        'flutter:\n  uses-material-design: true\n  qr_assets: x\n',
        'dependencies:\n  string_cursor: ^1.0.0\n',
      ]) {
        expect(_scannerDependencies(ok), isEmpty, reason: ok);
      }
    });
  });

  group('flag-off inertness stays pinned by tests', () {
    // A meta-test: these tests assert that with the flag off and no vault
    // nothing shows and nothing is called. Brittle by design; if one is
    // renamed, update the name here, do not delete the test.
    const pinned = {
      'test/features/messages/domain/e2ee/encryption_access_test.dart':
          'flag off or unknown with no vault is hidden',
      'test/features/messages/presentation/e2ee/encrypted_inbox_test.dart':
          'no port: encrypted rows show the placeholder and nothing is called',
      'test/features/settings/presentation/encryption_settings_screen_test.dart':
          'access hidden: no Settings row and the route shows the unavailable '
          'headline, no port call',
    };

    for (final e in pinned.entries) {
      test('${e.key} still has "${e.value}"', () {
        expect(
          _declaresTest(_read(e.key), e.value),
          isTrue,
          reason: 'Restore the flag-off inertness test in ${e.key}.',
        );
      });
    }
  });
}
