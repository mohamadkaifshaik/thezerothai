import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart' show readTree;
import 'vault_scan.dart' show stripSource;

/// Plan 6 Task 1.B: with `e2ee_required` in the enabled features no plaintext
/// `MessagingRepository.sendMessage` is reachable. This guard pins:
///
/// 1. every `sendMessage` name in lib/ (outside lib/gen/), by file and count:
///    the repository's declaration and its two RPC calls (the plaintext one and
///    `sendEncrypted`'s), and ONE plaintext call site in each of the composer
///    and the share cubit. A new caller anywhere fails here first;
/// 2. that each plaintext call site sits behind the required check: an
///    `if (_plaintextRefused(...)) return|continue;` earlier in the same block
///    (or an enclosing one), close to the call, in a file whose
///    `_plaintextRefused` reads `_encryptionRequired()`;
/// 3. that every construction of the two cubits in lib/ passes
///    `encryptionRequired:`, and the pipeline the port reads it from gets it
///    too, so the check is wired in production and not only in tests;
/// 4. that `SendMessageRequest(` is built only in the repository.
///
/// Run from app/ (like the other guards).

const _repository = 'lib/features/messages/data/messaging_repository.dart';
const _composer =
    'lib/features/messages/presentation/bloc/message_composer_cubit.dart';
const _share = 'lib/features/messages/presentation/bloc/share_post_cubit.dart';
const _bootstrap = 'lib/app/bootstrap.dart';

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

/// The required check that must precede a plaintext call.
final _guardStatement = RegExp(
  r'if\s*\(\s*_plaintextRefused\s*\([^;{}]*\)\s*\)\s*(?:return|continue)\b[^;{}]*;',
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
    final guards = _guardStatement.allMatches(before).toList();
    if (guards.isEmpty) {
      problems.add(
        'a plaintext call with no _plaintextRefused check before it',
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
    if (!RegExp(r'\b_encryptionRequired\s*\(\s*\)').hasMatch(body)) {
      problems.add('_plaintextRefused does not read _encryptionRequired()');
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

/// The argument lists of every `[type](` construction in [source] that does
/// not pass `[argument]:` (a declaration `[type]({` of the class itself is
/// skipped).
List<String> constructionsWithout(String source, String type, String argument) {
  final code = _code(source);
  final found = <String>[];
  for (final m in RegExp('\\b$type\\s*\\(').allMatches(code)) {
    final args = _balanced(code, m.end - 1, 0x28, 0x29);
    // The class's own constructor declaration takes named parameters
    // (`X({`); a construction never opens its arguments with a brace.
    if (RegExp(r'^\(\s*\{').hasMatch(args)) continue;
    if (!RegExp('\\b$argument\\s*:').hasMatch(args)) found.add(args);
  }
  return found;
}

void main() {
  final files = readTree('lib', {'.dart'});

  test('every sendMessage name in lib/ is pinned by file and count', () {
    final found = <String, int>{
      for (final e in files.entries)
        if (!e.key.startsWith('lib/gen/') && _countSendMessage(e.value) > 0)
          e.key: _countSendMessage(e.value),
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

  test('every composer and share cubit built in lib/ gets encryptionRequired, '
      'and so does the pipeline the port reads it from', () {
    final missing = <String>[];
    for (final e in files.entries) {
      if (e.key.startsWith('lib/gen/')) continue;
      for (final type in ['MessageComposerCubit', 'SharePostCubit']) {
        for (final args in constructionsWithout(
          e.value,
          type,
          'encryptionRequired',
        )) {
          missing.add('${e.key}: $type$args');
        }
      }
    }
    expect(missing, isEmpty);
    // The constructions exist (a guard that matches nothing proves nothing).
    var built = 0;
    for (final e in files.entries) {
      if (e.key.startsWith('lib/gen/') ||
          e.key == _composer ||
          e.key == _share) {
        continue;
      }
      built += RegExp(r'\b(?:MessageComposerCubit|SharePostCubit)\s*\(')
          .allMatches(_code(e.value))
          .length;
    }
    expect(built, greaterThanOrEqualTo(3));
    final bootstrap = files[_bootstrap]!;
    expect(
      constructionsWithout(bootstrap, 'E2eePipeline', 'encryptionRequired'),
      isEmpty,
      reason: 'bootstrap must hand e2ee_required to the pipeline',
    );
    expect(RegExp(r'\bE2eePipeline\s*\(').hasMatch(_code(bootstrap)), isTrue);
  });

  test('SendMessageRequest is built only in the repository', () {
    final found = <String, int>{
      for (final e in files.entries)
        if (!e.key.startsWith('lib/gen/'))
          if (RegExp(r'\bSendMessageRequest\s*\(')
                  .allMatches(_code(e.value))
                  .length
              case final n when n > 0)
            e.key: n,
    };
    expect(found, {_repository: 2});
  });

  group('self-tests', () {
    const guarded = '''
class C {
  bool _plaintextRefused(String id) {
    if (!_encryptionRequired()) return false;
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
        'check that does not read the flag are each flagged', () {
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

      final notReading = guarded.replaceFirst(
        'if (!_encryptionRequired()) return false;',
        'if (!_somethingElse()) return false;',
      );
      expect(unguardedCalls(notReading), isNotEmpty);

      final commentedCheck = guarded.replaceFirst(
        'if (_plaintextRefused(key)) return;',
        '// if (_plaintextRefused(key)) return;',
      );
      expect(unguardedCalls(commentedCheck), isNotEmpty);
    });

    test('names in comments and strings are not counted; a tear-off is', () {
      expect(_countSendMessage("// sendMessage(\nfinal s = 'sendMessage';"), 0);
      expect(_countSendMessage('final f = repo.sendMessage;'), 1);
    });

    test('a construction without the argument is flagged; one with it and '
        'the class declaration are not', () {
      const source = '''
class MessageComposerCubit {
  MessageComposerCubit({required this.a, bool Function()? encryptionRequired});
}
final a = MessageComposerCubit(a: 1, encryptionRequired: () => true);
final b = MessageComposerCubit(a: 1);
''';
      final found = constructionsWithout(
        source,
        'MessageComposerCubit',
        'encryptionRequired',
      );
      expect(found, ['(a: 1)']);
    });
  });
}
