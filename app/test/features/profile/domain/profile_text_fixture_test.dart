import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/features/profile/domain/profile_extras_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs every row of the shared profile text fixture
/// (`testdata/profile_text/{website,location,display_name,bio}.json`, W3-22
/// L-2 / L-3) through the functions the Edit profile screen uses. The Go
/// validators run the same files (`profile_text_fixture_test.go`), so a rule
/// changed on one side fails on the other. Tests run from `app/`. No row is
/// skipped: a file whose decoded rows differ from the `"raw":` keys in its text
/// fails, as the Go runner does.

class _Accept {
  const _Accept(this.name, this.raw, this.stored, this.host);

  final String name;
  final String raw;
  final String stored;
  final String host;
}

class _Reject {
  const _Reject(this.name, this.raw, this.why);

  final String name;
  final String raw;
  final String why;
}

class _Fixture {
  _Fixture(this.field)
    : text = File('../testdata/profile_text/$field.json').readAsStringSync() {
    final json = jsonDecode(text) as Map<String, dynamic>;
    declaredField = json['field'] as String;
    accept = [
      for (final r in (json['accept'] as List).cast<Map<String, dynamic>>())
        _Accept(
          r['name'] as String,
          r['raw'] as String,
          r['stored'] as String,
          (r['host'] as String?) ?? '',
        ),
    ];
    reject = [
      for (final r in (json['reject'] as List).cast<Map<String, dynamic>>())
        _Reject(
          r['name'] as String,
          r['raw'] as String,
          (r['why'] as String?) ?? '',
        ),
    ];
  }

  final String field;
  final String text;
  late final String declaredField;
  late final List<_Accept> accept;
  late final List<_Reject> reject;

  int get rawKeys => '"raw":'.allMatches(text).length;
}

/// One file: a test per row (named after the row, so a failure points at it)
/// and one that the file was read in full.
void _runFile(
  String field, {
  required bool Function(String raw) valid,
  required String Function(String raw) stored,
  String? Function(String raw)? host,
}) {
  final fixture = _Fixture(field);
  group('shared fixture profile_text/$field.json', () {
    test('every row of the file was decoded', () {
      expect(fixture.declaredField, field);
      expect(fixture.accept, isNotEmpty);
      expect(fixture.reject, isNotEmpty);
      expect(fixture.accept.length + fixture.reject.length, fixture.rawKeys);
    });

    for (final row in fixture.accept) {
      test('accepts: ${row.name}', () {
        final reason = 'raw: ${jsonEncode(row.raw)}';
        expect(valid(row.raw), isTrue, reason: reason);
        expect(stored(row.raw), row.stored, reason: reason);
        if (host != null) {
          expect(host(row.raw) ?? '', row.host, reason: reason);
        }
      });
    }

    for (final row in fixture.reject) {
      test('rejects: ${row.name}', () {
        expect(
          valid(row.raw),
          isFalse,
          reason: 'raw: ${jsonEncode(row.raw)}; must fail because: ${row.why}',
        );
      });
    }
  });
}

void main() {
  _runFile(
    'website',
    valid: (raw) => websiteIssue(raw) == null,
    stored: normalizeProfileWebsite,
    host: websiteHostPreview,
  );
  _runFile(
    'location',
    valid: (raw) => locationIssue(raw) == null,
    stored: normalizeProfileLocation,
  );
  _runFile(
    'display_name',
    valid: (raw) => displayNameIssue(raw) == null,
    stored: normalizeDisplayName,
  );
  _runFile('bio', valid: (raw) => bioIssue(raw) == null, stored: normalizeBio);
}
