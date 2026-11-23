import 'package:flutter_test/flutter_test.dart';

import 'vault_scan.dart';

/// Guards around the encrypted message pipeline
/// (`lib/features/messages/domain/e2ee/`, plan 5a Task 15) and the
/// presentation code that shows decrypted content. Moved out of
/// `vault_guard_test.dart` (Task 15 fix round); the vault, keys, logging and
/// toString guards stay there. Each rule has a self-test that plants a
/// violation. Pipeline rules cover the directory, so a new file is checked
/// without a list change.
///
/// Run from app/ (like the other guards).

Map<String, String> _libFiles() => libFiles();

Map<String, String> _handWrittenLib() => handWrittenLib();

Map<String, String> _pipelineFiles() => pipelineFiles();

const String _pipelineDir = pipelineDir;

// ---------------------------------------------------------------------------
// R14: nothing readable leaves the vault.

/// What pipeline code may not import: the plaintext cache and outbox, the
/// drift storage layer and drift, any other place that can persist or send
/// (files, preferences, browser storage and JS interop, secure storage, local
/// databases, HTTP clients, the raw network client and the generated Connect
/// clients). The pipeline talks to the server only through
/// MessagingRepository / KeysRepository.
bool _forbiddenPipelineImport(String t) =>
    t.endsWith('/messaging_store.dart') ||
    t.endsWith('/message_outbox.dart') ||
    t.startsWith('lib/core/storage/') ||
    t.startsWith('package:drift') ||
    t == 'dart:io' ||
    t == 'dart:html' ||
    t.startsWith('dart:js') || // dart:js, dart:js_util, dart:js_interop...
    t.startsWith('package:web/') ||
    t.startsWith('package:universal_html') ||
    t.startsWith('package:shared_preferences') ||
    t.startsWith('package:path_provider') ||
    t.startsWith('package:flutter_secure_storage') ||
    t.startsWith('package:hive') || // hive, hive_flutter, hive_ce
    t.startsWith('package:sqflite') ||
    t.startsWith('package:sqlite3') ||
    t.startsWith('package:http/') ||
    t.startsWith('package:dio') ||
    t == 'lib/core/network/api_client.dart' ||
    t.endsWith('.connect.client.dart');

List<String> _pipelineImportViolations(String path, String source) => [
  for (final t in importTargets(path, source))
    if (_forbiddenPipelineImport(t)) t,
];

/// The `MessagingRepository` members pipeline code may reference (plan 5a
/// Task 15), so `sendMessage`, `refreshThread`, `pollThread`,
/// `cachedThread` and every other member (a new one included) can never be
/// reached from it under the guarded names.
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

/// The only names a MessagingRepository may have in pipeline code (also as
/// the end of a chain: `_p._messaging`); every member referenced on them
/// must be allowed (a new member included).
const Set<String> _repositoryNames = {'messaging', '_messaging'};

/// Calls of a forbidden repository member NAME on another type, exempt by
/// shape and receiver, never by name alone (Task 15 fix round, CR I1):
/// - `SecureVault.outbox(` on the vault (`v`, `vault`, `_vault`,
///   `op.vault`): the vault's sealed rows. The repository's `outbox` is a
///   field, never called.
/// - `VaultTx.deleteConversation(` on the transaction `tx` (cleared_at,
///   delete-for-me).
final List<RegExp> _collisionShapes = [
  RegExp(r'(?<![\w$])(?:v|vault|_vault)\s*\.\s*outbox\s*\('),
  RegExp(r'(?<![\w$.])tx\s*\.\s*deleteConversation\s*\('),
];

String _withoutCollisionShapes(String source) {
  var text = stripSource(source, keepStrings: false);
  for (final s in _collisionShapes) {
    text = text.replaceAll(s, ' ');
  }
  return text;
}

/// The members pipeline code may not name on any receiver: every public
/// member of MessagingRepository, as declared today, outside the allowed
/// list.
Set<String> _forbiddenRepositoryMembers() => publicMembers(
  _libFiles()[_messagingRepositoryFile]!,
  'MessagingRepository',
).difference(_pipelineRepositoryMembers);

/// Findings for one pipeline file: a repository under another name, an
/// alias of it, a member on it outside the allowed list (chained too), and a
/// forbidden member name on any receiver outside the collision shapes.
List<String> _repositoryViolations(String source, Set<String> forbidden) => [
  for (final n in namesTyped(source, 'MessagingRepository'))
    if (!_repositoryNames.contains(n)) 'MessagingRepository named $n',
  for (final n in aliasAssignments(source, _repositoryNames))
    'repository aliased as $n',
  for (final m in membersOn(source, _repositoryNames))
    if (!_pipelineRepositoryMembers.contains(m)) 'messaging.$m',
  for (final m in memberReferences(_withoutCollisionShapes(source), forbidden))
    '.$m',
];

/// No Equatable (its `stringify` prints every field) in pipeline code.
final RegExp _equatable = RegExp(r'(?<![\w$])(?:Equatable|stringify)\b');

// ---------------------------------------------------------------------------
// Idempotency keys.

/// Idempotency keys: a `Uuid` use, or a `package:uuid` import, in [source].
List<String> _uuidViolations(String path, String source) => [
  ...codeMatches(source, RegExp(r'(?<![\w$])Uuid\b')),
  for (final t in importTargets(path, source))
    if (t.startsWith('package:uuid')) 'imports $t',
];

// ---------------------------------------------------------------------------
// One door to a removal (Task 15 fix round, SA M3: the whole of lib/).

/// The only files in lib/ that may pass `removeDeviceIds:`, each with why.
const Map<String, String> _removalDoors = {
  'lib/features/messages/domain/e2ee/membership_rules.dart': 'a door (plan)',
  'lib/features/messages/domain/e2ee/commit_runner.dart': 'a door (plan)',
  'lib/features/messages/domain/e2ee/membership_upkeep.dart': 'a door (plan)',
  'lib/features/messages/domain/e2ee/removal_queue_runner.dart':
      'a door (plan)',
  // #1082: `reconcile` moved into this part of membership_upkeep.dart (the
  // same library); its removals are the upkeep's.
  'lib/features/messages/domain/e2ee/membership_upkeep_reconcile.dart':
      'part of membership_upkeep.dart',
  // #1095 (fix round 3, ruling 3): one conversation's attempt moved into
  // this part of removal_queue_runner.dart (the same library).
  'lib/features/messages/domain/e2ee/removal_queue_runner_attempt.dart':
      'part of removal_queue_runner.dart',
  // The engine forwards the commit runner's parameter to the core.
  'lib/core/crypto/guarded_crypto_engine.dart': 'engine forwarder',
  'lib/core/crypto/native_crypto_engine.dart': 'engine forwarder',
};

/// The part files among the doors and the library each belongs to.
const Map<String, String> _doorParts = {
  'lib/features/messages/domain/e2ee/membership_upkeep_reconcile.dart':
      'membership_upkeep.dart',
  'lib/features/messages/domain/e2ee/removal_queue_runner_attempt.dart':
      'removal_queue_runner.dart',
};

/// The pipeline's public removal entry points: every function in the
/// pipeline that declares a `removeDeviceIds` parameter. A new one fails
/// until it is reviewed and pinned here.
const Map<String, List<String>> _removalMethods = {
  'lib/features/messages/domain/e2ee/commit_runner.dart': [
    'change',
    'changeLocked',
  ],
};

/// The door libraries; no file outside the pipeline may import one, so the
/// removal methods can only be called from pipeline code (the user's own
/// removal goes through the port's `removeDevice`).
const List<String> _doorLibraries = [
  'membership_rules.dart',
  'commit_runner.dart',
  'membership_upkeep.dart',
  'removal_queue_runner.dart',
];

final RegExp _removeDeviceIdsArg = RegExp(r'(?<![\w$])removeDeviceIds\s*:');

List<String> _doorImportViolations(String path, String source) => [
  if (!path.startsWith(_pipelineDir))
    for (final t in importTargets(path, source))
      if (_doorLibraries.any((d) => t == '$_pipelineDir$d')) t,
];

/// `export` of a door library from anywhere in lib/, the pipeline included
/// (SA R6): a re-export would let a file outside import a door through it.
List<String> _doorExportViolations(String path, String source) {
  final exports = RegExp(r'\bexport\s[^;]*;')
      .allMatches(stripSource(source, keepStrings: true))
      .map((m) => m.group(0)!)
      .join('\n');
  return [
    for (final t in importTargets(path, exports))
      if (_doorLibraries.any((d) => t == '$_pipelineDir$d')) t,
  ];
}

/// The removal entry points every other pipeline function goes through.
const Set<String> _removalRoots = {'change', 'changeLocked'};

/// Every public pipeline function that reaches [_removalRoots] (directly or
/// through another pipeline function, on any receiver), by file (SA R6). A
/// new one fails until it is reviewed and pinned here.
const Map<String, List<String>> _removalReachers = {
  // The membership upkeep (plan; #1082 moved reconcile into a part): an
  // acceptance and the reconcile pass commit the decided removals.
  'lib/features/messages/domain/e2ee/membership_upkeep.dart': [
    'acceptForReply',
    'acceptForReplyLocked',
    'noteAcceptedSeen',
    'onAccepted',
    'reconcile',
  ],
  // The removal queue runner (plan; #1095 part): the user's own removal and
  // the pass its triggers start.
  'lib/features/messages/domain/e2ee/removal_queue_runner.dart': [
    'noteConversation',
    'onAccepted',
    'onAppResumed',
    'onVaultReady',
    'removeDevice',
    'runPass',
  ],
};

/// The public names among [functionsReaching] over the pipeline.
Map<String, List<String>> _publicRemovalReachers(Map<String, String> files) => {
  for (final e in functionsReaching(files, _removalRoots).entries)
    if (e.value.any((n) => !n.startsWith('_')))
      e.key: [
        for (final n in e.value)
          if (!n.startsWith('_')) n,
      ],
};

// ---------------------------------------------------------------------------
// Errors and reports (Task 15 fix round, ruling 3: the positive rule).

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

/// Error constructor arguments that are not fixed text but are allowed, by
/// file (exact source fragments; each with why).
const Map<String, List<String>> _errorArgumentExempt = {
  'lib/features/messages/domain/e2ee/group_starter_reset.dart': [
    // #1083 (reset): the refusal carries the typed AppException the
    // repository threw (its kind decides the copy); no id, key or content.
    'throw E2eeActionException(E2eeRefusal.unavailable, cause: e)',
    // #1083: the run's own E2eeActionException (a typed refusal built from
    // the fixed E2eeRefusal values above), thrown again to the caller.
    'throw refusal',
  ],
  // #1074 (receive walks): `pending()` notes the catch-up pair in memory and
  // returns `const _WalkPending()`, a field-less control-flow signal.
  'lib/features/messages/domain/e2ee/message_receiver_sink.dart': [
    'throw pending()',
  ],
};

/// Constants an error constructor may pass, by file (each with why).
const Map<String, Set<String>> _errorArgumentConstants = {
  // #1083: the limit's fixed name (a const String) for the typed refusal.
  'lib/features/messages/domain/e2ee/group_starter_reset.dart': {
    'kLimitCommitsPerConversationDaily',
  },
};

/// The one forwarding call in sync_coordinator.dart whose step name is not
/// a literal: `_step` passes its own (literal-checked) `name` on.
const String _stepForwarder = '_value<void>(name, step, null)';

/// Every `E2eePipelineError(<not a literal>)` in the pipeline, by file: the
/// reporters that forward a `step` their callers name (each caller's step is
/// a literal, checked below), and the coordinator's `'sync.$name'`.
const Map<String, List<String>> _pinnedForwards = {
  'lib/features/messages/domain/e2ee/commit_runner.dart': ['step', 'step'],
  'lib/features/messages/domain/e2ee/conversation_crypto.dart': ['step'],
  'lib/features/messages/domain/e2ee/e2ee_pipeline.dart': ['step'],
  'lib/features/messages/domain/e2ee/encrypted_sender.dart': ['step', 'step'],
  'lib/features/messages/domain/e2ee/group_starter.dart': ['step', 'step'],
  'lib/features/messages/domain/e2ee/membership_upkeep.dart': ['step'],
  'lib/features/messages/domain/e2ee/message_receiver.dart': ['step'],
  'lib/features/messages/domain/e2ee/removal_queue_runner.dart': [
    'step',
    'step',
  ],
  'lib/features/messages/domain/e2ee/sync_coordinator.dart': [r"'sync.$name'"],
};

/// The only local alias of the injected error callback: the pipeline's parts
/// hand the pipeline's callback to each part (#1103). It is only ever passed
/// on as `onUnexpectedError: report`, never called.
const Map<String, List<String>> _pinnedReportAliases = {
  'lib/features/messages/domain/e2ee/e2ee_pipeline_parts.dart': ['report'],
};

const Set<String> _callbackNames = {'onUnexpectedError', '_onUnexpectedError'};

/// What a `_report...(` helper call may pass where the helper takes the
/// caught error (an `Object` parameter). The helper reports only
/// `E2eePipelineError(step)`; the sink rule checks that.
const Set<String> _errorNames = {'e', 'err', 'error'};

/// What a report call may pass where it takes a stack (a `StackTrace`).
const Set<String> _stackNames = {
  's',
  'st',
  'stack',
  'stackTrace',
  'StackTrace.current',
  'stack ?? StackTrace.current',
};

/// The parameter kinds of every `_report...` helper declared in [sources],
/// by name, each signature as declared ('step' for a String, 'stack' for a
/// StackTrace, 'error' for an Object, else 'other'). A name declared twice
/// lists each signature (the guard requires one).
Map<String, Set<String>> _reporterSignatures(Iterable<String> sources) {
  final out = <String, Set<String>>{};
  for (final s in sources) {
    final code = stripSource(s, keepStrings: false);
    for (final m in RegExp(
      r'\b(?:void|Future<void>|bool)\s+(_report\w*)\s*\(([^)]*)\)',
    ).allMatches(code)) {
      final kinds = [
        for (final p
            in m.group(2)!.replaceAll(RegExp(r'[\[\]{}]'), '').split(','))
          if (p.trim().isNotEmpty)
            switch (p.trim().split(RegExp(r'\s+')).first.replaceAll('?', '')) {
              'String' => 'step',
              'StackTrace' => 'stack',
              'Object' || 'dynamic' => 'error',
              _ => 'other',
            },
      ];
      (out[m.group(1)!] ??= {}).add(kinds.join(','));
    }
  }
  return out;
}

/// Any `report...Error(` call, also on a receiver (`_pipeline.reportPortError(`).
final RegExp _reportErrorCall = RegExp(r'(?<![\w$])report\w*Error\s*\(');

/// Report helper calls that forward a step their own caller named, by file
/// (the finding as `_reportCallViolations` prints it). Each needs a why; the
/// forwarder's callers are checked like any other report call.
const Map<String, List<String>> _pinnedReportForwards = {
  // Task 13b: `reportPortError(step, stack)` is the port's one door into the
  // pipeline's reporter; every caller (`_pipeline.reportPortError(`) passes a
  // step literal, which `_reportErrorCall` checks.
  'lib/features/messages/domain/e2ee/e2ee_pipeline.dart': ['_report*(step)'],
};

/// Report calls in [source] that pass anything but, position by position,
/// what the helper's declaration takes there (SA R2): a step literal for a
/// String, the caught error for an Object, the stack for a StackTrace. A
/// helper call on any receiver counts (`this._report(`, `_p._report(`, SA
/// R1); a helper with no known declaration takes step literals only.
/// [signatures] defaults to the helpers declared in [source].
List<String> _reportCallViolations(
  String source, [
  Map<String, Set<String>>? signatures,
]) {
  final sigs = signatures ?? _reporterSignatures([source]);
  final bad = <String>[];
  void check(List<String> args, List<String> kinds) {
    for (var k = 0; k < args.length; k++) {
      final a = args[k];
      final ok = switch (k < kinds.length ? kinds[k] : 'none') {
        'step' => stepLiteral.hasMatch(a),
        'error' => _errorNames.contains(a),
        'stack' => _stackNames.contains(a),
        _ => false,
      };
      if (!ok) bad.add('_report*($a)');
    }
  }

  for (final e in sigs.entries) {
    final kinds = e.value.length == 1
        ? e.value.single.split(',')
        : const <String>[];
    for (final args in callArguments(
      source,
      RegExp(r'(?<![\w$])' + RegExp.escape(e.key) + r'\s*\('),
    )) {
      check(args, kinds);
    }
  }
  final known = sigs.keys.map(RegExp.escape).join('|');
  for (final args in callArguments(
    source,
    RegExp(
      r'(?<![\w$])' +
          (known.isEmpty ? '' : r'(?!(?:' + known + r')\s*\()') +
          r'_report\w*\s*\(',
    ),
  )) {
    check(args, [for (final _ in args) 'step']);
  }
  bad.addAll(_reportErrorCallViolations(source));
  return bad;
}

/// `report...Error(` calls in [source] that pass anything but a step literal
/// or `E2eePipelineError('<literal>')`, then stack names.
List<String> _reportErrorCallViolations(String source) => [
  for (final args in callArguments(source, _reportErrorCall))
    for (var k = 0; k < args.length; k++)
      if (k == 0
          ? !(stepLiteral.hasMatch(args[k]) ||
                RegExp(
                  r"^(?:const\s+)?E2eePipelineError\s*\(\s*'[A-Za-z.]+'\s*\)$",
                ).hasMatch(args[k]))
          : !_stackNames.contains(args[k]))
        'report*Error(${args[k]})',
];

/// Uses of a pinned alias other than its declaration and
/// `onUnexpectedError: <alias>`.
List<String> _aliasMisuse(String source, String alias) {
  final text = stripSource(source, keepStrings: false);
  final all = RegExp(r'(?<![\w$.])' + RegExp.escape(alias) + r'(?![\w$])')
      .allMatches(text)
      .length;
  final declared = RegExp(
    r'(?<![\w$.])' + RegExp.escape(alias) + r'\s*=(?![=>])',
  ).allMatches(text).length;
  final passed = RegExp(
    r'(?<![\w$.])onUnexpectedError\s*:\s*' +
        RegExp.escape(alias) +
        r'(?![\w$])',
  ).allMatches(text).length;
  return all == declared + passed ? const [] : ['$alias used otherwise'];
}

// ---------------------------------------------------------------------------
// Presentation.

/// The one `pb.Message` construction allowed in lib/: #1062 (5b search) opens
/// an encrypted hit with an id-only message, never its text (5b review of
/// PR 5). The exemption holds only where `)` or `,` follows it.
const Map<String, List<String>> _messageConstructionExempt = {
  'lib/features/messages/presentation/widgets/message_search_panel.dart': [
    'pb.Message( id: entry.messageId, conversationId: entry.conversation.id, )',
  ],
};

/// The data layer's own writes into messaging protos (the plaintext cache
/// reading its rows back, and the encrypted marker clearing the snippet).
/// Pinned by file and finding; nothing else in lib/ may write one.
const Map<String, List<String>> _pinnedPbMutations = {
  // Marks a row encrypted: the snippet is emptied, never filled.
  'lib/features/messages/data/messaging_repository.dart': ['..snippet ='],
  // The same marker, and the cache's own rows decoded on read.
  'lib/features/messages/data/messaging_store.dart': [
    '..snippet =',
    'pb.Message.fromBuffer(',
    'pb.Message.fromBuffer(',
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

/// SA L7 (Task 15 fix round): the global search's parsed query printed the
/// typed text. Its toString now prints the kind and the issue only.
const String _searchQueryFile = 'lib/features/search/domain/search_query.dart';
const String _searchQueryToString =
    r"=> 'SearchQuery(${kind.name}, ${issue.name})';";

/// `toString` declarations in [source] (generated code included), comments
/// and strings ignored.
List<String> _toStringDecls(String source) =>
    codeMatches(source, toStringDeclaration);

final RegExp _freezedOptOut = RegExp(
  r'@Freezed\s*\([^)]*\btoStringOverride\s*:\s*false\b[^)]*\)',
);

/// Freezed annotations in [source] that keep the generated toString.
List<String> _freezedWithToString(String source) => [
  for (final m in RegExp(
    r'@(?:(?:freezed|unfreezed)(?![\w$])|Freezed\s*\([^)]*\))',
  ).allMatches(stripSource(source, keepStrings: true)))
    if (!_freezedOptOut.hasMatch(m.group(0)!)) m.group(0)!,
];

/// The writes of a preview field (`snippet`, `lastMessage`) under
/// lib/features/messages/, whatever the file imports (SA R3), by file.
/// Filled from the tree; each with why.
const Map<String, List<String>> _pinnedPbNameMutations = {
  // The encrypted marker: the preview copy gets `encrypted` and an EMPTY
  // snippet (#1071); never filled.
  'lib/features/messages/data/messaging_repository.dart': [
    '..lastMessage =',
    '..snippet =',
  ],
  'lib/features/messages/data/messaging_store.dart': [
    // The cache merge keeps the server's own cached preview when a page has
    // none (a copy of a server row, no decrypted text).
    '.lastMessage =',
    // The same encrypted marker on read (#1071).
    '..lastMessage =',
    '..snippet =',
  ],
};

final RegExp _blocObserver = RegExp(
  r'(?<![\w$])BlocObserver\b|(?<![\w$])Bloc\s*\.\s*observer\b',
);

void main() {
  group('pipeline: nothing readable leaves the vault (R14)', () {
    test('no pipeline file imports the plaintext cache, the outbox, '
        'core/storage, drift or another way to persist or send', () {
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
            'vault only, and reaches the server only through the '
            'repositories.\n${bad.join('\n')}',
      );
    });

    test('pipeline code references only the allowed MessagingRepository '
        'members, holds it only as messaging / _messaging, and aliases it '
        'nowhere', () {
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
        'declared, the four named ones are forbidden, and each collision '
        'shape is still used', () {
      final declared = publicMembers(
        _libFiles()[_messagingRepositoryFile]!,
        'MessagingRepository',
      );
      expect(declared, containsAll(_pipelineRepositoryMembers));
      expect(
        _forbiddenRepositoryMembers(),
        containsAll([
          'sendMessage',
          'refreshThread',
          'pollThread',
          'cachedThread',
          'outbox',
          'deleteConversation',
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
      for (final s in _collisionShapes) {
        expect(
          _pipelineFiles().values.any(
            (src) => s.hasMatch(stripSource(src, keepStrings: false)),
          ),
          isTrue,
          reason: '$s is no longer needed: remove it',
        );
      }
    });

    test('no Equatable or stringify in pipeline code', () {
      final bad = <String>[
        for (final e in _pipelineFiles().entries)
          for (final m in codeMatches(e.value, _equatable)) '${e.key}: $m',
      ];
      expect(bad, isEmpty, reason: bad.join('\n'));
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
        "import 'dart:io';",
        "import 'dart:html';",
        "import 'package:web/web.dart';",
        "import 'package:shared_preferences/shared_preferences.dart';",
        "import 'package:path_provider/path_provider.dart';",
        "import 'package:flutter_secure_storage/flutter_secure_storage.dart';",
        "import '../../../../core/network/api_client.dart';",
        "import '../../../../gen/dzeroth/messaging/v1/"
            "messaging.connect.client.dart';",
        // SA R4.
        "import 'package:http/http.dart' as http;",
        "import 'package:dio/dio.dart';",
        "import 'dart:js_interop';",
        "import 'dart:js_util';",
        "import 'package:universal_html/html.dart';",
        "import 'package:hive/hive.dart';",
        "import 'package:hive_flutter/hive_flutter.dart';",
        "import 'package:sqflite/sqflite.dart';",
        "import 'package:sqlite3/sqlite3.dart';",
      ]) {
        expect(_pipelineImportViolations(p, src), isNotEmpty, reason: src);
      }
      for (final src in [
        "import '../../data/messaging_repository.dart';",
        "import '../../../../core/vault/secure_vault.dart';",
        "import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart';",
        "import 'dart:typed_data';",
        "// import 'package:drift/drift.dart';",
      ]) {
        expect(_pipelineImportViolations(p, src), isEmpty, reason: src);
      }
    });

    test('self-test: a forbidden member is flagged on any receiver, chained '
        'or aliased; the collision shapes and allowed members are not', () {
      final forbidden = {
        'sendMessage',
        'refreshThread',
        'pollThread',
        'cachedThread',
        'outbox',
        'deleteConversation',
      };
      for (final bad in [
        'await _messaging.sendMessage(conversationId: id, text: t);',
        'final f = _messaging.refreshThread;',
        'messaging?.pollThread(id);',
        '_messaging..cachedThread(id);',
        'final o = _messaging\n    .outbox;',
        // Chained and aliased (CR I1 / SA L1).
        '_pipeline.messaging.outbox.save(row);',
        'await _p._messaging.deleteConversation(conversationId: id);',
        'final repo = _pipeline.messaging; repo.outbox;',
        'final x = _p._messaging.notOnTheList;',
        'final o = x.outbox;',
        'await other.deleteConversation(id);',
        '_messaging\n    ..brandNewMember();',
        'final x = _messaging!.markConversationRead;',
        'final MessagingRepository repo;',
        'void f(MessagingRepository? m) {}',
        'MessagingRepository get repository => _messaging;',
        'final r = _p._messaging;',
        // SA R1 / code Nit 4: `!`, `as`, `??` and getter aliases.
        'final r = _pipeline.messaging!;',
        'final r = _p._messaging as MessagingRepository;',
        'final r = other ?? _messaging;',
        'final r = _messaging ?? other;',
        'get repo => _messaging;',
        'Object get repo => _p.messaging;',
      ]) {
        expect(_repositoryViolations(bad, forbidden), isNotEmpty, reason: bad);
      }
      for (final ok in [
        'final rows = (await vault.outbox()).items;',
        'for (final r in (await v.outbox(conversationId: id)).items) {}',
        'final read = await _vault.outbox();',
        'final read = await op.vault.outbox(conversationId: id);',
        'await tx.deleteConversation(id, upToCreatedAtMicros: b);',
        'final MessagingRepository _messaging;',
        'required MessagingRepository messaging,',
        'final messaging = _p._messaging;',
        '_messaging = messaging,',
        'await _messaging.listWelcomes(deviceId: d);',
        '_messaging.cacheSession;',
        "import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;",
        '// _messaging.sendMessage(x)',
        "final s = 'refreshThread';",
      ]) {
        expect(_repositoryViolations(ok, forbidden), isEmpty, reason: ok);
      }
      // The class parser: members at the body's top level, nothing inside
      // bodies, parameter lists, initializers, `=>` expressions or
      // annotations; block-bodied getters too (CR M3).
      final members = publicMembers('''
class Repo {
  Repo({required Store store}) : _store = store, _gate = Gate(store.thing());
  final Store _store;
  final MessageOutbox outbox = MessageOutbox(inner());
  void Function(String id)? onThing;
  Gate get gate => _gate.wrapped();
  Thread get thread {
    return _store.thread('x');
  }
  @pragma('vm:prefer-inline')
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
        'thread',
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

    test('self-test: Equatable and stringify are flagged', () {
      for (final bad in [
        'class A extends Equatable {}',
        '@override\nbool get stringify => true;',
      ]) {
        expect(codeMatches(bad, _equatable), isNotEmpty, reason: bad);
      }
      expect(
        codeMatches("// Equatable\nfinal s = 'stringify';", _equatable),
        isEmpty,
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

  group('one door to a removal (all of lib/)', () {
    test('only the doors, their parts and the engine forwarders pass '
        'removeDeviceIds:', () {
      final bad = <String>[];
      for (final e in _handWrittenLib().entries) {
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

    test('the pipeline\'s removal entry points are pinned, and no file '
        'outside the pipeline imports a door library', () {
      final found = <String, List<String>>{
        for (final e in _pipelineFiles().entries)
          if (functionsDeclaring(e.value, 'removeDeviceIds').isNotEmpty)
            e.key: functionsDeclaring(e.value, 'removeDeviceIds'),
      };
      expect(found, _removalMethods);
      expect(
        _publicRemovalReachers(_pipelineFiles()),
        _removalReachers,
        reason:
            'Every public pipeline function that reaches change / '
            'changeLocked is pinned; a new one is reviewed first.',
      );
      final bad = <String>[
        for (final e in _handWrittenLib().entries) ...[
          for (final t in _doorImportViolations(e.key, e.value))
            '${e.key} imports $t',
          for (final t in _doorExportViolations(e.key, e.value))
            '${e.key} exports $t',
        ],
      ];
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('each allowed part file is still a part of its door, and every '
        'door file exists', () {
      for (final e in _doorParts.entries) {
        expect(
          RegExp(
            r'''^\s*part\s+of\s+['"]''' + RegExp.escape(e.value) + r'''['"]''',
          ).hasMatch(stripSource(_libFiles()[e.key]!, keepStrings: true)),
          isTrue,
          reason: e.key,
        );
      }
      for (final f in _removalDoors.keys) {
        expect(_libFiles().containsKey(f), isTrue, reason: f);
      }
    });

    test('self-test: a planted removeDeviceIds:, a new removal entry point '
        'and a door import from outside are flagged', () {
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
      expect(
        _removalDoors.containsKey('lib/features/settings/x.dart'),
        isFalse,
      );
      expect(
        functionsDeclaring(
          'Future<CommitOutcome> change(\n  String id, {\n'
              '  List<UsableClaim> adds = const [],\n'
              '  List<Uint8List> removeDeviceIds = const [],\n}) => x(\n'
              '  removes: removeDeviceIds,\n);\n'
              'Future<void> sneaky(List<Uint8List> removeDeviceIds) async {}',
          'removeDeviceIds',
        ),
        ['change', 'sneaky'],
      );
      expect(
        _doorImportViolations(
          'lib/features/settings/presentation/x.dart',
          "import '../../messages/domain/e2ee/removal_queue_runner.dart';",
        ),
        isNotEmpty,
      );
      expect(
        _doorImportViolations(
          'lib/features/messages/domain/e2ee/x.dart',
          "import 'removal_queue_runner.dart';",
        ),
        isEmpty,
      );
      // SA R6: a door is exported nowhere, the pipeline included.
      expect(
        _doorExportViolations(
          'lib/features/messages/domain/e2ee/e2ee.dart',
          "export 'commit_runner.dart' show CommitRunner;",
        ),
        isNotEmpty,
      );
      expect(
        _doorExportViolations(
          'lib/features/messages/domain/e2ee/x.dart',
          "import 'commit_runner.dart';\nexport 'e2ee_types.dart';",
        ),
        isEmpty,
      );
      // SA R6: whatever its parameter is called, a function reaching change
      // (directly, through another function, on any receiver) is listed.
      final reach = functionsReaching({
        'a.dart':
            'class Runner {\n'
            '  Future<void> change(String id, {List<int> removeDeviceIds = '
            'const []}) async {}\n'
            '  Future<void> changeLocked(String id) async {}\n'
            '}\n',
        'b.dart':
            'class Upkeep {\n'
            '  Future<void> dropAll(List<int> gone) => '
            '_runner.change(id, removeDeviceIds: gone);\n'
            '  Future<void> _inner(List<int> x) async {\n'
            '    await _r.changeLocked(id);\n  }\n'
            '  Future<void> sweep() async { await _inner(const []); }\n'
            '  void unrelated() { exchange(1); onChange(); }\n'
            '}\n',
        // A part of b.dart reaches through b's private helper; c.dart's
        // `_inner` is another library's name.
        'b_part.dart':
            "part of 'b.dart';\n"
            'extension on Upkeep { Future<void> viaPart() => _inner(x); }\n',
        'c.dart':
            'Future<void> outer() async => upkeep.sweep();\n'
            'Future<void> other() async => _inner(1);\n'
            'T apply<T>(T Function(T) change, T x) => change(x);\n',
      }, _removalRoots);
      expect(reach, {
        'b.dart': ['_inner', 'dropAll', 'sweep'],
        'b_part.dart': ['viaPart'],
      });
    });
  });

  group('pipeline: errors and reports carry fixed names only', () {
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

    test('every error constructor in the pipeline takes fixed arguments '
        '(\$-free, +-free literals, a .length, a number)', () {
      final bad = <String>[];
      for (final e in _pipelineFiles().entries) {
        for (final m in errorArgumentViolations(
          e.value,
          allowedNames: _errorArgumentConstants[e.key] ?? const {},
          exemptSnippets: [
            ...?_interpolatedErrorExempt[e.key],
            ...?_errorArgumentExempt[e.key],
          ],
        )) {
          bad.add('${e.key}: $m');
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
      // Each exemption and constant is still used, exactly where pinned.
      for (final e in _errorArgumentExempt.entries) {
        for (final s in e.value) {
          expect(
            errorArgumentViolations(
              _libFiles()[e.key]!,
              allowedNames: _errorArgumentConstants[e.key] ?? const {},
              exemptSnippets: [
                for (final o in e.value)
                  if (o != s) o,
              ],
            ),
            isNotEmpty,
            reason: '${e.key}: $s is no longer needed',
          );
        }
      }
      for (final e in _errorArgumentConstants.entries) {
        expect(
          errorArgumentViolations(
            _libFiles()[e.key]!,
            exemptSnippets: _errorArgumentExempt[e.key] ?? const [],
          ),
          isNotEmpty,
          reason: '${e.key}: ${e.value} no longer needed',
        );
      }
    });

    test('the error callback only ever receives E2eePipelineError, the '
        'forwarded step names are pinned, and the callback has one pinned '
        'alias', () {
      final sinks = <String>[];
      final forwards = <String, List<String>>{};
      final aliases = <String, List<String>>{};
      final reports = <String, List<String>>{};
      final signatures = _reporterSignatures(_pipelineFiles().values);
      expect(signatures, isNotEmpty);
      for (final s in signatures.entries) {
        expect(
          s.value,
          hasLength(1),
          reason: '${s.key} is declared with different parameters',
        );
      }
      for (final e in _pipelineFiles().entries) {
        for (final v in sinkArgumentViolations(e.value)) {
          sinks.add('${e.key}: $v');
        }
        final f = pipelineErrorForwards(e.value);
        if (f.isNotEmpty) forwards[e.key] = f;
        final a = aliasAssignments(e.value, _callbackNames);
        if (a.isNotEmpty) aliases[e.key] = a;
        final r = _reportCallViolations(e.value, signatures);
        if (r.isNotEmpty) reports[e.key] = r;
      }
      expect(sinks, isEmpty, reason: sinks.join('\n'));
      expect(forwards, _pinnedForwards);
      expect(aliases, _pinnedReportAliases);
      for (final e in _pinnedReportAliases.entries) {
        for (final alias in e.value) {
          expect(
            _aliasMisuse(_libFiles()[e.key]!, alias),
            isEmpty,
            reason: e.key,
          );
        }
      }
      expect(
        reports,
        _pinnedReportForwards,
        reason:
            'A _report... helper takes a step literal and the caught error '
            'and stack; a report...Error call takes a step literal or '
            "E2eePipelineError('<literal>') and a stack. A forwarder that "
            'passes its own `step` on is pinned in _pinnedReportForwards.',
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
        names.where((n) => !stepLiteral.hasMatch(n)),
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
        r"return Future<void>.error('lost $messageId');",
        r"throw 'plain $text';",
        r"x ?? (throw StateError('$y'));",
        r"controller.addError(Exception('$z'));",
        r"throw Error('$z');",
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
    });

    test('self-test: an error constructor with a value, a concatenation or '
        'a bare / generic form is flagged; fixed ones and declarations are '
        'not', () {
      for (final bad in [
        "throw StateError('no row ' + id);",
        'throw StateError(id);',
        'throw ArgumentError.value(reportKey, \'reportKey\');',
        "throw Exception(row.text);",
        'throw Error(conversationId);',
        "throw FormatException('bad', bytes);",
        "throw StateError(message: deviceId);",
        // Code Nit 2: only a real constructor declaration is skipped.
        'throw StateError(this.conversationId);',
        "throw ArgumentError.value({'id': id});",
        'throw ArgumentError([conversationId]);',
        'final e = StateError(String id);',
        // SA R7 / code Nit 1: a static field is not an enum value.
        'throw ArgumentError(Uri.base);',
        'throw StateError(Limits.maxText);',
        // SA R7: what is thrown or forwarded.
        'throw e;',
        'throw refusal;',
        'throw pending();',
        "throw 'lost';",
        'throw _Stopped(conversationId);',
        'throw const _Stopped(id);',
        'completer.completeError(e, s);',
        'w.completeError(StateError(id));',
        "w.completeError(StateError('x'), deviceId);",
        'controller.addError(err);',
        'return Future.error(error);',
        "return Future<void>.error(StateError('x' + id));",
        'return Future<bool>.error(Wrapped(row.text));',
      ]) {
        expect(
          errorArgumentViolations(bad, enumNames: const {'E2eeRefusal'}),
          isNotEmpty,
          reason: bad,
        );
      }
      for (final ok in [
        "throw StateError('no row');",
        "throw StateError('a' 'b');",
        "throw ArgumentError.value(reportKey.length, 'reportKey', 'bad');",
        "throw RangeError.range(1, 0, 32);",
        "throw const NetworkException('timed out');",
        "throw StateError(r'raw');",
        'class FooError { const FooError(this.step); final String step; }',
        'class FooException {\n  @literal\n'
            '  FooException({required this.code, this.detail});\n}',
        'class BarError extends Error { BarError(String step) : super(step); }',
        'class B2Error { factory B2Error.of(String s) => const B2Error(); '
            'const B2Error(); }',
        "throw const E2eePipelineError('x');",
        'throw const E2eeActionException(E2eeRefusal.unavailable);',
        'Error.throwWithStackTrace(failure, failureStack!);',
        'RateLimitedException(:final retryAfter) => retryAfter,',
        'case RateLimitedException(retryAfter: final r):',
        'rethrow;',
        'throw const _Stopped();',
        'x ?? (throw const _Malformed());',
        'w.completeError(const BudgetPaused());',
        "w.completeError(StateError('The budget was reset.'));",
        "w.completeError(StateError('x'), StackTrace.current);",
        "return Future<bool>.error(StateError('not ready'));",
        'void addError(Object error, [StackTrace? s]) {}',
      ]) {
        expect(
          errorArgumentViolations(ok, enumNames: const {'E2eeRefusal'}),
          isEmpty,
          reason: ok,
        );
      }
      // A constant is allowed only by name; an enum value only of an enum
      // declared in lib/ (the default reads lib/).
      const limit = "throw const RateLimitedException('x', limitName: kLimit);";
      expect(errorArgumentViolations(limit), isNotEmpty);
      expect(errorArgumentViolations(limit, allowedNames: {'kLimit'}), isEmpty);
      expect(declaredEnums(), contains('E2eeRefusal'));
      expect(declaredEnums(), isNot(contains('Uri')));
      expect(
        errorArgumentViolations(
          'throw const E2eeActionException(E2eeRefusal.unavailable);',
          enumNames: const {},
        ),
        isNotEmpty,
      );
    });

    test('self-test: the callback, forwards, aliases and report helpers', () {
      for (final bad in [
        '_onUnexpectedError?.call(e, s);',
        'onUnexpectedError(error, stack);',
        '_onUnexpectedError!.call(StateError(id), s);',
        // SA R1: on a receiver.
        '_p._onUnexpectedError?.call(e, s);',
        'this._onUnexpectedError(error, s);',
        'widget.onUnexpectedError?.call(StateError(id), s);',
      ]) {
        expect(sinkArgumentViolations(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        "_onUnexpectedError?.call(const E2eePipelineError('a.b'), s);",
        '_onUnexpectedError?.call(\n  E2eePipelineError(step),\n  s,\n);',
        'void Function(Object e, StackTrace s)? onUnexpectedError,',
        'onUnexpectedError: onUnexpectedError,',
      ]) {
        expect(sinkArgumentViolations(ok), isEmpty, reason: ok);
      }
      expect(
        pipelineErrorForwards(
          "E2eePipelineError(step); const E2eePipelineError('a.b'); "
          'E2eePipelineError(row.localId); const E2eePipelineError(this.step);',
        ),
        ['step', 'row.localId'],
      );
      // SA R1: a prefixed construction is read too.
      expect(pipelineErrorForwards('types.E2eePipelineError(row.id);'), [
        'row.id',
      ]);
      expect(
        aliasAssignments(
          'final report = _p._onUnexpectedError; '
          '_onUnexpectedError = onUnexpectedError, '
          'final cb = onUnexpectedError; '
          'get _g => _onUnexpectedError; '
          'final b = _p._onUnexpectedError!; '
          'final c = onUnexpectedError as Reporter; '
          'final d = x ?? _onUnexpectedError; '
          'final f = (_onUnexpectedError ?? fallback); '
          'final same = a == onUnexpectedError;',
          _callbackNames,
        ),
        ['report', 'cb', '_g', 'b', 'c', 'd', 'f'],
      );
      expect(
        _aliasMisuse(
          'final report = _p._onUnexpectedError;\n'
              'X(onUnexpectedError: report); Y(onUnexpectedError: report);',
          'report',
        ),
        isEmpty,
      );
      expect(
        _aliasMisuse(
          'final report = _p._onUnexpectedError;\nreport?.call(x, s);',
          'report',
        ),
        isNotEmpty,
      );
      // The helpers as the pipeline declares them.
      final sigs = _reporterSignatures([
        'void _reportIfBug(Object e, StackTrace s, String step) {}',
        'void _reportBug(String step) => x;',
        'void _reportOnce(String step, [StackTrace? stack]) {}',
        'void _report(String step, StackTrace stack) => x;',
      ]);
      expect(sigs, {
        '_reportIfBug': {'error,stack,step'},
        '_reportBug': {'step'},
        '_reportOnce': {'step,stack'},
        '_report': {'step,stack'},
      });
      for (final bad in [
        '_reportIfBug(e, s, row.localId);',
        "_reportOnce('a' + id);",
        'this._reportBug(conversationId);',
        'x ? _reportBug(step) : null;',
        'x ?? _reportBug(id);',
        'reportPortError(e, s);',
        "reportUnexpectedError(StateError('x'), s);",
        "reportPortError(const E2eePipelineError('a'), deviceId);",
        '_pipeline.reportPortError(conversationId, s);',
        'void reportPortError(String step, StackTrace s) => _report(step, s);',
        // SA R2 / code Nit 3: a caught name in the step position.
        "_reportIfBug('commit.x', s, e);",
        '_reportBug(e);',
        '_reportOnce(error, s);',
        "_reportIfBug(e, e, 'commit.x');",
        "_reportIfBug(s, s, 'commit.x');",
        "_reportBug('a', s);", // more arguments than declared
        // SA R1: on a receiver.
        '_p._report(conversationId, s);',
        'this._reportOnce(e);',
        "_unknownReporter('a'); _reportNew(e, s);",
      ]) {
        expect(_reportCallViolations(bad, sigs), isNotEmpty, reason: bad);
      }
      expect(
        _reportCallViolations(
          'void reportPortError(String step, StackTrace s) => _report(step, s);',
          sigs,
        ),
        ['_report*(step)'],
      );
      for (final ok in [
        "_reportIfBug(e, s, 'commit.mayCommit');",
        "_reportBug('commit.random');",
        "_reportOnce('send.outbox.unreadable', stack);",
        "_reportOnce('send.outbox.unreadable');",
        "_p._report('port.send', s);",
        'void _reportIfBug(Object e, StackTrace s, String step) {}',
        "reportPortError(const E2eePipelineError('port.send'), s);",
        "_pipeline.reportPortError('port.send', s);",
        "_reportNew('a.b');",
      ]) {
        expect(_reportCallViolations(ok, sigs), isEmpty, reason: ok);
      }
      // The coordinator's literal check sees ternary, ?? and this. calls.
      expect(
        firstArguments(
          "await _step('drain', f); x ? _step(name, f) : null;\n"
              'y ?? this._step(other, f);\n'
              '_p._step(third, f);\n'
              'Future<void> _step(String name, F step) => '
              '_value<void>(name, step, null);',
          '_step',
        ),
        ["'drain'", 'name', 'other', 'third'],
      );
      expect(
        firstArguments(
          "await _value<int>(\n  stepName, g, 0);\n"
              'Future<T> _value<T>(String name) async {}\n'
              'Foo? _value(String n) => null;\n'
              '=> _value<void>(name, step, null);',
          '_value',
          exemptSnippets: [_stepForwarder],
        ),
        ['stepName'],
      );
    });
  });

  group('presentation: no state observer, no printed query, no message '
      'built or changed from a hit', () {
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
            'A BlocObserver logs every state; states hold queries and '
            'decrypted content. Do not observe states.\n${bad.join('\n')}',
      );
    });

    test('every freezed class under lib/features/messages opts out of the '
        'generated toString', () {
      final bad = <String>[
        for (final e in _handWrittenLib().entries)
          if (e.key.startsWith('lib/features/messages/'))
            for (final a in _freezedWithToString(e.value)) '${e.key}: $a',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'Use @Freezed(toStringOverride: false): a generated toString '
            'prints every field (a query, a preview, a hit).\n'
            '${bad.join('\n')}',
      );
    });

    test('MessageSearchState opts out of the generated toString, and its '
        'freezed file declares none (it printed the typed query)', () {
      expect(
        codeMatches(_libFiles()[_searchStateFile]!, _freezedOptOut),
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

    test('SearchQuery.toString prints no query text', () {
      expect(
        toStringDeclarations(_libFiles()[_searchQueryFile]!),
        {'SearchQuery': _searchQueryToString},
        reason:
            'The global search query is what the user typed; its toString '
            'prints the kind and the issue only.',
      );
    });

    test('self-test: a generated or hand-written toString is seen; a '
        'comment, a string or a call is not; a freezed class without the '
        'opt-out is seen', () {
      for (final bad in [
        '@override\nString toString() {\n  return '
            "'MessageSearchState(query: \$query)';\n}",
        "@override\nString toString() => 'MessageSearchState(\$query)';",
        'String  toString ()=> x;',
        "toString() => 'no return type \$query';",
        'String? toString() => query;',
      ]) {
        expect(_toStringDecls(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '// String toString() => query;',
        "final s = 'String toString()';",
        'final t = state.toString();',
        'return toString();',
      ]) {
        expect(_toStringDecls(ok), isEmpty, reason: ok);
      }
      for (final bad in [
        '@freezed\nabstract class S {}',
        '@Freezed()\nabstract class S {}',
        '@Freezed(copyWith: false)\nabstract class S {}',
        '@Freezed(toStringOverride: true)\nabstract class S {}',
        '@unfreezed\nabstract class S {}', // SA R5
      ]) {
        expect(_freezedWithToString(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '@Freezed(toStringOverride: false)\nabstract class S {}',
        '@Freezed(copyWith: false, toStringOverride: false)\nclass S {}',
        '// @freezed',
      ]) {
        expect(_freezedWithToString(ok), isEmpty, reason: ok);
      }
      // A SearchQuery body that prints the query is not the pinned one.
      expect(
        toStringDeclarations(
          "class SearchQuery {\n  @override\n  String toString() => "
          "'SearchQuery(\$kind, \"\$body\", \$issue)';\n}",
        )['SearchQuery'],
        isNot(_searchQueryToString),
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

    test('no file importing messaging.pb writes text or a snippet into a '
        'message, rebuilds one or decodes one, but the pinned data layer', () {
      final found = <String, List<String>>{
        for (final e in _handWrittenLib().entries)
          if (pbMutations(e.value).isNotEmpty) e.key: pbMutations(e.value),
      };
      expect(
        found,
        _pinnedPbMutations,
        reason:
            'Decrypted text must never be written into a messaging proto '
            '(it would reach the cache or a request).',
      );
    });

    test('no file under lib/features/messages writes a preview field '
        '(snippet, lastMessage), whatever it imports, but the pinned ones', () {
      final found = <String, List<String>>{
        for (final e in _handWrittenLib().entries)
          if (e.key.startsWith('lib/features/messages/') &&
              pbNameMutations(e.value).isNotEmpty)
            e.key: pbNameMutations(e.value),
      };
      expect(found, _pinnedPbNameMutations);
    });

    test('no record typedef in the pipeline has a field named like content, '
        'an id or a key (a record prints every field)', () {
      final bad = <String>[
        for (final e in _pipelineFiles().entries)
          for (final f in recordFieldViolations(e.value)) '${e.key}: $f',
      ];
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('self-test: preview writes without the import and text-named record '
        'fields are flagged', () {
      for (final bad in [
        'row.lastMessage.deepCopy()..snippet = decrypted;',
        'c.lastMessage = preview;',
        'c..lastMessage = p;',
        'p.snippet = hit.text;',
        'Preview(snippet: hit.text);',
      ]) {
        expect(pbNameMutations(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        "Preview(snippet: '');",
        '// p.snippet = x;',
        'final same = p.snippet == other;',
        'final s = p.lastMessage.snippet;',
      ]) {
        expect(pbNameMutations(ok), isEmpty, reason: ok);
      }
      for (final bad in [
        'typedef _Row = ({String text, int at});',
        'typedef _Pair = (Uint8List plaintext, int n);',
        'typedef F = Future<({String conversationId})?> Function(int a);',
        'typedef _K = ({Uint8List reportKey});',
      ]) {
        expect(recordFieldViolations(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        'typedef _Fail = ({_FailKind kind, int stamp});',
        'typedef _TokenSave = ({String token, String expect});',
        'typedef F = void Function(GroupState state, String text);',
        'typedef _Op = PipelineOp;',
        '// typedef _Row = ({String text});',
      ]) {
        expect(recordFieldViolations(ok), isEmpty, reason: ok);
      }
    });

    test('self-test: observers, constructions and mutations are flagged', () {
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
      final exempt = _messageConstructionExempt.values.first;
      for (final bad in [
        '${imp}final m = pb.Message(text: hit.text);',
        '${imp}final m = pb.Message()..text = t;',
        '${imp}final m = pb.Message.create();',
        "import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart'"
            ' as wire;\nfinal m = wire.Message(id: i);',
        "import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart';"
            '\nfinal m = Message(id: i);',
        // The exemption covers the id-only form only, never a cascade.
        '${imp}pb.Message(id: entry.messageId, '
            'conversationId: entry.conversation.id, text: hit.text)',
        '${imp}final m = pb.Message(id: entry.messageId, '
            'conversationId: entry.conversation.id,)..text = hit.text;',
      ]) {
        expect(
          messageConstructions(bad, exemptSnippets: exempt),
          isNotEmpty,
          reason: bad,
        );
      }
      for (final ok in [
        '${imp}final p = pb.MessagePreview(encrypted: true);',
        '$imp// pb.Message(text: t)',
        'final m = Message(id: i);', // not the messaging proto
        '${imp}List<pb.Message> list = [];',
        '${imp}f(message: pb.Message(\n  id: entry.messageId,\n'
            '  conversationId: entry.conversation.id,\n), x: 1)',
      ]) {
        expect(
          messageConstructions(ok, exemptSnippets: exempt),
          isEmpty,
          reason: ok,
        );
      }
      for (final bad in [
        '${imp}m.text = decrypted;',
        '${imp}final c = m.deepCopy()..text = decrypted;',
        '${imp}row.lastMessage.deepCopy()..snippet = decrypted;',
        '${imp}p.snippet = hit.text;',
        "${imp}pb.MessagePreview(snippet: hit.text);",
        "${imp}pb.MessagePreview(snippet: 'x');",
        '${imp}final n = m.rebuild((b) => b.text = t);',
        '${imp}final m = pb.Message.fromBuffer(bytes);',
        '${imp}final m = pb.Message.fromJson(json);',
      ]) {
        expect(pbMutations(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        "${imp}const X({super.key, this.text = 'x'});",
        "${imp}pb.MessagePreview(snippet: '');",
        "${imp}final same = m.text == other;",
        '$imp// m.text = x;',
        'm.text = decrypted;', // not a file importing messaging.pb
      ]) {
        expect(pbMutations(ok), isEmpty, reason: ok);
      }
    });
  });
}
