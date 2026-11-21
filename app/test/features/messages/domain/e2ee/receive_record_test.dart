import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/receive_record.dart';
import 'package:flutter_test/flutter_test.dart';

const _c1 = '11111111111111111111111111111111';
final _hex = 'a' * 32;

/// A walk entry exactly as §3.1 stores it.
Map<String, Object?> _walk({bool close = false}) => {
  'g': 1,
  'e': 1,
  't': '',
  's': '',
  'r': true,
  'c': true,
  'end': false,
  'l': [10, _hex],
  'f': [5, ''],
  if (!close) 'lt': 7,
  if (close) 'm': 'c',
};

/// A record with every key present and every slot set.
Map<String, Object?> _record() => {
  'v': 1,
  'open': _walk(),
  'close': _walk(close: true),
  'orphan': _walk(),
  'rec': {'armed': true, 't': '', 'n': 0, 'l': ''},
  'anchor': '',
  'gf': null,
};

Map<String, Object?> _slot(Map<String, Object?> r, String key) =>
    r[key]! as Map<String, Object?>;

Uint8List _bytes(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

/// A vault whose receive setting holds [bytes] (or throws [error]); every
/// other call is a test bug.
class _Vault implements SecureVault {
  _Vault(this.bytes, {this.error});

  final Uint8List? bytes;
  final Object? error;

  @override
  Future<Uint8List?> setting(String key) async {
    if (error != null) throw error!;
    return bytes;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('the receive record codec bounds (§3.1)', () {
    // (row, change to a valid record, decodes). A row that does not decode
    // throws FormatException, and ReceiveRecords.read returns the
    // unreadable record for it (empty but for an armed reconcile entry;
    // reported once as receive.read).
    final rows = <(String, void Function(Map<String, Object?> r), bool)>[
      ('a valid record', (_) {}, true),
      (
        'a value over 16 KB',
        (r) => r['pad'] = 'x' * kMaxReceiveRecordBytes,
        false,
      ),
      (
        'a token of exactly 1,024 characters',
        (r) => _slot(r, 'open')['t'] = 'x' * kMaxTokenChars,
        true,
      ),
      (
        'a next token over 1,024 characters',
        (r) => _slot(r, 'open')['t'] = 'x' * (kMaxTokenChars + 1),
        false,
      ),
      (
        'a settle token over 1,024 characters',
        (r) => _slot(r, 'close')['s'] = 'x' * (kMaxTokenChars + 1),
        false,
      ),
      (
        'an anchor over 1,024 characters',
        (r) => r['anchor'] = 'x' * (kMaxTokenChars + 1),
        false,
      ),
      (
        'a reconcile token over 1,024 characters',
        (r) => _slot(r, 'rec')['t'] = 'x' * (kMaxTokenChars + 1),
        false,
      ),
      (
        'a token with a control character',
        (r) => _slot(r, 'open')['t'] = 'a\u0001b',
        false,
      ),
      (
        'a token with a non-ASCII character',
        (r) => _slot(r, 'close')['s'] = 'aéb',
        false,
      ),
      ('a token with a quote', (r) => r['anchor'] = 'a"b', false),
      ('a token with a backslash', (r) => _slot(r, 'rec')['t'] = r'a\b', false),
      ('a token with a space', (r) => _slot(r, 'orphan')['t'] = 'a b', false),
      (
        'a token of every allowed character',
        (r) => _slot(r, 'open')['s'] = String.fromCharCodes([
          for (var c = 0x21; c <= 0x7e; c++)
            if (c != 0x22 && c != 0x5c) c,
        ]),
        true,
      ),
      ('a negative lt', (r) => _slot(r, 'open')['lt'] = -1, false),
      (
        'an upper-case id in l',
        (r) => _slot(r, 'open')['l'] = [10, 'A' * 32],
        false,
      ),
      (
        'a 31-character id in l',
        (r) => _slot(r, 'open')['l'] = [10, 'a' * 31],
        false,
      ),
      (
        'a time-only position in l',
        (r) => _slot(r, 'open')['l'] = [10, ''],
        false,
      ),
      (
        'a time-only position in f',
        (r) => _slot(r, 'orphan')['f'] = [10, ''],
        true,
      ),
      (
        'a non-hex id in f',
        (r) => _slot(r, 'orphan')['f'] = [10, 'g' * 32],
        false,
      ),
      (
        'a non-hex last tombstone id',
        (r) => _slot(r, 'rec')['l'] = 'g' * 32,
        false,
      ),
      ('G at 2^53 - 1', (r) => _slot(r, 'open')['g'] = kMaxPairComponent, true),
      (
        'G at 2^53',
        (r) => _slot(r, 'open')['g'] = kMaxPairComponent + 1,
        false,
      ),
      (
        'E at 2^53',
        (r) => _slot(r, 'close')['e'] = kMaxPairComponent + 1,
        false,
      ),
      (
        'a position time at 2^53',
        (r) => _slot(r, 'open')['l'] = [kMaxPairComponent + 1, _hex],
        false,
      ),
      ('a negative G', (r) => _slot(r, 'open')['g'] = -1, false),
      for (final key in const [
        'v',
        'open',
        'close',
        'orphan',
        'rec',
        'anchor',
        'gf',
      ])
        ('a missing "$key"', (r) => r.remove(key), false),
      ('a missing "end"', (r) => _slot(r, 'open').remove('end'), false),
      ('an unknown version', (r) => r['v'] = 2, false),
      ('an unknown m', (r) => _slot(r, 'close')['m'] = 'x', false),
      ('a close entry with no m', (r) => _slot(r, 'close').remove('m'), false),
      ('a number for gf', (r) => r['gf'] = 1, false),
      ('a list for gf', (r) => r['gf'] = <Object?>[], false),
      ('a string for gf', (r) => r['gf'] = 'x', false),
      ('an empty object for gf', (r) => r['gf'] = <String, Object?>{}, false),
      (
        'a group failure count',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2},
        true,
      ),
      (
        'a group failure count of 0',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 0},
        false,
      ),
      (
        'a group failure count above the maximum',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': kGroupFailuresMax + 1},
        false,
      ),
      (
        'a group failure pair above 2^53 - 1',
        (r) => r['gf'] = {'g': kMaxPairComponent + 1, 'e': 1, 'n': 1},
        false,
      ),
      ('a group failure with no n', (r) => r['gf'] = {'g': 1, 'e': 1}, false),
      (
        'a group failure with the time of its last counted strike at its '
            'maximum',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'at': kMaxPairComponent},
        true,
      ),
      (
        'a negative group failure time',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'at': -1},
        false,
      ),
      (
        'a group failure time at 2^53',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'at': kMaxPairComponent + 1},
        false,
      ),
      (
        'a string for the group failure time',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'at': '1'},
        false,
      ),
      (
        'a group failure count of the full-record kind',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'k': 'f'},
        true,
      ),
      (
        'a group failure count of the describe-failed kind',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'k': 'd'},
        true,
      ),
      (
        'a group failure count with no kind',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'at': 5},
        true,
      ),
      (
        'a group failure count of an unknown kind',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'k': 'x'},
        false,
      ),
      (
        'a number for the group failure kind',
        (r) => r['gf'] = {'g': 1, 'e': 1, 'n': 2, 'k': 1},
        false,
      ),
      (
        'a reconcile failure count at its maximum with its time',
        (r) => _slot(r, 'rec')
          ..['f'] = kReconcileGiveUpAfter
          ..['fa'] = kMaxPairComponent,
        true,
      ),
      (
        'a negative reconcile failure count',
        (r) => _slot(r, 'rec')['f'] = -1,
        false,
      ),
      (
        'a reconcile failure count above its maximum',
        (r) => _slot(r, 'rec')['f'] = kReconcileGiveUpAfter + 1,
        false,
      ),
      (
        'a string for the reconcile failure count',
        (r) => _slot(r, 'rec')['f'] = '1',
        false,
      ),
      (
        'a negative reconcile failure time',
        (r) => _slot(r, 'rec')['fa'] = -1,
        false,
      ),
      (
        'a reconcile failure time at 2^53',
        (r) => _slot(r, 'rec')['fa'] = kMaxPairComponent + 1,
        false,
      ),
      (
        'a string for the reconcile failure time',
        (r) => _slot(r, 'rec')['fa'] = 'x',
        false,
      ),
      (
        'a reconcile page count above 2^53 - 1',
        (r) => _slot(r, 'rec')['n'] = kMaxPairComponent + 1,
        false,
      ),
      ('an abandoned-walk count', (r) => r['ab'] = 3, true),
      ('a negative abandoned-walk count', (r) => r['ab'] = -1, false),
      (
        'an abandoned-walk count above its bound',
        (r) => r['ab'] = kAbandonedWalksMax + 1,
        false,
      ),
      ('a string for the abandoned-walk count', (r) => r['ab'] = '1', false),
      (
        'a refusal count at its maximum with its time',
        (r) => _slot(r, 'close')
          ..['mf'] = kWalkGiveUpAfter
          ..['mfAt'] = kMaxPairComponent,
        true,
      ),
      ('a negative refusal count', (r) => _slot(r, 'close')['mf'] = -1, false),
      (
        'a refusal count above its maximum',
        (r) => _slot(r, 'orphan')['mf'] = kWalkGiveUpAfter + 1,
        false,
      ),
      (
        'a string for the refusal count',
        (r) => _slot(r, 'close')['mf'] = '1',
        false,
      ),
      ('a negative refusal time', (r) => _slot(r, 'close')['mfAt'] = -1, false),
      (
        'a refusal time at 2^53',
        (r) => _slot(r, 'orphan')['mfAt'] = kMaxPairComponent + 1,
        false,
      ),
      (
        'a string for the refusal time',
        (r) => _slot(r, 'close')['mfAt'] = 'x',
        false,
      ),
      (
        'an old orphan entry with lt',
        (r) => _slot(r, 'orphan')['lt'] = 9,
        true,
      ),
      ('a slot that is not an object', (r) => r['open'] = 'x', false),
      ('not an object at all', (r) => r['v'] = null, false),
    ];

    for (final (name, change, decodes) in rows) {
      test('$name ${decodes ? 'decodes' : 'reads as unreadable'}', () async {
        final m = _record();
        change(m);
        final bytes = _bytes(m);
        if (decodes) {
          expect(() => ReceiveRecord.decode(bytes), returnsNormally);
        } else {
          expect(
            () => ReceiveRecord.decode(bytes),
            throwsA(isA<FormatException>()),
          );
        }
        final reported = <Object>[];
        final records = ReceiveRecords(
          onUnexpectedError: (e, _) => reported.add(e),
        );
        final read = await records.read(_Vault(bytes), _c1);
        if (decodes) {
          expect(read, isNot(same(ReceiveRecord.empty)));
          expect(reported, isEmpty);
        } else {
          expect(read, same(ReceiveRecord.unreadable));
          expect(reported.single, isA<E2eePipelineError>());
          expect((reported.single as E2eePipelineError).step, 'receive.read');
          // Once per conversation per run.
          await records.read(_Vault(bytes), _c1);
          expect(reported, hasLength(1));
        }
      });
    }

    test('a seal that does not open reads as unreadable', () async {
      final reported = <Object>[];
      final read = await ReceiveRecords(
        onUnexpectedError: (e, _) => reported.add(e),
      ).read(_Vault(null, error: const VaultCorruptException('x')), _c1);
      expect(read, same(ReceiveRecord.unreadable));
      expect(reported, hasLength(1));
    });

    test('an unreadable receive record with a since token stored reads with '
        'the reconcile armed', () async {
      final stored = const ConversationSync().copyWith(sinceToken: 'token-a');
      final reported = <Object>[];
      final read = await ReceiveRecords(
        onUnexpectedError: (e, _) => reported.add(e),
      ).read(_Vault(Uint8List.fromList([1, 2, 3])), _c1);
      expect(reported, hasLength(1));

      // Whatever it held (an armed reconcile, perhaps), it reads with the
      // entry armed from the top, also with a since token stored.
      final rec = read.normalized(sync: stored, groups: const []).rec;
      expect(rec, isNotNull);
      expect((rec!.armed, rec.t, rec.n, rec.l, rec.f), (true, '', 0, '', 0));
      // No walk, no anchor, no count: everything else is as an empty one.
      expect(
        (read.open, read.close, read.orphan, read.anchor, read.gf),
        (null, null, null, '', null),
      );
      expect(read.abandoned, 0);

      // A MISSING record keeps its rule: no entry while a token is stored,
      // an armed one while none is.
      final missing = await ReceiveRecords().read(_Vault(null), _c1);
      expect(missing, same(ReceiveRecord.empty));
      expect(missing.normalized(sync: stored, groups: const []).rec, isNull);
      expect(
        missing
            .normalized(sync: const ConversationSync(), groups: const [])
            .rec!
            .armed,
        isTrue,
      );
    });

    test('a worst-case record (every token slot at 1,024 allowed characters) '
        'encodes under the 16 KiB bound', () {
      // The widest allowed character JSON can write is still one byte.
      final token = '~' * kMaxTokenChars;
      final pos = WalkPos(kMaxPairComponent, _hex);
      WalkEntry walk({WalkMode? mode, int? lt}) => WalkEntry(
        pair: const MlsPair(kMaxPairComponent, kMaxPairComponent),
        t: token,
        s: token,
        r: false,
        c: false,
        end: true,
        l: pos,
        f: pos,
        lt: lt,
        mode: mode,
        // The refusal count and its time at their maxima.
        mf: kWalkGiveUpAfter,
        mfAt: kMaxPairComponent,
      );
      final r = ReceiveRecord(
        open: walk(lt: kMaxPairComponent),
        close: walk(mode: WalkMode.undecryptable),
        orphan: walk(),
        rec: ReconcileEntry(
          armed: true,
          t: token,
          n: kMaxPairComponent,
          l: _hex,
          // The reconcile failure count and its time at their maxima.
          f: kReconcileGiveUpAfter,
          fa: kMaxPairComponent,
        ),
        anchor: token,
        // The group failure count, the time of its last counted strike and
        // the abandoned-walk count at their maxima too, with the kind of
        // the count (either value is written as one character).
        gf: const GroupFailures(
          MlsPair(kMaxPairComponent, kMaxPairComponent),
          kGroupFailuresMax,
          at: kMaxPairComponent,
          kind: GroupFailureKind.describeFailed,
        ),
        abandoned: kAbandonedWalksMax,
      );
      final bytes = r.encode();
      expect(bytes.length, lessThan(kMaxReceiveRecordBytes));
      final again = ReceiveRecord.decode(bytes);
      expect(again.anchor, token);
      expect(again.gf!.n, kGroupFailuresMax);
      expect(again.gf!.pair.epoch, kMaxPairComponent);
      expect(again.gf!.at, kMaxPairComponent);
      expect(again.gf!.kind, GroupFailureKind.describeFailed);
      expect(again.abandoned, kAbandonedWalksMax);
      expect(
        (again.rec!.f, again.rec!.fa),
        (kReconcileGiveUpAfter, kMaxPairComponent),
      );
      for (final w in [again.open!, again.close!, again.orphan!]) {
        expect((w.mf, w.mfAt), (kWalkGiveUpAfter, kMaxPairComponent));
      }
    });

    test('the reconcile failure count round-trips, is clamped into its bounds '
        'at encode, is kept by a restart, and a record without it reads '
        '0', () {
      ReconcileEntry? again(ReconcileEntry e) =>
          ReceiveRecord.decode(ReceiveRecord(rec: e).encode()).rec;
      const e = ReconcileEntry(
        armed: true,
        t: 'tok',
        n: 4,
        l: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        f: 3,
        fa: 99,
      );
      final back = again(e)!;
      expect((back.armed, back.t, back.n, back.l), (true, 'tok', 4, e.l));
      expect((back.f, back.fa), (3, 99));
      final restarted = e.restarted(armed: false);
      expect(
        (restarted.armed, restarted.t, restarted.n, restarted.l),
        (false, '', 0, ''),
      );
      expect((restarted.f, restarted.fa), (3, 99));
      // Every value written is one the decoder accepts.
      final clamped = again(
        const ReconcileEntry(armed: true, n: -4, f: 99, fa: -5),
      )!;
      expect((clamped.n, clamped.f, clamped.fa), (0, kReconcileGiveUpAfter, 0));
      final high = again(
        const ReconcileEntry(
          armed: true,
          n: kMaxPairComponent + 5,
          f: -2,
          fa: kMaxPairComponent + 5,
        ),
      )!;
      expect(
        (high.n, high.f, high.fa),
        (kMaxPairComponent, 0, kMaxPairComponent),
      );
      // A record written before the count existed.
      final old = ReceiveRecord.decode(_bytes(_record())).rec!;
      expect((old.f, old.fa), (0, 0));
    });

    test('normalization reads an unarmed reconcile entry as armed once a '
        'since token is stored, and keeps it unarmed while there is none', () {
      const r = ReceiveRecord(
        rec: ReconcileEntry(armed: false, t: 'tok', n: 2, f: 3, fa: 9),
      );
      final stored = r
          .normalized(
            sync: const ConversationSync(sinceToken: 's:1'),
            groups: [],
          )
          .rec!;
      expect((stored.armed, stored.t, stored.n), (true, 'tok', 2));
      expect((stored.f, stored.fa), (3, 9));
      final empty = r.normalized(sync: const ConversationSync(), groups: []);
      expect(empty.rec!.armed, isFalse);
    });

    test('the refusal count round-trips, is clamped into its bounds at encode, '
        'is kept by a restart and reset by an applied page', () {
      const w = WalkEntry(
        pair: MlsPair(1, 1),
        mode: WalkMode.undecryptable,
        mf: 3,
        mfAt: 77,
      );
      final again = ReceiveRecord.decode(
        const ReceiveRecord(close: w).encode(),
      );
      expect((again.close!.mf, again.close!.mfAt), (3, 77));
      // A record written before the count existed has none.
      final old = ReceiveRecord.decode(_bytes(_record()));
      expect((old.close!.mf, old.close!.mfAt), (0, 0));
      const over = WalkEntry(
        pair: MlsPair(1, 1),
        mf: kWalkGiveUpAfter + 3,
        mfAt: -4,
      );
      final clamped = ReceiveRecord.decode(
        const ReceiveRecord(orphan: over).encode(),
      );
      expect((clamped.orphan!.mf, clamped.orphan!.mfAt), (kWalkGiveUpAfter, 0));
      // A refused token is not an applied page.
      expect((w.restarted().mf, w.restarted().mfAt), (3, 77));
      expect(w.copyWith(end: true).mf, 3);
      final applied = w.afterPage(
        next: 'tok',
        resume: 'tok',
        settled: true,
        last: null,
        open: false,
        nowLocal: 5,
      );
      expect((applied.mf, applied.mfAt), (0, 0));
    });

    test('a local clock before 1970 is written as lt 0 and decodes', () {
      const w = WalkEntry(pair: MlsPair(1, 1));
      final next = w.afterPage(
        next: '',
        resume: '',
        settled: true,
        last: null,
        open: true,
        nowLocal: -5,
      );
      expect(next.lt, 0);
      final r = ReceiveRecord(open: next);
      expect(ReceiveRecord.decode(r.encode()).open!.lt, 0);
    });

    test('a record round-trips', () {
      final r = ReceiveRecord.decode(_bytes(_record()));
      final again = ReceiveRecord.decode(r.encode());
      expect(
        again.open!.l,
        const WalkPos(10, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      );
      expect(again.open!.f, const WalkPos(5, ''));
      expect(again.open!.lt, 7);
      expect(again.close!.mode, WalkMode.decrypt);
      expect(again.rec!.armed, isTrue);
    });
  });

  group('the group failure count and the abandoned-walk count', () {
    GroupRecord group(int g, int e) => GroupRecord(
      conversationId: _c1,
      generation: g,
      epoch: e,
      state: Uint8List(1),
    );

    test('both round-trip, and a record without the abandoned-walk count '
        'reads it as 0', () {
      const r = ReceiveRecord(
        gf: GroupFailures(MlsPair(1, 4), 2),
        abandoned: 7,
      );
      final again = ReceiveRecord.decode(r.encode());
      expect(again.gf!.pair, const MlsPair(1, 4));
      expect(again.gf!.n, 2);
      expect(again.abandoned, 7);
      expect(ReceiveRecord.decode(_bytes(_record())).abandoned, 0);
      expect(ReceiveRecord.decode(_bytes(_record())).gf, isNull);
    });

    test('the time of the last counted group failure round-trips, is clamped '
        'into its bounds at encode, and a record without it reads 0', () {
      const r = ReceiveRecord(gf: GroupFailures(MlsPair(1, 4), 2, at: 77));
      final again = ReceiveRecord.decode(r.encode());
      expect(
        (again.gf!.pair, again.gf!.n, again.gf!.at),
        (const MlsPair(1, 4), 2, 77),
      );
      // A record written before the time existed has none: the next strike
      // counts.
      final old = _record()..['gf'] = {'g': 1, 'e': 4, 'n': 2};
      expect(ReceiveRecord.decode(_bytes(old)).gf!.at, 0);
      for (final (written, read) in [
        (-4, 0),
        (kMaxPairComponent + 9, kMaxPairComponent),
      ]) {
        final clamped = ReceiveRecord.decode(
          ReceiveRecord(gf: GroupFailures(const MlsPair(1, 4), 1, at: written))
              .encode(),
        );
        expect(clamped.gf!.at, read);
      }
    });

    test('the kind of a group failure count round-trips in each value, and a '
        'record without it reads as the full-record kind', () {
      for (final kind in GroupFailureKind.values) {
        final again = ReceiveRecord.decode(
          ReceiveRecord(
            gf: GroupFailures(const MlsPair(1, 4), 2, at: 77, kind: kind),
          ).encode(),
        );
        expect((again.gf!.n, again.gf!.at, again.gf!.kind), (2, 77, kind));
      }
      // A record written before the kind existed has none: it reads as the
      // kind that never breaks a group.
      final old = _record()..['gf'] = {'g': 1, 'e': 4, 'n': 2, 'at': 77};
      expect(
        ReceiveRecord.decode(_bytes(old)).gf!.kind,
        GroupFailureKind.fullRecord,
      );
      for (final (written, kind) in [
        ('f', GroupFailureKind.fullRecord),
        ('d', GroupFailureKind.describeFailed),
      ]) {
        final stored = _record()
          ..['gf'] = {'g': 1, 'e': 4, 'n': 2, 'at': 77, 'k': written};
        expect(ReceiveRecord.decode(_bytes(stored)).gf!.kind, kind);
      }
    });

    test('a count past its bound is written as the bound, so the record '
        'always decodes', () {
      const r = ReceiveRecord(
        gf: GroupFailures(MlsPair(1, 4), kGroupFailuresMax + 4),
        abandoned: kAbandonedWalksMax + 4,
      );
      final again = ReceiveRecord.decode(r.encode());
      expect(again.gf!.n, kGroupFailuresMax);
      expect(again.abandoned, kAbandonedWalksMax);
    });

    test('normalization keeps the count of a stored final group at its epoch '
        'and drops it for any other pair (§3.4 rule 5)', () {
      const sync = ConversationSync(sinceToken: 's:1');
      const r = ReceiveRecord(
        gf: GroupFailures(MlsPair(1, 3), 2),
        abandoned: 2,
      );
      final kept = r.normalized(sync: sync, groups: [group(1, 3)]);
      expect(kept.gf!.n, 2);
      expect(kept.abandoned, 2);
      // A kept older generation's group at its last epoch (the orphan walk
      // decrypts on it).
      expect(
        r.normalized(sync: sync, groups: [group(1, 3), group(2, 1)]).gf!.n,
        2,
      );
      expect(r.normalized(sync: sync, groups: [group(1, 4)]).gf, isNull);
      expect(r.normalized(sync: sync, groups: const []).gf, isNull);
      final provisional = GroupRecord(
        conversationId: _c1,
        generation: 1,
        epoch: 3,
        state: Uint8List(1),
        provisional: true,
        provisionalCreatedAtMicros: 1,
      );
      expect(r.normalized(sync: sync, groups: [provisional]).gf, isNull);
    });
  });

  group('the record shape and normalization (§3.1, §3.4)', () {
    test('an orphan entry is written without lt, the open entry with it', () {
      const r = ReceiveRecord(
        open: WalkEntry(pair: MlsPair(2, 1), lt: 5),
        orphan: WalkEntry(pair: MlsPair(1, 3), lt: 5),
      );
      final m = jsonDecode(utf8.decode(r.encode())) as Map<String, Object?>;
      expect(_slot(m, 'open'), containsPair('lt', 5));
      expect(_slot(m, 'orphan').containsKey('lt'), isFalse);
      expect(
        ReceiveRecord.decode(r.encode()).orphan!.pair,
        const MlsPair(1, 3),
      );
    });

    test('normalization makes no orphan slot for the pair the close slot '
        'holds', () {
      GroupRecord group(int g, int e) => GroupRecord(
        conversationId: _c1,
        generation: g,
        epoch: e,
        state: Uint8List(1),
      );
      // A join kept generation 1, whose last epoch (1, 3) the close walk
      // still holds (unfinished).
      const r = ReceiveRecord(close: WalkEntry(pair: MlsPair(1, 3)));
      final n = r.normalized(
        sync: const ConversationSync(sinceToken: 's:1'),
        groups: [group(1, 3), group(2, 1)],
      );
      expect(n.close!.pair, const MlsPair(1, 3));
      expect(n.orphan, isNull);
      expect(n.open!.pair, const MlsPair(2, 1));
      // With no close slot for it, the orphan check still finds it.
      final o = ReceiveRecord.empty.normalized(
        sync: const ConversationSync(sinceToken: 's:1'),
        groups: [group(1, 3), group(2, 1)],
      );
      expect(o.orphan!.pair, const MlsPair(1, 3));
    });
  });
}
