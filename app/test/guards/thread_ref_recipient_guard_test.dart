import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart' show readTree;
import 'vault_scan.dart' show stripSource;

/// Second re-read R1: a person is addressed only as `ThreadRef.recipientOf(snapshot)`, from the `AuthorSnapshot` the
/// screen got the person from, never from a string held elsewhere. The guard keeps a public string constructor from
/// being added back to `ThreadRef`.
///
/// Run from app/ (like the other guards).

const _portFile = 'lib/features/messages/domain/e2ee/encrypted_messaging.dart';

/// `ThreadRef.recipient(` (a string constructor for a person), anywhere.
List<String> findStringRecipientCalls(String source) => [
  for (final m in RegExp(
    r'ThreadRef\s*\.\s*recipient\s*\(',
  ).allMatches(stripSource(source, keepStrings: false)))
    m.group(0)!,
];

/// Constructors of `ThreadRef` other than the allowed three, inside the port file's own class body.
List<String> findOtherThreadRefConstructors(String source) {
  final code = stripSource(source, keepStrings: false);
  final start = code.indexOf('class ThreadRef');
  if (start < 0) return ['class ThreadRef not found'];
  // The class body ends at the first top-level "\n}" after its start.
  final end = code.indexOf('\n}', start);
  final body = code.substring(start, end < 0 ? code.length : end);
  const allowed = {'conversation', 'recipientOf', '_recipient'};
  return [
    for (final m in RegExp(
      r'(?:const\s+|factory\s+)?ThreadRef\s*(?:\.\s*(\w+))?\s*\(',
    ).allMatches(body))
      if (!allowed.contains(m.group(1))) m.group(0)!,
  ];
}

void main() {
  final files = readTree('lib', {'.dart'});

  test('no code builds a ThreadRef for a person from a string', () {
    final found = <String>[];
    for (final e in files.entries) {
      if (e.key.startsWith('lib/gen/')) continue;
      for (final hit in findStringRecipientCalls(e.value)) {
        found.add('${e.key}: $hit');
      }
    }
    expect(found, isEmpty);
  });

  test('ThreadRef has no constructor but conversation, recipientOf and '
      '_recipient', () {
    final source = files[_portFile];
    expect(source, isNotNull, reason: '$_portFile moved: update the guard');
    expect(findOtherThreadRefConstructors(source!), isEmpty);
  });

  group('self-tests', () {
    test('a ThreadRef.recipient( call is flagged', () {
      expect(
        findStringRecipientCalls('final r = ThreadRef.recipient(handle);'),
        isNotEmpty,
      );
      expect(
        findStringRecipientCalls('final r = ThreadRef.recipientOf(person);'),
        isEmpty,
      );
      expect(
        findStringRecipientCalls(
          "// ThreadRef.recipient(x)\nfinal a = 'ThreadRef.recipient(';",
        ),
        isEmpty,
      );
    });

    test('a new public constructor is flagged', () {
      const bad = '''
final class ThreadRef {
  const ThreadRef.conversation(String this.conversationId);
  const ThreadRef.recipient(String this.recipientUserId);
}
''';
      expect(findOtherThreadRefConstructors(bad), isNotEmpty);
      const ok = '''
final class ThreadRef {
  const ThreadRef.conversation(String this.conversationId);
  factory ThreadRef.recipientOf(Person p) => ThreadRef._recipient(p.id);
  const ThreadRef._recipient(String this.recipientUserId);
}
''';
      expect(findOtherThreadRefConstructors(ok), isEmpty);
      expect(
        findOtherThreadRefConstructors(
          'final class ThreadRef { const ThreadRef(this.a); }',
        ),
        isNotEmpty,
      );
    });
  });
}
