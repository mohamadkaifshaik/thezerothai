// Guard against the "time bomb" class of test bug: a fixed absolute date in a
// test that, directly or through a widget, is compared with the real clock.
//
// Example (2026-10-21): the notification fixtures used a fixed 2026-10-14
// while NotificationsScreen compared against DateTime.now(). The spoken
// relative time stops saying "ago" after 7 days, so the suite went red a week
// later with no code change.
//
// The rule: a fixed date in a test must never be compared with the real clock.
// Inject `now` (or a clock), or build the date relative to DateTime.now().
// Where a fixed date is genuinely safe, the file is listed in [_allowlist]
// with the reason it cannot meet the real clock.
//
// Limits: this finds fixed absolute dates only, not every clock dependence
// (a relative date near a cutoff, a timer, DateTime.now() used directly). The
// allowlist makes each fixed date an explicit, reviewed decision.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Test file (relative to `test/`, '/'-separated) -> why its fixed dates can
/// never be compared with the real clock.
const Map<String, String> _allowlist = {
  'core/feature_flags/service_feature_gate_test.dart':
      'the gate gets an injected now; the fixed date is only advanced by '
      'Duration adds and compared with itself',
  'core/storage/account_export_schema_test.dart':
      'the dates are stored in an in-memory database and read back; '
      'savedExport has no clock comparison',
  'features/account/presentation/bloc/data_export_cubit_test.dart':
      'the cubit gets clock: () => now; every comparison is between fixed '
      'values',
  'features/account/presentation/delete_account_screen_test.dart':
      'DateTime(2026) is only the mocked deleteAccount result; nothing in '
      'the delete flow compares it with DateTime.now()',
  'features/media/data/media_uploader_test.dart':
      'MediaUploader gets clock: () => now; upload expiry is compared only '
      'with that clock',
  'features/onboarding/presentation/bloc/onboarding_bloc_test.dart':
      'cachedAt is data on a mocked repository result; the bloc never '
      'compares it with the clock',
  'features/posts/domain/posts_feature_gate_test.dart':
      'the gate gets an injected now; the fixed date is only advanced by '
      'Duration adds and compared with itself',
  'features/posts/presentation/bloc/composer_cubit_test.dart':
      'the cubit gets clock: () => fixed; nothing else in the test reads the '
      'real clock',
  'features/posts/presentation/bloc/composer_quote_cubit_test.dart':
      'the cubit gets clock: () => fixed; nothing else in the test reads the '
      'real clock',
  'features/profile/presentation/bloc/profile_edit_cubits_test.dart':
      'the cubit gets clock: () => now; every comparison is between fixed '
      'values',
  'features/profile/presentation/profile_header_data_test.dart':
      'the created time is only formatted into "Joined March 2026"; nothing '
      'compares it with the real clock',
  'features/profile/presentation/profile_sticky_tabs_test.dart':
      'the created time is only formatted into "Joined March 2026"; nothing '
      'compares it with the real clock',
  'guards/fixed_date_guard_test.dart':
      'the dates are sample strings for the scanner tests, never evaluated',
  'features/shells/shells_copy_guard_test.dart':
      'the date is a sample string the copy guard must reject, matched by a '
      'regex and never parsed or compared with the clock',
  'shared/format/joined_date_test.dart':
      'the dates are only formatted to a month name; the real clock is not '
      'read',
  'shared/format/relative_time_test.dart':
      'now is a parameter of every formatter call; the real clock is not '
      'read',
  'shared/widgets/pending_posts_section_test.dart':
      'createdAt and the row\'s now are both fixed and passed in; the real '
      'clock is not read',
  'shared/widgets/post_card_engagement_test.dart':
      'every PostCard (and, through it, every embedded card) gets '
      'now: _now',
  'shared/widgets/post_card_repost_actions_test.dart':
      'every PostCard (and, through it, every embedded card) gets '
      'now: _now',
  'shared/widgets/post_card_test.dart':
      'every PostCard (and, through it, every embedded card) gets '
      'now: _now',
};

const String _rule =
    'A fixed date in a test must never be compared with the real clock: '
    'inject `now`, or build the date relative to DateTime.now(). If it is '
    'genuinely safe, add the file to the allowlist in '
    'test/guards/fixed_date_guard_test.dart with the reason.';

/// One fixed absolute date found in a source file.
class FixedDateHit {
  const FixedDateHit(this.line, this.text);

  final int line;
  final String text;

  @override
  String toString() => 'line $line: $text';
}

// A 4-digit year literal as the first DateTime constructor argument.
final RegExp _yearConstructor = RegExp(
  r'DateTime(?:\.utc)?\(\s*(?:19|20)\d\d\b',
);
// DateTime.parse / tryParse of an ISO date.
final RegExp _isoParse = RegExp(
  r'''DateTime\.(?:try)?[Pp]arse\(\s*['"]\s*\d{4}-\d{2}-\d{2}''',
);
// A string literal that is an ISO date or date-time: '2026-10-14', '2026-10-14T12:00Z'.
final RegExp _isoLiteral = RegExp(
  r'''['"]\d{4}-\d{2}-\d{2}(?:[T ][^'"]*)?['"]''',
);
// Epoch literals.
final RegExp _epoch = RegExp(
  r'(?:fromMillisecondsSinceEpoch\(\s*\d{9,}|fromMicrosecondsSinceEpoch\(\s*\d{12,}|seconds:\s*(?:Int64\(\s*)?\d{9,})',
);

/// Blanks `//` comments (keeping offsets and newlines) so commented-out or
/// documented dates are not reported. `://` (URLs) is left alone.
String _blankLineComments(String source) => source.replaceAllMapped(
  RegExp(r'(?<!:)//[^\n]*'),
  (m) => ' ' * m[0]!.length,
);

/// The fixed absolute dates in [source] (empty when there are none).
List<FixedDateHit> findFixedDates(String source) {
  final code = _blankLineComments(source);
  final lines = source.split('\n');
  final seen = <int>{};
  final hits = <FixedDateHit>[];
  for (final re in [_yearConstructor, _isoParse, _isoLiteral, _epoch]) {
    for (final m in re.allMatches(code)) {
      final line = '\n'.allMatches(code.substring(0, m.start)).length + 1;
      if (seen.add(line * 100000 + m.start)) {
        hits.add(FixedDateHit(line, lines[line - 1].trim()));
      }
    }
  }
  hits.sort((a, b) => a.line.compareTo(b.line));
  return hits;
}

/// Every `*.dart` under `test/` (the working directory of `flutter test` is
/// the package root), keyed by its '/'-separated path relative to `test/`.
Map<String, List<FixedDateHit>> _scanTestTree() {
  final root = Directory('test');
  if (!root.existsSync()) {
    fail('run this test from the app/ directory (no test/ folder here)');
  }
  final result = <String, List<FixedDateHit>>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final normalized = entity.path.replaceAll('\\', '/');
    final rel = normalized.substring(normalized.indexOf('test/') + 5);
    result[rel] = findFixedDates(entity.readAsStringSync());
  }
  return result;
}

void main() {
  group('scanner', () {
    test('flags fixed absolute dates', () {
      const flagged = [
        'DateTime(2026, 10, 14)',
        'DateTime.utc(2026, 10, 14, 12)',
        'DateTime.utc(\n  2026,\n  10,\n)',
        'DateTime( 1999 )',
        'DateTime(2026)',
        "DateTime.parse('2026-10-14')",
        'DateTime.tryParse("2026-10-14T12:00:00Z")',
        "final s = '2026-10-14';",
        "final s = '2026-10-14T12:00:00Z';",
        'DateTime.fromMillisecondsSinceEpoch(1760443200000)',
        'Timestamp(seconds: Int64(1760443200))',
        'Timestamp(seconds: 1760443200)',
      ];
      for (final source in flagged) {
        expect(findFixedDates(source), isNotEmpty, reason: source);
      }
    });

    test('ignores relative dates and non-literal years', () {
      const clean = [
        'DateTime.now().subtract(const Duration(days: 3))',
        'final base = DateTime.now().toUtc();',
        'const Duration(minutes: 5)',
        'DateTime.utc(year, 1, 1)',
        'DateTime(base.year, base.month)',
        'DateTime.fromMillisecondsSinceEpoch(ms)',
        'Timestamp(seconds: Int64(5))',
        "test('amendment 2026-10-18 stays', () {});",
        '// DateTime.utc(2026, 10, 14) in a comment',
        "final u = 'https://example.com/a';",
      ];
      for (final source in clean) {
        expect(findFixedDates(source), isEmpty, reason: source);
      }
    });

    test('reports the line and the text', () {
      final hits = findFixedDates(
        'void f() {\n  final d = DateTime(2026, 1, 1);\n}',
      );
      expect(hits, hasLength(1));
      expect(hits.single.line, 2);
      expect(hits.single.text, 'final d = DateTime(2026, 1, 1);');
    });
  });

  group('fixed dates in tests', () {
    final scan = _scanTestTree();

    test('every file with a fixed date is allowlisted', () {
      final problems = <String>[];
      scan.forEach((file, hits) {
        if (hits.isNotEmpty && !_allowlist.containsKey(file)) {
          problems.add(
            'test/$file has a fixed date:\n    ${hits.join('\n    ')}',
          );
        }
      });
      expect(problems, isEmpty, reason: '${problems.join('\n')}\n$_rule');
    });

    test('no allowlist entry is stale', () {
      final stale = <String>[];
      _allowlist.forEach((file, _) {
        final hits = scan[file];
        if (hits == null) {
          stale.add('test/$file no longer exists: remove the stale entry');
        } else if (hits.isEmpty) {
          stale.add(
            'test/$file no longer contains a fixed date: remove the stale '
            'entry',
          );
        }
      });
      expect(stale, isEmpty, reason: stale.join('\n'));
    });

    test('every allowlist reason is filled in', () {
      final empty = [
        for (final e in _allowlist.entries)
          if (e.value.trim().isEmpty) 'test/${e.key}: the reason is empty',
      ];
      expect(empty, isEmpty, reason: '${empty.join('\n')}\n$_rule');
    });
  });
}
