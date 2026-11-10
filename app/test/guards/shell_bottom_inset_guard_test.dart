// Guard for the floating bottom bar (`ui_shell`, PR 3.2): the bar floats over
// the page and reports its height as the bottom padding of the MediaQuery.
// ListView, GridView and SafeArea read that padding; a CustomScrollView does
// not, so its last rows end under the bar and the bar takes their taps.
//
// Rule 1: every `CustomScrollView(` in lib/features and lib/shared ends its
// slivers with `ShellBottomInsetSliver()` (zero tall wherever the padding is
// already taken, so legacy and wide layouts are unchanged). A scroll view
// that never sits under the shell's bar is listed in [_exempt] with the reason.
//
// Rule 2: in the file of each screen the ShellRoute builds, a `ListView` or
// `GridView` with its own `padding:` (which replaces the MediaQuery padding),
// and any `SingleChildScrollView` (which never reads it), adds
// `MediaQuery.paddingOf(context).bottom` to its padding, unless the file has
// a `SafeArea`. Exceptions go in [_boxExempt] with the reason.
//
// Limits of rule 2 (it cannot be exact from the source text alone):
// - It scans only the file that declares a shell screen class. A list built
//   by a widget in another file (a shared row list, a tab body) is not seen.
// - Any `SafeArea(` in the file counts, even one that does not wrap the
//   scroll view (or sets `bottom: false`).
// - Dialogs, sheets and menus in a screen file sit above the shell and never
//   under the bar, but the text cannot tell them from the page, so they are
//   exempted by hand.
// - A padding that reads the inset through a variable is not recognised; it
//   must name `paddingOf` in the argument.
//
// Rule 3: a screen the ShellRoute builds that a root route (outside the
// shell, no bar) also builds must drop the bottom inset there with
// `MediaQuery.removePadding(removeBottom: true)`, or the page would add the
// device's home indicator in both chromes. Checked for screen classes named
// in app_router.dart. Not checked: a shell widget (a feed, a list) embedded
// in a root-route screen of another name; today none is (the root routes
// that scroll are the three in [_exempt]).
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

/// The index just past the string literal or line comment at [i] of
/// [source], or null when there is none at [i].
int? _skip(String source, int i) {
  if (source.startsWith('//', i)) {
    final end = source.indexOf('\n', i);
    return end < 0 ? source.length : end;
  }
  final c = source[i];
  if (c != '"' && c != "'") return null;
  final quote = source.startsWith(c * 3, i) ? c * 3 : c;
  var j = i + quote.length;
  while (j < source.length && !source.startsWith(quote, j)) {
    j += source[j] == r'\' ? 2 : 1;
  }
  return j + quote.length;
}

/// The source of the top-level [name] argument of [call] (the text from a
/// call's `(` to its `)`), or null when the call does not pass it.
String? _topLevelArg(String call, String name) {
  var depth = 0;
  var i = 0;
  while (i < call.length) {
    final skipped = _skip(call, i);
    if (skipped != null) {
      i = skipped;
      continue;
    }
    final c = call[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
    } else if (depth == 1 &&
        call.startsWith('$name:', i) &&
        !RegExp(r'\w').hasMatch(call[i - 1])) {
      // The argument runs to the next comma at this depth or the end.
      var j = i + name.length + 1;
      var inner = 0;
      while (j < call.length) {
        final s = _skip(call, j);
        if (s != null) {
          j = s;
          continue;
        }
        final d = call[j];
        if ('([{'.contains(d)) inner++;
        if (')]}'.contains(d)) {
          if (inner == 0) break;
          inner--;
        }
        if (d == ',' && inner == 0) break;
        j++;
      }
      return call.substring(i, j);
    }
    i++;
  }
  return null;
}

/// Box scroll views: `ListView` and `GridView` read the MediaQuery padding
/// only when they get no `padding:` of their own; `SingleChildScrollView`
/// never does.
final _boxScroll = RegExp(
  r'\b(?:ListView|GridView)(?:\.\w+)?\(|\bSingleChildScrollView\(',
);

/// The box scroll views of [source] that end under the floating bar, as
/// (offset, kind): an explicit `padding:` (any, for a
/// `SingleChildScrollView`) that does not add
/// `MediaQuery.paddingOf(context).bottom`.
List<(int, String)> _boxMissingInset(String source) => [
  for (final match in _boxScroll.allMatches(source))
    if (!_inComment(source, match.start) &&
        _boxNeedsInset(
          match.group(0)!,
          source.substring(match.end - 1, _closing(source, match.end - 1)),
        ))
      (match.start, RegExp(r'^\w+').firstMatch(match.group(0)!)!.group(0)!),
];

bool _inComment(String source, int offset) {
  final lineStart = source.lastIndexOf('\n', offset) + 1;
  return source.substring(lineStart, offset).contains('//');
}

bool _boxNeedsInset(String name, String call) {
  final padding = _topLevelArg(call, 'padding');
  if (padding != null && padding.contains('paddingOf')) return false;
  return name.startsWith('SingleChildScrollView') || padding != null;
}

/// `class XScreen extends` name -> file (relative to `lib/`).
Map<String, String> _screenFiles() => {
  for (final file in _sources())
    for (final m in RegExp(
      r'^class (\w+Screen) extends',
      multiLine: true,
    ).allMatches(file.readAsStringSync()))
      m.group(1)!: _relative(file),
};

/// The source of the `ShellRoute(...)` of the router.
String _shellRouteSource() {
  final router = File('lib/core/router/app_router.dart').readAsStringSync();
  final start = router.indexOf('ShellRoute(');
  expect(start, greaterThan(0));
  return router.substring(start, _closing(router, start + 10));
}

/// `'<file relative to lib/> <ListView|GridView|SingleChildScrollView>'` ->
/// why that kind of box scroll view in that shell screen file never sits
/// under the bar. Keyed by kind so the file's other scroll views stay
/// checked.
const Map<String, String> _boxExempt = {
  'features/account/presentation/delete_account_screen.dart '
          'SingleChildScrollView':
      'the password dialog, a modal route above the shell (no bar under '
      'it); the page ListView is checked and adds the inset',
};

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

  test('every ListView, GridView and SingleChildScrollView of a shell screen '
      'without a SafeArea keeps clear of the bar', () {
    final shell = _shellRouteSource();
    final files = _screenFiles();
    final shellFiles = <String>{
      for (final m in RegExp(r'\b(\w+Screen)\(').allMatches(shell))
        ?files[m.group(1)!],
    };
    expect(
      shellFiles,
      containsAll([
        'features/settings/presentation/settings_screen.dart',
        'features/account/presentation/delete_account_screen.dart',
      ]),
    );
    final offenders = <String>[];
    var scanned = 0;
    for (final path in shellFiles) {
      final source = File('lib/$path').readAsStringSync();
      // A SafeArea in the file takes the inset (see the limits above).
      if (source.contains('SafeArea(')) continue;
      scanned++;
      for (final (offset, kind) in _boxMissingInset(source)) {
        if (_boxExempt.containsKey('$path $kind')) continue;
        offenders.add('lib/$path:${_line(source, offset)} ($kind)');
      }
    }
    expect(scanned, greaterThan(3), reason: 'the scan found shell files');
    expect(
      offenders,
      isEmpty,
      reason:
          'add MediaQuery.paddingOf(context).bottom to the bottom padding (0 '
          'under the docked bar), wrap the page in a SafeArea, or list the '
          'scroll view in _boxExempt with the reason',
    );
  });

  test('a shell screen also routed outside the ShellRoute drops the bottom '
      'inset there', () {
    // The screen adds the bottom padding for the floating bar; a root route
    // has no bar, and there the padding is the device's home indicator. So
    // each such route must build it under MediaQuery.removePadding(
    // removeBottom: true).
    final router = File('lib/core/router/app_router.dart').readAsStringSync();
    final shellStart = router.indexOf('ShellRoute(');
    final shellEnd = _closing(router, shellStart + 10);
    final screen = RegExp(r'\b(\w+Screen)\(');
    final inShell = {
      for (final m in screen.allMatches(router.substring(shellStart, shellEnd)))
        m.group(1)!,
    };
    final offenders = <String>[];
    var shared = 0;
    for (final m in screen.allMatches(router)) {
      if (m.start >= shellStart && m.start < shellEnd) continue;
      if (_inComment(router, m.start) || !inShell.contains(m.group(1))) {
        continue;
      }
      shared++;
      // The innermost GoRoute( around the build.
      var route = router.lastIndexOf('GoRoute(', m.start);
      while (route >= 0 && _closing(router, route + 7) < m.start) {
        route = router.lastIndexOf('GoRoute(', route - 1);
      }
      final body = route < 0
          ? ''
          : router.substring(route, _closing(router, route + 7));
      if (!body.contains('removeBottom: true')) {
        offenders.add(
          '${m.group(1)} at app_router.dart:${_line(router, m.start)}',
        );
      }
    }
    expect(shared, greaterThan(0), reason: 'DeleteAccountScreen is one');
    expect(
      offenders,
      isEmpty,
      reason:
          'wrap the screen in MediaQuery.removePadding(context: context, '
          'removeBottom: true, child: ...) in its root route',
    );
  });

  test('every box exemption still names a flagged scroll view', () {
    for (final key in _boxExempt.keys) {
      final [path, kind] = key.split(' ');
      final source = File('lib/$path').readAsStringSync();
      expect(
        _boxMissingInset(source).any((hit) => hit.$2 == kind),
        isTrue,
        reason: 'stale box exemption: $key',
      );
    }
  });

  test('the box check tells an inset padding from a fixed one', () {
    const source = '''
Widget a() => ListView(padding: const EdgeInsets.all(16), children: []);
Widget b() => ListView(children: [Padding(padding: EdgeInsets.all(8))]);
Widget c() => ListView.builder(
  padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
  itemBuilder: (_, i) => Text('padding: ('),
);
Widget d() => SingleChildScrollView(child: Text('x'));
// ListView(padding: EdgeInsets.zero) in a comment is not a call site.
Widget e() => GridView.count(crossAxisCount: 2, padding: EdgeInsets.zero);
''';
    final hits = _boxMissingInset(source);
    expect(
      [for (final (offset, kind) in hits) (_line(source, offset), kind)],
      [(1, 'ListView'), (7, 'SingleChildScrollView'), (9, 'GridView')],
    );
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
