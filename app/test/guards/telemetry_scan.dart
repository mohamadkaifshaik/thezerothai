// Pure scanners behind `telemetry_guard_test.dart`. They take
// text and return findings, so the guard test can prove each one on synthetic
// input (a built-in mutation check) as well as on the real tree.
import 'dart:io';

/// `import` or `export` of a Firebase Crashlytics or Analytics package (also
/// the platform-interface and web packages), as the package name.
List<String> findSdkImports(String source) => [
  for (final m in RegExp(
    r'''(?:import|export)\s+['"]package:(firebase_(?:crashlytics|analytics)\w*)/''',
  ).allMatches(source))
    m.group(1)!,
];

/// Calls that would tie telemetry to a person (Q10 (f)). Case
/// insensitive, because iOS spells it `setUserID`.
List<String> findForbiddenCalls(String source) => [
  for (final m in RegExp(
    r'set(?:UserId|UserIdentifier|UserProperty\w*|DefaultEventParameters)',
    caseSensitive: false,
  ).allMatches(source))
    m.group(0)!,
];

/// The only custom keys that may exist.
const Set<String> allowedCrashKeys = {
  'build_number',
  'FIREBASE_ENV',
  'platform',
};

/// Every `setCustomKey(...)` use in [source] that is not one of the three
/// allowed literal keys. A declaration (`setCustomKey(String key, ...)`, the
/// port and its fakes) is not a call; the one variable-key call allowed is the
/// SDK forwarder `_c.setCustomKey(key, value)` in the crash adapter file.
List<String> findCustomKeyViolations(
  String source, {
  bool isCrashAdapter = false,
}) {
  final bad = <String>[];
  for (final m in RegExp(r'setCustomKey\s*\(\s*([^,)]*)').allMatches(source)) {
    final arg = m.group(1)!.trim();
    final literal = RegExp(r'''^(['"])(.*)\1$''').firstMatch(arg);
    if (literal != null) {
      if (!allowedCrashKeys.contains(literal.group(2))) bad.add(arg);
    } else if (arg == 'String key' || (isCrashAdapter && arg == 'key')) {
      continue;
    } else {
      bad.add(arg);
    }
  }
  return bad;
}

String stripXmlComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// `<meta-data android:name=".." android:value=".."/>` pairs, comments
/// ignored. A tag whose attributes are in another order is not seen, so the
/// guard fails closed (the expected key is then "missing").
Map<String, String> manifestMetaData(String manifest) => {
  for (final m in RegExp(
    r'<meta-data\s+android:name="([^"]+)"\s+android:value="([^"]*)"',
  ).allMatches(stripXmlComments(manifest)))
    m.group(1)!: m.group(2)!,
};

/// `<key>K</key><true/|false/>` pairs of a plist, comments ignored.
Map<String, String> plistBooleans(String plist) => {
  for (final m in RegExp(
    r'<key>([^<]+)</key>\s*<(true|false)\s*/>',
  ).allMatches(stripXmlComments(plist)))
    m.group(1)!: m.group(2)!,
};

/// The advertising permissions the Analytics SDK declares and the merged
/// manifest must not contain.
const List<String> adPermissions = [
  'com.google.android.gms.permission.AD_ID',
  'android.permission.ACCESS_ADSERVICES_AD_ID',
  'android.permission.ACCESS_ADSERVICES_ATTRIBUTION',
];

/// `<uses-permission>` tags (comments ignored) that name [permission] exactly.
List<String> _usesOf(String manifest, String permission) => [
  for (final m in RegExp(
    r'<uses-permission\b[^>]*>',
  ).allMatches(stripXmlComments(manifest)))
    if (m.group(0)!.contains('"$permission"')) m.group(0)!,
];

/// True when the SOURCE manifest (comments ignored) removes [permission] with
/// `tools:node="remove"` and declares it in no other way. It does not read the
/// merged manifest; that is checked on the built APK.
bool removesPermission(String manifest, String permission) {
  final uses = _usesOf(manifest, permission);
  return uses.isNotEmpty &&
      uses.every((t) => t.contains('tools:node="remove"'));
}

/// True when the source manifest removes all of [adPermissions].
bool removesAdPermissions(String manifest) =>
    adPermissions.every((p) => removesPermission(manifest, p));

/// True when [manifest] mentions none of [adPermissions], or only to remove
/// it (the debug and profile manifests must not add one back).
bool addsNoAdPermission(String manifest) => adPermissions.every(
  (p) => _usesOf(manifest, p).isEmpty || removesPermission(manifest, p),
);

/// Every `Content-Security-Policy` header value in a decoded `firebase.json`,
/// whatever the nesting (`hosting` may be a map or a list).
List<String> cspValues(Object? json) {
  final out = <String>[];
  void walk(Object? node) {
    if (node is Map) {
      if ('${node['key']}'.toLowerCase() == 'content-security-policy') {
        out.add('${node['value']}');
      }
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(json);
  return out;
}

const List<String> forbiddenCspHosts = ['googletagmanager', 'google-analytics'];

/// Files under [dir] (relative to the current directory) with one of
/// [extensions], '/'-separated, skipping build output. Fails loudly when [dir]
/// does not exist, so a moved folder cannot make a guard pass on nothing.
Map<String, String> readTree(String dir, Set<String> extensions) {
  final root = Directory(dir);
  if (!root.existsSync()) {
    throw StateError('guard cannot find $dir (run from app/)');
  }
  final out = <String, String>{};
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final path = e.path.replaceAll(r'\', '/');
    if (RegExp(r'/(build|\.dart_tool|Pods|\.gradle)/').hasMatch('/$path')) {
      continue;
    }
    if (!extensions.any(path.endsWith)) continue;
    out[path] = e.readAsStringSync();
  }
  return out;
}

/// Reads of the SDK identifiers that could join a report to an account (the app never calls `FirebaseInstallations.getId` or reads
/// the Analytics app-instance ID).
List<String> findIdentifierReads(String source) => [
  for (final m in RegExp(
    r'FirebaseInstallations|appInstanceId|getAppInstanceId',
    caseSensitive: false,
  ).allMatches(source))
    m.group(0)!,
];
