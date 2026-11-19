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
          'with the flag off nothing is sent and FeatureDisabled is thrown',
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
