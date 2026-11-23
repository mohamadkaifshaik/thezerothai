import 'package:flutter_test/flutter_test.dart';

import 'vault_scan.dart';

/// Guards around the encrypted message pipeline
/// (`lib/features/messages/domain/e2ee/`, plan 5a Task 15) and the
/// presentation code that shows decrypted content. Moved out of
/// `vault_guard_test.dart` (Task 15 fix round); the vault, keys, logging and
/// toString guards stay there. Each rule has a self-test that plants a
/// violation.
///
/// Run from app/ (like the other guards).

Map<String, String> _libFiles() => libFiles();

Map<String, String> _handWrittenLib() => handWrittenLib();

Map<String, String> _pipelineFiles() => pipelineFiles();

const String _pipelineDir = pipelineDir;

/// R14: what pipeline code may not import (the plaintext cache, the
/// plaintext outbox, the drift storage layer, drift itself).
List<String> _pipelineImportViolations(String path, String source) => [
  for (final t in importTargets(path, source))
    if (t.endsWith('/messaging_store.dart') ||
        t.endsWith('/message_outbox.dart') ||
        t.startsWith('lib/core/storage/') ||
        t.startsWith('package:drift'))
      t,
];

/// The `MessagingRepository` members pipeline code may reference (plan 5a
/// Task 15), so `sendMessage`, `refreshThread`, `pollThread`,
/// `cachedThread` and every other member (a new one included) can never be
/// reached from it.
const Set<String> _pipelineRepositoryMembers = {
  'sendEncrypted',
  'commitConversation',
  'listConversationCommits',
  'listEpochMessages',
  'listWelcomes',
  'ackWelcomes',
  'listMlsMessages',
  'acceptMessageRequest',
  'cachedConversation',
  'cachedConversations',
  'cachedEverEncrypted', // security read C1
  'cachedConversationWith', // second re-read R1; existing, read-only
  'conversationsChanged',
  'onEncryptedConversation',
  'onRequestAccepted',
  'onConversationDeleted',
  'gate',
  // Not in the plan's list; added by later PRs. None reads a cached thread
  // or sends plaintext:
  // #1071: records the ever-encrypted mark (the write side of C1); no read.
  'noteEverEncrypted',
  // #1071: the cache session number that guards that write; an int.
  'cacheSession',
  // #1082 (audit M2): the future of a still-running MLS call; no data.
  'abandonedMlsCall',
  // #1074: the server's tombstones for the reconcile walk; ids and times.
  'listMessageTombstones',
  // #1074: the shared rate-limit hold; no data.
  'rateLimitedFor',
};

const String _messagingRepositoryFile =
    'lib/features/messages/data/messaging_repository.dart';

/// The only names a MessagingRepository may have in pipeline code; every
/// member referenced on them must be allowed (a new member included).
const Set<String> _repositoryNames = {'messaging', '_messaging'};

/// Repository member names that pipeline code uses on ANOTHER type, so the
/// receiver-free name scan skips them (the receiver scan above still forbids
/// them on the repository). One why each.
const Map<String, String> _repositoryNameCollisions = {
  'outbox': 'SecureVault.outbox(): the vault\'s sealed outbox rows',
  'deleteConversation':
      'the vault transaction\'s deleteConversation (cleared_at, delete-for-me)',
};

/// The members pipeline code may not name on any receiver: every public
/// member of MessagingRepository, as declared today, outside the allowed
/// list and the collisions.
Set<String> _forbiddenRepositoryMembers() =>
    publicMembers(
      _libFiles()[_messagingRepositoryFile]!,
      'MessagingRepository',
    ).difference({
      ..._pipelineRepositoryMembers,
      ..._repositoryNameCollisions.keys,
    });

/// Findings for one pipeline file: a repository under another name, a
/// member on the repository outside the allowed list, and a forbidden
/// member name on any receiver.
List<String> _repositoryViolations(String source, Set<String> forbidden) => [
  for (final n in namesTyped(source, 'MessagingRepository'))
    if (!_repositoryNames.contains(n)) 'MessagingRepository named $n',
  for (final m in membersOn(source, _repositoryNames))
    if (!_pipelineRepositoryMembers.contains(m)) 'messaging.$m',
  for (final m in memberReferences(source, forbidden)) '.$m',
];

/// The only pipeline files that may pass `removeDeviceIds:` (one door to a
/// removal): the four the plan names, and two part files of them.
const Map<String, String?> _removalDoors = {
  'lib/features/messages/domain/e2ee/membership_rules.dart': null,
  'lib/features/messages/domain/e2ee/commit_runner.dart': null,
  'lib/features/messages/domain/e2ee/membership_upkeep.dart': null,
  'lib/features/messages/domain/e2ee/removal_queue_runner.dart': null,
  // #1082: `reconcile` moved into this part of membership_upkeep.dart (the
  // same library); its removals are the upkeep's.
  'lib/features/messages/domain/e2ee/membership_upkeep_reconcile.dart':
      'membership_upkeep.dart',
  // #1095 (fix round 3, ruling 3): one conversation's attempt moved into
  // this part of removal_queue_runner.dart (the same library).
  'lib/features/messages/domain/e2ee/removal_queue_runner_attempt.dart':
      'removal_queue_runner.dart',
};

/// Idempotency keys: a `Uuid` use, or a `package:uuid` import, in [source].
List<String> _uuidViolations(String path, String source) => [
  ...codeMatches(source, RegExp(r'(?<![\w$])Uuid\b')),
  for (final t in importTargets(path, source))
    if (t.startsWith('package:uuid')) 'imports $t',
];

final RegExp _removeDeviceIdsArg = RegExp(r'(?<![\w$])removeDeviceIds\s*:');

/// Error messages built with an interpolation that are allowed, by file:
/// exact source fragments (whitespace-insensitive).
const Map<String, List<String>> _interpolatedErrorExempt = {
  // #1103 (Task 13): the coordinator's report names its step; `name` is a
  // string literal at every `_step(` / `_value(` call (pinned below), never
  // an id or content.
  'lib/features/messages/domain/e2ee/sync_coordinator.dart': [
    r"E2eePipelineError('sync.$name')",
  ],
  // #1057 (foundations codec): the texts interpolate compile-time constants
  // (32, 4096); the ArgumentError's value is a length, never the bytes.
  'lib/features/messages/domain/e2ee/message_content_codec.dart': [
    r"'must be $kReportKeyBytes bytes'",
    r"'exceeds $kMaxMessageContentBytes bytes'",
  ],
};

/// The one forwarding call in sync_coordinator.dart whose step name is not
/// a literal: `_step` passes its own (literal-checked) `name` on.
const String _stepForwarder = '_value<void>(name, step, null)';

/// The one `pb.Message` construction allowed in lib/: #1062 (5b search) opens
/// an encrypted hit with an id-only message, never its text (5b review of
/// PR 5: the scan covers message_search_panel.dart with this one allowed).
const Map<String, List<String>> _messageConstructionExempt = {
  'lib/features/messages/presentation/widgets/message_search_panel.dart': [
    'pb.Message( id: entry.messageId, conversationId: entry.conversation.id, )',
  ],
};

/// Gate item 12 (#1062; plan 5a Task 15): the freezed MessageSearchState
/// holds the typed query, and its generated toString printed it. The state
/// opts out (`@Freezed(toStringOverride: false)`), so its generated file
/// declares no toString at all.
const String _searchStateFile =
    'lib/features/messages/presentation/bloc/message_search_state.dart';
const String _searchStateGenerated =
    'lib/features/messages/presentation/bloc/message_search_state.freezed.dart';

/// `toString` declarations in [source] (generated code included), comments
/// and strings ignored.
List<String> _toStringDecls(String source) =>
    codeMatches(source, RegExp(r'(?<![\w$.])String\s+toString\s*\('));

final RegExp _blocObserver = RegExp(
  r'(?<![\w$])BlocObserver\b|(?<![\w$])Bloc\s*\.\s*observer\b',
);

void main() {
  group('pipeline: nothing readable leaves the vault (R14)', () {
    test('no pipeline file imports the plaintext cache, the outbox, '
        'core/storage or drift', () {
      final bad = <String>[];
      for (final e in _pipelineFiles().entries) {
        for (final t in _pipelineImportViolations(e.key, e.value)) {
          bad.add('${e.key} imports $t');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Pipeline code reads and writes decrypted content through the '
            'vault only; the drift cache and the outbox hold plaintext.\n'
            '${bad.join('\n')}',
      );
    });

    test('pipeline code references only the allowed MessagingRepository '
        'members', () {
      final forbidden = _forbiddenRepositoryMembers();
      final bad = <String>[];
      for (final e in _pipelineFiles().entries) {
        for (final v in _repositoryViolations(e.value, forbidden)) {
          bad.add('${e.key}: $v');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Only the MLS calls, the cached-conversation reads, the change '
            'stream, the three callbacks and gate are for the pipeline '
            '(sendMessage, refreshThread, pollThread and cachedThread never '
            'are). A new legitimate member goes in '
            '_pipelineRepositoryMembers with a one-line why.\n'
            '${bad.join('\n')}',
      );
    });

    test('the member lists are not stale: every allowed member is still '
        'declared, and the four named ones are forbidden', () {
      final declared = publicMembers(
        _libFiles()[_messagingRepositoryFile]!,
        'MessagingRepository',
      );
      expect(declared, containsAll(_pipelineRepositoryMembers));
      expect(declared, containsAll(_repositoryNameCollisions.keys));
      expect(
        _forbiddenRepositoryMembers(),
        containsAll([
          'sendMessage',
          'refreshThread',
          'pollThread',
          'cachedThread',
        ]),
      );
      // The pipeline still holds the repository under the guarded names.
      expect(
        _pipelineFiles().values.expand(
          (s) => namesTyped(s, 'MessagingRepository'),
        ),
        containsAll(_repositoryNames),
      );
      // The parser read the class's own members, not its bodies.
      expect(declared, isNot(contains('isEverEncrypted')));
      expect(declared, isNot(contains('markEverEncrypted')));
    });

    test('self-test: each forbidden import form is flagged', () {
      const p = 'lib/features/messages/domain/e2ee/x.dart';
      for (final src in [
        "import '../../data/messaging_store.dart';",
        "import 'package:dzeroth/features/messages/data/message_outbox.dart';",
        "import '../../../../core/storage/app_database.dart';",
        "import 'package:drift/drift.dart';",
        "export 'package:drift/native.dart';",
        "import 'a.dart'\n    if (dart.library.io) "
            "'package:dzeroth/core/storage/x.dart';",
      ]) {
        expect(_pipelineImportViolations(p, src), isNotEmpty, reason: src);
      }
      for (final src in [
        "import '../../data/messaging_repository.dart';",
        "import '../../../../core/vault/secure_vault.dart';",
        "// import 'package:drift/drift.dart';",
      ]) {
        expect(_pipelineImportViolations(p, src), isEmpty, reason: src);
      }
    });

    test('self-test: a forbidden member is flagged as a call, tear-off, '
        'cascade or null-aware call; an allowed one is not', () {
      final forbidden = {
        'sendMessage',
        'refreshThread',
        'pollThread',
        'cachedThread',
        'outbox',
      };
      for (final bad in [
        'await _messaging.sendMessage(conversationId: id, text: t);',
        'final f = _messaging.refreshThread;',
        'messaging?.pollThread(id);',
        '_messaging..cachedThread(id);',
        'final o = _messaging\n    .outbox;',
      ]) {
        expect(memberReferences(bad, forbidden), isNotEmpty, reason: bad);
      }
      for (final ok in [
        'await _messaging.sendEncrypted(idempotencyKey: k);',
        '// _messaging.sendMessage(x)',
        "final s = 'refreshThread';",
      ]) {
        expect(memberReferences(ok, forbidden), isEmpty, reason: ok);
      }
      // The receiver scan: anything on the repository outside the allowed
      // list (a colliding or brand-new name too), and the repository under
      // another name.
      for (final bad in [
        'final r = await _messaging.outbox.read();',
        'await messaging?.deleteConversation(conversationId: id);',
        '_messaging\n    ..brandNewMember();',
        'final x = _messaging!.markConversationRead;',
        'final MessagingRepository repo;',
        'void f(MessagingRepository? m) {}',
        'MessagingRepository get repository => _messaging;',
      ]) {
        expect(_repositoryViolations(bad, const {}), isNotEmpty, reason: bad);
      }
      for (final ok in [
        'final rows = (await vault.outbox()).items;',
        'await tx.deleteConversation(id, upToCreatedAtMicros: b);',
        'final MessagingRepository _messaging;',
        'required MessagingRepository messaging,',
        'await _messaging.listWelcomes(deviceId: d);',
        '_messaging.cacheSession;',
        "import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;",
        'final c = _apiClient.messaging.listWelcomes;',
      ]) {
        expect(_repositoryViolations(ok, const {}), isEmpty, reason: ok);
      }
      // The four named members are never collisions.
      expect(
        _repositoryNameCollisions.keys.toSet().intersection({
          'sendMessage',
          'refreshThread',
          'pollThread',
          'cachedThread',
        }),
        isEmpty,
      );
      // The class parser: members at the body's top level, nothing inside
      // bodies, parameter lists, initializers or `=>` expressions.
      final members = publicMembers('''
class Repo {
  Repo({required Store store}) : _store = store, _gate = Gate(store.thing());
  final Store _store;
  final MessageOutbox outbox = MessageOutbox(inner());
  void Function(String id)? onThing;
  Gate get gate => _gate.wrapped();
  Future<Thread> cachedThread(String id) => _store.thread(id);
  Future<void> sendMessage({required String text, int n = 3}) async {
    final x = helper(text);
    await _store.write(x);
  }
  Future<T> _mls<T>(Future<T> Function() f) => f();
  static const int kLimit = 3;
  bool operator ==(Object other) => identical(this, other);
  @override
  int get hashCode => 1;
}
class Other { void notAMember() {} }
''', 'Repo');
      expect(members, {
        'outbox',
        'onThing',
        'gate',
        'cachedThread',
        'sendMessage',
        'kLimit',
        'hashCode',
      });
      expect(publicMembers('class X {}', 'Missing'), isEmpty);
      // A member added to the repository is forbidden until it is allowed.
      expect(
        publicMembers(
          'class MessagingRepository { Future<void> brandNew() async {} }',
          'MessagingRepository',
        ).difference(_pipelineRepositoryMembers),
        {'brandNew'},
      );
    });
  });

  group('pipeline: idempotency keys are not Uuids', () {
    test('no pipeline file names Uuid or imports package:uuid', () {
      final bad = <String>[];
      for (final e in _pipelineFiles().entries) {
        for (final v in _uuidViolations(e.key, e.value)) {
          bad.add('${e.key}: $v');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Pipeline idempotency keys are derived and stored with the row, '
            'never a fresh Uuid (a retry must replay the same key).\n'
            '${bad.join('\n')}',
      );
    });

    test('self-test: a Uuid use or import is flagged; comments and strings '
        'are not', () {
      const p = 'lib/features/messages/domain/e2ee/x.dart';
      for (final bad in [
        'final key = const Uuid().v4();',
        'final u = Uuid();',
        'final g = uuid.Uuid().v7();',
        "import 'package:uuid/uuid.dart';",
        "import 'package:uuid/uuid.dart' as uuid;",
      ]) {
        expect(_uuidViolations(p, bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '// Uuid().v4()',
        "final s = 'Uuid';",
        'MyUuidX()',
        "// import 'package:uuid/uuid.dart';",
      ]) {
        expect(_uuidViolations(p, ok), isEmpty, reason: ok);
      }
    });
  });

  group('pipeline: one door to a removal', () {
    test('only the removal doors pass removeDeviceIds:', () {
      final bad = <String>[];
      for (final e in _pipelineFiles().entries) {
        if (_removalDoors.containsKey(e.key)) continue;
        for (final m in codeMatches(e.value, _removeDeviceIdsArg)) {
          bad.add('${e.key}: $m');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'A device is removed from a conversation only through '
            'membership_rules, the commit runner, the membership upkeep and '
            'the removal queue runner.\n${bad.join('\n')}',
      );
    });

    test('each allowed part file is still a part of its door', () {
      for (final e in _removalDoors.entries) {
        final owner = e.value;
        if (owner == null) continue;
        expect(
          RegExp(
            r'''^\s*part\s+of\s+['"]''' + RegExp.escape(owner) + r'''['"]''',
          ).hasMatch(stripSource(_libFiles()[e.key]!, keepStrings: true)),
          isTrue,
          reason: e.key,
        );
        expect(_libFiles().containsKey('$_pipelineDir$owner'), isTrue);
      }
    });

    test('self-test: a planted removeDeviceIds: is flagged; a parameter '
        'declaration, a comment or a string is not', () {
      for (final bad in [
        'await _crypto.commit(id, removeDeviceIds: ids);',
        'f(removeDeviceIds : const []);',
        'f(\n  removeDeviceIds:\n      x,\n);',
      ]) {
        expect(codeMatches(bad, _removeDeviceIdsArg), isNotEmpty, reason: bad);
      }
      for (final ok in [
        'Future<void> commit({required List<String> removeDeviceIds}) {}',
        '// removeDeviceIds: ids',
        "final s = 'removeDeviceIds: x';",
        'f(keepRemoveDeviceIds: x);',
      ]) {
        expect(codeMatches(ok, _removeDeviceIdsArg), isEmpty, reason: ok);
      }
      // A file outside the doors is not exempt.
      expect(
        _removalDoors.containsKey(
          'lib/features/messages/domain/e2ee/encrypted_sender.dart',
        ),
        isFalse,
      );
    });
  });

  group('pipeline: error messages carry no interpolation', () {
    test('no exception or error built under the pipeline directory '
        'interpolates (\$) anything', () {
      final bad = <String>[];
      for (final e in _pipelineFiles().entries) {
        for (final m in interpolatedErrorMessages(
          e.value,
          exemptSnippets: _interpolatedErrorExempt[e.key] ?? const [],
        )) {
          bad.add('${e.key}: $m');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'An error message can reach a log or a crash report: use a '
            'fixed text or a fixed step name (E2eePipelineError(step)), '
            'never an id, a count of content or a value.\n'
            '${bad.join('\n')}',
      );
    });

    test('each exemption still exists exactly once and is still needed, and '
        'every step name the coordinator interpolates is a plain literal', () {
      for (final e in _interpolatedErrorExempt.entries) {
        final src = _libFiles()[e.key]!;
        final kept = stripSource(src, keepStrings: true);
        for (final s in e.value) {
          expect(
            RegExp(s.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s*'))
                .allMatches(kept)
                .length,
            1,
            reason: '${e.key}: $s',
          );
          // Without this one snippet the file is flagged.
          expect(
            interpolatedErrorMessages(
              src,
              exemptSnippets: [
                for (final o in e.value)
                  if (o != s) o,
              ],
            ),
            isNotEmpty,
            reason: '${e.key}: $s',
          );
        }
      }
      final names = <String>[];
      for (final e in _pipelineFiles().entries) {
        if (!e.key.startsWith('${_pipelineDir}sync_coordinator')) continue;
        for (final f in ['_step', '_value']) {
          names.addAll(
            firstArguments(e.value, f, exemptSnippets: [_stepForwarder]),
          );
        }
      }
      expect(names, isNotEmpty);
      expect(
        names.where((n) => !RegExp(r"^'[A-Za-z.]+'$").hasMatch(n)),
        isEmpty,
        reason:
            'Every step name passed to _step / _value is a literal like '
            "'drain'; the report interpolates it.",
      );
    });

    test('self-test: interpolated throws, constructors and completeError are '
        'flagged; fixed texts, toString and comments are not', () {
      for (final bad in [
        r"throw StateError('no row $id');",
        r"throw StateError('bad ${row.conversationId}');",
        "throw ArgumentError(\n  'device \$deviceId is not own',\n);",
        r"throw ArgumentError.value(x, 'n', 'was $x');",
        r"final e = E2eePipelineError('sync.$name');",
        r"completer.completeError(FormatException('at $offset'));",
        r"return Future.error('lost $messageId');",
        r"throw 'plain $text';",
        r"x ?? (throw StateError('$y'));",
        r"controller.addError(Exception('$z'));",
      ]) {
        expect(interpolatedErrorMessages(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        "throw StateError('no row');",
        "throw const E2eePipelineError('commit.send');",
        r"String toString() => 'E2eePipelineError($step)';",
        r"// throw StateError('$id');",
        r"throw StateError(r'literal $dollar');",
        "throw ArgumentError('a', 'b');",
        "rethrow;",
        r"final s = 'not an error $x'; throw StateError('fixed');",
      ]) {
        expect(interpolatedErrorMessages(ok), isEmpty, reason: ok);
      }
      // The exemption is exact: another interpolation in the same file is
      // still seen.
      expect(
        interpolatedErrorMessages(
          r"_report(E2eePipelineError('sync.$name'), s); "
          r"throw StateError('$id');",
          exemptSnippets: [r"E2eePipelineError('sync.$name')"],
        ),
        isNotEmpty,
      );
      // The literal check sees a non-literal step name.
      expect(
        firstArguments(
          "await _step('drain', f); await _value<int>(\n  stepName, g, 0);\n"
              'Future<void> _step(String name, F step) => '
              '_value<void>(name, step, null);',
          '_step',
        ),
        ["'drain'"],
      );
      expect(
        firstArguments(
          "await _value<int>(\n  stepName, g, 0);\n"
              'Future<T> _value<T>(String name) async {}\n'
              '=> _value<void>(name, step, null);',
          '_value',
          exemptSnippets: [_stepForwarder],
        ),
        ['stepName'],
      );
    });
  });

  group('presentation: no state observer, no message built from a hit', () {
    test('no BlocObserver or Bloc.observer anywhere in lib/', () {
      final bad = <String>[];
      for (final e in _handWrittenLib().entries) {
        for (final m in codeMatches(e.value, _blocObserver)) {
          bad.add('${e.key}: $m');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'A BlocObserver logs every state; the freezed MessageSearchState '
            'prints its query and other states hold decrypted content. Do '
            'not observe states.\n${bad.join('\n')}',
      );
    });

    test('MessageSearchState opts out of the generated toString, and its '
        'freezed file declares none (it printed the typed query)', () {
      expect(
        codeMatches(
          _libFiles()[_searchStateFile]!,
          RegExp(r'@Freezed\s*\(\s*toStringOverride\s*:\s*false\s*\)'),
        ),
        hasLength(1),
        reason: 'Keep @Freezed(toStringOverride: false) on MessageSearchState.',
      );
      final generated = _libFiles()[_searchStateGenerated]!;
      expect(
        RegExp(r'\bMessageSearchState\b').hasMatch(generated),
        isTrue,
        reason: 'the scan reads the right generated file',
      );
      expect(
        _toStringDecls(generated),
        isEmpty,
        reason:
            'The generated toString of MessageSearchState prints the typed '
            'query; run build_runner after keeping the opt-out.',
      );
    });

    test('self-test: a generated or hand-written toString is seen; a '
        'comment, a string or a call is not', () {
      for (final bad in [
        '@override\nString toString() {\n  return '
            "'MessageSearchState(query: \$query)';\n}",
        "@override\nString toString() => 'MessageSearchState(\$query)';",
        'String  toString ()=> x;',
      ]) {
        expect(_toStringDecls(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '// String toString() => query;',
        "final s = 'String toString()';",
        'final t = state.toString();',
      ]) {
        expect(_toStringDecls(ok), isEmpty, reason: ok);
      }
      expect(
        codeMatches(
          '@freezed\nabstract class MessageSearchState {}',
          RegExp(r'@Freezed\s*\(\s*toStringOverride\s*:\s*false\s*\)'),
        ),
        isEmpty,
      );
    });

    test('no pb.Message is constructed in lib/ but the one id-only open of '
        'an encrypted search hit', () {
      final bad = <String>[];
      for (final e in _handWrittenLib().entries) {
        for (final m in messageConstructions(
          e.value,
          exemptSnippets: _messageConstructionExempt[e.key] ?? const [],
        )) {
          bad.add('${e.key}: $m');
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'A pb.Message built in the app can carry decrypted text into '
            'the cache or the repository. Open hits by id only.\n'
            '${bad.join('\n')}',
      );
    });

    test('the id-only construction still exists exactly once', () {
      for (final e in _messageConstructionExempt.entries) {
        final src = _libFiles()[e.key]!;
        expect(messageConstructions(src), hasLength(1), reason: e.key);
        expect(
          messageConstructions(src, exemptSnippets: e.value),
          isEmpty,
          reason: e.key,
        );
      }
    });

    test('self-test: observers and message constructions are flagged', () {
      for (final bad in [
        'class LogAll extends BlocObserver {}',
        'Bloc.observer = LogAll();',
        'Bloc\n    .observer = x;',
      ]) {
        expect(codeMatches(bad, _blocObserver), isNotEmpty, reason: bad);
      }
      for (final ok in ["// Bloc.observer = x;", "final s = 'BlocObserver';"]) {
        expect(codeMatches(ok, _blocObserver), isEmpty, reason: ok);
      }
      const imp =
          "import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;\n";
      for (final bad in [
        '${imp}final m = pb.Message(text: hit.text);',
        '${imp}final m = pb.Message()..text = t;',
        '${imp}final m = pb.Message.create();',
        "import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart'"
            ' as wire;\nfinal m = wire.Message(id: i);',
        "import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart';"
            '\nfinal m = Message(id: i);',
        // The exemption covers the id-only form only.
        '${imp}pb.Message(id: entry.messageId, '
            'conversationId: entry.conversation.id, text: hit.text)',
      ]) {
        expect(
          messageConstructions(
            bad,
            exemptSnippets: _messageConstructionExempt.values.first,
          ),
          isNotEmpty,
          reason: bad,
        );
      }
      for (final ok in [
        '${imp}final p = pb.MessagePreview(encrypted: true);',
        '$imp// pb.Message(text: t)',
        'final m = Message(id: i);', // not the messaging proto
        '${imp}List<pb.Message> list = [];',
        '${imp}pb.Message(\n  id: entry.messageId,\n'
            '  conversationId: entry.conversation.id,\n)',
      ]) {
        expect(
          messageConstructions(
            ok,
            exemptSnippets: _messageConstructionExempt.values.first,
          ),
          isEmpty,
          reason: ok,
        );
      }
    });
  });
}
