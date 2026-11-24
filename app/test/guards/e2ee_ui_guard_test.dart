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
/// - `resetByUser` referenced as a MEMBER only by the reset screen:
///   `vault_guard_test.dart`. (The independent count of every bare mention is
///   here.)
/// - `toString` anywhere under `domain/e2ee/` (the port file included) and on
///   the port's types: `vault_guard_test.dart`.
///
/// Known gaps of every scan here (all are lexical, none is a type check):
/// - Aliasing: a value copied to a local under another name first
///   (`final s = draftText; log.info(s)`), or carried in a record or a list,
///   is not followed; only names written in the call's own arguments count.
/// - A call through a receiver the patterns do not know (a logger or a
///   navigator held in a field with an unusual name, `widget.router.go(`) or
///   through a helper that wraps the sink is not seen.
/// - `_declaresTest` matches a test that is present but skipped
///   (`skip: true`) or commented out; it proves the name exists, not that the
///   test runs or still asserts inertness.
/// - Identifiers starting with an upper-case letter (types, enum names) are
///   not judged by the name rules: they name a class, not a value.
/// - String concatenation in an error message (`'bad ' + text`) and a
///   variable as the whole message (`StateError(text)`) are not seen by the
///   interpolation scan (the reporter rule does catch a non-literal
///   `StateError(...)` that is handed to a reporter).
/// - Pins are by file and count, not by which call sits in the `try`: a pinned
///   raw forward can move to a different call in the same file unnoticed.
///
/// Run from app/ (like the other guards).

const String _port =
    'lib/features/messages/domain/e2ee/encrypted_messaging.dart';
const String _device =
    'lib/features/messages/domain/e2ee/encryption_device.dart';
const String _presentationE2ee = 'lib/features/messages/presentation/e2ee/';
const String _messagesPresentation = 'lib/features/messages/presentation/';
const String _statusFile =
    'lib/features/messages/presentation/e2ee/encryption_status.dart';
const String _settingsPresentation = 'lib/features/settings/presentation/';
const String _ownDeviceRow =
    'lib/features/settings/presentation/widgets/own_device_row.dart';
const String _messageSearchState =
    'lib/features/messages/presentation/bloc/message_search_state.dart';
const String _messageSearch =
    'lib/features/messages/domain/message_search.dart';
const String _outbox = 'lib/features/messages/data/message_outbox.dart';
const String _resetScreen =
    'lib/features/settings/presentation/reset_encryption_screen.dart';

/// The moderation files that carry an encrypted message's report.
const Set<String> _moderationFiles = {
  'lib/features/moderation/presentation/report_sheet.dart',
  'lib/features/moderation/presentation/bloc/report_cubit.dart',
};

/// The cubits that handle decrypted content on the thread, inbox and search
/// screens (named so the inventory test can see them).
const Set<String> _contentCubits = {
  'lib/features/messages/presentation/bloc/thread_cubit.dart',
  'lib/features/messages/presentation/bloc/message_composer_cubit.dart',
  'lib/features/messages/presentation/bloc/conversations_cubit.dart',
  'lib/features/messages/presentation/bloc/message_search_cubit.dart',
};

Map<String, String> _lib() => handWrittenLib();

bool _isSettingsEncryption(String path) =>
    path.startsWith(_settingsPresentation) &&
    (path.split('/').last.contains('encryption') || path == _ownDeviceRow);

/// The encrypted screens (strict rules: no freezed part at all): everything
/// under presentation/e2ee/ and the Settings files for encryption.
bool _isScreenFile(String path) =>
    path.startsWith(_presentationE2ee) || _isSettingsEncryption(path);

/// The wide scope of the content rules (logging, URL, reporter, bans):
/// every file under lib/features/messages/presentation/, the Settings files
/// that touch encryption, the report sheet and cubit, and the search domain.
bool _inWideScope(String path) =>
    path.startsWith(_messagesPresentation) ||
    _isSettingsEncryption(path) ||
    _moderationFiles.contains(path) ||
    path == _messageSearch;

Map<String, String> _screens() => {
  for (final e in _lib().entries)
    if (_isScreenFile(e.key)) e.key: e.value,
};

Map<String, String> _wide() => {
  for (final e in _lib().entries)
    if (_inWideScope(e.key)) e.key: e.value,
};

/// The wide scope plus the plaintext outbox (the toString rule).
Map<String, String> _printScope() => {..._wide(), _outbox: _lib()[_outbox]!};

/// The wide scope plus the port file and the device facts (their imports are
/// pinned too).
Map<String, String> _importScope() => {
  ..._wide(),
  for (final p in [_port, _device]) p: _lib()[p]!,
};

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

// ---------------------------------------------------------------------------
// No printable content.

final RegExp _freezedPart = RegExp(
  r'''^\s*part\s+['"][^'"]*\.freezed\.dart['"]''',
  multiLine: true,
);

List<String> _freezedParts(String source) => [
  for (final m in _freezedPart.allMatches(
    stripSource(source, keepStrings: true),
  ))
    'freezed: ${m.group(0)!.trim()}',
];

/// A `toString` declaration or a `part '*.freezed.dart'` in [source] (the
/// strict rule for the encrypted screens).
List<String> _printableViolations(String source) => [
  ...codeMatches(source, toStringDeclaration).map((m) => 'toString: $m'),
  ..._freezedParts(source),
];

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

/// The one `toString` the wider scope accepts: two integer offsets, no text.
const Map<String, Map<String, String>> _pinnedToStrings = {
  _messageSearch: {'SearchRange': r"=> 'SearchRange($start, $end)';"},
};

/// Findings for one file of [_printScope]: any `toString` (but the pinned
/// ones, exactly), and a freezed annotation that keeps the generated one.
List<String> _printScopeViolations(String path, String source) {
  final pin = _pinnedToStrings[path];
  final decls = codeMatches(source, toStringDeclaration);
  return [
    if (pin == null)
      for (final d in decls) 'toString: $d'
    else ...[
      if (decls.length != pin.length) 'toString count differs from the pin',
      if (!_sameMap(toStringDeclarations(source), pin))
        'toString body differs from the pin',
    ],
    for (final a in _freezedWithToString(source)) 'keeps toString: $a',
  ];
}

bool _sameMap(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// The decrypted-hit types, which no state or search-domain file may name
/// (security read M7): a freezed state would carry them to a log.
final RegExp _encryptedHitNames = RegExp(
  r'(?<![\w$])(?:EncryptedSearchHit|EncryptedHitGroups?|DecryptedMessage)\b',
);

/// Cheap bans in the wide scope: nothing that prints a widget's fields,
/// restores typed text across launches, or persists a field's value.
/// The one accepted use, by file and count: the thread's route `Page`
/// forwards Flutter's own `Page.restorationId` constructor parameter
/// (`super.restorationId`); it names no field and holds no value.
const Map<String, Map<String, int>> _pinnedBannedApis = {
  'lib/features/messages/presentation/thread_route_page.dart': {
    'restorationId': 1,
  },
};

final RegExp _bannedApis = RegExp(
  r'(?<![\w$])(?:debugFillProperties|toStringShort|toDiagnosticsNode'
  r'|restorationScopeId|restorationId|Restorable\w*|RestorationMixin)\b',
);

/// `restorationScopeId` anywhere in hand-written lib/ (it restores the whole
/// app's state, typed text included, so it is not scoped to the screens).
final RegExp _restorationScope = RegExp(
  r'(?<![\w$])restorationScopeId(?![\w$])',
);

// ---------------------------------------------------------------------------
// Clipboard and selection on the code screen.

/// The security code is compared by eye on two devices. A copied code invites
/// pasting it into the very chat being verified, so the encrypted screens
/// never touch the clipboard (any mention of `Clipboard`, `ClipboardData`,
/// ...), and the panel keeps its selection off. The name-based
/// `Clipboard.setData` rule below covers the rest of the messages screens.
const String _securityPanel =
    'lib/features/messages/presentation/e2ee/conversation_encryption_panel.dart';

List<String> _clipboardMentions(String source) =>
    codeMatches(source, RegExp(r'(?<![\w$])Clipboard\w*'));

bool _selectionDisabled(String source) => codeMatches(
  source,
  RegExp(r'(?<![\w$])SelectionContainer\s*\.\s*disabled\s*\('),
).isNotEmpty;

// ---------------------------------------------------------------------------
// No crypto in the screens.

bool _cryptoTarget(String t) =>
    t.startsWith('lib/core/crypto/') ||
    t.endsWith('/secure_vault.dart') ||
    t.endsWith('/vault_records.dart') ||
    t.endsWith('/keys_repository.dart') ||
    t.endsWith('/device_keys_service.dart');

const String _deviceKeysService =
    'lib/features/keys/domain/device_keys_service.dart';

/// The two files that may import the keys feature's status types, each with
/// the one target it may reach.
const Map<String, String> _statusTypeImporters = {
  _device: _deviceKeysService,
  _statusFile: _deviceKeysService,
};

/// The status types the two files may take from that library.
const Set<String> _statusTypes = {'DeviceKeysPhase', 'DeviceKeysStatus'};

List<String> _cryptoImportViolations(String path, String source) => [
  for (final t in importTargets(path, source))
    if (_cryptoTarget(t) && _statusTypeImporters[path] != t) t,
];

/// For a file that may import `device_keys_service.dart`: with [showOnly] the
/// import must carry a `show` clause naming [_statusTypes] only.
List<String> _statusImportViolations(String source, {required bool showOnly}) {
  final bad = <String>[];
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

/// The public top-level names a Dart library declares (types, typedefs,
/// consts, finals, functions; `_private` ones excluded) in the concatenated
/// [sources] of the library file and its part files.
Set<String> _publicTopLevelNames(Iterable<String> sources) {
  final names = <String>{};
  for (final source in sources) {
    final code = stripSource(source, keepStrings: false);
    final top = StringBuffer();
    var depth = 0;
    for (final c in code.split('')) {
      if (c == '(' || c == '{' || c == '[') {
        if (depth == 0) top.write(c);
        depth++;
      } else if (c == ')' || c == '}' || c == ']') {
        if (depth > 0) depth--;
        if (depth == 0) top.write(c);
      } else if (depth == 0) {
        top.write(c);
      }
    }
    final flat = top.toString();
    for (final m in RegExp(
      r'\b(?:class|enum|mixin|typedef|extension\s+type)\s+([A-Za-z]\w*)',
    ).allMatches(flat)) {
      names.add(m.group(1)!);
    }
    for (final m in RegExp(
      r'\b(?:const|final|var)\s+(?:[\w<>?,.]+\s+)?([A-Za-z]\w*)\s*=',
    ).allMatches(flat)) {
      names.add(m.group(1)!);
    }
    for (final m in RegExp(
      r'(?:^|[;}])\s*(?:@\w+\s*)*(?:[\w<>?,.]+\s+)+([a-z]\w*)\s*\(\)',
    ).allMatches(flat)) {
      names.add(m.group(1)!);
    }
  }
  return names;
}

/// The library file's source and the sources of its `part` files.
List<String> _librarySources(String path) {
  final src = _lib()[path]!;
  return [
    src,
    for (final m in RegExp(
      r'''\bpart\s+['"]([^'"]+)['"]\s*;''',
    ).allMatches(stripSource(src, keepStrings: true)))
      if (_lib()[Uri.parse(path).resolve(m.group(1)!).path] != null)
        _lib()[Uri.parse(path).resolve(m.group(1)!).path]!,
  ];
}

/// Names of `device_keys_service.dart` that [source] mentions, other than the
/// status types: the device facts take the status types only.
List<String> _serviceNamesIn(String source, Set<String> serviceNames) => [
  for (final n in serviceNames)
    if (!_statusTypes.contains(n) &&
        codeMatches(
          source,
          RegExp('(?<![\\w\$.])${RegExp.escape(n)}(?![\\w\$])'),
        ).isNotEmpty)
      n,
];

// ---------------------------------------------------------------------------
// Name rules: what a log line or a URL may never carry.

/// Whole name segments (camelCase and `_` split, lower case) that hold what
/// the user typed or what was decrypted.
const Set<String> _logSegments = {
  'text',
  'digits',
  'code',
  'preview',
  'query',
  'payload',
  'ref',
  // Review round 3 (security L3): the holders of those, by their usual names.
  'groups',
  'snippet',
  'body',
  'caption',
  'draft',
  'hit',
  'hits',
  'entry',
  'entries',
  'note',
};

/// The subset a URL, a route's `extra` or a `Uri` may never carry (the
/// thread's own conversation id is a path part and so is not on this list).
const Set<String> _urlSegments = {
  'text',
  'digits',
  'preview',
  'payload',
  'ref',
  'query',
  'code',
  // The log set also lists groups, snippet, body, caption, draft, hit(s),
  // entry/entries and note; the URL set does not: `hit.message.id` is a
  // search hit opened by message id (`queryParameters: {'m': ...}` in
  // conversations_screen.dart), an id and not content.
};

/// An identifier split into lower-case segments: `draftText` -> draft, text;
/// `conversation_id` -> conversation, id; `conversationID` -> conversation,
/// id; `context` -> context.
List<String> _segments(String id) => [
  for (final m in RegExp(
    r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+',
  ).allMatches(id.replaceAll('_', ' ')))
    m.group(0)!.toLowerCase(),
];

/// Reads of an exception's status code (`e.code`, `error.code`, `err.code`,
/// `ex.code`): the transport's own small code, never user text or a security
/// code. These exact receivers are exempt; `securityCode`, `hit.code` and
/// every other `code` are not.
final RegExp _exceptionCode = RegExp(
  r'(?<![\w$.])(?:e|ex|err|error|exception)\s*\.\s*code(?![\w$])',
);

/// A leading `label:` of each argument (`text: x`, `queryParameters: {...}`):
/// a parameter name, not a value.
final RegExp _argumentLabel = RegExp(
  r'(^|[(,{])(\s*)[A-Za-z_$][\w$]*\s*:(?!:)',
);

/// Identifiers in [arg] (string text dropped, interpolated code kept, labels
/// and `e.code` removed) that hold content by [segments]; with [pairs] also
/// `conversation`+`id` and `message`+`id`. Upper-case-initial identifiers
/// (types) are not judged.
List<String> _namedIn(
  String arg,
  Set<String> segments, {
  bool pairs = false,
  bool stripped = false,
}) {
  final text = (stripped ? arg : stripSource(arg, keepStrings: false))
      .replaceAll(_exceptionCode, ' ')
      .replaceAllMapped(_argumentLabel, (m) => '${m.group(1)}${m.group(2)}');
  final found = <String>[];
  for (final m in RegExp(r'[A-Za-z_$][\w$]*').allMatches(text)) {
    final id = m.group(0)!;
    final bare = id.replaceFirst(RegExp(r'^[_$]+'), '');
    if (bare.isEmpty || RegExp(r'^[A-Z]').hasMatch(bare)) continue;
    // `statusCode` / `errorCode` are the transport's own small numbers (an
    // HTTP or Connect status), never the user's security code. Exact names.
    if (bare == 'statusCode' || bare == 'errorCode') continue;
    final parts = _segments(bare);
    var hit = parts.any(segments.contains);
    if (pairs) {
      for (var i = 0; i + 1 < parts.length; i++) {
        if (parts[i + 1] == 'id' &&
            (parts[i] == 'conversation' || parts[i] == 'message')) {
          hit = true;
        }
      }
    }
    if (hit) found.add(id);
  }
  return found;
}

// ---------------------------------------------------------------------------
// No logging of content.

/// Sinks the shared discovery of `vault_scan.dart` does not know: `Logger(`
/// itself, `debugPrintStack`, `stderr` / `stdout` writes, a local reporter
/// alias (`report(`, `report?.call(`, `reporter(`) and `Clipboard.setData`
/// (a copy of the user's own text is allowed later, a copy of a name that
/// holds content is judged by the same name rule).
final RegExp _extraSinkCallee = RegExp(
  r'(?<![\w$.])(?:Logger|debugPrintStack|debugPrintThrottled)\s*\('
  r'|(?<![\w$])(?:stderr|stdout)\s*\.\s*\w+\s*\('
  r'|(?<![\w$.])(?:report|reporter)\s*[?!]?\s*(?:\.\s*call\s*)?\('
  r'|(?<![\w$.])Clipboard\s*\.\s*setData\s*\(',
);

/// Findings: a sink call (the shared `sinkCalls` discovery of
/// `vault_scan.dart` plus [_extraSinkCallee]) whose arguments name content.
List<String> _loggingViolations(String source) {
  return [
    for (final c in sinkCalls(source))
      for (final n in _namedIn(
        c.args,
        _logSegments,
        pairs: true,
        stripped: true,
      ))
        '${c.call} ... $n',
    for (final args in callArguments(source, _extraSinkCallee))
      for (final a in args)
        for (final n in _namedIn(a, _logSegments, pairs: true))
          'extra sink ... $n in ${_oneLine(a)}',
  ];
}

// ---------------------------------------------------------------------------
// Fixed errors after a port call.

/// The names in [source] typed `UnexpectedErrorReporter` (a field, a
/// parameter, a local: `UnexpectedErrorReporter? report`) or bound from the
/// provider (`final r = context.read<UnexpectedErrorReporter?>()`), found the
/// way the logger-variable discovery finds loggers. A callback that merely
/// happens to be called `report` (the bubble's `onReport`, typed otherwise) is
/// not one.
Set<String> _reporterNames(String source) {
  final text = stripSource(source, keepStrings: false);
  return {
    for (final m in RegExp(
      r'(?<![\w$.])UnexpectedErrorReporter\??\s+([A-Za-z_$][\w$]*)',
    ).allMatches(text))
      m.group(1)!,
    for (final m in RegExp(
      r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*=\s*context\s*\.\s*read\s*'
      r'<\s*UnexpectedErrorReporter\b',
    ).allMatches(text))
      m.group(1)!,
  };
}

/// A call of an unexpected-error reporter in a file whose typed reporter
/// names are [typed]: the injected `onUnexpectedError` (also
/// `_onUnexpectedError?.call(`), `reportUnexpectedError(`, any typed name or
/// `reporter`, bare or `.call(` (no receiver: `_repository.report(` is
/// another method), and `context.read<UnexpectedErrorReporter?>()?.call(`.
RegExp _reporterCalleeFor(Set<String> typed) {
  final alt = {...typed, 'reporter'}.map(RegExp.escape).join('|');
  return RegExp(
    r'(?<![\w$])(?:_?onUnexpectedError|reportUnexpectedError)'
    r'\s*[?!]?\s*(?:\.\s*call\s*)?\('
    '|(?<![\\w\$.])(?:$alt)\\s*[?!]?\\s*(?:\\.\\s*call\\s*)?\\('
    r'|(?<![\w$.])context\s*\.\s*read\s*<\s*UnexpectedErrorReporter\??\s*>'
    r'\s*\(\s*\)\s*[?!]?\s*(?:\.\s*call\s*)?\(',
  );
}

/// Where a reporter name may appear as a VALUE (not called): the only value
/// form accepted everywhere is `onUnexpectedError: <name>` (also
/// `widget.<name>`), a constructor's `this.<name>` and a private field
/// initializer (`_x = name`). Anything else (`onError: report`,
/// `value: reporter`) hands the reporter to code that is not judged here and
/// is flagged, to be pinned by file with a reason.
List<String> _reporterValueUses(String source) {
  var text = stripSource(source, keepStrings: false);
  // An enum's members are names, not values (`enum _Menu { block, report }`).
  text = text.replaceAll(RegExp(r'\benum\s+\w+[^{]*\{[^}]*\}'), ' ');
  final names = {
    ..._reporterNames(source),
    'reporter',
    'onUnexpectedError',
    '_onUnexpectedError',
  };
  final alt = names.map(RegExp.escape).join('|');
  final found = <String>[];
  for (final m in RegExp(
    '(?<![\\w\$.])(?:(?:widget|this)\\s*\\.\\s*)?($alt)(?![\\w\$])',
  ).allMatches(text)) {
    final after = text.substring(m.end);
    if (RegExp(r'^\s*[?!]?\s*(?:\.\s*call\s*)?\(').hasMatch(after)) continue;
    if (RegExp(r'^\s*=(?![=>])').hasMatch(after)) continue; // assigned to
    if (RegExp(r'^\s*:(?!:)').hasMatch(after)) continue; // an argument label
    final before = text.substring(0, m.start).trimRight();
    if (!RegExp(r'(?:[(,\[:=]|=>|\breturn)$').hasMatch(before)) continue;
    if (RegExp(r'\bonUnexpectedError\s*:$').hasMatch(before)) continue;
    if (m.group(0)!.startsWith('this')) continue; // constructor parameter
    if (RegExp(r'(?<![\w$.])_\w+\s*=$').hasMatch(before) &&
        RegExp(r'^\s*[,;{)]').hasMatch(after)) {
      continue; // `_onUnexpectedError = onUnexpectedError,`
    }
    found.add(m.group(1)!);
  }
  return found;
}

/// The only first argument a reporter takes: `StateError('<literal>')`, no
/// `$` and no concatenation.
final RegExp _fixedStateError = RegExp(
  r'''^(?:const\s+)?StateError\(\s*(?:'[^'$\\]*'|"[^"$\\]*")\s*,?\s*\)$''',
);

/// First arguments of reporter calls that are not a fixed `StateError`.
List<String> _reporterViolations(String source) => [
  for (final args in callArguments(
    source,
    _reporterCalleeFor(_reporterNames(source)),
  ))
    if (args.isEmpty)
      '(none)'
    else if (!_fixedStateError.hasMatch(_oneLine(args.first)))
      _oneLine(args.first),
];

/// Reporter forwards that are not a fixed `StateError`, accepted by file with
/// the first argument and its count. Most follow a call into the PLAINTEXT
/// cache or the plaintext repository; the forwarded object is the thrown
/// transport / cache exception (`error is UnknownApiException`, a drift or
/// disk error), not the decrypted body. Pinned so a new raw forward fails.
///
/// Not all of them stay clear of the encrypted port: the `on Object` forward
/// at `thread_cubit.dart:791` wraps `_apply` -> `_reevaluate`, which reaches
/// `port.hasLocal` and `port.watchThread`. That is safe today because both
/// calls take only the conversation id (nothing decrypted is passed in or
/// comes back through the thrown object).
///
/// TODO(e2ee-fixed-forwards): a lib follow-up turns the `on Object` forwards
/// into fixed `StateError('<step>')`; these pins then shrink to the
/// type-gated ones (`error is UnknownApiException`).
const Map<String, Map<String, int>> _pinnedRawReports = {
  // cachedThread / pollThread / sendMessage / noteSentRequestAnswered /
  // markRead ... (plaintext repository and cache); `on Object` and the
  // UnknownApiException guard.
  'lib/features/messages/presentation/bloc/thread_cubit.dart': {'error': 11},
  // sendMessage / outbox calls of the plaintext path.
  'lib/features/messages/presentation/bloc/message_composer_cubit.dart': {
    'error': 3,
  },
  // The cached search (plaintext cache) and the repository page fetch.
  'lib/features/messages/presentation/bloc/message_search_cubit.dart': {
    'error': 2,
  },
  // listConversations / cache reads; UnknownApiException guard.
  'lib/features/messages/presentation/bloc/conversations_cubit.dart': {
    'error': 4,
  },
  // sendMessage of the share flow (plaintext path), caught generically.
  'lib/features/messages/presentation/bloc/share_post_cubit.dart': {'error': 1},
  // searchPeople / listFollowing style repository calls (no message text).
  'lib/features/messages/presentation/bloc/recipient_picker_cubit.dart': {
    'error': 2,
  },
  // reportContent RPC; UnknownApiException guard.
  'lib/features/moderation/presentation/bloc/report_cubit.dart': {'error': 1},
  // `_report(String step, ...)`: every caller passes a literal step name
  // ('ownDevices', 'confirmItsYou', 'removeDevice', ...).
  'lib/features/settings/presentation/bloc/encryption_devices_cubit.dart': {
    'StateError(step)': 1,
  },
  // `report?.call(StateError(step), ...)` with a private literal step.
  'lib/features/messages/presentation/e2ee/connected_encryption_status_card.dart':
      {'StateError(step)': 1},
};

/// A reporter name handed on as a value (see [_reporterValueUses]), accepted
/// by file with the name and its count.
const Map<String, Map<String, int>> _pinnedReporterValues = {
  // `onError: report`: hands the reporter to the PLAINTEXT thread poller,
  // whose errors are the poll's transport / cache errors (it never sees the
  // encrypted port or a decrypted body).
  'lib/features/messages/presentation/thread_screen.dart': {'report': 1},
  // Re-provides the same reporter to the dialog route's RepositoryProvider (a
  // dialog is outside the caller's widget tree); the cubits that call it are
  // judged in their own files.
  'lib/features/messages/presentation/share_post_picker.dart': {'reporter': 1},
  // Handed to the screen's own `_confirm(report, ...)` (twice), which reports
  // only a fixed StateError('resetConfirm').
  'lib/features/settings/presentation/reset_encryption_screen.dart': {
    'report': 2,
  },
};

/// An `assert(` whose message (any argument after the first) interpolates.
List<String> _assertInterpolations(String source) => [
  for (final args in callArguments(source, RegExp(r'(?<![\w$.])assert\s*\(')))
    if (args.skip(1).any((a) => a.contains(r'$'))) _oneLine(args.join(', ')),
];

// ---------------------------------------------------------------------------
// Nothing in a URL.

/// A go_router navigation: `context.go(`, `router.push<T>(`,
/// `_router.pushReplacement(`, `GoRouter.of(context).go(`. Any other receiver
/// (`Navigator.of(context).push(`, `_undo.push(`) is not a URL.
final RegExp _navCallee = RegExp(
  r'(?<![\w$.])(?:context|_?router|GoRouter\s*\.\s*of\s*\([^()]*\))\s*[?!]?'
  r'\s*\.\s*(?:go|push|pushReplacement|replace|goNamed|pushNamed'
  r'|pushReplacementNamed|replaceNamed)\s*(?:<[^()]*?>)?\s*\(',
);

/// A `Uri` construction.
final RegExp _uriCallee = RegExp(r'(?<![\w$.])Uri\s*(?:\.\s*\w+\s*)?\(');

/// A route `extra` read (`GoRouterState.of(context).extra`, `state.extra`).
final RegExp _extraRead = RegExp(r'\.\s*extra(?![\w$])');

/// Findings: URL-name violations (a navigation or `Uri` argument naming
/// content) and `extra` uses (an `extra:` argument of a navigation call, a
/// `.extra` read), as separate lists.
({List<String> names, List<String> extras}) _urlFindings(String source) {
  final names = <String>[];
  final extras = <String>[];
  for (final callee in [_navCallee, _uriCallee]) {
    for (final args in callArguments(source, callee)) {
      for (final a in args) {
        for (final n in _namedIn(a, _urlSegments)) {
          names.add('$n in ${_oneLine(a)}');
        }
        if (callee == _navCallee && RegExp(r'^extra\s*:').hasMatch(a)) {
          extras.add('extra:');
        }
      }
    }
  }
  for (final _ in codeMatches(source, _extraRead)) {
    extras.add('.extra');
  }
  return (names: names, extras: extras);
}

/// The `extra:` uses accepted, by file and count: both pass a value that is
/// not message content (the peer's own snapshot object to a draft thread; a
/// `Folder` enum value for the requests list). The id-free uses the plan
/// knows about; a third use fails.
const Map<String, int> _pinnedExtras = {
  'lib/features/messages/presentation/open_conversation.dart': 2,
  'lib/features/messages/presentation/messages_list_detail.dart': 2,
};

// ---------------------------------------------------------------------------
// Dependencies and pinned tests.

/// Dependency names in a pubspec's dependency sections (a 2-space-indented
/// `name:` key under `dependencies`, `dev_dependencies` or
/// `dependency_overrides`) that name a QR, barcode or scanner package, or
/// Equatable (its `stringify` prints every field).
List<String> _bannedDependencies(String pubspec) {
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
        name.contains('scanner') ||
        name.contains('equatable')) {
      bad.add(m.group(1)!);
    }
  }
  return bad;
}

/// Whether [source] (a test file) declares `test(` / `testWidgets(` with the
/// literal name [name] (adjacent string pieces joined). A skipped or
/// commented-out test still matches (see the known gaps above).
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

/// Every bare mention of `resetByUser` in code (comments and string text
/// ignored), by file, outside lib/core/vault/.
Map<String, int> _resetByUserMentions(Map<String, String> lib) => {
  for (final e in lib.entries)
    if (!e.key.startsWith('lib/core/vault/'))
      if (RegExp(r'(?<![\w$])resetByUser(?![\w$])')
              .allMatches(stripSource(e.value, keepStrings: false))
              .length
          case final n when n > 0)
        e.key: n,
};

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
        _ownDeviceRow,
      ]),
    );
    final wide = _wide().keys.toSet();
    expect(
      wide,
      containsAll([
        ...screens,
        ..._contentCubits,
        ..._moderationFiles,
        _messageSearch,
        _messageSearchState,
        'lib/features/messages/presentation/widgets/message_search_panel.dart',
        'lib/features/messages/presentation/thread_screen.dart',
        'lib/features/messages/presentation/conversations_screen.dart',
        'lib/features/messages/presentation/draft_thread_screen.dart',
        'lib/features/messages/presentation/bloc/share_post_cubit.dart',
        'lib/features/messages/presentation/open_conversation.dart',
      ]),
    );
    // A scope that quietly shrank would pass every rule below.
    expect(wide.length, greaterThan(40));
    expect(_printScope().keys, contains(_outbox));
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
      expect(_freezedParts(_lib()[_port]!), isEmpty);
    });

    test('no toString in the messages presentation, the content cubits and '
        'their states, the report files or the outbox; no freezed state '
        'keeps its generated one; SearchRange is pinned', () {
      final bad = <String>[
        for (final e in _printScope().entries)
          for (final v in _printScopeViolations(e.key, e.value)) '${e.key}: $v',
        // The generated side of every freezed class in the scope.
        for (final e in libFiles().entries)
          if (e.key.endsWith('.freezed.dart') &&
              _printScope().containsKey(
                e.key.replaceFirst(RegExp(r'\.freezed\.dart$'), '.dart'),
              ))
            for (final d in codeMatches(e.value, toStringDeclaration))
              '${e.key}: generated toString: $d',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'A state, an outbox row or a search hit can hold a query or a '
            'decrypted text; its toString must not print it.\n'
            '${bad.join('\n')}',
      );
      expect(
        toStringDeclarations(_lib()[_messageSearch]!),
        _pinnedToStrings[_messageSearch],
      );
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

    test('nothing in the scope prints a widget, restores typed text or '
        'persists a field', () {
      final found = <String, Map<String, int>>{};
      for (final e in _printScope().entries) {
        final counts = <String, int>{};
        for (final m in codeMatches(e.value, _bannedApis)) {
          counts[m] = (counts[m] ?? 0) + 1;
        }
        if (counts.isNotEmpty) found[e.key] = counts;
      }
      expect(
        found,
        _pinnedBannedApis,
        reason:
            'debugFillProperties, toStringShort, toDiagnosticsNode and the '
            'restoration APIs print or persist a widget\'s fields. A use '
            'needs a reviewed reason: pin it by file and count in '
            '_pinnedBannedApis.',
      );
    });

    test('self-test: a planted toString, freezed part or hit field is seen; '
        'comments and strings are not', () {
      final real = _lib()[_resetScreen]!;
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
      expect(_freezedParts("part 'p.freezed.dart';"), isNotEmpty);

      // The wide rule: a toString on a cubit state, a freezed state that
      // keeps its toString, a changed SearchRange body.
      const cubit = 'lib/features/messages/presentation/bloc/thread_cubit.dart';
      expect(_printScopeViolations(cubit, _lib()[cubit]!), isEmpty);
      expect(
        _printScopeViolations(
          cubit,
          "${_lib()[cubit]!}\nclass S { @override String toString() => '\$text'; }",
        ),
        isNotEmpty,
      );
      expect(
        _printScopeViolations(_outbox, "class O { toString() => '\$text'; }"),
        isNotEmpty,
      );
      for (final bad in [
        '@freezed\nabstract class S {}',
        '@Freezed(copyWith: false)\nabstract class S {}',
        '@unfreezed\nabstract class S {}',
      ]) {
        expect(_printScopeViolations(cubit, bad), isNotEmpty, reason: bad);
      }
      expect(
        _printScopeViolations(
          cubit,
          '@Freezed(toStringOverride: false)\nabstract class S {}',
        ),
        isEmpty,
      );
      final range = _lib()[_messageSearch]!;
      expect(_printScopeViolations(_messageSearch, range), isEmpty);
      final changed = range.replaceFirst(
        r"=> 'SearchRange($start, $end)';",
        r"=> 'SearchRange($start, $end, $text)';",
      );
      expect(changed, isNot(range), reason: 'the plant found its anchor');
      expect(_printScopeViolations(_messageSearch, changed), isNotEmpty);
      expect(
        _printScopeViolations(
          _messageSearch,
          "$range\nclass Z { toString() => 'z'; }",
        ),
        isNotEmpty,
      );

      for (final bad in [
        'void debugFillProperties(DiagnosticPropertiesBuilder p) {}',
        "TextField(restorationId: 'draft');",
        'class S extends State<W> with RestorationMixin {}',
        'final c = RestorableTextEditingController();',
        "MaterialApp(restorationScopeId: 'app');",
      ]) {
        expect(codeMatches(bad, _bannedApis), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '// debugFillProperties',
        "final s = 'restorationId';",
      ]) {
        expect(codeMatches(ok, _bannedApis), isEmpty, reason: ok);
      }

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

  group('clipboard and selection on the encrypted screens', () {
    test('the encrypted screens and the Settings encryption files never '
        'mention the clipboard', () {
      final bad = <String>[
        for (final e in _screens().entries)
          for (final m in _clipboardMentions(e.value)) '${e.key}: $m',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'The security code is compared by eye; a copied code invites '
            'pasting it into the chat being verified. For a deliberate copy '
            'action elsewhere, ask for a security read, then pin it by file '
            'with the reason.\n${bad.join('\n')}',
      );
    });

    test('the code panel still disables selection', () {
      expect(
        _selectionDisabled(_lib()[_securityPanel]!),
        isTrue,
        reason:
            'conversation_encryption_panel.dart wraps the code grid in '
            'SelectionContainer.disabled so it cannot be selected and copied.',
      );
    });

    test('nothing in lib/ names restorationScopeId (it restores the whole '
        'app, typed text included)', () {
      final bad = <String>[
        for (final e in _lib().entries)
          for (final m in codeMatches(e.value, _restorationScope))
            '${e.key}: $m',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'restorationScopeId persists widget state across launches. If a '
            'screen needs it, ask for a security read and pin it by file.\n'
            '${bad.join('\n')}',
      );
    });

    test('self-test: a Clipboard mention, a removed SelectionContainer.'
        'disabled and a restorationScopeId are flagged', () {
      final screen = _lib()[_resetScreen]!;
      expect(_clipboardMentions(screen), isEmpty);
      for (final bad in [
        'Clipboard.setData(const ClipboardData(text: x));',
        'final d = await Clipboard.getData(Clipboard.kTextPlain);',
        'import "package:flutter/services.dart"; ClipboardData c;',
      ]) {
        expect(_clipboardMentions('$screen\n$bad'), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '// Clipboard.setData(x);',
        "final s = 'Clipboard';",
        'final myClipboardless = 1;',
      ]) {
        expect(_clipboardMentions(ok), isEmpty, reason: ok);
      }
      final panel = _lib()[_securityPanel]!;
      expect(_selectionDisabled(panel), isTrue);
      final removed = panel.replaceAll(
        'SelectionContainer.disabled(',
        'SelectionContainer(',
      );
      expect(removed, isNot(panel), reason: 'the plant found its anchor');
      expect(_selectionDisabled(removed), isFalse);
      expect(
        _selectionDisabled('// SelectionContainer.disabled(child: x)'),
        isFalse,
      );
      expect(
        codeMatches(
          "MaterialApp(restorationScopeId: 'app');",
          _restorationScope,
        ),
        isNotEmpty,
      );
      expect(
        codeMatches(
          "// restorationScopeId\nfinal s = 'restorationScopeId';",
          _restorationScope,
        ),
        isEmpty,
      );
      for (final bad in [
        'final s = widget.toStringShort();',
        'final n = x.toDiagnosticsNode();',
      ]) {
        expect(codeMatches(bad, _bannedApis), isNotEmpty, reason: bad);
      }
    });
  });

  group('no crypto in the screens', () {
    test('the screens, cubits, search files, port file and device facts '
        'import nothing from core/crypto, the vault records, the keys '
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
        'types only; the device facts name no other public name of the '
        'device-keys library', () {
      for (final e in _statusTypeImporters.entries) {
        expect(
          importTargets(e.key, _lib()[e.key]!),
          contains(e.value),
          reason: '${e.key}: the pin is stale, remove it',
        );
      }
      expect(
        _statusImportViolations(_lib()[_statusFile]!, showOnly: true),
        isEmpty,
      );
      final serviceNames = _publicTopLevelNames(
        _librarySources(_deviceKeysService),
      );
      expect(
        serviceNames,
        containsAll([
          'DeviceKeysService',
          'DeviceKeysError',
          'DeviceKeysPhase',
          'DeviceKeysStatus',
          'kDeviceKeysRunInterval',
          'deviceKeysForegroundFromBinding',
        ]),
        reason: 'the declaration reader still sees the library',
      );
      for (final p in [_device, _statusFile]) {
        expect(
          _serviceNamesIn(_lib()[p]!, serviceNames),
          isEmpty,
          reason:
              '$p may name the status types only; anything else from '
              'device_keys_service.dart is the service itself.',
        );
      }
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
      const imp =
          "import '../../../keys/domain/device_keys_service.dart' "
          'show DeviceKeysPhase;';
      expect(_cryptoImportViolations(_statusFile, imp), isEmpty);
      expect(_cryptoImportViolations(path, imp), isNotEmpty);
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

      // The names of the library, read from source, and a planted use.
      final names = _publicTopLevelNames([
        "const Duration kRun = Duration(days: 1);\n"
            "typedef Factory = Timer Function(Duration d, void Function() f);\n"
            "enum DeviceKeysPhase { idle }\n"
            "class DeviceKeysError implements Exception { final int a = 1; }\n"
            "class _Hidden {}\n"
            "bool deviceKeysForeground() { return true; }\n"
            "final int kLimit = 3;\n",
      ]);
      expect(names, {
        'kRun',
        'Factory',
        'DeviceKeysPhase',
        'DeviceKeysError',
        'deviceKeysForeground',
        'kLimit',
      });
      final device = _lib()[_device]!;
      final all = _publicTopLevelNames(_librarySources(_deviceKeysService));
      expect(_serviceNamesIn(device, all), isEmpty);
      expect(_serviceNamesIn('$device\nfinal e = DeviceKeysError(1);', all), [
        'DeviceKeysError',
      ]);
      expect(
        _serviceNamesIn('$device\nfinal d = kDeviceKeysRunInterval;', all),
        ['kDeviceKeysRunInterval'],
      );
      expect(
        _serviceNamesIn('$device\n// DeviceKeysError', all),
        isEmpty,
        reason: 'a comment names nothing',
      );
      expect(
        _serviceNamesIn('$device\nfinal s = DeviceKeysStatus.x;', all),
        isEmpty,
        reason: 'the status types are allowed',
      );
    });
  });

  group('no logging of content', () {
    test('no print, log, Logger, reporter or clipboard write in the wide '
        'scope names text, digits, code, preview, query, payload, ref, '
        'conversation id or message id (by name segment)', () {
      final bad = <String>[
        for (final e in _wide().entries)
          for (final v in _loggingViolations(e.value)) '${e.key}: $v',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'A log line, an error report or a copy must not carry decrypted '
            'text, a security code, a query or an id. For a deliberate copy '
            'action (the user copying their own message), ask for a '
            'security read, then pin it by file with the reason.\n'
            '${bad.join('\n')}',
      );
    });

    test('self-test: name segments are judged whole; `context` and an '
        'exception code are clean', () {
      for (final id in [
        'text',
        'draftText',
        'securityCode',
        'trimmedQuery',
        'queryText',
        'previewLine',
        'hit.messageId',
        'conversationId',
        'conversationID',
        'conversation_id',
        '_digits',
        'payload',
        'ref',
        'peerRef',
        'x.messageId',
        'myCode',
        // Review round 3 (security L3): the usual holders of content.
        'groups',
        'snippet',
        'bodyText',
        'body',
        'captionLine',
        'draft',
        'currentDraft',
        'hit',
        'hits',
        'hitList',
        'entry',
        'entries',
        'note',
        'noteBody',
      ]) {
        expect(
          _namedIn('f($id)', _logSegments, pairs: true),
          isNotEmpty,
          reason: id,
        );
      }
      for (final ok in [
        'context',
        'contextual',
        'textual',
        'codec',
        'e.code',
        'error.code',
        'err.code',
        'ex.code',
        'ThreadRef',
        'SecurityCode.none',
        'messages',
        'idle',
        'conversation',
        'message',
        'references',
        'encoded',
        // Exact transport numbers (item 9), and whole-segment matching.
        'statusCode',
        'errorCode',
        'x.statusCode',
        'notes',
        'notebook',
        'bodyguard',
        'entryway',
        'hitchhiker',
      ]) {
        expect(
          _namedIn('f($ok)', _logSegments, pairs: true),
          isEmpty,
          reason: ok,
        );
      }
      // The exemption is exact: only the exception receivers.
      expect(_namedIn('f(hit.code)', _logSegments), isNotEmpty);
      expect(_namedIn('f(e.code, securityCode)', _logSegments), [
        'securityCode',
      ]);
      // Labels are parameter names, not values.
      expect(_namedIn('f(text: 1, query: 2)', _logSegments), isEmpty);
      expect(_namedIn('f(label: draftText)', _logSegments), ['draftText']);
      // Strings are text, interpolations are code.
      expect(_namedIn("f('the text')", _logSegments), isEmpty);
      expect(_namedIn("f('x \$draftText')", _logSegments), ['draftText']);
    });

    test('self-test: each sink form is flagged; fixed strings, comments, '
        'declarations and unrelated calls are not', () {
      for (final sink in [
        'debugPrint(draftText);',
        'print(securityCode);',
        'log.info(trimmedQuery);',
        '_log.warning("x", queryText);',
        'logger.severe(widget.previewLine);',
        'reportUnexpectedError(e, st, hit.messageId);',
        "reportUnexpectedError(e, st, '\$draftText');",
        'Logger(draftText);',
        'log(draftText);',
        '_reportBug(s, draftText);',
        'onUnexpectedError?.call(e, draftText);',
        'appLog.fine("x \${state.draftText}");',
        // The shared sink discovery of vault_scan.dart (security M3).
        'developer.log(draftText);',
        'dev.log(draftText, name: "x");',
        "Logger('x').info(draftText);",
        'Logger.root.info(draftText);',
        "final audit = Logger('a');\naudit.fine(draftText);",
        "Logger notes = Logger('a');\nnotes.shout(securityCode);",
        'FlutterError.reportError(FlutterErrorDetails(exception: draftText));',
        'debugPrintStack(label: draftText);',
        'stderr.writeln(draftText);',
        'stdout.write(trimmedQuery);',
        'report(draftText);',
        'report?.call(draftText);',
        'Clipboard.setData(ClipboardData(text: previewLine));',
        'Clipboard.setData(ClipboardData(text: hit.text));',
        'unawaited(Clipboard.setData(ClipboardData(text: securityCode)));',
      ]) {
        expect(_loggingViolations(sink), isNotEmpty, reason: sink);
      }
      for (final ok in [
        "debugPrint('opened');",
        "log.info('step');",
        '// debugPrint(draftText);',
        'final s = draftText; use(s);',
        'Future<void> _report(String step) async {}',
        'void log(String text) {}',
        'dialog.show(draftText);',
        'reportUnexpectedError(e, st);',
        "print('the text field');",
        'log.severe(context);',
        'onUnexpectedError?.call(e.code, st);',
        "Clipboard.setData(const ClipboardData(text: 'fixed'));",
        'void report(String text) {}',
      ]) {
        expect(_loggingViolations(ok), isEmpty, reason: ok);
      }
      // Planted in a copy of a real screen.
      final real = _lib()[_resetScreen]!;
      expect(_loggingViolations(real), isEmpty);
      expect(
        _loggingViolations(
          '$real\nvoid f(String trimmedQuery) { print(trimmedQuery); }',
        ),
        isNotEmpty,
      );
    });
  });

  group('fixed errors after a port call', () {
    test('every unexpected-error report in the wide scope is a fixed '
        'StateError literal, but the pinned raw forwards', () {
      final found = <String, Map<String, int>>{};
      for (final e in _wide().entries) {
        final counts = <String, int>{};
        for (final v in _reporterViolations(e.value)) {
          counts[v] = (counts[v] ?? 0) + 1;
        }
        if (counts.isNotEmpty) found[e.key] = counts;
      }
      expect(
        found,
        _pinnedRawReports,
        reason:
            'A report names a step, never a message: the first argument is '
            "StateError('<literal>'). A raw forward (an `error` caught "
            'around a repository call) is pinned by file and count in '
            '_pinnedRawReports; a new one, or a changed count, needs a '
            'reviewed reason written next to the pin.',
      );
    });

    test('a reporter is handed on as a value only as onUnexpectedError: '
        '<name>, but the pinned uses', () {
      final found = <String, Map<String, int>>{};
      for (final e in _wide().entries) {
        final counts = <String, int>{};
        for (final v in _reporterValueUses(e.value)) {
          counts[v] = (counts[v] ?? 0) + 1;
        }
        if (counts.isNotEmpty) found[e.key] = counts;
      }
      expect(
        found,
        _pinnedReporterValues,
        reason:
            'A reporter passed on as a value reaches code this scan does not '
            'read (it may report a raw error). Pass it as '
            'onUnexpectedError: <name>, or pin the use by file and count in '
            '_pinnedReporterValues with a reviewed reason.',
      );
    });

    test('self-test: a reporter handed on as a value is flagged; calls, '
        'labels, declarations, enum members and initializers are not', () {
      const typed =
          'final report = context.read<UnexpectedErrorReporter?>();\n';
      for (final bad in [
        '${typed}Poller(onError: report);',
        '${typed}final alias = report;',
        '${typed}use(report, x);',
        '${typed}return report;',
        '${typed}RepositoryProvider.value(value: report);',
        'final reporter = r;\nProvider.value(value: reporter);',
        'final p = Poller(onError: onUnexpectedError);',
        'final p = Poller(onError: widget.onUnexpectedError);',
        'final f = _onUnexpectedError;',
        'void g(UnexpectedErrorReporter? report) { h(x, report); }',
      ]) {
        expect(_reporterValueUses(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        '${typed}Thing(onUnexpectedError: report);',
        '${typed}Thing(onUnexpectedError: widget.onUnexpectedError);',
        "${typed}report?.call(StateError('x'), s);",
        "${typed}report(StateError('x'), s);",
        'UnexpectedErrorReporter? onUnexpectedError;',
        'final void Function(Object e, StackTrace s)? onUnexpectedError;',
        'Foo(this.onUnexpectedError, {required this.other});',
        'Foo({this.onUnexpectedError});',
        'Foo(void Function(Object e, StackTrace s)? onUnexpectedError)\n'
            '    : _onUnexpectedError = onUnexpectedError,\n'
            '      _x = 1;',
        '${typed}final other = Foo(onUnexpectedError: report);',
        'enum _Menu { block, report, delete }\n$typed',
        'case _Menu.report:',
        '// Poller(onError: report);',
        "final s = 'onError: report';",
        'void f() { _repository.report(x); }',
      ]) {
        expect(_reporterValueUses(ok), isEmpty, reason: ok);
      }
      // A planted extra hand-off in a copy of the real thread screen.
      const screen = 'lib/features/messages/presentation/thread_screen.dart';
      final real = _lib()[screen]!;
      expect(_reporterValueUses(real), ['report']);
      final planted = real.replaceFirst(
        'onUnexpectedError: report,',
        'onUnexpectedError: report, extraHook: report,',
      );
      expect(planted, isNot(real), reason: 'the plant found its anchor');
      expect(_reporterValueUses(planted), ['report', 'report']);
    });

    test('no interpolation in a StateError, ArgumentError, other error '
        'constructor, throw or assert message in the wide scope', () {
      final bad = <String>[
        for (final e in _wide().entries)
          for (final v in [
            ...interpolatedErrorMessages(e.value),
            ..._assertInterpolations(e.value),
          ])
            '${e.key}: $v',
      ];
      expect(
        bad,
        isEmpty,
        reason:
            'An error message with `\$x` can carry a query or a text into a '
            'report.\n${bad.join('\n')}',
      );
    });

    test('self-test: a raw forward, a variable step, an interpolation and '
        'an assert message are flagged; a literal StateError is not', () {
      for (final bad in [
        'onUnexpectedError?.call(error, stack);',
        'onUnexpectedError?.call(e, st);',
        '_onUnexpectedError?.call(StateError(step), stack);',
        "onUnexpectedError?.call(StateError('x \$draftText'), stack);",
        "onUnexpectedError?.call(StateError('a' + draftText), stack);",
        "onUnexpectedError?.call(ArgumentError('x'), stack);",
        'onUnexpectedError?.call(error.toString(), stack);',
        'reportUnexpectedError(error, stack);',
        // A name typed UnexpectedErrorReporter, bare and `.call` (review
        // round 3): a field, a parameter, a local, a provider read.
        'UnexpectedErrorReporter? report;\nreport?.call(error, stack);',
        'UnexpectedErrorReporter? report;\nreport(error, stack);',
        'UnexpectedErrorReporter onError;\nonError(error, stack);',
        'final r = context.read<UnexpectedErrorReporter?>();\nr(e, st);',
        'final r = context.read<UnexpectedErrorReporter>();\nr.call(e, st);',
        'void f(UnexpectedErrorReporter? report) { report?.call(e, st); }',
        'reporter(error, stack);',
        'reporter.call(error, stack);',
        'context.read<UnexpectedErrorReporter?>()?.call(error, stack);',
        'context.read<UnexpectedErrorReporter>().call(error, stack);',
        'context.read<UnexpectedErrorReporter>()(error, stack);',
      ]) {
        expect(_reporterViolations(bad), isNotEmpty, reason: bad);
      }
      for (final ok in [
        "UnexpectedErrorReporter? report;\nreport?.call(StateError('x'), s);",
        "reporter.call(StateError('x'), stack);",
        "context.read<UnexpectedErrorReporter?>()?.call(StateError('x'), s);",
        // The bubble's `report` is typed by `onReport`, not as a reporter.
        'final report = data.reportable ? onReport : null;\n'
            'report(_globalRect(context));',
        'final r = _repository.report(idempotencyKey: key);',
      ]) {
        expect(_reporterViolations(ok), isEmpty, reason: ok);
      }
      expect(
        _reporterNames(
          'UnexpectedErrorReporter? a;\n'
          'final b = context.read<UnexpectedErrorReporter?>();\n'
          'final c = context.read<Other>();\n'
          'RepositoryProvider<UnexpectedErrorReporter>.value(value: d);',
        ),
        {'a', 'b'},
      );
      for (final ok in [
        "onUnexpectedError?.call(StateError('send'), stack);",
        "_onUnexpectedError?.call(StateError('retryOpen'), stack);",
        "reportUnexpectedError(StateError('x'), stack);",
        'void Function(Object e, StackTrace s)? onUnexpectedError;',
        'Future<void> report(Object error) async {}',
        'onUnexpectedError: report,',
        '// onUnexpectedError?.call(error, stack);',
        "onUnexpectedError?.call(\n  StateError(\n    'step',\n  ),\n  stack,\n);",
      ]) {
        expect(_reporterViolations(ok), isEmpty, reason: ok);
      }
      // Planted into a copy of a real cubit: one more raw forward.
      const cubit =
          'lib/features/messages/presentation/bloc/message_search_cubit.dart';
      final real = _lib()[cubit]!;
      expect(_reporterViolations(real), ['error', 'error']);
      expect(
        _reporterViolations(
          '$real\nvoid f(Object e, StackTrace s) { onUnexpectedError?.call(e, s); }',
        ),
        ['error', 'error', 'e'],
      );

      for (final bad in [
        r"throw StateError('bad $text');",
        r"final e = ArgumentError('bad $query');",
        r"throw ArgumentError.value(x, 'n', 'bad ${draftText}');",
        r"assert(ok, 'bad $draftText');",
        r"assert(ok, 'a' 'b $text');",
      ]) {
        expect(
          [...interpolatedErrorMessages(bad), ..._assertInterpolations(bad)],
          isNotEmpty,
          reason: bad,
        );
      }
      for (final ok in [
        "throw StateError('bad');",
        "assert(ok, 'fixed message');",
        r'assert(a == $x);',
        r"final s = '$text';",
        r"// throw StateError('$text');",
      ]) {
        expect(
          [...interpolatedErrorMessages(ok), ..._assertInterpolations(ok)],
          isEmpty,
          reason: ok,
        );
      }
    });
  });

  group('nothing in a URL', () {
    test('no go_router navigation or Uri in the wide scope takes text, '
        'digits, preview, payload, ref, query or code', () {
      final bad = <String>[
        for (final e in _wide().entries)
          for (final v in _urlFindings(e.value).names) '${e.key}: $v',
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

    test('route extra is used only where pinned (by file and count)', () {
      final found = <String, int>{
        for (final e in _wide().entries)
          if (_urlFindings(e.value).extras.isNotEmpty)
            e.key: _urlFindings(e.value).extras.length,
      };
      expect(
        found,
        _pinnedExtras,
        reason:
            'A route `extra` is an object the router keeps in memory and may '
            'serialize; the two known uses pass the peer snapshot and a '
            'folder enum. A new one needs a reviewed reason: pin it by file '
            'and count in _pinnedExtras.',
      );
    });

    test('self-test: each navigation form with each name, and a route '
        'extra, is flagged; constant paths and other receivers are not', () {
      for (final name in [..._urlSegments, 'draftText', 'trimmedQuery']) {
        for (final call in [
          'context.go($name);',
          "context.go('/x/\$$name');",
          'context.push<void>($name);',
          "unawaited(context.push('/x/\${hit.$name}'));",
          "await context.pushNamed('x', pathParameters: {'k': $name});",
          "context.pushReplacement(Uri(path: '/x', "
              "queryParameters: {'k': $name}).toString());",
          'GoRouter.of(context).go($name);',
          'router.push<void>($name);',
          '_router.pushReplacement($name);',
          "final u = Uri.parse('/x?q=\$$name');",
          'return Uri(path: $name);',
        ]) {
          expect(_urlFindings(call).names, isNotEmpty, reason: '$call ($name)');
        }
      }
      for (final bad in [
        'final e = GoRouterState.of(context).extra;',
        'final e = state.extra;',
      ]) {
        expect(_urlFindings(bad).extras, ['.extra'], reason: bad);
      }
      expect(_urlFindings("context.go('/x', extra: m);").extras, ['extra:']);
      expect(
        _urlFindings('GoRouter.of(context).pushReplacement<void>(l, extra: e);')
            .extras,
        ['extra:'],
      );
      for (final ok in [
        'context.push(AppRouter.encryptionSettingsPath);',
        'context.go(AppRouter.encryptionSettingsPath);',
        "unawaited(context.push('/settings/encryption'));",
        '// context.go(text);',
        "final s = 'context.go(text)';",
        'final extraLarge = 1;',
        'void go(String text) {}',
        'x.replaceAll(text, y);',
        // Other receivers: not the router.
        'Navigator.of(context).push(MaterialPageRoute(builder: (_) => X(text)));',
        '_undo.push(text);',
        'stack.push(draftText);',
        'Widget(extra: 1);',
        'final w = Row(extra: draftText);',
        'context.go(AppRouter.thread(conversationId));',
        "context.push('/m/\$conversationId');",
      ]) {
        final f = _urlFindings(ok);
        expect(f.names, isEmpty, reason: ok);
        expect(f.extras, isEmpty, reason: ok);
      }
      final real = _lib()[_resetScreen]!;
      expect(_urlFindings(real).names, isEmpty);
      expect(
        _urlFindings('$real\nvoid f(String text) { context.go(text); }').names,
        isNotEmpty,
      );
      const open = 'lib/features/messages/presentation/open_conversation.dart';
      expect(_urlFindings(_lib()[open]!).extras, ['extra:', 'extra:']);
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
        _declaresTest(
          "test('the fixed strings are verbatim', () {}, skip: true);",
          'the fixed strings are verbatim',
        ),
        isTrue,
        reason: 'known gap: a skipped test still matches',
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
    test('pubspec.yaml has no qr, barcode, scanner or equatable package', () {
      expect(
        _bannedDependencies(_read('pubspec.yaml')),
        isEmpty,
        reason:
            'The security code is compared by eye (Plan 5b); no camera or '
            'QR dependency. Equatable prints every field with stringify.',
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
        'equatable',
      ]) {
        final planted = real.replaceFirst(
          RegExp(r'^dependencies:\s*$', multiLine: true),
          'dependencies:\n  $name: ^1.0.0',
        );
        expect(planted, isNot(real), reason: 'the plant found its anchor');
        expect(_bannedDependencies(planted), [name], reason: name);
        final dev = real.replaceFirst(
          RegExp(r'^dev_dependencies:\s*$', multiLine: true),
          'dev_dependencies:\n  $name:\n    path: ../x',
        );
        expect(_bannedDependencies(dev), [name], reason: 'dev: $name');
      }
      for (final ok in [
        'dependencies:\n  # qr_flutter: ^1.0.0\n  http: ^1.0.0\n',
        'flutter:\n  uses-material-design: true\n  qr_assets: x\n',
        'dependencies:\n  string_cursor: ^1.0.0\n',
      ]) {
        expect(_bannedDependencies(ok), isEmpty, reason: ok);
      }
    });
  });

  group('one reset reference', () {
    test('resetByUser is mentioned once in lib/ outside lib/core/vault/, in '
        'the reset screen (an independent count; bare references too)', () {
      expect(_resetByUserMentions(libFiles()), {_resetScreen: 1});
    });

    test('self-test: a bare reference, a tear-off or a second file is '
        'counted; comments and strings are not', () {
      final real = _lib()[_resetScreen]!;
      expect(_resetByUserMentions({_resetScreen: real}), {_resetScreen: 1});
      expect(
        _resetByUserMentions({
          _resetScreen: real,
          'lib/a.dart': 'final f = session.resetByUser;',
        }),
        {_resetScreen: 1, 'lib/a.dart': 1},
      );
      expect(
        _resetByUserMentions({_resetScreen: '$real\nfinal g = resetByUser;'}),
        {_resetScreen: 2},
      );
      expect(
        _resetByUserMentions({
          'lib/b.dart': "Future<void> Function() r = vault?.resetByUser ?? x;",
        }),
        {'lib/b.dart': 1},
      );
      expect(
        _resetByUserMentions({
          'lib/c.dart': "// resetByUser\nfinal s = 'resetByUser';\nfinal resetByUserX = 1;",
          'lib/core/vault/vault_session.dart': 'void resetByUser() {}',
        }),
        isEmpty,
      );
    });
  });

  // Fix round G (security M3): the reset capability. `VaultSession` is
  // provided to the tree for the reset screen alone; the holder that runs the
  // reset is named only by that screen's file and by AppWidget (which makes
  // and provides it); no other file reads the session from the tree or drives
  // the holder's run.
  group('the reset capability stays with the reset screen', () {
    Map<String, int> hits(Map<String, String> lib, RegExp pattern) => {
      for (final e in lib.entries)
        if (pattern
            .allMatches(stripSource(e.value, keepStrings: false))
            .isNotEmpty)
          e.key: pattern
              .allMatches(stripSource(e.value, keepStrings: false))
              .length,
    };

    final holder = RegExp(r'(?<![\w$])ResetEncryptionHolder(?![\w$])');
    final sessionRead = RegExp(r'(?:read|watch)\s*<\s*VaultSession\b');
    final holderRun = RegExp(r'\.cubit\s*\??\s*\.run\s*\(');
    const appWidget = 'lib/app/app_widget.dart';

    test('ResetEncryptionHolder is named only by the reset screen and '
        'AppWidget', () {
      expect(hits(_lib(), holder).keys.toSet(), {_resetScreen, appWidget});
    });

    test('the VaultSession is read from the tree only by the reset screen', () {
      expect(hits(_lib(), sessionRead).keys.toSet(), {_resetScreen});
    });

    test(
      'the holder\'s cubit is run from no file outside the reset screen',
      () {
        expect(
          hits(_lib(), holderRun).keys.where((k) => k != _resetScreen),
          isEmpty,
        );
      },
    );

    test('self-test: each pattern flags a planted use, and not a comment or '
        'a string', () {
      expect(
        hits({
          'lib/x.dart': 'final h = ResetEncryptionHolder(session: s);',
        }, holder),
        {'lib/x.dart': 1},
      );
      expect(
        hits({
          'lib/x.dart':
              "// ResetEncryptionHolder\nfinal s = 'ResetEncryptionHolder';",
        }, holder),
        isEmpty,
      );
      expect(
        hits({
          'lib/x.dart': 'final v = context.read<VaultSession>();',
        }, sessionRead),
        {'lib/x.dart': 1},
      );
      expect(
        hits({'lib/x.dart': 'context.watch<VaultSession?>()'}, sessionRead),
        {'lib/x.dart': 1},
      );
      expect(
        hits({
          'lib/x.dart': 'final v = context.read<VaultStatus>();',
        }, sessionRead),
        isEmpty,
      );
      expect(hits({'lib/x.dart': 'await holder.cubit.run();'}, holderRun), {
        'lib/x.dart': 1,
      });
      expect(hits({'lib/x.dart': 'await holder?.cubit?.run();'}, holderRun), {
        'lib/x.dart': 1,
      });
      expect(hits({'lib/x.dart': '// holder.cubit.run()'}, holderRun), isEmpty);
    });
  });

  // Last round item 6 (security R1).
  group('the reset capability: the type, the holder\'s run, AppWidget', () {
    final vaultSessionName = RegExp(r'(?<![\w$])VaultSession(?![\w$])');
    final cubitAccess = RegExp(r'\.\s*cubit(?:IfCreated)?(?![\w$])');
    final holderName = RegExp(r'(?<![\w$])ResetEncryptionHolder(?![\w$])');
    const appWidget = 'lib/app/app_widget.dart';

    String code(String s) => stripSource(s, keepStrings: false);

    /// (a) The files under lib/features/ presentation or lib/shared/ that
    /// name `VaultSession`, other than the reset screen.
    List<String> namingVaultSession(Map<String, String> lib) => [
      for (final e in lib.entries)
        if ((RegExp(r'^lib/features/[^/]+/presentation/').hasMatch(e.key) ||
                e.key.startsWith('lib/shared/')) &&
            e.key != _resetScreen &&
            vaultSessionName.hasMatch(code(e.value)))
          e.key,
    ];

    /// (b) Files other than the reset screen that name the holder AND reach
    /// for `.cubit` / `.cubitIfCreated` (a tear-off, a cascade, a `!`, an
    /// alias or a helper call all go through the member name).
    List<String> reachingHolderCubit(Map<String, String> lib) => [
      for (final e in lib.entries)
        if (e.key != _resetScreen &&
            holderName.hasMatch(code(e.value)) &&
            cubitAccess.hasMatch(code(e.value)))
          e.key,
    ];

    /// (c) Every use of `_resetHolder` in AppWidget, as the text around it.
    /// Exactly: construct, provide, reset(), dispose().
    List<String> resetHolderUses(String source) {
      final text = _oneLine(code(source));
      final uses = <String>[];
      final allowed = <RegExp>[
        // construct
        RegExp(
          r'^ResetEncryptionHolder\? _resetHolder = widget\.vaultSession == '
          r'null \? null : ResetEncryptionHolder\(',
        ),
        // provide
        RegExp(
          r'^_resetHolder case final (\w+)\?\) '
          r'RepositoryProvider<ResetEncryptionHolder>\.value\(value: \1\)',
        ),
        RegExp(r'^_resetHolder\?\.reset\(\)\)'),
        RegExp(r'^_resetHolder\?\.dispose\(\);'),
      ];
      var from = 0;
      while (true) {
        final at = text.indexOf('_resetHolder', from);
        if (at < 0) break;
        from = at + '_resetHolder'.length;
        // The construct form starts at its type, a little before the name.
        final start = at >= 36 ? at - 36 : 0;
        final head = text.substring(start, at);
        final typed = head.lastIndexOf('ResetEncryptionHolder? ');
        final slice = typed >= 0 && head.length - typed <= 24
            ? text.substring(start + typed)
            : text.substring(at);
        if (!allowed.any((r) => r.hasMatch(slice))) {
          uses.add(slice.substring(0, slice.length.clamp(0, 70)));
        }
      }
      return uses;
    }

    test('(a) VaultSession is named in no presentation or shared file but '
        'the reset screen', () {
      expect(namingVaultSession(_lib()), isEmpty);
    });

    test('(b) no other file reaches the holder\'s cubit', () {
      expect(reachingHolderCubit(_lib()), isEmpty);
    });

    test('(c) AppWidget uses _resetHolder only to construct, provide, '
        'reset() and dispose()', () {
      expect(resetHolderUses(_lib()[appWidget]!), isEmpty);
      // Four uses, no fewer (the pin is not vacuous).
      expect(
        RegExp('_resetHolder').allMatches(code(_lib()[appWidget]!)).length,
        4,
      );
    });

    test('self-test (a): every form that names the type is flagged', () {
      for (final form in [
        'final s = RepositoryProvider.of<VaultSession>(context);',
        'final v = context.select<VaultSession, int>((s) => 1);',
        'final VaultSession s = context.read();',
        'VaultSession? maybe;',
      ]) {
        expect(
          namingVaultSession({
            'lib/features/a/presentation/x.dart': form,
            'lib/shared/y.dart': form,
          }),
          ['lib/features/a/presentation/x.dart', 'lib/shared/y.dart'],
          reason: form,
        );
      }
      expect(
        namingVaultSession({
          'lib/features/a/presentation/x.dart':
              '// VaultSession\nfinal s = "VaultSession";',
          _resetScreen: 'final VaultSession s = x;',
          'lib/features/a/data/x.dart': 'final VaultSession s = x;',
        }),
        isEmpty,
      );
    });

    test('self-test (b): a tear-off, cascade, bang, alias or helper call '
        'on the holder is flagged', () {
      for (final form in [
        'final f = holder.cubit.run;',
        'holder..cubit.run();',
        'holder!.cubit;',
        'final c = holder?.cubit; c?.run();',
        'helper(holder.cubit);',
        'holder.cubitIfCreated?.run();',
      ]) {
        expect(
          reachingHolderCubit({
            'lib/app/z.dart': 'final ResetEncryptionHolder holder = h; $form',
          }),
          ['lib/app/z.dart'],
          reason: form,
        );
      }
      expect(
        reachingHolderCubit({
          'lib/app/z.dart': 'final ResetEncryptionHolder h = x;',
          'lib/app/w.dart': 'widget.cubit.close();',
          _resetScreen: 'ResetEncryptionHolder h; h.cubit.run();',
        }),
        isEmpty,
      );
    });

    test('self-test (c): a fifth use of _resetHolder is flagged', () {
      final real = _lib()[appWidget]!;
      for (final extra in [
        'void x() { _resetHolder?.cubit.run(); }',
        'void y() { final h = _resetHolder; }',
        'void z() { _resetHolder!.attach(); }',
      ]) {
        expect(resetHolderUses('$real\n$extra'), isNotEmpty, reason: extra);
      }
    });
  });

  group('flag-off inertness stays pinned by tests', () {
    // A meta-test: these tests assert that with the flag off and no vault
    // nothing shows and nothing is called. Brittle by design; if one is
    // renamed, update the name here, do not delete the test. A skipped test
    // still matches (see the known gaps above).
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
