import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_status.dart';
import 'e2ee_types.dart';

/// Vault setting prefix of the deferred record of one conversation (design
/// rev 3 §7.3): `messages.e2ee.deferred.<conversationId>`, sealed.
const String kVaultSettingDeferredPrefix = 'messages.e2ee.deferred.';

/// Items one conversation holds at most (§7.3).
const int kDeferredMax = 16;

/// A deferred ciphertext is at most this long (the receiver never gives the
/// engine a longer one, so a longer one is never deferred).
const int kMaxDeferredCiphertextBytes = 8192;

/// A deferred report commitment is at most this long (a real one is 32
/// bytes; a longer one never matches and is kept as empty).
const int kMaxDeferredCommitmentBytes = 64;

/// A stored deferred record longer than this reads as unreadable (§7.3).
const int kMaxDeferredRecordBytes = 200 * 1024;

/// The bound of every counter of an item (`k`, `cc`, `cu`); a count above
/// it is written as the bound.
const int kDeferredCounterMax = 1000;

/// Witnessed strikes after which a deferred message becomes a row (§7.5).
const int kDeferredStrikes = 3;

/// Witnessed crashes after which a deferred message becomes a row (§7.5).
const int kDeferredCrashStrikes = 2;

/// The least time between two attempts on one deferred item (§7.4).
const Duration kDeferredRetrySpacing = Duration(minutes: 10);

/// How long the server keeps a ciphertext: a deferred item is kept at most
/// this long from the earlier of its server time and its local deferred-at
/// time (§7.6 end 4).
const Duration kCiphertextRetention = Duration(days: 30);

final RegExp _idShape = RegExp(r'^[0-9a-f]{32}$');
final RegExp _runShape = RegExp(r'^[0-9a-f]{16}$');

/// What the screens need to draw the placeholder of one deferred message
/// (§10): its id and server time; no bytes. No `toString`.
class DeferredView {
  const DeferredView(this.id, this.atMicros);

  final String id;
  final int atMicros;
}

/// One deferred message (§7.3): CIPHERTEXT only, never decrypted content.
/// [at]: the server's `created_at`; [da]: local micros when deferred; [ct]
/// the ciphertext; [rc] the report commitment; [fs] the server's
/// `from_self`; [k] witnessed strikes; [cc] witnessed crashes; [cu]
/// unwitnessed crashes; [la] local micros of the last attempt; [ru] the run
/// id of the last attempt. Immutable; no `toString`.
class DeferredItem {
  const DeferredItem({
    required this.id,
    required this.pair,
    required this.at,
    required this.da,
    required this.ct,
    required this.rc,
    required this.fs,
    this.k = 0,
    this.cc = 0,
    this.cu = 0,
    required this.la,
    required this.ru,
  });

  final String id;
  final MlsPair pair;
  final int at;
  final int da;
  final Uint8List ct;
  final Uint8List rc;
  final bool fs;
  final int k;
  final int cc;
  final int cu;
  final int la;
  final String ru;

  /// Deferred, or struck, with evidence that the engine works (§7.3).
  bool get witnessed => k >= 1;

  /// A crash-class item (§7.4): at most one such retry per run.
  bool get crashClass => cc + cu >= 1;

  /// The decoder accepts a ciphertext of [ct]'s and a commitment of [rc]'s
  /// length.
  static bool fits(Uint8List ct, Uint8List rc) =>
      ct.isNotEmpty &&
      ct.length <= kMaxDeferredCiphertextBytes &&
      rc.length <= kMaxDeferredCommitmentBytes;

  /// §7.6 end 4: [nowMicros] is at or past the earlier of the server time
  /// and the local deferred-at time plus [kCiphertextRetention].
  bool expired(int nowMicros) =>
      (at < da ? at : da) + kCiphertextRetention.inMicroseconds <= nowMicros;

  DeferredItem copyWith({int? k, int? cc, int? cu, int? la, String? ru}) =>
      DeferredItem(
        id: id,
        pair: pair,
        at: at,
        da: da,
        ct: ct,
        rc: rc,
        fs: fs,
        k: k ?? this.k,
        cc: cc ?? this.cc,
        cu: cu ?? this.cu,
        la: la ?? this.la,
        ru: ru ?? this.ru,
      );

  Map<String, Object?> _json() => {
    'id': id,
    'g': pair.generation,
    'e': pair.epoch,
    'at': _time(at),
    'da': _time(da),
    'ct': base64Encode(ct),
    'rc': base64Encode(rc),
    'fs': fs,
    'k': _count(k),
    'cc': _count(cc),
    'cu': _count(cu),
    'la': _time(la),
    'ru': ru,
  };

  // Every value written is one the decoder accepts: counters and local
  // times are clamped into their bounds.
  static int _count(int n) =>
      n < 0 ? 0 : (n > kDeferredCounterMax ? kDeferredCounterMax : n);

  static int _time(int micros) => micros < 0
      ? 0
      : (micros > kMaxPairComponent ? kMaxPairComponent : micros);
}

/// The deferred record of one conversation (§7.3): at most [kDeferredMax]
/// items, one per message id. Immutable; no `toString`.
class DeferredRecord {
  const DeferredRecord([this.items = const []]);

  static const DeferredRecord empty = DeferredRecord();

  final List<DeferredItem> items;

  bool get full => items.length >= kDeferredMax;

  DeferredItem? of(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// [item] replaces the item of its id, or is added last.
  DeferredRecord put(DeferredItem item) {
    var replaced = false;
    final next = [
      for (final i in items)
        if (i.id == item.id) item else i,
    ];
    for (final i in items) {
      if (i.id == item.id) replaced = true;
    }
    if (!replaced) next.add(item);
    return DeferredRecord(next);
  }

  DeferredRecord without(Iterable<String> ids) {
    final gone = ids.toSet();
    return DeferredRecord([
      for (final i in items)
        if (!gone.contains(i.id)) i,
    ]);
  }

  /// §7.6 end 3, the eviction order: among WITNESSED items only, the one
  /// with the most strikes, then the most witnessed crashes, then the
  /// oldest server time (then the lowest id). Null: none is witnessed.
  DeferredItem? evictable() {
    DeferredItem? best;
    for (final i in items) {
      if (!i.witnessed) continue;
      if (best == null || _evictBefore(i, best)) best = i;
    }
    return best;
  }

  static bool _evictBefore(DeferredItem a, DeferredItem b) {
    if (a.k != b.k) return a.k > b.k;
    if (a.cc != b.cc) return a.cc > b.cc;
    if (a.at != b.at) return a.at < b.at;
    return a.id.compareTo(b.id) < 0;
  }

  /// §10: ids and server times, newest first, leaving out items at or
  /// before [clearedAtMicros]. No bytes.
  List<DeferredView> view({int? clearedAtMicros}) {
    final shown = [
      for (final i in items)
        if (clearedAtMicros == null || i.at > clearedAtMicros) i,
    ];
    shown.sort((a, b) {
      final c = b.at.compareTo(a.at);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
    return [for (final i in shown) DeferredView(i.id, i.at)];
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'items': [for (final i in items) i._json()],
      }),
    ),
  );

  /// Throws [FormatException] for anything but exactly §7.3's shape within
  /// its bounds.
  static DeferredRecord decode(Uint8List bytes) {
    if (bytes.length > kMaxDeferredRecordBytes) {
      throw const FormatException('size');
    }
    final m = jsonDecode(utf8.decode(bytes));
    if (m is! Map<String, Object?> || m['v'] != 1) {
      throw const FormatException('shape');
    }
    final raw = m['items'];
    if (raw is! List<Object?> || raw.length > kDeferredMax) {
      throw const FormatException('items');
    }
    final items = <DeferredItem>[];
    final ids = <String>{};
    for (final r in raw) {
      final item = _item(r);
      if (!ids.add(item.id)) throw const FormatException('id');
      items.add(item);
    }
    return DeferredRecord(items);
  }

  static DeferredItem _item(Object? raw) {
    if (raw is! Map<String, Object?>) throw const FormatException('item');
    final id = raw['id'];
    final fs = raw['fs'];
    final ru = raw['ru'];
    if (id is! String ||
        !_idShape.hasMatch(id) ||
        fs is! bool ||
        ru is! String ||
        !_runShape.hasMatch(ru)) {
      throw const FormatException('item');
    }
    final k = _int(raw['k'], kDeferredCounterMax);
    final cc = _int(raw['cc'], kDeferredCounterMax);
    final cu = _int(raw['cu'], kDeferredCounterMax);
    // An item is held for a reason: a strike or a crash.
    if (k + cc + cu < 1) throw const FormatException('item');
    final ct = _b64(raw['ct']);
    final rc = _b64(raw['rc']);
    if (!DeferredItem.fits(ct, rc)) throw const FormatException('bytes');
    return DeferredItem(
      id: id,
      pair: MlsPair(
        _int(raw['g'], kMaxPairComponent),
        _int(raw['e'], kMaxPairComponent),
      ),
      at: _int(raw['at'], kMaxPairComponent),
      da: _int(raw['da'], kMaxPairComponent),
      ct: ct,
      rc: rc,
      fs: fs,
      k: k,
      cc: cc,
      cu: cu,
      la: _int(raw['la'], kMaxPairComponent),
      ru: ru,
    );
  }

  static int _int(Object? raw, int max) {
    if (raw is! int || raw < 0 || raw > max) {
      throw const FormatException('int');
    }
    return raw;
  }

  static Uint8List _b64(Object? raw) {
    if (raw is! String) throw const FormatException('b64');
    // The longest accepted value, before it is decoded.
    if (raw.length > 4 * ((kMaxDeferredCiphertextBytes + 2) ~/ 3)) {
      throw const FormatException('b64');
    }
    return base64Decode(raw);
  }
}

/// Reads and writes the deferred records (one sealed setting per
/// conversation). An unreadable value (not §7.3's shape, over the bounds,
/// or a seal that does not open) reads as empty with `unreadable` set,
/// reported once per conversation per run as
/// `E2eePipelineError('receive.deferred.read')`; the receiver then replaces
/// it and resets the conversation's walks in one transaction. Never logs.
class DeferredRecords {
  DeferredRecords({
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _onUnexpectedError = onUnexpectedError;

  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Set<String> _reported = {};

  static String keyOf(String conversationId) =>
      '$kVaultSettingDeferredPrefix$conversationId';

  Future<({DeferredRecord record, bool unreadable})> read(
    SecureVault vault,
    String conversationId,
  ) async {
    try {
      final bytes = await vault.setting(keyOf(conversationId));
      return (
        record: bytes == null
            ? DeferredRecord.empty
            : DeferredRecord.decode(bytes),
        unreadable: false,
      );
    } on FormatException catch (_, stack) {
      _unreadable(conversationId, stack);
    } on VaultCorruptException catch (_, stack) {
      _unreadable(conversationId, stack);
    }
    return (record: DeferredRecord.empty, unreadable: true);
  }

  /// Writes [record] in [tx] (call at most once per transaction).
  Future<void> putIn(
    VaultTx tx,
    String conversationId,
    DeferredRecord record,
  ) => tx.putSetting(keyOf(conversationId), record.encode());

  void _unreadable(String conversationId, StackTrace stack) {
    if (!_reported.add(conversationId)) return;
    _onUnexpectedError?.call(
      const E2eePipelineError('receive.deferred.read'),
      stack,
    );
  }
}
