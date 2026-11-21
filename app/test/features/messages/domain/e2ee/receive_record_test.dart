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
    // throws FormatException, and ReceiveRecords.read returns the empty
    // record for it (reported once as receive.read).
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
      ('an abandoned-walk count', (r) => r['ab'] = 3, true),
      ('a negative abandoned-walk count', (r) => r['ab'] = -1, false),
      (
        'an abandoned-walk count above its bound',
        (r) => r['ab'] = kAbandonedWalksMax + 1,
        false,
      ),
      ('a string for the abandoned-walk count', (r) => r['ab'] = '1', false),
      (
        'an old orphan entry with lt',
        (r) => _slot(r, 'orphan')['lt'] = 9,
        true,
      ),
      ('a slot that is not an object', (r) => r['open'] = 'x', false),
      ('not an object at all', (r) => r['v'] = null, false),
    ];

    for (final (name, change, decodes) in rows) {
      test('$name ${decodes ? 'decodes' : 'reads as empty'}', () async {
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
          expect(read, same(ReceiveRecord.empty));
          expect(reported.single, isA<E2eePipelineError>());
          expect((reported.single as E2eePipelineError).step, 'receive.read');
          // Once per conversation per run.
          await records.read(_Vault(bytes), _c1);
          expect(reported, hasLength(1));
        }
      });
    }

    test('a seal that does not open reads as empty', () async {
      final reported = <Object>[];
      final read = await ReceiveRecords(
        onUnexpectedError: (e, _) => reported.add(e),
      ).read(_Vault(null, error: const VaultCorruptException('x')), _c1);
      expect(read, same(ReceiveRecord.empty));
      expect(reported, hasLength(1));
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
        ),
        anchor: token,
      );
      final bytes = r.encode();
      expect(bytes.length, lessThan(kMaxReceiveRecordBytes));
      expect(ReceiveRecord.decode(bytes).anchor, token);
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
