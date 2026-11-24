// Pure scanners behind `vault_guard_test.dart` and `pipeline_guard_test.dart`.
// They take source text and return findings, so the guard tests can prove each
// rule on a small violating string (a built-in mutation check) as well as on
// the real tree.

import 'telemetry_scan.dart' show readTree;

Map<String, String>? _libCache;

/// Every `.dart` file under lib/ (run from app/), read once per test run.
Map<String, String> libFiles() => _libCache ??= readTree('lib', {'.dart'});

/// Files under lib/ in the generated trees.
bool isGeneratedPath(String path) =>
    path.startsWith('lib/gen/') ||
    path.startsWith('lib/core/crypto/frb_generated/') ||
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart');

/// lib/ outside the generated trees.
Map<String, String> handWrittenLib() => {
  for (final e in libFiles().entries)
    if (!isGeneratedPath(e.key)) e.key: e.value,
};

const String pipelineDir = 'lib/features/messages/domain/e2ee/';

/// The message pipeline: every file under [pipelineDir], so a file a later
/// task adds (13b's port implementation) is covered without a list change.
bool inPipeline(String path) =>
    path.startsWith(pipelineDir) && !isGeneratedPath(path);

Map<String, String> pipelineFiles() => {
  for (final e in libFiles().entries)
    if (inPipeline(e.key)) e.key: e.value,
};

/// [source] with comments removed. With [keepStrings] false the CONTENT of
/// string literals is dropped too (the quotes stay, and the code inside `$x` /
/// `${...}` interpolations is kept, because that is code). Handles raw
/// strings, triple quotes and nested block comments.
String stripSource(String source, {required bool keepStrings}) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;
  String at(int k) => k < n ? source[k] : '';
  while (i < n) {
    final c = source[i];
    if (c == '/' && at(i + 1) == '/') {
      while (i < n && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && at(i + 1) == '*') {
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (source[i] == '/' && at(i + 1) == '*') {
          depth++;
          i += 2;
        } else if (source[i] == '*' && at(i + 1) == '/') {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      out.write(' ');
      continue;
    }
    if (c == "'" || c == '"') {
      final raw = i > 0 && source[i - 1] == 'r' && !_isIdentChar(at(i - 2));
      final triple = at(i + 1) == c && at(i + 2) == c;
      final q = triple ? c * 3 : c;
      out.write(q);
      i += q.length;
      while (i < n) {
        if (source.startsWith(q, i)) {
          out.write(q);
          i += q.length;
          break;
        }
        if (!raw && source[i] == r'\') {
          if (keepStrings) {
            out.write(source.substring(i, i + 2 > n ? n : i + 2));
          }
          i += 2;
          continue;
        }
        if (!raw && source[i] == r'$' && at(i + 1) == '{') {
          var depth = 1;
          var j = i + 2;
          while (j < n && depth > 0) {
            if (source[j] == '{') depth++;
            if (source[j] == '}') depth--;
            j++;
          }
          final code = source.substring(i + 2, j - 1 < i + 2 ? i + 2 : j - 1);
          out.write(keepStrings ? source.substring(i, j) : ' $code ');
          i = j;
          continue;
        }
        if (!raw &&
            source[i] == r'$' &&
            RegExp(r'[A-Za-z_]').hasMatch(at(i + 1))) {
          var j = i + 1;
          while (j < n && _isIdentChar(source[j])) {
            j++;
          }
          out.write(
            keepStrings
                ? source.substring(i, j)
                : ' ${source.substring(i + 1, j)} ',
          );
          i = j;
          continue;
        }
        if (keepStrings) out.write(source[i]);
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

bool _isIdentChar(String c) =>
    c.isNotEmpty && RegExp(r'[A-Za-z0-9_$]').hasMatch(c);

const String vaultDir = 'lib/core/vault/';

/// Every URI the `import`/`export` directives of [source] (living at [path],
/// '/'-separated, relative to app/) can select: an in-package one resolved to
/// `lib/...` (relative or `package:dzeroth/`), any other (`package:drift/`,
/// `dart:io`) as written. Whole directives are read up to `;`, so a
/// conditional import that spans lines is seen with every URI it can select.
List<String> importTargets(String path, String source) {
  final text = stripSource(source, keepStrings: true);
  final found = <String>[];
  for (final d in RegExp(r'\b(?:import|export)\s[^;]*;').allMatches(text)) {
    for (final u in RegExp(r'''['"]([^'"]+)['"]''').allMatches(d.group(0)!)) {
      final uri = u.group(1)!;
      if (uri.startsWith('package:dzeroth/')) {
        found.add('lib/${uri.substring('package:dzeroth/'.length)}');
      } else if (uri.contains(':')) {
        found.add(uri);
      } else {
        found.add(Uri.parse(path).resolve(uri).path);
      }
    }
  }
  return found;
}

/// The files `import`/`export` directives of [source] (living at [path])
/// point into `lib/core/vault/`, as base names.
List<String> vaultImports(String path, String source) => [
  for (final t in importTargets(path, source))
    if (t.startsWith(vaultDir)) t.substring(vaultDir.length),
];

/// Vault files that [path] (outside the vault layer) imports but may not.
List<String> importViolations(
  String path,
  String source, {
  required Set<String> defaultAllowed,
  required Map<String, Set<String>> extraAllowed,
}) {
  final allowed = {...defaultAllowed, ...?extraAllowed[path]};
  return [
    for (final f in vaultImports(path, source))
      if (!allowed.contains(f)) f,
  ];
}

final RegExp _destructive = RegExp(
  r'\b(?:wipeVault\w*|deleteVaultKey\w*)\b|\.\s*(?:wipe|destroy)\b',
);

/// [source] with each of [snippets] (exact, whitespace-insensitive) removed.
String withoutSnippets(String source, List<String> snippets) =>
    _removeSnippets(source, snippets);

/// Exact fragments (whitespace-insensitive) removed from [text].
String _removeSnippets(String text, List<String> snippets) {
  for (final s in snippets) {
    final pattern = s
        .trim()
        .split(RegExp(r'\s+'))
        .map(RegExp.escape)
        .join(r'\s*');
    text = text.replaceAll(RegExp(pattern), ' ');
  }
  return text;
}

/// Member references (`x.name`, `x?.name`, `..name`: calls and tear-offs) to
/// any of [names] in [source], comments and string contents ignored, after
/// removing [exemptSnippets] (exact, whitespace-insensitive).
List<String> memberReferences(
  String source,
  Set<String> names, {
  List<String> exemptSnippets = const [],
}) {
  if (names.isEmpty) return const [];
  final text = _removeSnippets(
    stripSource(source, keepStrings: false),
    exemptSnippets,
  );
  final pattern = RegExp(
    r'\.\s*(' + names.map(RegExp.escape).join('|') + r')\b',
  );
  return [for (final m in pattern.allMatches(text)) m.group(1)!];
}

/// Every `=` / `??=` applied to any of [names] in [source] (plain, prefixed
/// `lib.name`, cascade `..name`, after `if (...)`, `else`, `case`, `return`
/// ...), comments and strings ignored. A declaration's initializer
/// (`bool name = false;`) is counted too: whatever precedes the name is not
/// classified, so the caller pins the allowed declarations by file and
/// count. `==`, `=>`, `!=`, `<=`, `>=` are not assignments.
List<String> assignmentsTo(String source, Set<String> names) {
  if (names.isEmpty) return const [];
  final text = stripSource(source, keepStrings: false);
  final alt = names.map(RegExp.escape).join('|');
  final pattern = RegExp(
    r'(?<![\w$])(' + alt + r')\s*(?:\?\?=|[|&^]=|=(?![=>]))',
  );
  // Record / pattern destructuring: `(debugX, _) = (true, 0);` (one level of
  // parentheses; `(...) =>` and `(...) ==` are not assignments).
  final destructuring = RegExp(
    r'\([^()]*(?<![\w$])(' + alt + r')(?![\w$])[^()]*\)\s*=(?![=>])',
  );
  return [
    for (final m in pattern.allMatches(text)) m.group(1)!,
    for (final m in destructuring.allMatches(text)) m.group(1)!,
  ];
}

/// References (calls AND tear-offs) to the destructive vault operations in
/// [source]. Comments and string contents are ignored. [exemptSnippets] are
/// exact wiring fragments (whitespace-insensitive) removed first.
List<String> destructiveReferences(
  String source, {
  List<String> exemptSnippets = const [],
}) {
  final text = _removeSnippets(
    stripSource(source, keepStrings: false),
    exemptSnippets,
  );
  return [for (final m in _destructive.allMatches(text)) m.group(0)!.trim()];
}

/// Name fragments (lower case) that make an identifier suspect in a log or
/// error-report argument list.
const List<String> sensitiveFragments = [
  'state',
  'key',
  'plaintext',
  'content',
  'sealed',
  'ciphertext',
  'deviceid',
  'uid',
  // The MLS message layer: commits, welcomes, pending state, init keys,
  // digests, report payloads.
  'commit',
  'welcome',
  'pending',
  'init',
  'digest',
  'payload',
  'reportkey', // named by the plan; 'key' above already flags every such name
  // The message pipeline (plan 5a Task 15). `text` also flags `context`: a
  // log or report names neither.
  'text',
  'sharedpostid',
  'conversationid',
  'messageid',
  'peeruserid',
  'signaturekey', // 'key' above already flags it; named by the plan
  'keypackage', // 'key' above already flags it; named by the plan
];

final RegExp _printCall = RegExp(r'(?<![\w$.])(?:debugPrint|print)\s*\(');

/// Calls that write somewhere: the error reporters (the app-level
/// `reportUnexpectedError`, and the injected `onUnexpectedError` the vault
/// session and the device-keys service reach through their private
/// `_report` / `_onUnexpectedError?.call`, the pipeline through its
/// `_reportIfBug` / `_reportBug`: any `_report...`, and any
/// `report...Error`), every logger (`package:logging` and `package:logger`
/// levels on any variable whose name ends in log / logger, `Logger.root`,
/// `Logger('x')`), `dart:developer`'s `log(`, `FlutterError.reportError` /
/// `dumpErrorToConsole`, and Crashlytics (`recordError`,
/// `recordFlutterError`, a `FirebaseCrashlytics` call).
final RegExp _sink = RegExp(
  r'(?<![\w$])(?:reportUnexpectedError|_report\w*|report\w*Error|log'
  r'|_?onUnexpectedError\s*\??\s*\.\s*call'
  r'|\w*(?:log|Log|logger|Logger)\s*\??\s*\.\s*(?:finest|finer|fine|config|info|warning|severe|shout|log|[tdiwef]|wtf)'
  r'|Logger\s*\.\s*root\s*\.\s*\w+'
  r'|Logger\s*\([^)]*\)\s*\.\s*\w+'
  r'|FlutterError\s*\.\s*(?:reportError|dumpErrorToConsole)'
  r'|FirebaseCrashlytics(?:\s*\.\s*instance)?\s*\.\s*\w+'
  r'|\w*\s*\.\s*record(?:Flutter)?Error)\s*\(',
);

/// Findings in [source]: `print(`/`debugPrint(` anywhere, and a sink call
/// whose argument list mentions a lower-case-initial identifier (a variable,
/// field or member, not a type) containing a [sensitiveFragments] entry.
/// Type names such as `DeviceKeysError` or `VaultKeyException` are exempt on
/// purpose: they name a class, not a value. String literal text is ignored
/// (`'keyMismatch'` is a step name) but interpolations inside it are read.
List<String> loggingViolations(String source) {
  final text = stripSource(source, keepStrings: false);
  final bad = <String>[];
  for (final m in _printCall.allMatches(text)) {
    bad.add(m.group(0)!.trim());
  }
  final loggerNames = _loggerVariableNames(text);
  final sinks = [
    ..._sink.allMatches(text),
    if (loggerNames.isNotEmpty)
      ...RegExp(
        r'(?<![\w$.])(?:' +
            loggerNames.map(RegExp.escape).join('|') +
            r')\s*\??\s*\.\s*\w+\s*\(',
      ).allMatches(text),
  ];
  for (final m in sinks) {
    final before = text.substring(0, m.start).trimRight();
    if (before.endsWith('void')) continue; // a declaration, not a call
    final args = _balanced(text, m.end - 1);
    for (final id in RegExp(r'[a-z_][A-Za-z0-9_]*').allMatches(args)) {
      final name = id.group(0)!;
      if (id.start > 0 && RegExp(r'[A-Z0-9]').hasMatch(args[id.start - 1])) {
        continue;
      }
      final lower = name.toLowerCase();
      if (sensitiveFragments.any(lower.contains)) {
        bad.add('${m.group(0)!.trim()} ... $name');
      }
    }
  }
  return bad;
}

/// Any variable holding a Logger, whatever its name (`final l = Logger(..)`,
/// `Logger audit`), is a sink too. [text] is comment- and string-stripped.
Set<String> _loggerVariableNames(String text) => {
  for (final m in RegExp(
    r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*=\s*Logger\s*[.(]',
  ).allMatches(text))
    m.group(1)!,
  for (final m in RegExp(
    r'(?<![\w$.])Logger\??\s+([A-Za-z_$][\w$]*)',
  ).allMatches(text))
    m.group(1)!,
};

/// Every call in [source] that writes somewhere, with its argument list text
/// (comments and string text removed, interpolated code kept): `print(` /
/// `debugPrint(`, every pattern of the sink regex above, and calls on any
/// variable holding a Logger. The same discovery [loggingViolations] uses,
/// without its name judgement, so a caller can judge the arguments by its own
/// rule. A declaration (`void log(`) is skipped.
List<({String call, String args})> sinkCalls(String source) {
  final text = stripSource(source, keepStrings: false);
  final loggerNames = _loggerVariableNames(text);
  final matches = [
    ..._printCall.allMatches(text),
    ..._sink.allMatches(text),
    if (loggerNames.isNotEmpty)
      ...RegExp(
        r'(?<![\w$.])(?:' +
            loggerNames.map(RegExp.escape).join('|') +
            r')\s*\??\s*\.\s*\w+\s*\(',
      ).allMatches(text),
  ];
  return [
    for (final m in matches)
      if (!text.substring(0, m.start).trimRight().endsWith('void'))
        (call: m.group(0)!.trim(), args: _balanced(text, m.end - 1)),
  ];
}

/// The text between the `(` at [open] and its matching `)`.
String _balanced(String text, int open) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '(') depth++;
    if (text[i] == ')') {
      depth--;
      if (depth == 0) return text.substring(open + 1, i);
    }
  }
  return text.substring(open + 1);
}

/// A `toString` declaration: with or without the `String` return type, an
/// `=>` or a `{` body (a call `x.toString()` or `toString();` is not one).
final RegExp toStringDeclaration = RegExp(
  r'(?<![\w$.])(?:String\s*\??\s+)?toString\s*\(\s*\)\s*(?:async\s*)?(?==>|\{)',
);

/// The type declarations that can own a member: class, mixin, enum,
/// extension type, and `class X = A with B;`.
final RegExp _typeHead = RegExp(
  r'\b(?:class|mixin|enum|extension\s+type)\s+(\w+)',
);

/// Every `toString` declared in [source] (with or without a return type), as
/// `Type` -> its body with whitespace collapsed (`=> ...;` or `{...}`). The
/// type is the nearest class / mixin / enum / extension type above it.
/// Comments are ignored, and so is anything inside a string literal.
Map<String, String> toStringDeclarations(String source) {
  final text = stripSource(source, keepStrings: true);
  final code = _maskStrings(text).code;
  final out = <String, String>{};
  final classes = _typeHead.allMatches(code).toList();
  for (final m in toStringDeclaration.allMatches(code)) {
    var owner = '?';
    for (final c in classes) {
      if (c.start < m.start) owner = c.group(1)!;
    }
    String body;
    if (code.startsWith('=>', m.end)) {
      final semi = code.indexOf(';', m.end);
      body = text.substring(m.end, semi + 1);
    } else {
      var depth = 0;
      var j = m.end;
      for (; j < code.length; j++) {
        if (code[j] == '{') depth++;
        if (code[j] == '}') {
          depth--;
          if (depth == 0) break;
        }
      }
      body = text.substring(m.end, j + 1);
    }
    out[owner] = body.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
  return out;
}

final RegExp _wideInts = RegExp(
  r'\b(?:setUint64|getUint64|setInt64|getInt64)\b',
);

/// `ByteData` 64-bit accessors in [source], comments and strings ignored. On
/// the web (dart2js) an `int` is a double: a 64-bit accessor silently loses
/// bits past 2^53, so wire and storage integers go through `Int64` or a
/// range-checked 53-bit value instead.
List<String> wideIntAccessors(String source) => [
  for (final m in _wideInts.allMatches(stripSource(source, keepStrings: false)))
    m.group(0)!,
];

/// The members of the `vaultTables` getter's list in [source] (a
/// `VaultDatabase`), in order; empty if the getter is absent.
List<String> vaultTableNames(String source) {
  final text = stripSource(source, keepStrings: false);
  final m = RegExp(r'\bvaultTables\s*=>\s*\[([^\]]*)\]').firstMatch(text);
  if (m == null) return const [];
  return [
    for (final id in RegExp(r'[A-Za-z_]\w*').allMatches(m.group(1)!))
      id.group(0)!,
  ];
}

/// The value of `const int kVaultSchemaVersion = N;` in [source], or null.
int? vaultSchemaVersion(String source) {
  final m = RegExp(r'\bconst\s+int\s+kVaultSchemaVersion\s*=\s*(\d+)\s*;')
      .firstMatch(stripSource(source, keepStrings: false));
  return m == null ? null : int.parse(m.group(1)!);
}

final RegExp _memory = RegExp(
  r'\b(?:kMessagesPerConversation|inMemoryExecutor|sessionMemoryExecutor'
  r'|keepingNothing)\b|NativeDatabase\s*\.\s*memory',
);

/// References to the cache's habits (a message cap, an in-memory database) in
/// [source], comments ignored.
List<String> cacheHabits(String source) => [
  for (final m in _memory.allMatches(stripSource(source, keepStrings: false)))
    m.group(0)!,
];

// ---------------------------------------------------------------------------
// The encrypted message pipeline (plan 5a Task 15).

/// Matches of [pattern] in the CODE of [source]: comments and string-literal
/// text removed (interpolated code kept), after removing [exemptSnippets]
/// (exact, whitespace-insensitive, in that stripped form).
List<String> codeMatches(
  String source,
  RegExp pattern, {
  List<String> exemptSnippets = const [],
}) {
  final text = _removeSnippets(
    stripSource(source, keepStrings: false),
    exemptSnippets,
  );
  return [for (final m in pattern.allMatches(text)) m.group(0)!.trim()];
}

/// [text] (comments already removed) with every string literal's text and
/// interpolations blanked to spaces (same length; quotes and newlines kept),
/// and the offsets where an interpolation (`$x`, `${...}`) starts in a
/// non-raw literal.
({String code, List<int> interpolations}) _maskStrings(String text) {
  final out = StringBuffer();
  final at = <int>[];
  final n = text.length;
  String ch(int k) => k < n ? text[k] : '';
  void blank(int from, int to) {
    for (var k = from; k < to && k < n; k++) {
      out.write(text[k] == '\n' ? '\n' : ' ');
    }
  }

  var i = 0;
  while (i < n) {
    final c = text[i];
    if (c != "'" && c != '"') {
      out.write(c);
      i++;
      continue;
    }
    final raw = i > 0 && text[i - 1] == 'r' && !_isIdentChar(ch(i - 2));
    final triple = ch(i + 1) == c && ch(i + 2) == c;
    final q = triple ? c * 3 : c;
    out.write(q);
    i += q.length;
    while (i < n) {
      if (text.startsWith(q, i)) {
        out.write(q);
        i += q.length;
        break;
      }
      if (!raw && text[i] == r'\') {
        blank(i, i + 2);
        i += 2;
        continue;
      }
      if (!raw && text[i] == r'$' && ch(i + 1) == '{') {
        at.add(i);
        var depth = 1;
        var j = i + 2;
        while (j < n && depth > 0) {
          if (text[j] == '{') depth++;
          if (text[j] == '}') depth--;
          j++;
        }
        blank(i, j);
        i = j;
        continue;
      }
      if (!raw && text[i] == r'$' && RegExp(r'[A-Za-z_]').hasMatch(ch(i + 1))) {
        at.add(i);
        var j = i + 1;
        while (j < n && _isIdentChar(text[j])) {
          j++;
        }
        blank(i, j);
        i = j;
        continue;
      }
      blank(i, i + 1);
      i++;
    }
  }
  return (code: out.toString(), interpolations: at);
}

/// The offset just past the `;` ending the expression that starts at [from]
/// in [code], or just before a closing bracket that ends an enclosing group.
int _expressionEnd(String code, int from) {
  var depth = 0;
  for (var i = from; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) return i;
      depth--;
    }
    if (c == ';' && depth == 0) return i + 1;
  }
  return code.length;
}

/// The offset just past the bracket matching the one at [open] in [code].
int _groupEnd(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return code.length;
}

/// An error or exception constructor call (`StateError(`, a bare `Error(` /
/// `Exception(`, a named one like `ArgumentError.value(`).
final RegExp _errorConstructor = RegExp(
  r'(?<![\w$.])(?:[A-Z][\w$]*)?(?:Error|Exception)(?:\s*\.\s*\w+)?\s*\(',
);

final RegExp _errorBuild = RegExp(
  r'\bthrow\b'
  r'|(?<![\w$.])(?:[A-Z][\w$]*)?(?:Error|Exception)(?:\s*\.\s*\w+)?\s*\('
  r'|\b(?:completeError|addError)\s*\('
  r'|\bFuture\s*(?:<[^()]*?>)?\s*\.\s*error\s*\(',
);

/// Error and exception messages in [source] built with an interpolation: a
/// `throw` expression (to its `;`), an `...Error(` / `...Exception(`
/// constructor call (bare and named ones too), `completeError(`,
/// `addError(` or `Future.error(` / `Future<T>.error(` whose text holds a
/// `$` interpolation in a string literal.
/// Comments are ignored, and so is a `$` in a `toString` body's literal
/// (that is not an error being built). [exemptSnippets] (exact,
/// whitespace-insensitive, in source form) are removed first.
List<String> interpolatedErrorMessages(
  String source, {
  List<String> exemptSnippets = const [],
}) {
  final text = _removeSnippets(
    stripSource(source, keepStrings: true),
    exemptSnippets,
  );
  final masked = _maskStrings(text);
  final code = masked.code;
  final bad = <String>[];
  for (final m in _errorBuild.allMatches(code)) {
    final end = m.group(0) == 'throw'
        ? _expressionEnd(code, m.end)
        : _groupEnd(code, m.end - 1);
    if (masked.interpolations.any((p) => p >= m.start && p < end)) {
      bad.add(
        text.substring(m.start, end).replaceAll(RegExp(r'\s+'), ' ').trim(),
      );
    }
  }
  return bad;
}

const Set<String> _notMemberNames = {
  'operator',
  'get',
  'set',
  'async',
  'sync',
  'return',
  'super',
  'this',
};

/// The public member names (methods, getters, setters, fields, static ones
/// too) declared in the body of `class [className]` in [source]; empty when
/// the class is absent. Read from the class body's top level only: bodies,
/// parameter lists, initializers and `=>` expressions are skipped.
Set<String> publicMembers(String source, String className) {
  final text = stripSource(source, keepStrings: false);
  final head = RegExp(r'\bclass\s+' + RegExp.escape(className) + r'\b[^{]*\{')
      .firstMatch(text);
  if (head == null) return const {};
  final top = StringBuffer();
  var last = '';
  void put(String c) {
    top.write(c);
    if (c.trim().isNotEmpty) last = c;
  }

  var depth = 0;
  var skipping = false;
  for (var i = head.end; i < text.length; i++) {
    final c = text[i];
    if (c == '(' || c == '[' || c == '{') {
      if (depth == 0 && !skipping) put(c);
      depth++;
      continue;
    }
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) break; // the class body's own `}`
      depth--;
      if (depth == 0) {
        if (skipping && c == '}') {
          skipping = false;
          put(';');
        } else if (!skipping) {
          put(c);
        }
      }
      continue;
    }
    if (depth > 0) continue;
    if (skipping) {
      if (c == ';') {
        skipping = false;
        put(';');
      }
      continue;
    }
    if (c == '=') {
      final next = i + 1 < text.length ? text[i + 1] : '';
      if (next == '=' || '!<>='.contains(last) && last.isNotEmpty) {
        put(c); // an operator declaration (`operator ==(`, `<=`)
        continue;
      }
      skipping = true; // `=> ...;` or `= initializer;`
      continue;
    }
    put(c);
  }
  final names = <String>{};
  final flat = top.toString();
  for (final m in RegExp(
    r'([A-Za-z_$][\w$]*)\s*(?:<[^;{}()]*>)?\s*(?:\(\)|;)'
    r'|\bget\s+([A-Za-z_$][\w$]*)\s*(?:async\s*\*?\s*|sync\s*\*\s*)?\{\}',
  ).allMatches(flat)) {
    final name = m.group(1) ?? m.group(2)!;
    // An annotation (`@pragma('x')`) is not a member.
    if (flat.substring(0, m.start).trimRight().endsWith('@')) continue;
    if (!RegExp(r'^[a-z]').hasMatch(name)) continue;
    if (_notMemberNames.contains(name)) continue;
    names.add(name);
  }
  return names;
}

/// Members referenced on a receiver named one of [receivers] in [source]
/// (`r.m`, `r?.m`, `r..m`, `r!.m`, across lines), also when the receiver is
/// itself reached through a chain (`_p._messaging.m`, `x.messaging.m`),
/// comments and strings ignored.
List<String> membersOn(String source, Set<String> receivers) {
  if (receivers.isEmpty) return const [];
  final alt = receivers.map(RegExp.escape).join('|');
  final pattern = RegExp(
    r'(?<![\w$])(?:' + alt + r')\s*!?\s*(?:\?\s*)?\.\.?\s*([A-Za-z_$][\w$]*)',
  );
  return [
    for (final m in pattern.allMatches(stripSource(source, keepStrings: false)))
      m.group(1)!,
  ];
}

/// The names declared with type [typeName] in [source] (fields, parameters,
/// locals, getters: `T name`, `T? name`, `T get name`), comments and strings
/// ignored.
List<String> namesTyped(String source, String typeName) => [
  for (final m in RegExp(
    r'(?<![\w$.])' +
        RegExp.escape(typeName) +
        r'\??\s+(?:get\s+)?([A-Za-z_$][\w$]*)',
  ).allMatches(stripSource(source, keepStrings: false)))
    m.group(1)!,
];

/// Constructions of the generated messaging `Message` (`pb.Message(`,
/// `pb.Message.create(`) in [source], under whatever prefix the file imports
/// `messaging.pb.dart` / `messaging.pbserver.dart` with (a file importing it
/// with no prefix is scanned for a bare `Message(`). Comments and string
/// text are ignored. An [exemptSnippets] entry (exact, whitespace-insensitive)
/// is removed only where `)` or `,` follows it, never before a cascade.
List<String> messageConstructions(
  String source, {
  List<String> exemptSnippets = const [],
}) {
  final prefixes = messagingPbPrefixes(source);
  var text = stripSource(source, keepStrings: false);
  for (final s in exemptSnippets) {
    final pattern = s
        .trim()
        .split(RegExp(r'\s+'))
        .map(RegExp.escape)
        .join(r'\s*');
    text = text.replaceAll(RegExp(pattern + r'(?=\s*[),])'), ' ');
  }
  final bad = <String>[];
  for (final p in prefixes) {
    final qualified = p.isEmpty ? '' : '${RegExp.escape(p)}\\s*\\.\\s*';
    final pattern = RegExp(
      r'(?<![\w$.])' + qualified + r'Message\s*(?:\.\s*create\s*)?\(',
    );
    bad.addAll([for (final m in pattern.allMatches(text)) m.group(0)!.trim()]);
  }
  return bad;
}

/// The prefixes [source] imports `messaging.pb.dart` /
/// `messaging.pbserver.dart` under ('' for no prefix); empty when it does
/// not import them.
Set<String> messagingPbPrefixes(String source) {
  final kept = stripSource(source, keepStrings: true);
  final prefixes = <String>{};
  for (final d in RegExp(r'\bimport\s[^;]*;').allMatches(kept)) {
    final directive = d.group(0)!;
    if (!RegExp(r'''['"][^'"]*messaging\.pb(?:server)?\.dart['"]''')
        .hasMatch(directive)) {
      continue;
    }
    final as = RegExp(r'\bas\s+(\w+)').firstMatch(directive);
    prefixes.add(as == null ? '' : as.group(1)!);
  }
  return prefixes;
}

/// Writes into a generated messaging message in [source], a file importing
/// `messaging.pb.dart` (empty for any other file): `.text =` / `..text =`
/// (not `this.text =`, a constructor default), `.snippet =` / `..snippet =`,
/// a `snippet:` argument that is not `''`, `.rebuild(`, and
/// `Message.fromBuffer(` / `Message.fromJson(`. Comments and string text are
/// ignored. Each finding is normalized (`..snippet =`, `pb.Message.fromBuffer(`).
List<String> pbMutations(String source) {
  final prefixes = messagingPbPrefixes(source);
  if (prefixes.isEmpty) return const [];
  final code = _maskStrings(stripSource(source, keepStrings: true)).code;
  final bad = <String>[];
  for (final m in RegExp(
    r'(\.\.?)\s*(text|snippet)\s*=(?![=>])',
  ).allMatches(code)) {
    final before = code.substring(0, m.start).trimRight();
    if (m.group(2) == 'text' &&
        m.group(1) == '.' &&
        RegExp(r'(?<![\w$])this$').hasMatch(before)) {
      continue;
    }
    bad.add('${m.group(1)}${m.group(2)} =');
  }
  for (final m in RegExp(r'(?<![\w$.])snippet\s*:\s*').allMatches(code)) {
    final rest = code.substring(m.end);
    if (RegExp(r'''^(?:''|"")\s*[,)]''').hasMatch(rest)) continue;
    bad.add('snippet:');
  }
  for (final _ in RegExp(r'\.\s*rebuild\s*\(').allMatches(code)) {
    bad.add('.rebuild(');
  }
  for (final p in prefixes) {
    final qualified = p.isEmpty ? '' : '${RegExp.escape(p)}\\s*\\.\\s*';
    for (final m in RegExp(
      r'(?<![\w$.])' + qualified + r'Message\s*\.\s*(fromBuffer|fromJson)\s*\(',
    ).allMatches(code)) {
      bad.add('${p.isEmpty ? '' : '$p.'}Message.${m.group(1)}(');
    }
  }
  return bad;
}

/// Whether the match at [start] in [code] is a call, not a declaration (the
/// name after a type: `Future<void> f(`, `void f(`, `Foo? f(`). After `=>`,
/// `??`, a ternary `?` or `:`, an opening bracket, a comma, an operator or
/// a keyword (`await`, `return` ...) it is a call.
bool _isCallAt(String code, int start) {
  final before = code.substring(0, start).trimRight();
  if (before.isEmpty) return true;
  if (before.endsWith('=>') || before.endsWith('??')) return true;
  if (before.endsWith('?')) {
    // `cond ? f(` is a ternary; `Foo? f(` is a nullable return type.
    final prior = code.substring(0, start).trimRight();
    return prior.length >= 2 && prior[prior.length - 2].trim().isEmpty;
  }
  if (before.endsWith('>')) return false; // `Future<void> f(`
  final word = RegExp(r'[\w$]+$').firstMatch(before)?.group(0);
  if (word == null) return true;
  return const {
    'await',
    'return',
    'yield',
    'else',
    'throw',
    'case',
    'in',
    'const',
    'new',
  }.contains(word);
}

/// The arguments (trimmed source text, `name:` kept) of every call matched
/// by [callee] in [source], comments ignored, after removing
/// [exemptSnippets] (exact, whitespace-insensitive). [callee] must end with
/// the opening `(`. A declaration is not a call (see [_isCallAt]).
List<List<String>> callArguments(
  String source,
  RegExp callee, {
  List<String> exemptSnippets = const [],
}) {
  final text = _removeSnippets(
    stripSource(source, keepStrings: true),
    exemptSnippets,
  );
  final masked = _maskStrings(text).code;
  final out = <List<String>>[];
  for (final m in callee.allMatches(masked)) {
    if (!_isCallAt(masked, m.start)) continue;
    out.add(_splitArguments(text, masked, m.end - 1));
  }
  return out;
}

/// The top-level arguments of the group opened at [open] in [masked] (the
/// text taken from [text]), empty trailing ones dropped.
List<String> _splitArguments(String text, String masked, int open) {
  final close = _groupEnd(masked, open) - 1;
  final args = <String>[];
  var depth = 0;
  var from = open + 1;
  for (var i = open + 1; i < close; i++) {
    final c = masked[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ',' && depth == 0) {
      args.add(text.substring(from, i).trim());
      from = i + 1;
    }
  }
  args.add(text.substring(from, close < from ? from : close).trim());
  return [
    for (final a in args)
      if (a.isNotEmpty) a,
  ];
}

/// The first argument of every call of [function] (`f(`, `f<T>(`, also on
/// a receiver: `this.f(`, `_p.f(`) in [source]; see [callArguments].
List<String> firstArguments(
  String source,
  String function, {
  List<String> exemptSnippets = const [],
}) => [
  for (final args in callArguments(
    source,
    RegExp(r'(?<![\w$])' + RegExp.escape(function) + r'\s*(?:<[^()]*?>)?\s*\('),
    exemptSnippets: exemptSnippets,
  ))
    args.isEmpty ? '' : args.first,
];

/// A plain step name literal (`'commit.send'`).
final RegExp stepLiteral = RegExp(r"^'[A-Za-z.]+'$");

Set<String>? _enumCache;

/// The enum types declared in hand-written lib/.
Set<String> declaredEnums() => _enumCache ??= {
  for (final s in handWrittenLib().values)
    for (final m in RegExp(
      r'\benum\s+([A-Za-z_$][\w$]*)',
    ).allMatches(stripSource(s, keepStrings: false)))
      m.group(1)!,
};

/// The stack trace names an error forward may pass after the error.
const Set<String> stackArgumentNames = {
  's',
  'st',
  'stack',
  'stackTrace',
  'StackTrace.current',
};

/// A thrown or forwarded error expression that is a constructor call
/// (`StateError(`, `const _Stopped(`, `ArgumentError.value(`).
final RegExp _constructorHead = RegExp(
  r'(?:const\s+|new\s+)?(_?[A-Z][\w$]*(?:\s*\.\s*[A-Za-z_$][\w$]*)?)\s*'
  r'(?:<[^()]*?>)?\s*\(',
);

/// What every error built or forwarded in [source] is made of. Findings:
/// - an `...Error(` / `...Exception(` constructor call (bare and named ones
///   too), or the constructor a `throw`, `completeError(`, `addError(` or
///   `Future.error(` starts with, whose arguments are not all fixed. Each
///   argument (a named one by its value) must be a string literal (adjacent
///   ones too) with no `$` interpolation and no `+`, an expression ending in
///   `.length`, a number, `null`, `true`, `false`, a value of an enum
///   declared in lib/ ([enumNames]), or one of [allowedNames];
/// - a `throw` of anything but a constructor call (use `rethrow`, or
///   `Error.throwWithStackTrace` for a caught error);
/// - an error forward (`completeError`, `addError`, `Future.error`) whose
///   error is not a constructor call, or whose stack is not a stack name.
/// `E2eePipelineError(` is judged by [pipelineErrorForwards] instead. Skipped:
/// a constructor declaration (inside its own class, at a member start) and
/// an object pattern (`case RateLimitedException(:final retryAfter)`).
/// [exemptSnippets] (exact, source form) are removed first.
List<String> errorArgumentViolations(
  String source, {
  Set<String> allowedNames = const {},
  List<String> exemptSnippets = const [],
  Set<String>? enumNames,
}) {
  final enums = enumNames ?? declaredEnums();
  final text = _removeSnippets(
    stripSource(source, keepStrings: true),
    exemptSnippets,
  );
  final masked = _maskStrings(text);
  final code = masked.code;
  final bad = <String>[];
  final checked = <int>{};

  void checkArguments(String name, int open) {
    if (!checked.add(open)) return;
    final args = _splitArguments(text, code, open);
    final codeArgs = _splitArguments(code, code, open);
    if (codeArgs.isNotEmpty && codeArgs.every(_isPatternField)) return;
    final close = _groupEnd(code, open);
    final interpolated = masked.interpolations.any(
      (p) => p > open && p < close,
    );
    for (var k = 0; k < args.length; k++) {
      final value = args[k].replaceFirst(RegExp(r'^[A-Za-z_]\w*\s*:\s*'), '');
      final maskedValue = codeArgs[k].replaceFirst(
        RegExp(r'^[A-Za-z_]\w*\s*:\s*'),
        '',
      );
      final isLiteral =
          RegExp(r'''^(?:r?['"]+[\s]*['"]+\s*)+$''').hasMatch(maskedValue) &&
          !interpolated;
      final enumValue = RegExp(r'^([A-Za-z_$][\w$]*)\.[a-z]\w*$')
          .firstMatch(value);
      final ok =
          isLiteral ||
          RegExp(r'^[\w$.?!]+\.length$').hasMatch(value) ||
          RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(value) ||
          (enumValue != null && enums.contains(enumValue.group(1))) ||
          const {'null', 'true', 'false'}.contains(value) ||
          allowedNames.contains(value);
      if (!ok) {
        bad.add('$name(... ${value.replaceAll(RegExp(r'\s+'), ' ')} ...)');
      }
    }
  }

  /// The error expression at [from] (to [end]): a constructor call whose
  /// arguments are checked, else a finding.
  void checkThrown(String what, int from, int end) {
    var start = from;
    while (start < end && code[start].trim().isEmpty) {
      start++;
    }
    final expr = text.substring(start, end).trim();
    final head = _constructorHead.matchAsPrefix(code, start);
    if (head != null) {
      final open = head.end - 1;
      final close = _groupEnd(code, open);
      final rest = code.substring(close, end).trim();
      if (rest.isEmpty || rest == ';') {
        final name = head.group(1)!.replaceAll(RegExp(r'\s'), '');
        if (!name.startsWith('E2eePipelineError')) checkArguments(name, open);
        return;
      }
    }
    bad.add('$what ${expr.replaceAll(RegExp(r'\s+'), ' ')}');
  }

  for (final m in _errorConstructor.allMatches(code)) {
    final name = m.group(0)!.replaceAll(RegExp(r'[\s(]'), '');
    if (name.startsWith('E2eePipelineError')) continue;
    // A rethrow of a caught error with its stack builds no message.
    if (name == 'Error.throwWithStackTrace') continue;
    if (_isConstructorDeclaration(code, m.start, name)) continue;
    checkArguments(name, m.end - 1);
  }
  for (final m in RegExp(r'(?<![\w$.])throw\b').allMatches(code)) {
    checkThrown('throw', m.end, _argumentEnd(code, m.end));
  }
  for (final m in RegExp(
    r'(?<![\w$])(?:completeError|addError)\s*\('
    r'|(?<![\w$.])Future\s*(?:<[^()]*?>)?\s*\.\s*error\s*\(',
  ).allMatches(code)) {
    if (!_isCallAt(code, m.start)) continue;
    final open = m.end - 1;
    final close = _groupEnd(code, open) - 1;
    final what = m.group(0)!.replaceAll(RegExp(r'\s'), '');
    // The first top-level argument's span, then the rest.
    var depth = 0;
    var comma = close;
    for (var i = open + 1; i < close; i++) {
      final c = code[i];
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') depth--;
      if (c == ',' && depth == 0) {
        comma = i;
        break;
      }
    }
    checkThrown(what, open + 1, comma);
    final rest = _splitArguments(text, code, open).skip(1);
    for (final r in rest) {
      if (!stackArgumentNames.contains(r)) bad.add('$what(... $r)');
    }
  }
  return bad;
}

/// The end of the expression starting at [from] in [code]: before a `,`, a
/// `;` or a closing bracket at its own level (`_ => throw X(),` in a
/// switch expression ends at the comma).
int _argumentEnd(String code, int from) {
  var depth = 0;
  for (var i = from; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) return i;
      depth--;
    }
    if ((c == ',' || c == ';') && depth == 0) return i;
  }
  return code.length;
}

/// An object pattern field (`:final retryAfter`, `kind: final k`).
bool _isPatternField(String arg) {
  final a = arg.trim();
  return a.startsWith(':') ||
      RegExp(r'^[A-Za-z_$][\w$]*\s*:\s*(?:final|var)\b').hasMatch(a);
}

/// Whether the `name(` at [start] in [code] declares a constructor: it is
/// inside the body of `class <type>` and starts a member (after `;`, `{`,
/// `}` or an annotation, a `const` / `factory` keyword allowed).
bool _isConstructorDeclaration(String code, int start, String name) {
  final type = name.split('.').first;
  for (final m in RegExp(
    r'\bclass\s+' + RegExp.escape(type) + r'\b[^{;]*\{',
  ).allMatches(code)) {
    final open = m.end - 1;
    if (start <= open || start >= _groupEnd(code, open)) continue;
    final before = code
        .substring(0, start)
        .trimRight()
        .replaceFirst(RegExp(r'(?:\b(?:const|factory)\s*)+$'), '')
        .trimRight();
    return before.endsWith(';') ||
        before.endsWith('{') ||
        before.endsWith('}') ||
        RegExp(r'@[\w$.]+(?:\([^()]*\))?$').hasMatch(before);
  }
  return false;
}

/// The argument of every `E2eePipelineError(` in [source] that is not a
/// plain step literal ([stepLiteral]): a forward of a `step` the caller
/// named. The type's own constructor (`this.step`) is skipped.
/// [exemptSnippets]: none; the sync coordinator's `'sync.$name'` is returned
/// as written and pinned by the caller.
List<String> pipelineErrorForwards(String source) => [
  for (final args in callArguments(
    source,
    RegExp(r'(?<![\w$])E2eePipelineError\s*\('),
  ))
    if (args.isEmpty)
      '(none)'
    else if (!stepLiteral.hasMatch(args.first) &&
        !args.first.startsWith('this.'))
      args.first,
];

/// The first argument of every call of the injected error callback in
/// [source] (`onUnexpectedError(`, `_onUnexpectedError?.call(`, also on a
/// receiver: `_p._onUnexpectedError?.call(`, `this._onUnexpectedError(`)
/// that is not an `E2eePipelineError(...)` (const or not).
List<String> sinkArgumentViolations(String source) => [
  for (final args in callArguments(
    source,
    RegExp(r'(?<![\w$])_?onUnexpectedError\s*[?!]?\s*(?:\.\s*call\s*)?\('),
  ))
    if (args.isEmpty ||
        !RegExp(r'^(?:const\s+)?E2eePipelineError\s*\(').hasMatch(args.first))
      args.isEmpty ? '(none)' : args.first,
];

/// Local names bound to any of [names] in [source] (`x = names;`,
/// `x = a.b.names;`, `x = a.names!;`, `x = names as T;`, `x = names ?? y;`,
/// `x = y ?? names;`, a getter `get x => names;`), except names that are
/// themselves in [names] (the constructor's `_x = x`). Comments and strings
/// ignored.
List<String> aliasAssignments(String source, Set<String> names) {
  final alt = names.map(RegExp.escape).join('|');
  final text = stripSource(source, keepStrings: false);
  const head =
      r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*(?:=>|=(?![=>]))\s*'
      r'(?:[\w$.?!\s]*\?\?\s*)?\(?\s*(?:[\w$]+\s*[?!]?\s*\.\s*)*';
  const tail = r'(?![\w$])\s*!?\s*(?:\bas\b[^;,)]*|\?\?[^;,)]*)?\)?\s*[;,)]';
  return [
    for (final m in RegExp('$head(?:$alt)$tail').allMatches(text))
      if (!names.contains(m.group(1)!)) m.group(1)!,
  ];
}

/// Writes of a messaging proto's preview fields in [source], whatever it
/// imports (SA R3, for files under lib/features/messages/): `.snippet =` /
/// `..snippet =`, `.lastMessage =` / `..lastMessage =`, and a `snippet:`
/// argument that is not `''`. Comments and string text are ignored.
List<String> pbNameMutations(String source) {
  final code = _maskStrings(stripSource(source, keepStrings: true)).code;
  return [
    for (final m in RegExp(
      r'(\.\.?)\s*(snippet|lastMessage)\s*=(?![=>])',
    ).allMatches(code))
      '${m.group(1)}${m.group(2)} =',
    for (final m in RegExp(r'(?<![\w$.])snippet\s*:\s*').allMatches(code))
      if (!RegExp(r'''^(?:''|"")\s*[,)]''').hasMatch(code.substring(m.end)))
        'snippet:',
  ];
}

/// Record type fields in the typedefs of [source] whose name holds a
/// [sensitiveFragments] entry (`typedef _Row = ({String text, int at});`): a
/// record's toString prints every field. Function parameter lists inside a
/// typedef are not records and are skipped.
List<String> recordFieldViolations(String source) {
  final code = stripSource(source, keepStrings: false);
  final bad = <String>[];
  for (final t in RegExp(r'\btypedef\s+[^;=]*=([^;]*);').allMatches(code)) {
    final rhs = t.group(1)!;
    for (final g in RegExp(r'\(([^()]*)\)').allMatches(rhs)) {
      final before = rhs.substring(0, g.start).trimRight();
      // `Function(...)` / `Function<T>(...)`: parameters, not a record.
      if (RegExp(r'Function\s*(?:<[^()]*>)?$').hasMatch(before)) continue;
      for (final part
          in g.group(1)!.replaceAll(RegExp(r'[{}]'), '').split(',')) {
        final tokens = part.trim().split(RegExp(r'\s+'));
        if (tokens.length < 2) continue;
        final name = tokens.last.toLowerCase();
        if (sensitiveFragments.any(name.contains)) bad.add(tokens.last);
      }
    }
  }
  return bad;
}

/// Function and method bodies in [source]: (name, body) for every
/// declaration with a `{...}` or `=> ...;` body (constructors excluded).
/// Comments and string text are ignored.
List<(String, String)> functionBodies(String source) {
  final code = _maskStrings(stripSource(source, keepStrings: true)).code;
  const notNames = {
    'if', 'for', 'while', 'switch', 'catch', 'on', 'assert', 'super', //
    'this', 'return', 'await', 'Function',
  };
  final out = <(String, String)>[];
  for (final m in RegExp(
    r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*(?:<[^()]*?>)?\s*\(',
  ).allMatches(code)) {
    final name = m.group(1)!;
    if (notNames.contains(name) || _isCallAt(code, m.start)) continue;
    var i = _groupEnd(code, m.end - 1);
    final rest = RegExp(r'\s*(?:async\s*\*?|sync\s*\*)?\s*')
        .matchAsPrefix(code, i);
    if (rest != null) i = rest.end;
    if (i < code.length && code[i] == '{') {
      out.add((name, code.substring(i, _groupEnd(code, i))));
    } else if (code.startsWith('=>', i)) {
      out.add((name, code.substring(i + 2, _expressionEnd(code, i + 2))));
    }
  }
  return out;
}

/// The library [path] belongs to: its own path, or for a part file
/// (`part of 'x.dart';`) the path of `x.dart` beside it.
String libraryOf(String path, String source) {
  final m = RegExp(r'''\bpart\s+of\s+['"]([^'"]+)['"]''')
      .firstMatch(stripSource(source, keepStrings: true));
  return m == null ? path : Uri.parse(path).resolve(m.group(1)!).path;
}

/// For each file of [files], the functions whose body calls one of [roots]
/// (on any receiver) directly, or through a private function of the same
/// library (its part files included) that does, by name. Public functions
/// are not followed further: a door library is not imported outside the
/// pipeline, and its public reachers are what the caller pins. The roots
/// themselves are not listed.
Map<String, List<String>> functionsReaching(
  Map<String, String> files,
  Set<String> roots,
) {
  final bodies = {
    for (final e in files.entries) e.key: functionBodies(e.value),
  };
  final library = {
    for (final e in files.entries) e.key: libraryOf(e.key, e.value),
  };
  // A bare `change(` counts only in the library that declares the root (a
  // callback parameter named `change` elsewhere is another function); a
  // call on a receiver (`_commits.change(`) counts everywhere.
  final rootLibraries = {
    for (final e in bodies.entries)
      if (e.value.any((b) => roots.contains(b.$1))) library[e.key]!,
  };
  final rootAlt = roots.map(RegExp.escape).join('|');
  final onReceiver = RegExp(r'\.\s*(?:' + rootAlt + r')\s*(?:<[^()]*?>)?\s*\(');
  final privateReached = <String, Set<String>>{};
  final found = <String, Set<String>>{};
  var grew = true;
  while (grew) {
    grew = false;
    for (final e in bodies.entries) {
      final lib = library[e.key]!;
      final names = {
        if (rootLibraries.contains(lib)) ...roots,
        ...?privateReached[lib],
      };
      final call = names.isEmpty
          ? onReceiver
          : RegExp(
              r'(?<![\w$])(?:' +
                  names.map(RegExp.escape).join('|') +
                  r')\s*(?:<[^()]*?>)?\s*\(',
            );
      for (final (name, body) in e.value) {
        if (roots.contains(name)) continue;
        if (!call.hasMatch(body) && !onReceiver.hasMatch(body)) continue;
        if ((found[e.key] ??= {}).add(name)) grew = true;
        if (name.startsWith('_') && (privateReached[lib] ??= {}).add(name)) {
          grew = true;
        }
      }
    }
  }
  return {for (final e in found.entries) e.key: e.value.toList()..sort()};
}

/// Functions in [source] that declare a parameter named [param] (typed:
/// `List<Uint8List> removeDeviceIds`), by name, in order.
List<String> functionsDeclaring(String source, String param) {
  final code = stripSource(source, keepStrings: false);
  final out = <String>[];
  for (final m in RegExp(
    r'[\w>?]\s+' + RegExp.escape(param) + r'\b(?!\s*:)',
  ).allMatches(code)) {
    var depth = 0;
    for (var i = m.start; i >= 0; i--) {
      final c = code[i];
      if (c == ')' || c == ']' || c == '}') depth++;
      if (c == '(' || c == '[' || c == '{') {
        if (depth == 0 && c == '(') {
          final name = RegExp(r'([A-Za-z_$][\w$]*)\s*(?:<[^()]*?>)?\s*$')
              .firstMatch(code.substring(0, i))
              ?.group(1);
          if (name != null) out.add(name);
          break;
        }
        if (depth > 0) depth--;
      }
    }
  }
  return out;
}
