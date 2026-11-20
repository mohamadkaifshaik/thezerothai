import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_status.dart';
import 'e2ee_types.dart';

/// Vault setting prefix: one sealed device key history per conversation,
/// under `messages.e2ee.keys.<conversationId>`. The conversation id in the
/// key is already a clear column (pins, groups, conversations, messages).
/// Sealed
/// `{"v":1,"ids":{deviceIdHex:keyB64},"changed":[deviceIdHex],"closed":false,"allow":256}`.
const String kVaultSettingKeyHistoryPrefix = 'messages.e2ee.keys.';

/// One allowance step: the entries (`ids` plus `changed`) a conversation's
/// history holds before it closes, and what one "allow new devices here"
/// adds.
const int kKeyHistoryAllowanceStep = 256;

/// The allowance never grows past this.
const int kMaxKeyHistoryAllowance = 1024;

/// Why a (device id, key) pair is not attributable in a conversation.
///
/// `tainted`: the id was seen in the conversation with two keys (refused on
/// every key, its first included). `unrecorded`: a new id while the history
/// is closed or at its allowance, or a pin the history does not hold.
/// `unreadable`: the history cannot be read (or is missing or contradicts
/// the pins).
enum KeyRefusal { none, tainted, unrecorded, unreadable }

/// The device key histories, read from and written to the vault.
///
/// The rule: a (device id, key) pair is attributable in a conversation only
/// when that conversation's history records the id with exactly that key,
/// the id was never recorded there with another key, and the history is
/// readable. Every other pair is refused: pinned `unattributed`, never given
/// a side.
///
/// Every transaction that writes a group, a pin or a mark of a conversation
/// reads the history fresh inside its `runWrite` body with that body's
/// vault ([of]), admits every other device it pins ([KeyHistory.admit];
/// only `none` may get a side) and calls [writeIn] once at its end. Nothing
/// ever shrinks a record: removals, `selfRemoved`, joins, provisional
/// discards and resets leave it; only a vault wipe removes it.
///
/// Fails closed, per conversation: an unreadable history refuses every
/// unattributed member of that conversation, is reported once per
/// conversation per run as `E2eePipelineError('keyHistory.read')`, and is
/// never overwritten. Never logs. No `toString` here or on [KeyHistory]
/// prints an id or a key.
class DeviceKeyHistory {
  DeviceKeyHistory({
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _onUnexpectedError = onUnexpectedError;

  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Set<String> _reported = {};

  static String _keyOf(String conversationId) =>
      '$kVaultSettingKeyHistoryPrefix$conversationId';

  /// [conversationId]'s history, read fresh with the body's [vault].
  ///
  /// A missing history is never a fresh one: it is unreadable whenever the
  /// conversation has a group, a pin, a former pin or an after-pair or join
  /// high-water mark; with none of that it is empty and dirty (the first
  /// transaction that stores a group or a pin writes it, empty if need be).
  /// Then every current and former pin (this device excluded) is checked
  /// against the record ([KeyHistory.read]). [currentPins] and [formerPins]
  /// are the body's own reads.
  Future<KeyHistory> of(
    SecureVault vault,
    String conversationId, {
    required List<MemberRecord> currentPins,
    required List<MemberRecord> formerPins,
  }) async {
    final thisDevice = await vault.deviceId();
    final thisHex = thisDevice == null ? null : vaultDeviceIdHex(thisDevice);
    final Uint8List? bytes;
    try {
      bytes = await vault.setting(_keyOf(conversationId));
    } on VaultCorruptException catch (_, stack) {
      _unreadable(conversationId, stack);
      return KeyHistory.unreadableRecord();
    }
    var hasState = currentPins.isNotEmpty || formerPins.isNotEmpty;
    if (bytes == null && !hasState) {
      final record = await vault.conversation(conversationId);
      hasState =
          record?.afterPair != null ||
          record?.joinHighWater != null ||
          (await vault.groups(conversationId)).isNotEmpty;
    }
    final history = KeyHistory.read(
      bytes,
      hasState: hasState,
      currentPins: currentPins,
      formerPins: formerPins,
      thisDeviceHex: thisHex,
    );
    if (history.unreadable) _unreadable(conversationId, StackTrace.current);
    return history;
  }

  /// One `putSetting`, only when [history] is dirty and readable. Call it
  /// once, at the end of the body's transaction.
  Future<void> writeIn(
    VaultTx tx,
    String conversationId,
    KeyHistory history,
  ) async {
    if (history.unreadable || !history.dirty) return;
    await tx.putSetting(_keyOf(conversationId), history.encode());
    history._dirty = false;
  }

  void _unreadable(String conversationId, StackTrace stack) {
    if (!_reported.add(conversationId)) return;
    _onUnexpectedError?.call(const E2eePipelineError('keyHistory.read'), stack);
  }
}

/// One conversation's device key history, read for one transaction. Mutable:
/// [admit] and [allowNewDevices] change it, [DeviceKeyHistory.writeIn]
/// stores it. No `toString` prints an id or a key.
class KeyHistory {
  KeyHistory._({
    required Map<String, String> ids,
    required Set<String> changed,
    required bool closed,
    required int allowance,
    required bool dirty,
    required this.unreadable,
    required String? thisDeviceHex,
  }) : _ids = ids,
       _changed = changed,
       _closed = closed,
       _allowance = allowance,
       _dirty = dirty,
       _thisHex = thisDeviceHex;

  /// A history that cannot be read: every pair is refused and nothing
  /// changes it.
  factory KeyHistory.unreadableRecord() => KeyHistory._(
    ids: {},
    changed: {},
    closed: false,
    allowance: kKeyHistoryAllowanceStep,
    dirty: false,
    unreadable: true,
    thisDeviceHex: null,
  );

  /// The history stored as [bytes] (null: no setting), cross-checked.
  ///
  /// Null with [hasState] is unreadable; null without is empty and dirty.
  /// Bytes that do not decode are unreadable. Then every pin of
  /// [currentPins] and [formerPins] other than [thisDeviceHex] must agree
  /// with the record, or the whole record is unreadable: a pin whose id is
  /// recorded with another key, or whose id is in neither list. One
  /// exemption: an `unattributed` pin absent from a `closed` record (an
  /// overflow refusal, refused anyway).
  factory KeyHistory.read(
    Uint8List? bytes, {
    required bool hasState,
    required List<MemberRecord> currentPins,
    required List<MemberRecord> formerPins,
    required String? thisDeviceHex,
  }) {
    if (bytes == null) {
      if (hasState) return KeyHistory.unreadableRecord();
      return KeyHistory._(
        ids: {},
        changed: {},
        closed: false,
        allowance: kKeyHistoryAllowanceStep,
        dirty: true,
        unreadable: false,
        thisDeviceHex: thisDeviceHex,
      );
    }
    final KeyHistory history;
    try {
      history = _decode(bytes, thisDeviceHex);
    } on FormatException {
      return KeyHistory.unreadableRecord();
    }
    for (final pin in [...currentPins, ...formerPins]) {
      final hex = vaultDeviceIdHex(pin.deviceId);
      if (hex == thisDeviceHex) continue;
      final key = history._ids[hex];
      if (key != null) {
        if (key != base64Encode(pin.signatureKey)) {
          return KeyHistory.unreadableRecord();
        }
        continue;
      }
      if (history._changed.contains(hex)) continue;
      if (history._closed && pin.side == MemberSide.unattributed) continue;
      return KeyHistory.unreadableRecord();
    }
    return history;
  }

  final Map<String, String> _ids;
  final Set<String> _changed;
  final String? _thisHex;
  bool _closed;
  int _allowance;
  bool _dirty;

  /// The stored record cannot be read (or is missing, or contradicts the
  /// pins): every pair is refused and nothing is written.
  final bool unreadable;

  /// No new id is admitted until the user allows new devices.
  bool get closed => _closed;

  /// Changed since it was read (or never stored): [DeviceKeyHistory.writeIn]
  /// writes it.
  bool get dirty => _dirty;

  /// This conversation's allowance: 256, raised in steps of 256 up to 1024.
  int get allowance => _allowance;

  /// The entries held: ids seen with one key plus tainted ids.
  int get size => _ids.length + _changed.length;

  /// Closed, and the allowance can still be raised.
  bool get mayAllowMore =>
      !unreadable && _closed && _allowance < kMaxKeyHistoryAllowance;

  /// The user's "allow new devices here": clears `closed`, raises the
  /// allowance by one step (a [StateError] at the maximum or when
  /// [unreadable]), then admits every unattributed current or former pin
  /// the record does not hold (an overflow refusal: never seen before, so
  /// admitting it drops nothing). No id and no taint is ever dropped.
  void allowNewDevices({
    required List<MemberRecord> currentPins,
    required List<MemberRecord> formerPins,
  }) {
    if (unreadable) throw StateError('The key history is unreadable.');
    if (_allowance >= kMaxKeyHistoryAllowance) {
      throw StateError('The key history allowance is at its maximum.');
    }
    _closed = false;
    _allowance += kKeyHistoryAllowanceStep;
    _dirty = true;
    for (final pin in [...currentPins, ...formerPins]) {
      if (pin.side != MemberSide.unattributed) continue;
      final hex = vaultDeviceIdHex(pin.deviceId);
      if (hex == _thisHex) continue;
      if (_ids.containsKey(hex) || _changed.contains(hex)) continue;
      // Through admit: it closes again at the new allowance.
      admit(hex, pin.signatureKey);
    }
  }

  /// Records the pair, then returns its refusal.
  ///
  /// An unknown id is added with its key (`none`), or, while closed or at
  /// the allowance, the record closes and the id is `unrecorded`. The same
  /// key again is `none`. Another key moves the id to the tainted list for
  /// good: `tainted`, on every key from then on. An unreadable record
  /// answers `unreadable` and never changes. This device is never recorded
  /// and never refused.
  KeyRefusal admit(String deviceIdHex, Uint8List signatureKey) {
    if (unreadable) return KeyRefusal.unreadable;
    if (deviceIdHex == _thisHex) return KeyRefusal.none;
    if (_changed.contains(deviceIdHex)) return KeyRefusal.tainted;
    final key = base64Encode(signatureKey);
    final recorded = _ids[deviceIdHex];
    if (recorded != null) {
      if (recorded == key) return KeyRefusal.none;
      _ids.remove(deviceIdHex);
      _changed.add(deviceIdHex);
      _dirty = true;
      return KeyRefusal.tainted;
    }
    if (_closed || size >= _allowance) {
      if (!_closed) {
        _closed = true;
        _dirty = true;
      }
      return KeyRefusal.unrecorded;
    }
    _ids[deviceIdHex] = key;
    _dirty = true;
    return KeyRefusal.none;
  }

  /// Read-only, for attribution: the id recorded with exactly this key is
  /// `none`; a tainted id (or a recorded id asked with another key) is
  /// `tainted`; an absent id is `unrecorded`.
  KeyRefusal refusal(String deviceIdHex, Uint8List signatureKey) {
    if (unreadable) return KeyRefusal.unreadable;
    if (deviceIdHex == _thisHex) return KeyRefusal.none;
    if (_changed.contains(deviceIdHex)) return KeyRefusal.tainted;
    final recorded = _ids[deviceIdHex];
    if (recorded == null) return KeyRefusal.unrecorded;
    return recorded == base64Encode(signatureKey)
        ? KeyRefusal.none
        : KeyRefusal.tainted;
  }

  /// Read-only, for claims and adds: [admit] would return `none`.
  bool admissible(String deviceIdHex, Uint8List signatureKey) {
    if (unreadable) return false;
    if (deviceIdHex == _thisHex) return true;
    if (_changed.contains(deviceIdHex)) return false;
    final recorded = _ids[deviceIdHex];
    if (recorded != null) return recorded == base64Encode(signatureKey);
    return !_closed && size < _allowance;
  }

  /// The stored form.
  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'ids': _ids,
        'changed': _changed.toList(),
        'closed': _closed,
        'allow': _allowance,
      }),
    ),
  );

  static final RegExp _hex = RegExp(r'^([0-9a-f]{2})*$');

  static KeyHistory _decode(Uint8List bytes, String? thisDeviceHex) {
    final m = jsonDecode(utf8.decode(bytes));
    if (m is! Map<String, Object?> || m['v'] != 1) {
      throw const FormatException('shape');
    }
    final rawIds = m['ids'];
    final rawChanged = m['changed'];
    final closed = m['closed'];
    final allow = m['allow'];
    if (rawIds is! Map<String, Object?> ||
        rawChanged is! List<Object?> ||
        closed is! bool ||
        allow is! int) {
      throw const FormatException('shape');
    }
    if (allow < kKeyHistoryAllowanceStep ||
        allow > kMaxKeyHistoryAllowance ||
        allow % kKeyHistoryAllowanceStep != 0) {
      throw const FormatException('allow');
    }
    final ids = <String, String>{};
    for (final e in rawIds.entries) {
      final key = e.value;
      if (!_hex.hasMatch(e.key) || key is! String || key.isEmpty) {
        throw const FormatException('entry');
      }
      // A key that is not base64 cannot be compared: unreadable. Stored in
      // the canonical form the comparisons use.
      ids[e.key] = base64Encode(base64Decode(key));
    }
    final changed = <String>{};
    for (final id in rawChanged) {
      if (id is! String || !_hex.hasMatch(id) || ids.containsKey(id)) {
        throw const FormatException('entry');
      }
      if (!changed.add(id)) throw const FormatException('entry');
    }
    // Against the stored allowance, not the constant.
    if (ids.length + changed.length > allow) {
      throw const FormatException('size');
    }
    return KeyHistory._(
      ids: ids,
      changed: changed,
      closed: closed,
      allowance: allow,
      dirty: false,
      unreadable: false,
      thisDeviceHex: thisDeviceHex,
    );
  }

  @override
  String toString() =>
      'KeyHistory(unreadable: $unreadable, closed: $_closed, '
      'size: $size, allowance: $_allowance)';
}
