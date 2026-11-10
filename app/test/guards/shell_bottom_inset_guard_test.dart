// Guard for the floating bottom bar (`ui_shell`, PR 3.2): the bar floats over
// the page and reports its height as the bottom padding of the MediaQuery.
// ListView, GridView and SafeArea read that padding; a CustomScrollView does
// not, so its last rows end under the bar and the bar takes their taps.
//
// The rule: every `CustomScrollView(` in lib/features and lib/shared ends its
// slivers with `ShellBottomInsetSliver()` (zero tall wherever the padding is
// already taken, so legacy and wide layouts are unchanged). A scroll view
// that never sits under the shell's bar is listed in [_exempt] with the reason.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source file (relative to `lib/`, '/'-separated) -> why its scroll views
/// never sit under the shell's bottom bar.
const Map<String, String> _exempt = {
  'features/messages/presentation/thread_screen.dart':
      'a conversation is a root route outside the ShellRoute (after it on '
      'purpose, see AppRouter.messagesPath); no bottom bar',
  'features/posts/presentation/drafts_screen.dart':
      '/drafts is a root-level full-screen route like /compose; no bottom bar',
  'features/posts/presentation/scheduled_posts_screen.dart':
      '/scheduled is a root-level full-screen route like /compose; no bottom '
      'bar',
};

const _helper = 'ShellBottomInsetSliver(';
const _call = 'CustomScrollView(';

/// The index of the bracket that closes the one at [open] in [source],
/// skipping string literals and line comments.
int _closing(String source, int open) {
  final opener = source[open];
  final closer = switch (opener) {
    '(' => ')',
    '[' => ']',
    _ => throw ArgumentError(opener),
  };
  var depth = 0;
  var i = open;
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      i = end < 0 ? source.length : end;
      continue;
    }
    final c = source[i];
    if (c == '"' || c == "'") {
      final triple = source.startsWith(c * 3, i);
      final quote = triple ? c * 3 : c;
      var j = i + quote.length;
      while (j < source.length && !source.startsWith(quote, j)) {
        j += source[j] == r'\' ? 2 : 1;
      }
      i = j + quote.length;
      continue;
    }
    if (c == opener) depth++;
    if (c == closer) {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  throw StateError('unbalanced $opener at $open');
}

/// 1-based line of [offset] in [source].
int _line(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

Iterable<File> _sources() sync* {
  for (final root in ['lib/features', 'lib/shared']) {
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.endsWith('.g.dart') || path.endsWith('.freezed.dart')) continue;
      yield entity;
    }
  }
}

/// Offsets of the `CustomScrollView(` calls in [source] whose slivers do not
/// include the helper.
List<int> _missingHelper(String source) => [
  for (final match in _callSites(source))
    if (!_hasHelper(
      source.substring(match.end - 1, _closing(source, match.end - 1)),
    ))
      match.start,
];

/// The `CustomScrollView(` matches of [source] outside line comments.
Iterable<Match> _callSites(String source) =>
    _call.allMatches(source).where((match) {
      final lineStart = source.lastIndexOf('\n', match.start) + 1;
      return !source.substring(lineStart, match.start).contains('//');
    });

bool _hasHelper(String call) {
  final slivers = call.indexOf('slivers:');
  // In this call's slivers (nested scroll views are checked on their own).
  return slivers >= 0 && call.substring(slivers).contains(_helper);
}

String _relative(File file) =>
    file.path.replaceAll(r'\', '/').replaceFirst(RegExp('^lib/'), '');

void main() {
  test('every CustomScrollView of a shell screen ends with '
      'ShellBottomInsetSliver', () {
    final offenders = <String>[];
    var checked = 0;
    for (final file in _sources()) {
      final path = _relative(file);
      if (_exempt.containsKey(path)) continue;
      final source = file.readAsStringSync();
      checked += _callSites(source).length;
      for (final offset in _missingHelper(source)) {
        offenders.add('lib/$path:${_line(source, offset)}');
      }
    }
    expect(checked, greaterThan(10), reason: 'the scan found the call sites');
    expect(
      offenders,
      isEmpty,
      reason:
          'end the slivers with `const ShellBottomInsetSliver()` (see '
          'lib/core/widgets/shell_bottom_inset_sliver.dart), or, for a screen '
          'outside the ShellRoute, list it in _exempt with the reason',
    );
  });

  test('every exemption is still a CustomScrollView outside the shell', () {
    final router = File('lib/core/router/app_router.dart').readAsStringSync();
    final shellStart = router.indexOf('ShellRoute(');
    expect(shellStart, greaterThan(0));
    final shell = router.substring(
      shellStart,
      _closing(router, shellStart + 10),
    );
    for (final path in _exempt.keys) {
      final file = File('lib/$path');
      expect(file.existsSync(), isTrue, reason: path);
      final source = file.readAsStringSync();
      expect(source.contains(_call), isTrue, reason: 'stale exemption: $path');
      // The screen class the file declares is not built inside the shell.
      final screens = RegExp(
        r'^class (\w+Screen) extends',
        multiLine: true,
      ).allMatches(source).map((m) => m.group(1)!);
      for (final screen in screens) {
        expect(
          RegExp(
            r'\b'
            '$screen'
            r'\(',
          ).hasMatch(shell),
          isFalse,
          reason: '$screen is built inside the ShellRoute: drop the exemption',
        );
      }
    }
  });

  test('the scan tells a call site with the helper from one without', () {
    const source = '''
Widget a() => CustomScrollView(
  slivers: [SliverList.builder(itemBuilder: (_, i) => Text('(')), ],
);
// CustomScrollView( in a comment is not a call site.
Widget b() => CustomScrollView(
  key: const Key(']'),
  slivers: [const SliverToBoxAdapter(), const ShellBottomInsetSliver()],
);
Widget c() => CustomScrollView(slivers: slivers);
''';
    final missing = _missingHelper(source);
    expect(missing.map((o) => _line(source, o)), [1, 9]);
  });
}
