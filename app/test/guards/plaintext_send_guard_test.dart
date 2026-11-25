import 'package:flutter_test/flutter_test.dart';

import 'vault_scan.dart'
    show handWrittenLib, isGeneratedPath, pipelineDir, stripSource;

/// Plan 6 Task 1.B: with `e2ee_required` in the enabled features no plaintext
/// `MessagingRepository.sendMessage` is reachable. This guard pins:
///
/// 1. every `sendMessage` name in lib/ (hand-written), by file and count: the
///    repository's declaration and its two RPC calls (the plaintext one and
///    `sendEncrypted`'s), and ONE plaintext call site in each of the composer
///    and the share cubit. A new caller anywhere fails here first;
/// 2. that each plaintext call site sits behind the required check: an
///    `if (_plaintextRefused(...)) return|continue;` that STARTS a statement
///    (after `;`, `{` or `}`), earlier in the same block (or an enclosing
///    one), close to the call, in a file whose `_plaintextRefused` opens with
///    `if (!_encryptionRequired()) return false;` and then `return true;`;
/// 3. that every construction of the two cubits and of `E2eePipeline` in lib/
///    (`X(` or `X.new(`; a bare `X.new` tear-off is refused) passes
///    `encryptionRequired: e2eeRequiredOf(...)`, the ONE fail-closed reader
///    (security L1/L2), so the check is wired in production;
/// 4. that `SendMessageRequest(` is built only in the repository;
/// 5. that the message pipeline (lib/features/messages/domain/e2ee/) names
///    `SendOutcomeKind.notEncrypted` exactly once, in a `SendOutcome(`
///    construction: the port's one answer that leads to plaintext, which
///    `_notEncryptedUnlessRequired` holds back under required.
///
/// Run from app/ (like the other guards).

const _repository = 'lib/features/messages/data/messaging_repository.dart';
const _composer =
    'lib/features/messages/presentation/bloc/message_composer_cubit.dart';
const _share = 'lib/features/messages/presentation/bloc/share_post_cubit.dart';
const _bootstrap = 'lib/app/bootstrap.dart';
const _impl = 'lib/features/messages/domain/e2ee/encrypted_messaging_impl.dart';

/// Every `sendMessage` name in code, by file. Pinned: change it only with a
/// reviewed reason, and keep each new plaintext call behind the check.
const pinnedSendMessageNames = {
  // `Future<...> sendMessage({` (plaintext), its `_apiClient.messaging.
  // sendMessage(request)`, and `sendEncrypted`'s RPC call.
  _repository: 3,
  // `_deliver`: the composer's one plaintext call.
  _composer: 1,
  // `send`: the share's one plaintext call.
  _share: 1,
};

/// The files whose `_repository.sendMessage(` is a plaintext call site.
const plaintextCallSites = {_composer, _share};

/// The types that must be given the required reader, and the one reader.
const requiredReaderTypes = [
  'MessageComposerCubit',
  'SharePostCubit',
  'E2eePipeline',
];
const requiredReader = 'e2eeRequiredOf';

/// The required check that must precede a plaintext call. Group 1 is what
/// comes right before it: it must end a statement or open/close a block.
final _guardStatement = RegExp(
  r'(\S?)\s*\bif\s*\(\s*_plaintextRefused\s*\([^;{}]*\)\s*\)\s*'
  r'(?:return|continue)\b[^;{}]*;',
);

/// The furthest (in code characters, comments stripped) the guard may sit
/// before the call it covers.
const kMaxGuardDistance = 400;

String _code(String source) => stripSource(source, keepStrings: false);

int _countSendMessage(String source) =>
    RegExp(r'\bsendMessage\b').allMatches(_code(source)).length;

/// Why the plaintext calls of [source] are not covered, empty when each is.
List<String> unguardedCalls(String source) {
  final code = _code(source);
  final problems = <String>[];
  final calls = RegExp(r'_repository\s*\.\s*sendMessage\s*\(')
      .allMatches(code)
      .toList();
  if (calls.isEmpty) problems.add('no plaintext call found');
  for (final call in calls) {
    final before = code.substring(0, call.start);
    final guards = [
      for (final m in _guardStatement.allMatches(before))
        if (const {';', '{', '}'}.contains(m.group(1))) m,
    ];
    if (guards.isEmpty) {
      problems.add(
        'a plaintext call with no _plaintextRefused statement before it',
      );
      continue;
    }
    final between = before.substring(guards.last.end);
    if (between.length > kMaxGuardDistance) {
      problems.add('the _plaintextRefused check is too far from the call');
      continue;
    }
    var depth = 0;
    for (final unit in between.codeUnits) {
      if (unit == 0x7B) depth++; // {
      if (unit == 0x7D) depth--; // }
      if (depth < 0) break;
    }
    if (depth < 0) {
      problems.add(
        'the _plaintextRefused check is in a block that ends '
        'before the call',
      );
    }
  }
  final declaration = RegExp(r'bool\s+_plaintextRefused\s*\([^)]*\)\s*\{')
      .firstMatch(code);
  if (declaration == null) {
    problems.add('_plaintextRefused is not declared here');
  } else {
    final body = _balanced(code, declaration.end - 1, 0x7B, 0x7D);
    final opening = RegExp(
      r'^\{\s*if\s*\(\s*!\s*_encryptionRequired\s*\(\s*\)\s*\)\s*'
      r'return\s+false\s*;',
    ).firstMatch(body);
    if (opening == null) {
      problems.add(
        '_plaintextRefused does not open with '
        'if (!_encryptionRequired()) return false;',
      );
    } else {
      final rest = body.substring(opening.end);
      if (RegExp(r'\breturn\s+false\b').hasMatch(rest)) {
        problems.add('_plaintextRefused answers false elsewhere');
      }
      if (!RegExp(r'\breturn\s+true\s*;').hasMatch(rest)) {
        problems.add('_plaintextRefused never answers true');
      }
    }
  }
  return problems;
}

/// The text from [open] (an opening bracket) to its matching close.
String _balanced(String code, int open, int openUnit, int closeUnit) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final u = code.codeUnitAt(i);
    if (u == openUnit) depth++;
    if (u == closeUnit) {
      depth--;
      if (depth == 0) return code.substring(open, i + 1);
    }
  }
  return code.substring(open);
}

/// Every construction of [type] in [source] (`X(` or `X.new(`), as its
/// argument list; a bare `X.new` tear-off is listed as `.new` (its arguments
/// cannot be checked). The class's own constructor declaration (`X({`) is
/// skipped.
List<String> constructionsOf(String source, String type) {
  final code = _code(source);
  final found = <String>[];
  for (final m in RegExp(
    '\\b$type(\\s*\\.\\s*new\\b)?(\\s*\\()?',
  ).allMatches(code)) {
    final isNew = m.group(1) != null;
    final opens = m.group(2) != null;
    if (!opens) {
      if (isNew) found.add('.new');
      continue;
    }
    final args = _balanced(code, m.end - 1, 0x28, 0x29);
    // The class's own constructor declaration takes named parameters
    // (`X({`); a construction never opens its arguments with a brace.
    if (!isNew && RegExp(r'^\(\s*\{').hasMatch(args)) continue;
    found.add(args);
  }
  return found;
}

/// The constructions of [type] in [source] whose [argument] is not exactly a
/// call of [reader] (missing, another expression, or a tear-off).
List<String> constructionsWithout(
  String source,
  String type,
  String argument, {
  String? reader,
}) {
  final bad = <String>[];
  for (final args in constructionsOf(source, type)) {
    if (args == '.new') {
      bad.add(args);
      continue;
    }
    final m = RegExp('\\b$argument\\s*:\\s*').firstMatch(args);
    if (m == null) {
      bad.add(args);
      continue;
    }
    if (reader == null) continue;
    // The value runs to the next top-level comma or the closing paren.
    final value = _argumentValue(args, m.end);
    if (!RegExp('^$reader\\s*\\(').hasMatch(value) ||
        _balanced(value, value.indexOf('('), 0x28, 0x29).length !=
            value.length - value.indexOf('(')) {
      bad.add(args);
    }
  }
  return bad;
}

/// The argument value in [args] that starts at [start], trimmed.
String _argumentValue(String args, int start) {
  var depth = 0;
  for (var i = start; i < args.length; i++) {
    final u = args.codeUnitAt(i);
    if (u == 0x28 || u == 0x5B || u == 0x7B) depth++;
    if (u == 0x29 || u == 0x5D || u == 0x7D) {
      if (depth == 0) return args.substring(start, i).trim();
      depth--;
    }
    if (u == 0x2C && depth == 0) return args.substring(start, i).trim();
  }
  return args.substring(start).trim();
}

/// Every `SendOutcomeKind.notEncrypted` in [code], and how many of them are
/// the kind of a `SendOutcome(` / `SendOutcome.new(` construction.
({int names, int constructions}) notEncryptedIn(String source) {
  final code = _code(source);
  return (
    names: RegExp(r'\bSendOutcomeKind\s*\.\s*notEncrypted\b')
        .allMatches(code)
        .length,
    constructions: RegExp(
      r'\bSendOutcome\s*(?:\.\s*new\s*)?\(\s*SendOutcomeKind\s*\.\s*'
      r'notEncrypted\b',
    ).allMatches(code).length,
  );
}

void main() {
  final files = handWrittenLib();

  test('every sendMessage name in lib/ is pinned by file and count', () {
    final found = <String, int>{
      for (final e in files.entries)
        if (_countSendMessage(e.value) > 0) e.key: _countSendMessage(e.value),
    };
    expect(
      found,
      pinnedSendMessageNames,
      reason:
          'A new sendMessage caller must sit behind the e2ee_required check '
          '(Plan 6 Task 1.B); add it here only with that check.',
    );
  });

  test('each plaintext sendMessage call site is behind the required check', () {
    for (final path in plaintextCallSites) {
      final source = files[path];
      expect(source, isNotNull, reason: '$path moved: update the guard');
      expect(unguardedCalls(source!), isEmpty, reason: path);
    }
  });

  test('every composer, share cubit and pipeline built in lib/ gets '
      'encryptionRequired: $requiredReader(...)', () {
    final missing = <String>[];
    var built = 0;
    for (final e in files.entries) {
      for (final type in requiredReaderTypes) {
        built += constructionsOf(e.value, type).length;
        for (final args in constructionsWithout(
          e.value,
          type,
          'encryptionRequired',
          reader: requiredReader,
        )) {
          missing.add('${e.key}: $type$args');
        }
      }
    }
    expect(missing, isEmpty);
    // The constructions exist (a guard that matches nothing proves nothing):
    // the thread, the draft, the picker and bootstrap.
    expect(built, greaterThanOrEqualTo(4));
    expect(constructionsOf(files[_bootstrap]!, 'E2eePipeline'), hasLength(1));
  });

  test('SendMessageRequest is built only in the repository', () {
    final found = <String, int>{
      for (final e in files.entries)
        if (RegExp(r'\bSendMessageRequest\s*\(')
                .allMatches(_code(e.value))
                .length
            case final n when n > 0)
          e.key: n,
    };
    expect(found, {_repository: 2});
  });

  test('the pipeline constructs notEncrypted once, in the port', () {
    final found = <String, ({int names, int constructions})>{
      for (final e in files.entries)
        if (e.key.startsWith(pipelineDir) && !isGeneratedPath(e.key))
          if (notEncryptedIn(e.value) case final n when n.names > 0) e.key: n,
    };
    expect(found, {_impl: (names: 1, constructions: 1)});
  });

  group('self-tests', () {
    const guarded = '''
class C {
  bool _plaintextRefused(String id) {
    if (!_encryptionRequired()) return false;
    emit(state);
    return true;
  }
  Future<void> f() async {
    if (_plaintextRefused(key)) return;
    await _repository.sendMessage(idempotencyKey: key, text: text);
  }
  Future<void> g() async {
    for (final id in ids) {
      if (_plaintextRefused(id)) continue;
      await _repository.sendMessage(idempotencyKey: id, text: t);
    }
  }
}
''';

    test('a guarded call is accepted', () {
      expect(unguardedCalls(guarded), isEmpty);
    });

    test('a call with no check, a check in a closed block, a far check and a '
        'commented-out check are each flagged', () {
      final noCheck = guarded.replaceFirst(
        'if (_plaintextRefused(key)) return;',
        '',
      );
      expect(unguardedCalls(noCheck), isNotEmpty);

      final closedBlock = guarded.replaceFirst(
        'if (_plaintextRefused(key)) return;\n',
        'if (x) { if (_plaintextRefused(key)) return; }\n',
      );
      expect(unguardedCalls(closedBlock), isNotEmpty);

      final far = guarded.replaceFirst(
        'if (_plaintextRefused(key)) return;\n',
        'if (_plaintextRefused(key)) return;\n'
            '${'    a();\n' * 120}',
      );
      expect(unguardedCalls(far), isNotEmpty);

      final commentedCheck = guarded.replaceFirst(
        'if (_plaintextRefused(key)) return;',
        '// if (_plaintextRefused(key)) return;',
      );
      expect(unguardedCalls(commentedCheck), isNotEmpty);
    });

    test('a check that does not start a statement is flagged (an else-if or '
        'the body of another if)', () {
      for (final prefix in ['if (a) {} else ', 'if (a) ']) {
        final nested = guarded.replaceFirst(
          'if (_plaintextRefused(key)) return;',
          '${prefix}if (_plaintextRefused(key)) return;',
        );
        expect(unguardedCalls(nested), isNotEmpty, reason: prefix);
      }
    });

    test('a _plaintextRefused that does not open with the flag check, answers '
        'false elsewhere or never answers true is flagged', () {
      for (final (from, to) in [
        (
          'if (!_encryptionRequired()) return false;',
          'if (!_somethingElse()) return false;',
        ),
        (
          'if (!_encryptionRequired()) return false;',
          'if (!_encryptionRequired() && x) return false;',
        ),
        (
          'if (!_encryptionRequired()) return false;\n    emit(state);',
          'emit(state);\n    if (!_encryptionRequired()) return false;',
        ),
        ('emit(state);', 'if (y) return false;'),
        ('return true;\n  }\n  Future', 'return y;\n  }\n  Future'),
      ]) {
        final changed = guarded.replaceFirst(from, to);
        expect(changed, isNot(guarded), reason: 'mutation applies: $to');
        expect(unguardedCalls(changed), isNotEmpty, reason: to);
      }
    });

    test('names in comments and strings are not counted; a tear-off is', () {
      expect(_countSendMessage("// sendMessage(\nfinal s = 'sendMessage';"), 0);
      expect(_countSendMessage('final f = repo.sendMessage;'), 1);
    });

    test('a construction without the reader is flagged, through X( and '
        'X.new(, and a bare X.new tear-off; the reader and the class '
        'declaration are not', () {
      const source = '''
class MessageComposerCubit {
  MessageComposerCubit({required this.a, bool Function()? encryptionRequired});
}
final a = MessageComposerCubit(a: 1, encryptionRequired: e2eeRequiredOf(b));
final b = MessageComposerCubit(a: 1);
final c = MessageComposerCubit(a: 1, encryptionRequired: () => false);
final d = MessageComposerCubit.new(a: 1);
final e = MessageComposerCubit.new(a: 1, encryptionRequired: e2eeRequiredOf(b, signedInUid: () => u));
final f = MessageComposerCubit.new;
final g = MessageComposerCubit(a: 1, encryptionRequired: e2eeRequiredOf(b) || x);
''';
      expect(constructionsOf(source, 'MessageComposerCubit'), hasLength(7));
      final found = constructionsWithout(
        source,
        'MessageComposerCubit',
        'encryptionRequired',
        reader: requiredReader,
      );
      expect(found, [
        '(a: 1)',
        '(a: 1, encryptionRequired: () => false)',
        '(a: 1)',
        '.new',
        '(a: 1, encryptionRequired: e2eeRequiredOf(b) || x)',
      ]);
    });

    test('notEncrypted: names and constructions are counted apart, with '
        'X.new; comments are not', () {
      expect(
        notEncryptedIn('''
// SendOutcome(SendOutcomeKind.notEncrypted)
final a = SendOutcome(SendOutcomeKind.notEncrypted, conversationId: id);
final b = SendOutcome.new(SendOutcomeKind.notEncrypted);
if (k == SendOutcomeKind.notEncrypted) {}
'''),
        (names: 3, constructions: 2),
      );
    });
  });
}
