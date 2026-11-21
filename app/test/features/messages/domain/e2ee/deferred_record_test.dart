import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/deferred_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:flutter_test/flutter_test.dart';

const _c1 = '11111111111111111111111111111111';

String _id(int n) => n.toRadixString(16).padLeft(32, '0');

/// An item exactly as §7.3 stores it.
Map<String, Object?> _item({int n = 1}) => {
  'id': _id(n),
  'g': 1,
  'e': 2,
  'at': 1000,
  'da': 2000,
  'ct': base64Encode([1, 2, 3]),
  'rc': base64Encode(List.filled(32, 9)),
  'fs': false,
  'k': 1,
  'cc': 0,
  'cu': 0,
  'la': 2000,
  'ru': '00000000000000aa',
};

Map<String, Object?> _record([List<Map<String, Object?>>? items]) => {
  'v': 1,
  'items': items ?? [_item()],
};

Uint8List _bytes(Object? m) => Uint8List.fromList(utf8.encode(jsonEncode(m)));

DeferredItem _built(
  int n, {
  int k = 1,
  int cc = 0,
  int cu = 0,
  int at = 1000,
  int da = 2000,
  int ctBytes = 3,
  MlsPair pair = const MlsPair(1, 2),
}) => DeferredItem(
  id: _id(n),
  pair: pair,
  at: at,
  da: da,
  ct: Uint8List.fromList(List.filled(ctBytes, 5)),
  rc: Uint8List.fromList(List.filled(32, 9)),
  fs: false,
  k: k,
  cc: cc,
  cu: cu,
  la: da,
  ru: '00000000000000aa',
);

/// A vault whose deferred setting holds [bytes] (or throws [error]); every
/// other call is a test bug.
class _Vault implements SecureVault {
  _Vault(this.bytes, {this.error});

  final Uint8List? bytes;
  final Object? error;
  final List<String> keys = [];

  @override
  Future<Uint8List?> setting(String key) async {
    keys.add(key);
    if (error != null) throw error!;
    return bytes;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('the deferred record codec (§7.3)', () {
    test('a record decodes to its items and encodes back to the same '
        'value', () {
      final r = DeferredRecord.decode(_bytes(_record()));
      final i = r.items.single;
      expect(i.id, _id(1));
      expect(i.pair, const MlsPair(1, 2));
      expect((i.at, i.da, i.la), (1000, 2000, 2000));
      expect(i.ct, [1, 2, 3]);
      expect(i.rc, List.filled(32, 9));
      expect(i.fs, isFalse);
      expect((i.k, i.cc, i.cu), (1, 0, 0));
      expect(i.ru, '00000000000000aa');
      expect(jsonDecode(utf8.decode(r.encode())), _record());
    });

    test('an empty record encodes with no items and decodes', () {
      final bytes = DeferredRecord.empty.encode();
      expect(jsonDecode(utf8.decode(bytes)), {'v': 1, 'items': <Object?>[]});
      expect(DeferredRecord.decode(bytes).items, isEmpty);
    });

    // Every value outside §7.3's shape or bounds: unreadable.
    final refused = <String, Object? Function()>{
      'not a map': () => [1],
      'a wrong version': () => {..._record(), 'v': 2},
      'no items key': () => {'v': 1},
      'items that are not a list': () => {'v': 1, 'items': 3},
      'an item that is not a map': () => {
        'v': 1,
        'items': [3],
      },
      'seventeen items': () =>
          _record([for (var n = 1; n <= kDeferredMax + 1; n++) _item(n: n)]),
      'two items with one id': () => _record([_item(), _item()]),
      'an id that is not 32 lower-case hex': () => _record([
        {..._item(), 'id': 'A' * 32},
      ]),
      'a short id': () => _record([
        {..._item(), 'id': 'abc'},
      ]),
      'a negative generation': () => _record([
        {..._item(), 'g': -1},
      ]),
      'an epoch above 2^53 - 1': () => _record([
        {..._item(), 'e': kMaxPairComponent + 1},
      ]),
      'a generation that is not an integer': () => _record([
        {..._item(), 'g': '1'},
      ]),
      'a negative server time': () => _record([
        {..._item(), 'at': -1},
      ]),
      'a server time above 2^53 - 1': () => _record([
        {..._item(), 'at': kMaxPairComponent + 1},
      ]),
      'a negative deferred-at time': () => _record([
        {..._item(), 'da': -1},
      ]),
      'a deferred-at time above 2^53 - 1': () => _record([
        {..._item(), 'da': kMaxPairComponent + 1},
      ]),
      'a negative last-attempt time': () => _record([
        {..._item(), 'la': -1},
      ]),
      'a last-attempt time that is not an integer': () => _record([
        {..._item(), 'la': 1.5},
      ]),
      'an empty ciphertext': () => _record([
        {..._item(), 'ct': ''},
      ]),
      'a ciphertext that is not base64': () => _record([
        {..._item(), 'ct': '***'},
      ]),
      'a ciphertext over 8192 bytes': () => _record([
        {
          ..._item(),
          'ct': base64Encode(List.filled(kMaxDeferredCiphertextBytes + 1, 1)),
        },
      ]),
      'a ciphertext that is not a string': () => _record([
        {..._item(), 'ct': 5},
      ]),
      'a report commitment over 64 bytes': () => _record([
        {
          ..._item(),
          'rc': base64Encode(List.filled(kMaxDeferredCommitmentBytes + 1, 1)),
        },
      ]),
      'a report commitment that is not base64': () => _record([
        {..._item(), 'rc': '***'},
      ]),
      'a from_self that is not a bool': () => _record([
        {..._item(), 'fs': 1},
      ]),
      'a negative strike count': () => _record([
        {..._item(), 'k': -1},
      ]),
      'a strike count over the bound': () => _record([
        {..._item(), 'k': kDeferredCounterMax + 1},
      ]),
      'a witnessed crash count over the bound': () => _record([
        {..._item(), 'cc': kDeferredCounterMax + 1},
      ]),
      'an unwitnessed crash count over the bound': () => _record([
        {..._item(), 'cu': kDeferredCounterMax + 1},
      ]),
      'a crash count that is not an integer': () => _record([
        {..._item(), 'cu': null},
      ]),
      'an item with no strike and no crash at all': () => _record([
        {..._item(), 'k': 0, 'cc': 0, 'cu': 0},
      ]),
      'a run id that is not 16 lower-case hex': () => _record([
        {..._item(), 'ru': 'xyz'},
      ]),
      'a missing key': () => _record([
        {..._item()}..remove('fs'),
      ]),
    };
    for (final e in refused.entries) {
      test('${e.key} is refused', () {
        expect(
          () => DeferredRecord.decode(_bytes(e.value())),
          throwsFormatException,
        );
      });
    }

    test('bytes that are not JSON or not UTF-8 are refused', () {
      expect(
        () => DeferredRecord.decode(Uint8List.fromList([0x7b, 0x7b])),
        throwsFormatException,
      );
      expect(
        () => DeferredRecord.decode(Uint8List.fromList([0xff, 0xfe])),
        throwsFormatException,
      );
    });

    test('a value over 200 KB is refused before it is parsed', () {
      final big = Uint8List(kMaxDeferredRecordBytes + 1)
        ..fillRange(0, kMaxDeferredRecordBytes + 1, 0x20);
      expect(() => DeferredRecord.decode(big), throwsFormatException);
    });

    test('an empty report commitment and the largest bounds are accepted', () {
      final r = DeferredRecord.decode(
        _bytes(
          _record([
            {
              ..._item(),
              'rc': '',
              'g': kMaxPairComponent,
              'e': kMaxPairComponent,
              'at': kMaxPairComponent,
              'da': 0,
              'la': kMaxPairComponent,
              'k': 0,
              'cu': kDeferredCounterMax,
              'ct': base64Encode(List.filled(kMaxDeferredCiphertextBytes, 1)),
            },
          ]),
        ),
      );
      expect(r.items.single.rc, isEmpty);
      expect(r.items.single.cu, kDeferredCounterMax);
    });

    test('sixteen items with the largest ciphertext encode within the size '
        'bound and decode', () {
      var r = DeferredRecord.empty;
      for (var n = 1; n <= kDeferredMax; n++) {
        r = r.put(_built(n, ctBytes: kMaxDeferredCiphertextBytes));
      }
      final bytes = r.encode();
      expect(bytes.length, lessThanOrEqualTo(kMaxDeferredRecordBytes));
      expect(DeferredRecord.decode(bytes).items, hasLength(kDeferredMax));
    });

    test('every value an item can be built with is one the decoder accepts: '
        'counters and local times are clamped on write', () {
      final r = DeferredRecord.empty.put(
        DeferredItem(
          id: _id(1),
          pair: const MlsPair(1, 2),
          at: 5,
          da: -7,
          ct: Uint8List.fromList([1]),
          rc: Uint8List(0),
          fs: true,
          k: kDeferredCounterMax + 5,
          cc: -2,
          cu: kDeferredCounterMax + 9,
          la: kMaxPairComponent + 3,
          ru: '00000000000000aa',
        ),
      );
      final i = DeferredRecord.decode(r.encode()).items.single;
      expect((i.k, i.cc, i.cu), (kDeferredCounterMax, 0, kDeferredCounterMax));
      expect((i.da, i.la), (0, kMaxPairComponent));
      expect(i.fs, isTrue);
    });

    test('fits refuses a ciphertext or a commitment the decoder would '
        'refuse', () {
      expect(DeferredItem.fits(Uint8List(1), Uint8List(32)), isTrue);
      expect(DeferredItem.fits(Uint8List(0), Uint8List(32)), isFalse);
      expect(
        DeferredItem.fits(
          Uint8List(kMaxDeferredCiphertextBytes + 1),
          Uint8List(32),
        ),
        isFalse,
      );
      expect(
        DeferredItem.fits(
          Uint8List(1),
          Uint8List(kMaxDeferredCommitmentBytes + 1),
        ),
        isFalse,
      );
    });
  });

  group('the record', () {
    test('put replaces an item of the same id and keeps the others', () {
      final r = DeferredRecord.empty
          .put(_built(1))
          .put(_built(2))
          .put(_built(1, k: 2));
      expect([for (final i in r.items) i.id], [_id(1), _id(2)]);
      expect(r.of(_id(1))!.k, 2);
      expect(r.of(_id(3)), isNull);
    });

    test('without removes the named ids only', () {
      final r = DeferredRecord.empty.put(_built(1)).put(_built(2));
      expect(r.without([_id(1), _id(9)]).items.single.id, _id(2));
    });

    test('the eviction order is the most strikes, then the most witnessed '
        'crashes, then the oldest server time, among witnessed items only', () {
      var r = DeferredRecord.empty
          .put(_built(1, k: 0, cu: 5, at: 1))
          .put(_built(2, k: 1, at: 50))
          .put(_built(3, k: 2, cc: 0, at: 70))
          .put(_built(4, k: 2, cc: 1, at: 90))
          .put(_built(5, k: 2, cc: 1, at: 80));
      expect(r.evictable()!.id, _id(5));
      r = r.without([_id(5)]);
      expect(r.evictable()!.id, _id(4));
      r = r.without([_id(4)]);
      expect(r.evictable()!.id, _id(3));
      r = r.without([_id(3), _id(2)]);
      // Only an unwitnessed item is left: none is evicted.
      expect(r.evictable(), isNull);
    });

    test('an item expires 30 days after the earlier of its server time and '
        'its local deferred-at time', () {
      final d = kCiphertextRetention.inMicroseconds;
      expect(_built(1, at: 1000, da: 2000).expired(1000 + d - 1), isFalse);
      expect(_built(1, at: 1000, da: 2000).expired(1000 + d), isTrue);
      expect(_built(1, at: 9000, da: 2000).expired(2000 + d - 1), isFalse);
      expect(_built(1, at: 9000, da: 2000).expired(2000 + d), isTrue);
    });

    test('view lists ids and times newest first and hides items at or before '
        'cleared_at, with no bytes', () {
      final r = DeferredRecord.empty
          .put(_built(1, at: 10))
          .put(_built(2, at: 30))
          .put(_built(3, at: 20));
      expect(
        [for (final v in r.view()) (v.id, v.atMicros)],
        [(_id(2), 30), (_id(3), 20), (_id(1), 10)],
      );
      expect([for (final v in r.view(clearedAtMicros: 20)) v.id], [_id(2)]);
    });

    test('no class that carries an id or bytes has a text form', () {
      final item = _built(1);
      final record = DeferredRecord.empty.put(item);
      for (final o in <Object>[item, record, record.view().single]) {
        expect(o.toString(), startsWith('Instance of '));
      }
    });
  });

  group('reading', () {
    test(
      'the setting key is messages.e2ee.deferred.<conversationId>',
      () async {
        final vault = _Vault(null);
        final read = await DeferredRecords().read(vault, _c1);
        expect(vault.keys, ['messages.e2ee.deferred.$_c1']);
        expect(read.record.items, isEmpty);
        expect(read.unreadable, isFalse);
        expect(DeferredRecords.keyOf(_c1), 'messages.e2ee.deferred.$_c1');
      },
    );

    test('a stored record is read', () async {
      final read = await DeferredRecords().read(_Vault(_bytes(_record())), _c1);
      expect(read.record.items.single.id, _id(1));
      expect(read.unreadable, isFalse);
    });

    test('a value that does not decode, or whose seal does not open, reads '
        'as empty and unreadable, reported once per conversation as '
        'receive.deferred.read', () async {
      final reported = <Object>[];
      final records = DeferredRecords(
        onUnexpectedError: (e, _) => reported.add(e),
      );
      final bad = await records.read(_Vault(_bytes({'v': 9})), _c1);
      expect(bad.record.items, isEmpty);
      expect(bad.unreadable, isTrue);
      final corrupt = await records.read(
        _Vault(null, error: const VaultCorruptException('x')),
        _c1,
      );
      expect(corrupt.unreadable, isTrue);
      expect(reported, hasLength(1));
      final e = reported.single as E2eePipelineError;
      expect(e.step, 'receive.deferred.read');
      expect(e.toString(), isNot(contains(_c1)));
    });
  });
}
