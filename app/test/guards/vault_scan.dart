// Pure scanners behind `vault_guard_test.dart`. They take source text and
// return findings, so the guard test can prove each rule on a small violating
// string (a built-in mutation check) as well as on the real tree.

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

/// The files `import`/`export` directives of [source] (living at [path],
/// '/'-separated, relative to app/) point into `lib/core/vault/`, as base
/// names. Whole directives are read up to `;`, so a conditional import that
/// spans lines is seen with every URI it can select.
List<String> vaultImports(String path, String source) {
  final text = stripSource(source, keepStrings: true);
  final found = <String>[];
  for (final d in RegExp(r'\b(?:import|export)\s[^;]*;').allMatches(text)) {
    for (final u in RegExp(r'''['"]([^'"]+)['"]''').allMatches(d.group(0)!)) {
      final uri = u.group(1)!;
      String resolved;
      if (uri.startsWith('package:dzeroth/')) {
        resolved = 'lib/${uri.substring('package:dzeroth/'.length)}';
      } else if (uri.contains(':')) {
        continue;
      } else {
        resolved = Uri.parse(path).resolve(uri).path;
      }
      if (resolved.startsWith(vaultDir)) {
        found.add(resolved.substring(vaultDir.length));
      }
    }
  }
  return found;
}

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
  r'\b(?:wipeVaultFile\w*|deleteVaultKey\w*)\b|\.\s*(?:wipe|destroy)\b',
);

/// References (calls AND tear-offs) to the destructive vault operations in
/// [source]. Comments and string contents are ignored. [exemptSnippets] are
/// exact wiring fragments (whitespace-insensitive) removed first.
List<String> destructiveReferences(
  String source, {
  List<String> exemptSnippets = const [],
}) {
  var text = stripSource(source, keepStrings: false);
  for (final s in exemptSnippets) {
    final pattern = s
        .trim()
        .split(RegExp(r'\s+'))
        .map(RegExp.escape)
        .join(r'\s*');
    text = text.replaceAll(RegExp(pattern), ' ');
  }
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
];

final RegExp _printCall = RegExp(r'(?<![\w$.])(?:debugPrint|print)\s*\(');

/// Calls that write somewhere: the error reporters (the app-level
/// `reportUnexpectedError`, and the injected `onUnexpectedError` the vault
/// session and the device-keys service reach through their private
/// `_report` / `_onUnexpectedError?.call`) and `package:logging` loggers.
final RegExp _sink = RegExp(
  r'(?<![\w$])(?:reportUnexpectedError|_report|_?onUnexpectedError\s*\??\s*\.\s*call'
  r'|_?log(?:ger)?\s*\??\s*\.\s*(?:finest|finer|fine|config|info|warning|severe|shout|log)'
  r'|Logger\s*\([^)]*\)\s*\.\s*\w+)\s*\(',
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
  for (final m in _sink.allMatches(text)) {
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

/// Every `String toString()` declared in [source], as `Class` -> its body with
/// whitespace collapsed (`=> ...;` or `{...}`). The class is the nearest
/// `class` declaration above it.
Map<String, String> toStringDeclarations(String source) {
  final text = stripSource(source, keepStrings: true);
  final out = <String, String>{};
  final classes = RegExp(r'\bclass\s+(\w+)').allMatches(text).toList();
  for (final m in RegExp(r'String\s+toString\s*\(\s*\)\s*').allMatches(text)) {
    var owner = '?';
    for (final c in classes) {
      if (c.start < m.start) owner = c.group(1)!;
    }
    String body;
    if (text.startsWith('=>', m.end)) {
      final semi = text.indexOf(';', m.end);
      body = text.substring(m.end, semi + 1);
    } else {
      var depth = 0;
      var j = m.end;
      for (; j < text.length; j++) {
        if (text[j] == '{') depth++;
        if (text[j] == '}') {
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
