import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_status.dart';
import 'e2ee_types.dart';

/// Vault setting prefix: one sealed device key history per conversation,
/// under `messages.e2ee.keys.<conversationId>`. The conversation id in the
/// key is already a clear column (pins, groups, conversations, messages).
/// Sealed
/// `{"v":1,"ids":{deviceIdHex:keyB64},"changed":[deviceIdHex],"held":{deviceIdHex:keyB64},"closed":false,"allow":256}`
/// (a record without `held` reads as an empty `held`).
const String kVaultSettingKeyHistoryPrefix = 'messages.e2ee.keys.';

/// One allowance step: the entries (`ids` plus `changed`) a conversation's
/// history holds before it closes, and what one "allow new devices here"
/// adds. The allowance limits which ids are attributable, never which are
/// remembered, and is enforced only when a new id is admitted.
const int kKeyHistoryAllowanceStep = 256;

/// The allowance never grows past this.
const int kMaxKeyHistoryAllowance = 1024;

/// The entries one history ever holds: `ids`, `changed` and `held`
/// together. Past it a new id cannot be recorded at all.
const int kMaxKeyHistoryTotal = 2048;

/// Why a (device id, key) pair is not attributable in a conversation.
///
/// `tainted`: the id was seen in the conversation with two keys (refused on
/// every key, its first included). `unrecorded`: an id the history only
/// remembers (first seen while it was closed or at its allowance: held
/// with its key, never attributable until the user allows new devices), or
/// an id it does not hold at all. `unreadable`: the history cannot be read
/// (or is missing or contradicts the pins).
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
/// A closed history still remembers what it sees. An id first seen while
/// the allowance is full is held with its key (`held`): not attributable,
/// but a later change of its key taints it like any recorded id, and the
/// user's "allow new devices" admits it only on the key first seen. The
/// only moves between the lists are `ids` to `changed` and `held` to
/// `changed` (a key change) and `held` to `ids` (that promotion).
///
/// The one case where an id is not remembered: the record already holds
/// [kMaxKeyHistoryTotal] entries. A new id is then refused and cannot be
/// recorded. That is safe because nothing can ever admit it: an id enters
/// `ids` only when first seen by an open record with room, or by promotion
/// out of `held`. It is not in `held`; and a record at the bound is closed
/// and never reopens (reopening needs `held` empty and room, which would
/// put the total under the allowance, and the total never shrinks). So it
/// stays unknown in this conversation for good, on every key.
///
/// Fails closed, per conversation: an unreadable history refuses every
/// unattributed member of that conversation, is reported once per
/// conversation per run as `E2eePipelineError('keyHistory.read')`, and is
/// never overwritten. Never logs. Neither this class nor [KeyHistory] has a
/// text form (both keep `Object.toString`).
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
  ///
  /// [report] false: an unreadable history is not reported and does not
  /// spend this conversation's one report. For a reader that holds no lock
  /// (`describeState`), which can meet a half-written state; every write
  /// body reports. Never pass false inside a write body: only for read-only
  /// state queries.
  Future<KeyHistory> of(
    SecureVault vault,
    String conversationId, {
    required List<MemberRecord> currentPins,
    required List<MemberRecord> formerPins,
    bool report = true,
  }) async {
    final thisDevice = await vault.deviceId();
    final thisHex = thisDevice == null ? null : vaultDeviceIdHex(thisDevice);
    final Uint8List? bytes;
    try {
      bytes = await vault.setting(_keyOf(conversationId));
    } on VaultCorruptException catch (_, stack) {
      if (report) _unreadable(conversationId, stack);
      return KeyHistory.unreadableRecord(thisDeviceHex: thisHex);
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
    if (history.unreadable && report) {
      _unreadable(conversationId, StackTrace.current);
    }
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
/// stores it. It carries ids, so it has no text form (`Object.toString`).
class KeyHistory {
  KeyHistory._({
    required Map<String, String> ids,
    required Set<String> changed,
    required Map<String, String> held,
    required bool closed,
    required int allowance,
    required bool dirty,
    required this.unreadable,
    required String? thisDeviceHex,
  }) : _ids = ids,
       _changed = changed,
       _held = held,
       _closed = closed,
       _allowance = allowance,
       _dirty = dirty,
       _thisHex = thisDeviceHex;

  /// A history that cannot be read: every pair is refused, except this
  /// device's ([thisDeviceHex]), and nothing changes it.
  factory KeyHistory.unreadableRecord({String? thisDeviceHex}) => KeyHistory._(
    ids: {},
    changed: {},
    held: {},
    closed: false,
    allowance: kKeyHistoryAllowanceStep,
    dirty: false,
    unreadable: true,
    thisDeviceHex: thisDeviceHex,
  );

  /// The history stored as [bytes] (null: no setting), cross-checked.
  ///
  /// Null with [hasState] is unreadable; null without is empty and dirty.
  /// Bytes that do not decode are unreadable. Then every pin of
  /// [currentPins] and [formerPins] other than [thisDeviceHex] must agree
  /// with the record, or the whole record is unreadable:
  /// - an id in `ids`: the pin has the recorded key;
  /// - an id in `changed`: any pin;
  /// - an id in `held`: the pin is `unattributed` and has the held key (a
  ///   held id never gets a side, and a pin on another key cannot exist:
  ///   the change would have tainted the id);
  /// - an id in none of them: only an `unattributed` pin of a record at
  ///   [kMaxKeyHistoryTotal] entries (it could not be recorded).
  factory KeyHistory.read(
    Uint8List? bytes, {
    required bool hasState,
    required List<MemberRecord> currentPins,
    required List<MemberRecord> formerPins,
    required String? thisDeviceHex,
  }) {
    if (bytes == null) {
      if (hasState) {
        return KeyHistory.unreadableRecord(thisDeviceHex: thisDeviceHex);
      }
      return KeyHistory._(
        ids: {},
        changed: {},
        held: {},
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
      return KeyHistory.unreadableRecord(thisDeviceHex: thisDeviceHex);
    }
    for (final pin in [...currentPins, ...formerPins]) {
      final hex = vaultDeviceIdHex(pin.deviceId);
      if (hex == thisDeviceHex) continue;
      final key = history._ids[hex];
      if (key != null) {
        if (key != base64Encode(pin.signatureKey)) {
          return KeyHistory.unreadableRecord(thisDeviceHex: thisDeviceHex);
        }
        continue;
      }
      if (history._changed.contains(hex)) continue;
      final unattributed = pin.side == MemberSide.unattributed;
      final heldKey = history._held[hex];
      if (heldKey != null) {
        if (unattributed && heldKey == base64Encode(pin.signatureKey)) {
          continue;
        }
        return KeyHistory.unreadableRecord(thisDeviceHex: thisDeviceHex);
      }
      if (unattributed && history.total == kMaxKeyHistoryTotal) continue;
      return KeyHistory.unreadableRecord(thisDeviceHex: thisDeviceHex);
    }
    return history;
  }

  final Map<String, String> _ids;
  final Set<String> _changed;
  final Map<String, String> _held;
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

  /// The entries the allowance counts: ids seen with one key plus tainted
  /// ids. It can pass the allowance, by taints of held ids only.
  int get size => _ids.length + _changed.length;

  /// Every entry the record holds, held ids included: never more than
  /// [kMaxKeyHistoryTotal], and it never shrinks.
  int get total => size + _held.length;

  /// Closed, and the allowance can still be raised.
  bool get mayAllowMore =>
      !unreadable && _closed && _allowance < kMaxKeyHistoryAllowance;

  /// The user's "allow new devices here": raises the allowance by one step
  /// (a [StateError] at the maximum or when [unreadable]), then promotes
  /// held ids into `ids`, in device id order, while there is room under the
  /// new allowance. Each is admitted on the key it was first seen with (the
  /// key in `held`), never on the key of a current pin. `closed` clears
  /// only when no id is held any more and there is room; otherwise the
  /// record stays closed. No id and no taint is ever dropped.
  void allowNewDevices() {
    if (unreadable) throw StateError('The key history is unreadable.');
    if (_allowance >= kMaxKeyHistoryAllowance) {
      throw StateError('The key history allowance is at its maximum.');
    }
    _allowance += kKeyHistoryAllowanceStep;
    _dirty = true;
    for (final hex in _held.keys.toList()..sort()) {
      if (size >= _allowance) break;
      _ids[hex] = _held.remove(hex)!;
    }
    if (_held.isEmpty && size < _allowance) _closed = false;
  }

  /// Records the pair, then returns its refusal.
  ///
  /// An unknown id is added with its key (`none`) when the record is open
  /// and has room under its allowance. Otherwise the record closes and the
  /// id is held with its key: remembered, `unrecorded`, not attributable
  /// (at [kMaxKeyHistoryTotal] entries it cannot even be held). The same
  /// key again is `none` for a recorded id and still `unrecorded` for a
  /// held one. Another key moves the id, recorded or held, to the tainted
  /// list for good: `tainted`, on every key from then on. An unreadable
  /// record answers `unreadable` and never changes. This device is never
  /// recorded and never refused.
  KeyRefusal admit(String deviceIdHex, Uint8List signatureKey) {
    // This device first: never refused, also by an unreadable history.
    if (deviceIdHex == _thisHex) return KeyRefusal.none;
    return _admitOther(deviceIdHex, signatureKey);
  }

  /// Plan 5a Task 12, "set up again" (carryovers from Task 5): this
  /// device's OLD (id, key) is recorded as [admit] records any other
  /// device's, although the history still reads it as this device. Its
  /// pin becomes a former pin while the device takes a new id, and from
  /// then on the cross-check holds the old id to that key like any other
  /// pin. Nothing else in the record changes; no id or taint is dropped.
  KeyRefusal admitFormerSelf(String deviceIdHex, Uint8List signatureKey) =>
      _admitOther(deviceIdHex, signatureKey);

  KeyRefusal _admitOther(String deviceIdHex, Uint8List signatureKey) {
    if (unreadable) return KeyRefusal.unreadable;
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
    final held = _held[deviceIdHex];
    if (held != null) {
      if (held == key) return KeyRefusal.unrecorded;
      // A key change while held taints like any other: the allowance is
      // not asked, and the total does not change.
      _held.remove(deviceIdHex);
      _changed.add(deviceIdHex);
      _dirty = true;
      return KeyRefusal.tainted;
    }
    if (_closed || size >= _allowance) {
      if (!_closed) {
        _closed = true;
        _dirty = true;
      }
      // Remembered with the key first seen, unless the record is full.
      if (total < kMaxKeyHistoryTotal) {
        _held[deviceIdHex] = key;
        _dirty = true;
      }
      return KeyRefusal.unrecorded;
    }
    _ids[deviceIdHex] = key;
    _dirty = true;
    return KeyRefusal.none;
  }

  /// Read-only, for attribution: the id recorded with exactly this key is
  /// `none`; a tainted id (or a recorded or held id asked with another key)
  /// is `tainted`; a held id on its key, or an absent id, is `unrecorded`.
  /// Nothing moves here: the commit or join that brings a changed key goes
  /// through [admit].
  KeyRefusal refusal(String deviceIdHex, Uint8List signatureKey) {
    if (deviceIdHex == _thisHex) return KeyRefusal.none;
    if (unreadable) return KeyRefusal.unreadable;
    if (_changed.contains(deviceIdHex)) return KeyRefusal.tainted;
    final key = base64Encode(signatureKey);
    final recorded = _ids[deviceIdHex];
    if (recorded != null) {
      return recorded == key ? KeyRefusal.none : KeyRefusal.tainted;
    }
    final held = _held[deviceIdHex];
    if (held != null && held != key) return KeyRefusal.tainted;
    return KeyRefusal.unrecorded;
  }

  /// Read-only, for claims and adds: [admit] would return `none`.
  bool admissible(String deviceIdHex, Uint8List signatureKey) {
    if (deviceIdHex == _thisHex) return true;
    if (unreadable) return false;
    if (_changed.contains(deviceIdHex)) return false;
    final recorded = _ids[deviceIdHex];
    if (recorded != null) return recorded == base64Encode(signatureKey);
    if (_held.containsKey(deviceIdHex)) return false;
    return !_closed && size < _allowance;
  }

  /// The stored form.
  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'ids': _ids,
        'changed': _changed.toList(),
        'held': _held,
        'closed': _closed,
        'allow': _allowance,
      }),
    ),
  );

  /// A device id: lower-case hex, whole bytes, never empty.
  static final RegExp _hex = RegExp(r'^([0-9a-f]{2})+$');

  /// A stored `{deviceIdHex: keyB64}` map (`ids` or `held`), checked.
  static Map<String, String> _decodeKeys(Map<String, Object?> raw) {
    final out = <String, String>{};
    for (final e in raw.entries) {
      final key = e.value;
      if (!_hex.hasMatch(e.key) || key is! String || key.isEmpty) {
        throw const FormatException('entry');
      }
      // A key that is not base64 cannot be compared: unreadable. Stored in
      // the canonical form the comparisons use.
      out[e.key] = base64Encode(base64Decode(key));
    }
    return out;
  }

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
    // A record written before `held` existed has none.
    final rawHeld = m.containsKey('held') ? m['held'] : <String, Object?>{};
    if (rawHeld is! Map<String, Object?>) throw const FormatException('shape');
    final ids = _decodeKeys(rawIds);
    final changed = <String>{};
    for (final id in rawChanged) {
      if (id is! String || !_hex.hasMatch(id) || ids.containsKey(id)) {
        throw const FormatException('entry');
      }
      if (!changed.add(id)) throw const FormatException('entry');
    }
    // An id is in exactly one of the three.
    final held = _decodeKeys(rawHeld);
    for (final id in held.keys) {
      if (ids.containsKey(id) || changed.contains(id)) {
        throw const FormatException('entry');
      }
    }
    // An id is held only while the record is closed.
    if (held.isNotEmpty && !closed) throw const FormatException('closed');
    // The allowance is enforced when a new id is admitted, not here: a
    // taint of a held id takes `ids` plus `changed` past it, and a taint
    // must never make the record unreadable. The total bounds the cost.
    if (ids.length + changed.length + held.length > kMaxKeyHistoryTotal) {
      throw const FormatException('size');
    }
    return KeyHistory._(
      ids: ids,
      changed: changed,
      held: held,
      closed: closed,
      allowance: allow,
      dirty: false,
      unreadable: false,
      thisDeviceHex: thisDeviceHex,
    );
  }
}
