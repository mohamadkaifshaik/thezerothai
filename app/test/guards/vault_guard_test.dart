import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart' show readTree;
import 'vault_scan.dart';

/// Guards around the encrypted vault (`lib/core/vault`, `lib/features/keys`).
/// A wrong wipe destroys a user's message history, a stray log line can leak
/// a key or a message, and a vault that opens in memory silently stops being
/// durable. Each rule has a self-test that feeds the scanner a small violating
/// source and expects it to be flagged, so a guard cannot pass by scanning
/// nothing.
///
/// Run from app/ (like the other guards).

/// What a file outside the vault layer may import from lib/core/vault/.
/// Features reach the vault only through the session, the SecureVault types,
/// the status/exception types and the keyed mutex.
const Set<String> _defaultAllowedImports = {
  'vault_session.dart',
  'secure_vault.dart',
  'vault_status.dart',
  'keyed_mutex.dart',
};

/// Per-file extras, one reason each. Nothing here may be a platform file
/// (vault_database, vault_cipher_{android,web,stub}, vault_open_{io,web},
/// web_interop, vault_owner_{web,io}); those never leave the vault layer.
const Map<String, Set<String>> _extraImports = {
  // Builds the production VaultSession from the vault layer's facades.
  'lib/app/bootstrap.dart': {
    'vault_cipher.dart', // openVaultCipher, deleteVaultKeyForAlias
    'vault_markers.dart', // DriftVaultMarkers, vaultMarkersPersistent
    'vault_open.dart', // openVault, wipeVaultFileForAlias
    'vault_owner.dart', // createVaultOwner
  },
};

/// The nine implementation files that must stay inside lib/core/vault/.
const List<String> _vaultPrivate = [
  'vault_database.dart',
  'vault_cipher_android.dart',
  'vault_cipher_web.dart',
  'vault_cipher_stub.dart',
  'vault_open_io.dart',
  'vault_open_web.dart',
  'web_interop.dart',
  'vault_owner_web.dart',
  'vault_owner_io.dart',
];

/// The only code outside lib/core/vault/ that may mention a destructive
/// operation: bootstrap passes the production wipers into the session as
/// tear-offs. Exact fragments; any other reference there still fails.
const Map<String, List<String>> _destructiveWiring = {
  'lib/app/bootstrap.dart': [
    'wipeVaultFile: vault_open.wipeVaultFileForAlias,',
    'deleteVaultKey: deleteVaultKeyForAlias,',
  ],
};

/// The session's destructive entry points and the ONLY file outside
/// lib/core/vault that may reference each (null: none may, until a UI plan
/// adds a caller and updates this guard). `onSessionEnded` turns an explicit
/// end into a wipe; `noteAccountDeleted` journals one;
/// `resetVaultForStorageChange` destroys history on purpose.
const Map<String, String?> _sessionEntryOwners = {
  'onSessionEnded': 'lib/app/session_wiring.dart',
  'noteAccountDeleted': 'lib/app/bootstrap.dart',
  'resetVaultForStorageChange': null,
};

/// Same-named members that are NOT the session's: exact fragments removed
/// before scanning that file. `AuthRepository.noteAccountDeleted` records the
/// deletion (bootstrap forwards it to the session).
const Map<String, List<String>> _sessionEntryExempt = {
  'lib/features/account/presentation/bloc/account_cubit.dart': [
    '_auth.noteAccountDeleted(',
  ],
};

/// The vault layer's test-only top-level hooks: set by tests, never by app
/// code (a production assignment would disable a check or corrupt a key).
const Set<String> _vaultDebugHooks = {
  'debugFailWebVaultKeyCheck',
  'debugCorruptWebVaultReadBack',
  'debugBeforeWebVaultKeyDelete',
  'debugWebCryptoKeyConstructorName',
  'debugLocksProvider',
};

/// The only `=` on a hook allowed in lib/: each declaration's own
/// initializer, by file and count (`debugBeforeWebVaultKeyDelete` is
/// declared without one).
const Map<String, Map<String, int>> _vaultDebugHookDeclarations = {
  'lib/core/vault/vault_cipher_web.dart': {
    'debugFailWebVaultKeyCheck': 1,
    'debugCorruptWebVaultReadBack': 1,
    'debugWebCryptoKeyConstructorName': 1,
  },
  'lib/core/vault/vault_owner_web.dart': {'debugLocksProvider': 1},
};

/// Every `toString` the vault and keys code may define, and its exact body.
/// A new one, or a changed body, fails the guard: read it, then add it here
/// only if it prints no secret. Bodies show ids, counts, step or status names,
/// never keys, state, content or ciphertext.
const Map<String, Map<String, String>> _allowedToStrings = {
  'lib/core/vault/secure_vault.dart': {
    'StoredMessage': "=> 'StoredMessage(\$conversationId, \$messageId)';",
    'OutboxItem': "=> 'OutboxItem(\$idempotencyKey)';",
    'GroupRecord': "=> 'GroupRecord(\$conversationId)';",
    'OutboxRead': "=> 'OutboxRead(\${items.length} items, \${unreadableKeys.length} unreadable)';",
  },
  'lib/core/vault/vault_markers.dart': {
    'KnownVault': "=> 'KnownVault(\$storage)';",
    'OwedWipe': "=> 'OwedWipe(fileStarted: \$fileStarted, fileDone: \$fileDone, ' 'anyCopy: \$anyCopy)';",
  },
  'lib/core/vault/vault_cipher.dart': {
    'VaultKeyException': "=> 'VaultKeyException(\${failure.name})';",
    'VaultRowException': "=> 'VaultRowException';",
  },
  'lib/core/vault/vault_status.dart': {
    'VaultOpenException': "=> 'VaultOpenException(\${status.name})';",
    'VaultCorruptException': "=> 'VaultCorruptException(\$table)';",
  },
  'lib/core/vault/web_interop.dart': {
    'WebOperationError': "=> 'WebOperationError(\$name)';",
  },
  'lib/core/vault/vault_session.dart': {
    'VaultSessionError': "=> 'VaultSessionError(\$step)';",
  },
  'lib/features/keys/domain/device_keys_service.dart': {
    'DeviceKeysStatus': "=> phase == DeviceKeysPhase.failed ? 'DeviceKeysStatus.failed(retryable: \$retryable)' : 'DeviceKeysStatus.\${phase.name}';",
    'DeviceKeysError': "=> 'DeviceKeysError(\$step)';",
  },
};

/// The session entry points [source] (at [path], outside lib/core/vault)
/// references without owning them.
List<String> _entryViolations(String path, String source) => [
  for (final name in memberReferences(
    source,
    _sessionEntryOwners.keys.toSet(),
    exemptSnippets: _sessionEntryExempt[path] ?? const [],
  ))
    if (_sessionEntryOwners[name] != path) name,
];

bool _inVaultLayer(String path) =>
    path.startsWith('lib/core/vault/') || path.startsWith('lib/features/keys/');

Map<String, String> _libFiles() => readTree('lib', {'.dart'});

Map<String, String> _vaultAndKeys() => {
  for (final e in _libFiles().entries)
    if (_inVaultLayer(e.key) && !e.key.endsWith('.g.dart')) e.key: e.value,
};

void main() {
  group('import boundary', () {
    test('outside lib/core/vault the vault is reached only through the '
        'session, SecureVault, status and KeyedMutex', () {
      final bad = <String>[];
      for (final e in _libFiles().entries) {
        if (e.key.startsWith('lib/core/vault/')) continue;
        for (final f in importViolations(
          e.key,
          e.value,
          defaultAllowed: _defaultAllowedImports,
          extraAllowed: _extraImports,
        )) {
          bad.add('${e.key} imports core/vault/$f');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'The vault is opened, closed and wiped by VaultSession only; '
            'depend on vault_session.dart / secure_vault.dart instead:\n'
            '${bad.join('\n')}',
      );
    });

    test('no allowlist entry names a private implementation file', () {
      for (final extras in _extraImports.values) {
        expect(extras.intersection(_vaultPrivate.toSet()), isEmpty);
      }
      expect(
        _defaultAllowedImports.intersection(_vaultPrivate.toSet()),
        isEmpty,
      );
    });

    test('self-test: each private file is flagged, in both import forms', () {
      for (final f in _vaultPrivate) {
        expect(
          importViolations(
            'lib/features/keys/domain/x.dart',
            "import '../../../core/vault/$f';",
            defaultAllowed: _defaultAllowedImports,
            extraAllowed: _extraImports,
          ),
          [f],
          reason: f,
        );
        expect(
          importViolations(
            'lib/features/x/y.dart',
            "import 'package:dzeroth/core/vault/$f';",
            defaultAllowed: _defaultAllowedImports,
            extraAllowed: _extraImports,
          ),
          [f],
          reason: f,
        );
      }
      // A conditional import spanning lines and an export are read too.
      expect(
        importViolations(
          'lib/core/x.dart',
          "import 'a.dart'\n    if (dart.library.io) '../core/vault/vault_open_io.dart';",
          defaultAllowed: _defaultAllowedImports,
          extraAllowed: _extraImports,
        ),
        ['vault_open_io.dart'],
      );
      expect(
        importViolations(
          'lib/core/x.dart',
          "export 'vault/vault_database.dart';",
          defaultAllowed: _defaultAllowedImports,
          extraAllowed: _extraImports,
        ),
        ['vault_database.dart'],
      );
      // An allowed one and a comment mentioning a private one are not.
      expect(
        importViolations(
          'lib/features/x/y.dart',
          "// import 'package:dzeroth/core/vault/vault_database.dart';\n"
              "import 'package:dzeroth/core/vault/vault_session.dart';",
          defaultAllowed: _defaultAllowedImports,
          extraAllowed: _extraImports,
        ),
        isEmpty,
      );
      // bootstrap's extras do not extend to another file.
      expect(
        importViolations(
          'lib/app/other.dart',
          "import '../core/vault/vault_open.dart';",
          defaultAllowed: _defaultAllowedImports,
          extraAllowed: _extraImports,
        ),
        ['vault_open.dart'],
      );
    });
  });

  group('destructive calls belong to the session', () {
    test('wipe/destroy/delete-key are referenced only in lib/core/vault', () {
      final bad = <String>[];
      for (final e in _libFiles().entries) {
        if (e.key.startsWith('lib/core/vault/')) continue;
        for (final r in destructiveReferences(
          e.value,
          exemptSnippets: _destructiveWiring[e.key] ?? const [],
        )) {
          bad.add('${e.key}: $r');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Wipes belong to the session: only VaultSession decides to erase '
            'a vault file or its key (a wrong wipe destroys the user\'s '
            'message history). Ask the session; do not wipe from here.\n'
            '${bad.join('\n')}',
      );
    });

    test('the exempt wiring in bootstrap still exists exactly once', () {
      final src = File('lib/app/bootstrap.dart').readAsStringSync();
      for (final s in _destructiveWiring['lib/app/bootstrap.dart']!) {
        expect(
          RegExp(s.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s*'))
              .allMatches(stripSource(src, keepStrings: false))
              .length,
          1,
          reason: s,
        );
      }
    });

    test('self-test: calls, tear-offs and method forms are flagged', () {
      for (final bad in [
        'await wipeVaultFile(uid: u);',
        'await vault_open.wipeVaultFileForAlias(alias: a);',
        'final f = deleteVaultKey;',
        'await deleteVaultKeyForAlias(alias: a);',
        'await wipeVaultDatabase(db);', // B-M2: any wipeVault* name
        'await vault_open.wipeVaultSomethingNew();',
        'await vault.wipe();',
        'await vault?.wipe();',
        'await cipher.destroy();',
        'final w = vault.wipe;',
      ]) {
        expect(destructiveReferences(bad), isNotEmpty, reason: bad);
      }
      // Comments and string text are not references; the exempt wiring is
      // removed only when it matches exactly.
      expect(
        destructiveReferences("// vault.wipe()\nfinal s = 'wipeVaultFile';"),
        isEmpty,
      );
      final wired =
          'VaultSession(\n  wipeVaultFile: vault_open.wipeVaultFileForAlias,\n);';
      expect(
        destructiveReferences(
          wired,
          exemptSnippets: ['wipeVaultFile: vault_open.wipeVaultFileForAlias,'],
        ),
        isEmpty,
      );
      expect(
        destructiveReferences(
          '$wired\nawait wipeVaultFileForAlias(alias: a);',
          exemptSnippets: ['wipeVaultFile: vault_open.wipeVaultFileForAlias,'],
        ),
        isNotEmpty,
      );
    });
  });

  group('who may end or reset the vault session (B-M1)', () {
    test('each destructive session entry point is referenced only by its '
        'owner outside lib/core/vault', () {
      final bad = <String>[];
      for (final e in _libFiles().entries) {
        if (e.key.startsWith('lib/core/vault/')) continue;
        for (final name in _entryViolations(e.key, e.value)) {
          bad.add('${e.key}: $name');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Only the session wiring ends the vault session '
            '(onSessionEnded), only bootstrap forwards an account deletion '
            '(noteAccountDeleted), and nothing calls '
            'resetVaultForStorageChange yet (a UI plan must update this '
            'guard). Each can wipe a vault.\n${bad.join('\n')}',
      );
    });

    test('each owner still references its entry point exactly once', () {
      for (final e in _sessionEntryOwners.entries) {
        final owner = e.value;
        if (owner == null) continue;
        expect(memberReferences(File(owner).readAsStringSync(), {e.key}), [
          e.key,
        ], reason: '$owner: ${e.key}');
      }
    });

    test('the exempt same-named member still exists exactly once', () {
      for (final e in _sessionEntryExempt.entries) {
        final text = stripSource(
          File(e.key).readAsStringSync(),
          keepStrings: false,
        );
        for (final s in e.value) {
          expect(
            RegExp(s.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s*'))
                .allMatches(text)
                .length,
            1,
            reason: '${e.key}: $s',
          );
        }
      }
    });

    test('self-test: calls, null-aware calls, cascades and tear-offs are '
        'flagged; comments, strings, declarations and exempt snippets not', () {
      final names = _sessionEntryOwners.keys.toSet();
      for (final bad in [
        'await session.onSessionEnded(uid, SessionEnd.userSignedOut);',
        'unawaited(vaultSession?.onSessionEnded(a, b));',
        'final f = vaultSession.noteAccountDeleted;',
        'session..resetVaultForStorageChange();',
        'await s.resetVaultForStorageChange();',
      ]) {
        expect(memberReferences(bad, names), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '// vaultSession.onSessionEnded(a, b)',
        "final s = 'x.resetVaultForStorageChange()';",
        'void noteAccountDeleted(String uid) {}',
      ]) {
        expect(memberReferences(ok, names), isEmpty, reason: ok);
      }
      expect(
        memberReferences(
          '_auth.noteAccountDeleted(uid);',
          names,
          exemptSnippets: ['_auth.noteAccountDeleted('],
        ),
        isEmpty,
      );
      expect(
        memberReferences(
          '_auth.noteAccountDeleted(uid); vaultSession.noteAccountDeleted(u);',
          names,
          exemptSnippets: ['_auth.noteAccountDeleted('],
        ),
        ['noteAccountDeleted'],
      );
      // An owner's allowance covers its own entry point in its own file
      // only; the exempt snippet only in its own file.
      const end = 'unawaited(vaultSession?.onSessionEnded(a, b));';
      expect(_entryViolations('lib/app/session_wiring.dart', end), isEmpty);
      expect(_entryViolations('lib/app/other.dart', end), ['onSessionEnded']);
      expect(
        _entryViolations(
          'lib/app/session_wiring.dart',
          'vaultSession.noteAccountDeleted(u);',
        ),
        ['noteAccountDeleted'],
      );
      expect(
        _entryViolations(
          'lib/app/bootstrap.dart',
          'session.onSessionEnded(a);',
        ),
        ['onSessionEnded'],
      );
      expect(
        _entryViolations('lib/app/bootstrap.dart', 'x.noteAccountDeleted(u);'),
        isEmpty,
      );
      expect(
        _entryViolations('lib/app/other.dart', '_auth.noteAccountDeleted(u);'),
        ['noteAccountDeleted'],
      );
      expect(
        _entryViolations(
          'lib/features/account/presentation/bloc/account_cubit.dart',
          '_auth.noteAccountDeleted(u);',
        ),
        isEmpty,
      );
      expect(
        _entryViolations(
          'lib/app/bootstrap.dart',
          'session.resetVaultForStorageChange();',
        ),
        ['resetVaultForStorageChange'],
      );
    });
  });

  group('vault debug hooks are never set by app code (A-M7)', () {
    test('no file under lib/ assigns a vault debug* top-level (only the '
        'pinned declaration initializers)', () {
      final found = <String, Map<String, int>>{};
      for (final e in _libFiles().entries) {
        for (final name in assignmentsTo(e.value, _vaultDebugHooks)) {
          final counts = found.putIfAbsent(e.key, () => {});
          counts[name] = (counts[name] ?? 0) + 1;
        }
      }
      expect(
        found,
        _vaultDebugHookDeclarations,
        reason:
            'The vault debug hooks are for tests only; app code never sets '
            'them. The only `=` allowed is each declaration\'s own '
            'initializer.',
      );
    });

    test('every listed hook is still declared in lib/core/vault (the list '
        'is not stale)', () {
      final vault = [
        for (final e in _libFiles().entries)
          if (e.key.startsWith('lib/core/vault/'))
            stripSource(e.value, keepStrings: false),
      ].join('\n');
      for (final name in _vaultDebugHooks) {
        expect(
          RegExp(r'\b' + RegExp.escape(name) + r'\b').hasMatch(vault),
          isTrue,
          reason: name,
        );
      }
    });

    test('self-test: every assignment form is counted (declarations too, '
        'which the real-tree test pins); reads and comments are not', () {
      for (final bad in [
        'debugFailWebVaultKeyCheck = true;',
        'void f() { debugLocksProvider = () => null; }',
        'web.debugCorruptWebVaultReadBack = true;',
        "x..debugWebCryptoKeyConstructorName = 'Other';",
        'debugBeforeWebVaultKeyDelete ??= () {};',
        'final f = () => debugFailWebVaultKeyCheck = true;',
        'if (kDebugMode) debugFailWebVaultKeyCheck = true;',
        'if (a) {} else debugLocksProvider = f;',
        'switch (x) { case 1: debugCorruptWebVaultReadBack = true; }',
        "String g() { return debugWebCryptoKeyConstructorName = 'x'; }",
        'debugFailWebVaultKeyCheck |= true;',
        'debugFailWebVaultKeyCheck ^= true;',
        'debugFailWebVaultKeyCheck &= false;',
        'debugFailWebVaultKeyCheck ??= y;',
        '(debugFailWebVaultKeyCheck, _) = (true, 0);',
        '(a, debugCorruptWebVaultReadBack) = f();',
      ]) {
        expect(assignmentsTo(bad, _vaultDebugHooks), isNotEmpty, reason: bad);
      }
      // A declaration initializer counts once; the real tree pins exactly
      // those, so a second `=` in the declaring file is still caught.
      expect(
        assignmentsTo(
          'bool debugFailWebVaultKeyCheck = false;',
          _vaultDebugHooks,
        ),
        ['debugFailWebVaultKeyCheck'],
      );
      expect(
        assignmentsTo(
          'bool debugFailWebVaultKeyCheck = false;\n'
          'void f() { if (x) debugFailWebVaultKeyCheck = true; }',
          _vaultDebugHooks,
        ),
        ['debugFailWebVaultKeyCheck', 'debugFailWebVaultKeyCheck'],
      );
      for (final ok in [
        'void Function()? debugBeforeWebVaultKeyDelete;',
        'if (debugFailWebVaultKeyCheck) throw StateError("x");',
        'final same = debugCorruptWebVaultReadBack == true;',
        'final other = debugCorruptWebVaultReadBack != true;',
        'final g = () => debugLocksProvider();',
        '// debugFailWebVaultKeyCheck = true;',
        "final s = 'debugFailWebVaultKeyCheck = true';",
        'final xdebugFailWebVaultKeyCheck = true;',
        'final g = (debugLocksProvider) => 1;',
        'final h = (debugLocksProvider, a) == b;',
      ]) {
        expect(assignmentsTo(ok, _vaultDebugHooks), isEmpty, reason: ok);
      }
    });
  });

  group('no sensitive logging', () {
    test('vault and keys code prints nothing and reports no secret names', () {
      final bad = <String>[];
      for (final e in _vaultAndKeys().entries) {
        for (final v in loggingViolations(e.value)) {
          bad.add('${e.key}: $v');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Do not print, log or report a value named like a key, state, '
            'content, sealed data, ciphertext, device id or uid. Report a '
            'fixed step name instead (VaultSessionError / DeviceKeysError).\n'
            '${bad.join('\n')}',
      );
    });

    test('self-test: prints and secret-named arguments are flagged', () {
      for (final bad in [
        "print('hi');",
        "debugPrint('hi');",
        'reportUnexpectedError(e, stack, state);',
        'reportUnexpectedError(deviceId, stack);',
        '_report(vault.uid, stack);',
        '_onUnexpectedError?.call(plaintext, stack);',
        r"_log.warning('failed $storageKey');",
        r"_log.info('x ${sealedBytes.length}');",
        "Logger('x').severe(ciphertext);",
        '_report(contentFor(id), stack);',
      ]) {
        expect(loggingViolations(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        "_report('keyMismatch', stack);",
        '_report(step, stack);',
        '_onUnexpectedError?.call(VaultSessionError(step), stack);',
        'reportUnexpectedError(const DeviceKeysError(step), StackTrace.current);',
        'reportUnexpectedError(VaultKeyException(failure), stack);',
        'void _report(String step, StackTrace stack) => null;',
        '// print(state)',
      ]) {
        expect(loggingViolations(ok), isEmpty, reason: ok);
      }
    });
  });

  group('no printable secrets', () {
    test('only the pinned vault and keys types define toString', () {
      final found = <String, Map<String, String>>{};
      for (final e in _vaultAndKeys().entries) {
        final d = toStringDeclarations(e.value);
        if (d.isNotEmpty) found[e.key] = d;
      }
      expect(
        found,
        _allowedToStrings,
        reason:
            'A toString on a vault type must print ids, counts or names only. '
            'If this is a new or changed one, check it shows no key, state, '
            'content or ciphertext, then pin it in _allowedToStrings. '
            '(The drift row classes in vault_database.g.dart print their '
            'sealed columns, which are ciphertext at rest; they never leave '
            'lib/core/vault because vault_database.dart is import-guarded.)',
      );
    });

    test('self-test: a new or changed toString is seen', () {
      final d = toStringDeclarations(
        'class StoredMessage {\n'
        '  String toString() => \'StoredMessage(\$content)\';\n'
        '}\n'
        'class Other {\n'
        '  @override\n'
        '  String toString() {\n    return \'x\';\n  }\n'
        '}\n',
      );
      expect(d.keys, ['StoredMessage', 'Other']);
      expect(d['StoredMessage'], "=> 'StoredMessage(\$content)';");
      expect(
        d['StoredMessage'],
        isNot(
          _allowedToStrings['lib/core/vault/secure_vault.dart']!['StoredMessage'],
        ),
      );
    });
  });

  group('no cache habits', () {
    test('the vault never caps messages or opens in memory', () {
      final bad = <String>[];
      for (final e in _vaultAndKeys().entries) {
        for (final h in cacheHabits(e.value)) {
          bad.add('${e.key}: $h');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'The vault is durable history, not a cache: no '
            'kMessagesPerConversation, no in-memory database.\n'
            '${bad.join('\n')}',
      );
    });

    test('self-test: each habit is flagged, comments are not', () {
      for (final bad in [
        'final n = kMessagesPerConversation;',
        'final e = inMemoryExecutor();',
        'NativeDatabase.memory()',
        'AppDatabase.keepingNothing()',
        'sessionMemoryExecutor(x)',
      ]) {
        expect(cacheHabits(bad), isNotEmpty, reason: bad);
      }
      expect(cacheHabits('/// e.g. `NativeDatabase.memory()`'), isEmpty);
    });
  });

  group('flag-off inertness stays pinned by tests', () {
    // A meta-test: these tests assert that with the flag off nothing is
    // opened, generated or sent. Brittle by design; if one is renamed, update
    // the name here, do not delete the test.
    String joined(String path) =>
        File(path)
            .readAsStringSync()
            .replaceAll(RegExp(r'''(['"])\s+\1'''), '');

    const pinned = {
      'test/core/vault/vault_session_test.dart':
          'flag off / unsupported, nothing known: no collaborator is ever '
          'called',
      'test/features/keys/device_keys_service_test.dart':
          'flag off: the vault never opens, nothing is generated or sent',
      'test/features/keys/keys_repository_test.dart':
          'flag off and no vault on this device: nothing is sent and '
          'FeatureDisabled is thrown',
    };

    for (final e in pinned.entries) {
      test('${e.key} still has "${e.value}"', () {
        expect(
          RegExp(r'''\btest\(\s*['"]''' + RegExp.escape(e.value) + r'''['"]''')
              .hasMatch(joined(e.key)),
          isTrue,
          reason: 'Restore the flag-off inertness test in ${e.key}.',
        );
      });
    }
  });
}
