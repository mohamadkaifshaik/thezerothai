import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/features/lists/domain/list_text_rules.dart';
import 'package:dzeroth/features/profile/domain/profile_extras_rules.dart';
import 'package:dzeroth/shared/format/single_line_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs every row of `testdata/profile_text/single_line_text.json` (W5-45
/// vectors, ported by W5-49) through each place the client pre-validates a
/// one-line field: display name, location, List name and List description. The
/// Go side runs the same file (`identity.SingleLineText`), so a rule changed on
/// one side fails on the other. Tests run from `app/`. A file whose decoded
/// rows differ from the `"raw":` keys in its text fails.

final String _text = File('../testdata/profile_text/single_line_text.json')
    .readAsStringSync();
final Map<String, dynamic> _json = jsonDecode(_text) as Map<String, dynamic>;
final List<Map<String, dynamic>> _accept = (_json['accept'] as List)
    .cast<Map<String, dynamic>>();
final List<Map<String, dynamic>> _reject = (_json['reject'] as List)
    .cast<Map<String, dynamic>>();

/// One test per row, named after it. For the fields where "" is a valid clear
/// (location, description) the fixture's whitespace-only row is valid on its
/// own, so [valid] there also requires a non-empty value.
void _run(
  String field, {
  required bool Function(String raw) valid,
  required String Function(String raw) stored,
}) {
  group('single_line_text.json as $field', () {
    for (final row in _accept) {
      test('accepts: ${row['name']}', () {
        final raw = row['raw'] as String;
        expect(valid(raw), isTrue, reason: 'raw: ${jsonEncode(raw)}');
        expect(stored(raw), row['stored']);
      });
    }
    for (final row in _reject) {
      test('rejects: ${row['name']}', () {
        final raw = row['raw'] as String;
        expect(
          valid(raw),
          isFalse,
          reason: 'raw: ${jsonEncode(raw)}; must fail: ${row['why']}',
        );
      });
    }
  });
}

void main() {
  test('every row of the file was decoded', () {
    expect(_json['field'], 'single_line_text');
    expect(_accept, hasLength(12));
    expect(_reject, hasLength(30));
    expect(_accept.length + _reject.length, '"raw":'.allMatches(_text).length);
  });

  _run(
    'display name',
    valid: (raw) => displayNameIssue(raw) == null,
    stored: normalizeDisplayName,
  );
  _run(
    'location',
    valid: (raw) =>
        normalizeProfileLocation(raw).isNotEmpty && locationIssue(raw) == null,
    stored: normalizeProfileLocation,
  );
  _run(
    'list name',
    valid: (raw) => listNameIssue(raw) == null,
    stored: normalizeListText,
  );
  _run(
    'list description',
    valid: (raw) =>
        normalizeListText(raw).isNotEmpty && listDescriptionIssue(raw) == null,
    stored: normalizeListText,
  );

  group('isFormatCharacter', () {
    test('matches the Cf members the server refuses', () {
      for (final r in [0xAD, 0x61C, 0x200B, 0x2060, 0xFEFF, 0xE0041, 0xE007F]) {
        expect(isFormatCharacter(r), isTrue, reason: r.toRadixString(16));
      }
    });
    test('does not match letters, fillers or unassigned neighbours', () {
      for (final r in [0x41, 0x20, 0x115F, 0x3164, 0x1F600, 0xE0000, 0x2065]) {
        expect(isFormatCharacter(r), isFalse, reason: r.toRadixString(16));
      }
    });
  });

  test('empty text is not refused by the visible-rune rule', () {
    expect(singleLineIssue(''), isNull);
  });
}
