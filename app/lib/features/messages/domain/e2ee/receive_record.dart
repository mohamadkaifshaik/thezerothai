import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_status.dart';
import 'e2ee_types.dart';

/// Vault setting prefix of the receive record of one conversation (design
/// rev 3 §3.1): `messages.e2ee.receive.<conversationId>`, sealed.
const String kVaultSettingReceivePrefix = 'messages.e2ee.receive.';

/// A token longer than this is treated as refused (§3.1).
const int kMaxTokenChars = 1024;

/// The one token shape (next, resume, settle, reconcile, anchor): printable
/// ASCII without `"` or `\`, at most [kMaxTokenChars] characters. JSON writes
/// each of these characters as one byte, so a record of tokens in this shape
/// stays within [kMaxReceiveRecordBytes]; a token outside it is treated as
/// refused and is never recorded. The server's tokens are base64url.
final RegExp _tokenShape = RegExp(
  '^[\\x21\\x23-\\x5b\\x5d-\\x7e]{0,$kMaxTokenChars}\$',
);

/// [token] has the one token shape ([kMaxTokenChars]).
bool isTokenShape(String token) => _tokenShape.hasMatch(token);

/// A stored receive record longer than this reads as unreadable (§3.1).
const int kMaxReceiveRecordBytes = 16 * 1024;

final RegExp _idShape = RegExp(r'^[0-9a-f]{32}$');

/// A listing position: the server's `created_at` in microseconds, then the
/// message id; id `''` is a time-only position, before every id at [at].
/// No `toString` (it holds a message id).
class WalkPos {
  const WalkPos(this.at, this.id);

  final int at;
  final String id;

  int compareTo(WalkPos other) {
    final c = at.compareTo(other.at);
    return c != 0 ? c : id.compareTo(other.id);
  }

  @override
  bool operator ==(Object other) =>
      other is WalkPos && other.at == at && other.id == id;

  @override
  int get hashCode => Object.hash(at, id);
}

/// How a close walk handles its messages: `c` decrypts, `u` writes an
/// undecryptable row for every unstored message with no engine call.
enum WalkMode { decrypt, undecryptable }

const Object _keep = Object();

/// One walk of one pair (§3.1 `W`): the next page token [t], the settle
/// token [s], [r] (the next page starts a listing), [c] (every page of the
/// current listing so far was settled), [end] (the last listing reached its
/// end), [l] (the last message of the last applied page), [f] (the settle
/// floor), [lt] (open only: local micros when the last listing from [s]
/// began) and [mode] (close only). Immutable; no `toString`.
class WalkEntry {
  const WalkEntry({
    required this.pair,
    this.t = '',
    this.s = '',
    this.r = true,
    this.c = true,
    this.end = false,
    this.l,
    this.f,
    this.lt,
    this.mode,
  });

  final MlsPair pair;
  final String t;
  final String s;
  final bool r;
  final bool c;
  final bool end;
  final WalkPos? l;
  final WalkPos? f;
  final int? lt;
  final WalkMode? mode;

  WalkEntry copyWith({
    String? t,
    String? s,
    bool? r,
    bool? c,
    bool? end,
    Object? l = _keep,
    Object? f = _keep,
    Object? lt = _keep,
    Object? mode = _keep,
  }) => WalkEntry(
    pair: pair,
    t: t ?? this.t,
    s: s ?? this.s,
    r: r ?? this.r,
    c: c ?? this.c,
    end: end ?? this.end,
    l: identical(l, _keep) ? this.l : l as WalkPos?,
    f: identical(f, _keep) ? this.f : f as WalkPos?,
    lt: identical(lt, _keep) ? this.lt : lt as int?,
    mode: identical(mode, _keep) ? this.mode : mode as WalkMode?,
  );

  /// A refused page token (§3.2): the walk lists again from the start.
  WalkEntry restarted() =>
      copyWith(t: '', s: '', r: true, c: true, l: null, f: null);

  /// A close or orphan slot created from this walk (§5.2): a new listing
  /// from the settle token.
  WalkEntry adopted(WalkMode? mode) =>
      WalkEntry(pair: pair, t: s, s: s, l: l, f: f, mode: mode);

  /// The entry after one applied page (§3.2). [last]: the page's last
  /// message (null for an empty page); [nowLocal]: set as [lt] when this
  /// page starts a listing and [open] is true (0 for a local clock before
  /// 1970, which the decoder would refuse).
  WalkEntry afterPage({
    required String next,
    required String resume,
    required bool settled,
    required WalkPos? last,
    required bool open,
    required int nowLocal,
  }) {
    var s = this.s;
    var c = this.c;
    var f = this.f;
    var end = this.end;
    var lt = this.lt;
    if (r) {
      end = false;
      if (open) lt = nowLocal < 0 ? 0 : nowLocal;
    }
    if (c) {
      s = resume;
      if (settled && last != null) f = last;
      if (!settled) c = false;
    }
    var t = next;
    var r2 = false;
    if (next.isEmpty) {
      t = s;
      r2 = true;
      c = true;
      end = true;
    }
    return WalkEntry(
      pair: pair,
      t: t,
      s: s,
      r: r2,
      c: c,
      end: end,
      l: last ?? l,
      f: f,
      lt: lt,
      mode: mode,
    );
  }
}

/// The reconcile cursor (§3.1 `rec`). Its listing is step 2's; step 1 only
/// creates, resets and arms it. No `toString`.
class ReconcileEntry {
  const ReconcileEntry({
    required this.armed,
    this.t = '',
    this.n = 0,
    this.l = '',
  });

  final bool armed;
  final String t;
  final int n;
  final String l;
}

/// The receive record of one conversation (§3.1). Step 1 always writes
/// `gf: null`. No `toString`.
class ReceiveRecord {
  const ReceiveRecord({
    this.open,
    this.close,
    this.orphan,
    this.rec,
    this.anchor = '',
  });

  static const ReceiveRecord empty = ReceiveRecord();

  final WalkEntry? open;
  final WalkEntry? close;
  final WalkEntry? orphan;
  final ReconcileEntry? rec;
  final String anchor;

  ReceiveRecord copyWith({
    Object? open = _keep,
    Object? close = _keep,
    Object? orphan = _keep,
    Object? rec = _keep,
    String? anchor,
  }) => ReceiveRecord(
    open: identical(open, _keep) ? this.open : open as WalkEntry?,
    close: identical(close, _keep) ? this.close : close as WalkEntry?,
    orphan: identical(orphan, _keep) ? this.orphan : orphan as WalkEntry?,
    rec: identical(rec, _keep) ? this.rec : rec as ReconcileEntry?,
    anchor: anchor ?? this.anchor,
  );

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'open': _walkJson(open, close: false, lt: true),
        'close': _walkJson(close, close: true),
        // §3.1: `lt` is the open walk's only (decode still accepts an old
        // orphan entry that has it).
        'orphan': _walkJson(orphan, close: false),
        'rec': rec == null
            ? null
            : {'armed': rec!.armed, 't': rec!.t, 'n': rec!.n, 'l': rec!.l},
        'anchor': anchor,
        'gf': null,
      }),
    ),
  );

  /// Throws [FormatException] for anything but exactly §3.1's shape within
  /// its bounds.
  static ReceiveRecord decode(Uint8List bytes) {
    if (bytes.length > kMaxReceiveRecordBytes) {
      throw const FormatException('size');
    }
    final m = jsonDecode(utf8.decode(bytes));
    if (m is! Map<String, Object?> || m['v'] != 1) {
      throw const FormatException('shape');
    }
    for (final k in const ['open', 'close', 'orphan', 'rec', 'anchor', 'gf']) {
      if (!m.containsKey(k)) throw const FormatException('shape');
    }
    final rec = m['rec'];
    ReconcileEntry? reconcile;
    if (rec != null) {
      if (rec is! Map<String, Object?>) throw const FormatException('rec');
      final armed = rec['armed'];
      final n = rec['n'];
      final l = rec['l'];
      if (armed is! bool ||
          n is! int ||
          n < 0 ||
          l is! String ||
          (l.isNotEmpty && !_idShape.hasMatch(l))) {
        throw const FormatException('rec');
      }
      reconcile = ReconcileEntry(armed: armed, t: _token(rec['t']), n: n, l: l);
    }
    final gf = m['gf'];
    if (gf != null && gf is! Map<String, Object?>) {
      throw const FormatException('gf');
    }
    return ReceiveRecord(
      open: _walk(m['open'], close: false),
      close: _walk(m['close'], close: true),
      orphan: _walk(m['orphan'], close: false),
      rec: reconcile,
      anchor: _token(m['anchor']),
    );
  }

  static Object? _walkJson(
    WalkEntry? w, {
    required bool close,
    bool lt = false,
  }) {
    if (w == null) return null;
    return {
      'g': w.pair.generation,
      'e': w.pair.epoch,
      't': w.t,
      's': w.s,
      'r': w.r,
      'c': w.c,
      'end': w.end,
      'l': _posJson(w.l),
      'f': _posJson(w.f),
      if (lt) 'lt': w.lt,
      if (close) 'm': w.mode == WalkMode.undecryptable ? 'u' : 'c',
    };
  }

  static Object? _posJson(WalkPos? p) => p == null ? null : [p.at, p.id];

  static WalkEntry? _walk(Object? raw, {required bool close}) {
    if (raw == null) return null;
    if (raw is! Map<String, Object?>) throw const FormatException('walk');
    final g = raw['g'];
    final e = raw['e'];
    final r = raw['r'];
    final c = raw['c'];
    final end = raw['end'];
    if (g is! int ||
        e is! int ||
        g < 0 ||
        e < 0 ||
        g > kMaxPairComponent ||
        e > kMaxPairComponent ||
        r is! bool ||
        c is! bool ||
        end is! bool) {
      throw const FormatException('walk');
    }
    final lt = raw['lt'];
    if (lt != null && (lt is! int || lt < 0)) {
      throw const FormatException('lt');
    }
    WalkMode? mode;
    if (close) {
      mode = switch (raw['m']) {
        'c' => WalkMode.decrypt,
        'u' => WalkMode.undecryptable,
        _ => throw const FormatException('m'),
      };
    }
    return WalkEntry(
      pair: MlsPair(g, e),
      t: _token(raw['t']),
      s: _token(raw['s']),
      r: r,
      c: c,
      end: end,
      l: _pos(raw['l'], timeOnly: false),
      f: _pos(raw['f'], timeOnly: true),
      lt: close ? null : lt as int?,
      mode: mode,
    );
  }

  static WalkPos? _pos(Object? raw, {required bool timeOnly}) {
    if (raw == null) return null;
    if (raw is! List<Object?> || raw.length != 2) {
      throw const FormatException('pos');
    }
    final at = raw[0];
    final id = raw[1];
    if (at is! int || at < 0 || at > kMaxPairComponent || id is! String) {
      throw const FormatException('pos');
    }
    if (!(_idShape.hasMatch(id) || (timeOnly && id.isEmpty))) {
      throw const FormatException('pos');
    }
    return WalkPos(at, id);
  }

  static String _token(Object? raw) {
    if (raw is! String || !isTokenShape(raw)) {
      throw const FormatException('token');
    }
    return raw;
  }

  /// §3.4: the record cross-checked against the vault ([sync], [groups] as
  /// stored now). Rules, in order: (1) a close or orphan slot whose pair is
  /// completed, or whose generation's group moved past its epoch, is ended
  /// (null); a close slot whose group is gone switches to mode `u`; (2) the
  /// orphan check (§6): a stored final group below the current generation
  /// whose last epoch is not completed gets the orphan slot (adopting `open`
  /// when that is for the pair); (3) `open` is null while a close or orphan
  /// slot holds the current pair, else it is for the current pair (created
  /// from the start when missing or for another pair); (4) an empty since
  /// token with no reconcile entry creates an armed one; (5) `gf` is null.
  ReceiveRecord normalized({
    required ConversationSync sync,
    required List<GroupRecord> groups,
  }) {
    final finals = [
      for (final g in groups)
        if (!g.provisional) g,
    ]..sort((a, b) => a.generation.compareTo(b.generation));
    final byGeneration = {for (final g in finals) g.generation: g};
    final current = finals.isEmpty ? null : finals.last;
    final done = sync.completedEpochs;
    bool ended(WalkEntry w) {
      final group = byGeneration[w.pair.generation];
      return done.contains(w.pair) ||
          (group != null && group.epoch > w.pair.epoch);
    }

    var open = this.open;
    var close = this.close;
    var orphan = this.orphan;
    if (close != null && ended(close)) close = null;
    if (close != null &&
        byGeneration[close.pair.generation] == null &&
        close.mode != WalkMode.undecryptable) {
      close = close.copyWith(mode: WalkMode.undecryptable);
    }
    if (orphan != null && ended(orphan)) orphan = null;
    if (orphan == null && current != null) {
      for (final g in finals) {
        final pair = MlsPair(g.generation, g.epoch);
        if (g.generation >= current.generation || done.contains(pair)) {
          continue;
        }
        // M4: the close slot already walks this pair (one slot per pair).
        if (close?.pair == pair) continue;
        if (open != null && open.pair == pair) {
          orphan = open.adopted(null);
          open = null;
        } else {
          orphan = WalkEntry(pair: pair);
        }
        break;
      }
    }
    if (current != null) {
      final cp = MlsPair(current.generation, current.epoch);
      if (close?.pair == cp || orphan?.pair == cp) {
        open = null;
      } else if (open == null || open.pair != cp) {
        open = WalkEntry(pair: cp);
      }
    }
    var rec = this.rec;
    if (sync.sinceToken.isEmpty && rec == null) {
      rec = const ReconcileEntry(armed: true);
    }
    return ReceiveRecord(
      open: open,
      close: close,
      orphan: orphan,
      rec: rec,
      anchor: anchor,
    );
  }
}

/// Reads and writes the receive records (one sealed setting per
/// conversation). An unreadable value (not §3.1's shape, over the bounds, or
/// a seal that does not open) reads as empty, reported once per
/// conversation per run as `E2eePipelineError('receive.read')`; the next
/// write replaces it. Never logs.
class ReceiveRecords {
  ReceiveRecords({
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _onUnexpectedError = onUnexpectedError;

  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Set<String> _reported = {};

  static String keyOf(String conversationId) =>
      '$kVaultSettingReceivePrefix$conversationId';

  /// The stored record as it is (not normalized), or empty.
  Future<ReceiveRecord> read(SecureVault vault, String conversationId) async {
    try {
      final bytes = await vault.setting(keyOf(conversationId));
      if (bytes == null) return ReceiveRecord.empty;
      return ReceiveRecord.decode(bytes);
    } on FormatException catch (_, stack) {
      _unreadable(conversationId, stack);
    } on VaultCorruptException catch (_, stack) {
      _unreadable(conversationId, stack);
    }
    return ReceiveRecord.empty;
  }

  /// Writes [record] in [tx] (call at most once per transaction).
  Future<void> putIn(VaultTx tx, String conversationId, ReceiveRecord record) =>
      tx.putSetting(keyOf(conversationId), record.encode());

  void _unreadable(String conversationId, StackTrace stack) {
    if (!_reported.add(conversationId)) return;
    _onUnexpectedError?.call(const E2eePipelineError('receive.read'), stack);
  }
}
