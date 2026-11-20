import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dzeroth/core/crypto/mls_pair.dart';

import 'vault_status.dart';

// The values the vault stores for end-to-end encrypted conversations (schema
// version 2), and the sealed encoding of the records that are kept as one
// sealed blob. None of these types defines a `toString`: they hold device
// state, keys and message content, so the default (which prints only the type
// name) is deliberate.
//
// Sealed record encoding (pending commits, conversation sync, system lines,
// the removal queue): UTF-8 JSON, a top-level `"v": 1`, byte values as padded
// standard base64, pairs as `[generation, epoch]`. Web integers are exact up
// to 2^53 - 1 only, so every number is range-checked on read and a value
// above [kMaxPairComponent] is refused.

/// Why a pending commit was built.
enum PendingKind { init, change, reset, selfUpdate }

/// A commit this device built and sent (or is about to send) and has not seen
/// accepted yet. Kept so a retry sends the exact bytes again.
class PendingCommit {
  const PendingCommit({
    required this.kind,
    required this.builtOn,
    required this.commit,
    this.welcome,
    this.welcomeDeviceIds = const [],
  });

  final PendingKind kind;

  /// The (generation, epoch) the commit was built on.
  final MlsPair builtOn;

  /// The exact bytes sent.
  final Uint8List commit;
  final Uint8List? welcome;
  final List<String> welcomeDeviceIds;

  Uint8List encode() => _encodeJson({
    'kind': kind.name,
    'builtOn': _pairJson(builtOn),
    'commit': base64Encode(commit),
    if (welcome != null) 'welcome': base64Encode(welcome!),
    'welcomeDeviceIds': welcomeDeviceIds,
  });

  /// [VaultCorruptException] (`vault_group_states`) for a value that is not
  /// valid JSON, has another `v`, or is malformed.
  static PendingCommit decode(Uint8List bytes) =>
      _decodeJson(bytes, 'vault_group_states', (m) {
        final welcome = m['welcome'];
        return PendingCommit(
          kind: PendingKind.values.byName(_string(m['kind'])),
          builtOn: _pairFrom(m['builtOn']),
          commit: _bytes(m['commit']),
          welcome: welcome == null ? null : _bytes(welcome),
          welcomeDeviceIds: [
            for (final id in _list(m['welcomeDeviceIds'])) _string(id),
          ],
        );
      });
}

/// Which side of the conversation a pinned device belongs to.
abstract final class MemberSide {
  static const String mine = 'mine';
  static const String theirs = 'theirs';
  static const String unattributed = 'unattributed';
}

/// A device pinned in a conversation: its signature key, which side it is on
/// and the pair at which it joined.
class MemberRecord {
  const MemberRecord({
    required this.conversationId,
    required this.deviceId,
    required this.signatureKey,
    required this.side,
    required this.since,
  });

  final String conversationId;
  final Uint8List deviceId;
  final Uint8List signatureKey;

  /// One of [MemberSide].
  final String side;
  final MlsPair since;
}

/// The sealed per-conversation bookkeeping of the pipeline (`sync` column).
class ConversationSync {
  const ConversationSync({
    this.firstSawGeneration,
    this.firstSawGenerationAtMicros,
    this.lastSelfUpdateAtMicros,
    this.sinceToken = '',
    this.clearedAtMicros,
    this.completedEpochs = const [],
    this.commitCallsDay = '',
    this.commitCallsToday = 0,
    this.epochMustAdvance = false,
    this.requestAccepted = false,
  });

  final int? firstSawGeneration;
  final int? firstSawGenerationAtMicros;
  final int? lastSelfUpdateAtMicros;
  final String sinceToken;
  final int? clearedAtMicros;
  final List<MlsPair> completedEpochs;

  /// The server's day, `YYYY-MM-DD` in IST (UTC+05:30); see [istDay].
  final String commitCallsDay;
  final int commitCallsToday;
  final bool epochMustAdvance;
  final bool requestAccepted;

  /// A copy with the given fields replaced. A nullable field can be set to
  /// null by passing null explicitly.
  ConversationSync copyWith({
    Object? firstSawGeneration = _keep,
    Object? firstSawGenerationAtMicros = _keep,
    Object? lastSelfUpdateAtMicros = _keep,
    String? sinceToken,
    Object? clearedAtMicros = _keep,
    List<MlsPair>? completedEpochs,
    String? commitCallsDay,
    int? commitCallsToday,
    bool? epochMustAdvance,
    bool? requestAccepted,
  }) => ConversationSync(
    firstSawGeneration: identical(firstSawGeneration, _keep)
        ? this.firstSawGeneration
        : firstSawGeneration as int?,
    firstSawGenerationAtMicros: identical(firstSawGenerationAtMicros, _keep)
        ? this.firstSawGenerationAtMicros
        : firstSawGenerationAtMicros as int?,
    lastSelfUpdateAtMicros: identical(lastSelfUpdateAtMicros, _keep)
        ? this.lastSelfUpdateAtMicros
        : lastSelfUpdateAtMicros as int?,
    sinceToken: sinceToken ?? this.sinceToken,
    clearedAtMicros: identical(clearedAtMicros, _keep)
        ? this.clearedAtMicros
        : clearedAtMicros as int?,
    completedEpochs: completedEpochs ?? this.completedEpochs,
    commitCallsDay: commitCallsDay ?? this.commitCallsDay,
    commitCallsToday: commitCallsToday ?? this.commitCallsToday,
    epochMustAdvance: epochMustAdvance ?? this.epochMustAdvance,
    requestAccepted: requestAccepted ?? this.requestAccepted,
  );

  Uint8List encode() => _encodeJson({
    if (firstSawGeneration != null) 'firstSawGeneration': firstSawGeneration,
    if (firstSawGenerationAtMicros != null)
      'firstSawGenerationAtMicros': firstSawGenerationAtMicros,
    if (lastSelfUpdateAtMicros != null)
      'lastSelfUpdateAtMicros': lastSelfUpdateAtMicros,
    'sinceToken': sinceToken,
    if (clearedAtMicros != null) 'clearedAtMicros': clearedAtMicros,
    'completedEpochs': [for (final p in completedEpochs) _pairJson(p)],
    'commitCallsDay': commitCallsDay,
    'commitCallsToday': commitCallsToday,
    'epochMustAdvance': epochMustAdvance,
    'requestAccepted': requestAccepted,
  });

  /// [VaultCorruptException] (`vault_conversations`) for a value that is not
  /// valid JSON, has another `v`, or is malformed.
  static ConversationSync decode(Uint8List bytes) =>
      _decodeJson(bytes, 'vault_conversations', (m) {
        return ConversationSync(
          firstSawGeneration: _optInt(m['firstSawGeneration']),
          firstSawGenerationAtMicros: _optInt(m['firstSawGenerationAtMicros']),
          lastSelfUpdateAtMicros: _optInt(m['lastSelfUpdateAtMicros']),
          sinceToken: _string(m['sinceToken']),
          clearedAtMicros: _optInt(m['clearedAtMicros']),
          completedEpochs: [
            for (final p in _list(m['completedEpochs'])) _pairFrom(p),
          ],
          commitCallsDay: _string(m['commitCallsDay']),
          commitCallsToday: _int(m['commitCallsToday']),
          epochMustAdvance: _bool(m['epochMustAdvance']),
          requestAccepted: _bool(m['requestAccepted']),
        );
      });
}

const Object _keep = Object();

/// One conversation's marks and sync record.
class ConversationRecord {
  const ConversationRecord({
    required this.conversationId,
    this.afterPair,
    this.joinHighWater,
    this.sync = const ConversationSync(),
  });

  final String conversationId;

  /// The pair below which no message is accepted as new; null when none.
  final MlsPair? afterPair;

  /// The highest pair this device joined at; null when none.
  final MlsPair? joinHighWater;
  final ConversationSync sync;
}

/// The `check` of a stored message (equals `MessageCheck.name`).
abstract final class StoredMessageCheck {
  static const String ok = 'ok';
  static const String unverified = 'unverified';
  static const String undecodable = 'undecodable';

  static const Set<String> all = {ok, unverified, undecodable};
}

/// The `kind` of a stored message.
abstract final class StoredMessageKind {
  static const String message = 'message';
  static const String system = 'system';

  static const Set<String> all = {message, system};
}

/// The lines a system row can carry.
abstract final class SystemLine {
  static const String encryptionReset = 'encryptionReset';
  static const String deviceAdded = 'deviceAdded';
  static const String deviceRemoved = 'deviceRemoved';
  static const String unknownDevice = 'unknownDevice';
}

/// The `content` of a system row.
class SystemLineContent {
  const SystemLineContent({required this.line, this.deviceId, this.side});

  /// One of [SystemLine].
  final String line;
  final Uint8List? deviceId;

  /// One of [MemberSide], when the line names a device.
  final String? side;

  Uint8List encode() => _encodeJson({
    'line': line,
    if (deviceId != null) 'deviceId': base64Encode(deviceId!),
    if (side != null) 'side': side,
  });

  /// Null for a value that is not valid JSON, has another `v`, or is
  /// malformed (a system line that cannot be read is not shown).
  static SystemLineContent? decode(Uint8List bytes) {
    try {
      return _decodeJson(bytes, 'vault_messages', (m) {
        final id = m['deviceId'];
        final side = m['side'];
        return SystemLineContent(
          line: _string(m['line']),
          deviceId: id == null ? null : _bytes(id),
          side: side == null ? null : _string(side),
        );
      });
    } on VaultCorruptException {
      return null;
    }
  }
}

/// The id of a system row: the first 32 hex of
/// SHA-256(utf8("dz-sysline-v1|$conversationId|$generation|$epoch|$line|$deviceIdHex")),
/// so re-processing the same event writes the same row.
String systemLineId(
  String conversationId,
  MlsPair pair,
  String line, {
  Uint8List? deviceId,
}) {
  final id = deviceId == null ? '' : vaultDeviceIdHex(deviceId);
  final text =
      'dz-sysline-v1|$conversationId|${pair.generation}|${pair.epoch}|$line|$id';
  return sha256.convert(utf8.encode(text)).toString().substring(0, 32);
}

/// Lower-case hex of a device id's bytes (the `device_id` of a member row).
String vaultDeviceIdHex(Uint8List deviceId) {
  final out = StringBuffer();
  for (final b in deviceId) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// The stage of an outbox item.
abstract final class OutboxStage {
  /// Not encrypted yet: the plain content waits for a group state.
  static const String plain = 'plain';

  /// Encrypted for a (generation, epoch) and waiting to be sent.
  static const String encrypted = 'encrypted';

  static const Set<String> all = {plain, encrypted};
}

/// [utc] as a `YYYY-MM-DD` day at UTC+05:30, the server's day.
String istDay(DateTime utc) {
  final d = utc.toUtc().add(const Duration(hours: 5, minutes: 30));
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// Vault setting: one byte, 0x01, once this device registered its keys.
const String kVaultSettingRegisteredOnce = 'keys.device.registeredOnce';

/// Vault setting: the [RemovalQueue].
const String kVaultSettingRemovalQueue = 'messages.removalQueue';

/// One device to remove from one conversation.
class RemovalQueueEntry {
  const RemovalQueueEntry({
    required this.deviceId,
    required this.conversationId,
    this.parked = false,
  });

  final Uint8List deviceId;
  final String conversationId;
  final bool parked;
}

/// Removals waiting to be committed.
class RemovalQueue {
  const RemovalQueue({this.entries = const [], this.notBeforeMicros});

  final List<RemovalQueueEntry> entries;
  final int? notBeforeMicros;

  Uint8List encode() => _encodeJson({
    'entries': [
      for (final e in entries)
        {
          'deviceId': base64Encode(e.deviceId),
          'conversationId': e.conversationId,
          'parked': e.parked,
        },
    ],
    if (notBeforeMicros != null) 'notBeforeMicros': notBeforeMicros,
  });

  /// [VaultCorruptException] (`vault_settings`) for a value that is not valid
  /// JSON, has another `v`, or is malformed.
  static RemovalQueue decode(Uint8List bytes) =>
      _decodeJson(bytes, 'vault_settings', (m) {
        return RemovalQueue(
          entries: [for (final e in _list(m['entries'])) _entry(e)],
          notBeforeMicros: _optInt(m['notBeforeMicros']),
        );
      });

  static RemovalQueueEntry _entry(Object? value) {
    final m = _map(value);
    return RemovalQueueEntry(
      deviceId: _bytes(m['deviceId']),
      conversationId: _string(m['conversationId']),
      parked: _bool(m['parked']),
    );
  }
}

// --- the sealed JSON encoding ---

const int _version = 1;

Uint8List _encodeJson(Map<String, Object?> fields) =>
    Uint8List.fromList(utf8.encode(jsonEncode({'v': _version, ...fields})));

/// Decodes [bytes]; any failure (not UTF-8, not JSON, not an object, another
/// `v`, a malformed field) is [VaultCorruptException] for [table].
T _decodeJson<T>(
  Uint8List bytes,
  String table,
  T Function(Map<String, Object?> fields) build,
) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    final m = _map(decoded);
    if (m['v'] != _version) throw const FormatException('version');
    return build(m);
  } on VaultCorruptException {
    rethrow;
  } catch (_) {
    throw VaultCorruptException(table);
  }
}

List<int> _pairJson(MlsPair p) => [p.generation, p.epoch];

Map<String, Object?> _map(Object? v) {
  if (v is Map<String, Object?>) return v;
  throw const FormatException('object');
}

List<Object?> _list(Object? v) {
  if (v is List<Object?>) return v;
  throw const FormatException('list');
}

String _string(Object? v) {
  if (v is String) return v;
  throw const FormatException('string');
}

bool _bool(Object? v) {
  if (v is bool) return v;
  throw const FormatException('bool');
}

/// A whole number in 0..[kMaxPairComponent] (exact on the web).
int _int(Object? v) {
  if (v is int && v >= 0 && v <= kMaxPairComponent) return v;
  throw const FormatException('int');
}

int? _optInt(Object? v) => v == null ? null : _int(v);

MlsPair _pairFrom(Object? v) {
  final l = _list(v);
  if (l.length != 2) throw const FormatException('pair');
  return MlsPair(_int(l[0]), _int(l[1]));
}

/// Padded standard base64 only (no URL alphabet, no missing padding).
Uint8List _bytes(Object? v) {
  final s = _string(v);
  if (s.length % 4 != 0 || !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(s)) {
    throw const FormatException('base64');
  }
  return base64Decode(s);
}
