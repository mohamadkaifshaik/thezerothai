import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_key_history.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

Uint8List _key(int n) => Uint8List.fromList(List.filled(32, n));

/// A device id hex of [n] (two bytes).
String _hex(int n) => n.toRadixString(16).padLeft(4, '0');

Uint8List _idOf(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

MemberRecord _pin(String hex, Uint8List key, String side) => MemberRecord(
  conversationId: _c1,
  deviceId: _idOf(hex),
  signatureKey: key,
  side: side,
  since: const MlsPair(1, 1),
);

Uint8List _json(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

Map<String, Object?> _record({
  Map<String, String> ids = const {},
  List<String> changed = const [],
  bool closed = false,
  int allow = 256,
}) => {
  'v': 1,
  'ids': ids,
  'changed': changed,
  'closed': closed,
  'allow': allow,
};

KeyHistory _read(
  Uint8List? bytes, {
  bool hasState = true,
  List<MemberRecord> current = const [],
  List<MemberRecord> former = const [],
  String? thisHex,
}) => KeyHistory.read(
  bytes,
  hasState: hasState,
  currentPins: current,
  formerPins: former,
  thisDeviceHex: thisHex,
);

KeyHistory _empty() => _read(null, hasState: false);

Map<String, Object?> _stored(KeyHistory h) =>
    jsonDecode(utf8.decode(h.encode())) as Map<String, Object?>;

void main() {
  test('admit records a first key, taints another key, and closes at the '
      'allowance', () {
    final h = _empty();
    expect(h.dirty, isTrue);
    expect(h.unreadable, isFalse);
    expect(h.allowance, 256);
    expect(_stored(h), _record());

    expect(h.admit(_hex(1), _key(1)), KeyRefusal.none);
    expect(h.admit(_hex(1), _key(1)), KeyRefusal.none);
    expect(h.size, 1);
    expect(_stored(h)['ids'], {_hex(1): base64Encode(_key(1))});

    // Another key under the same id: tainted, its key no longer kept.
    expect(h.admit(_hex(1), _key(2)), KeyRefusal.tainted);
    expect(_stored(h)['ids'], isEmpty);
    expect(_stored(h)['changed'], [_hex(1)]);
    expect(h.size, 1);

    // Fill to the allowance: 256 entries, the tainted one included.
    for (var i = 2; i <= 256; i++) {
      expect(h.admit(_hex(i), _key(1)), KeyRefusal.none);
    }
    expect(h.size, 256);
    expect(h.closed, isFalse);

    // The next new id closes the record and is refused.
    expect(h.admit(_hex(1000), _key(1)), KeyRefusal.unrecorded);
    expect(h.closed, isTrue);
    expect(h.size, 256);
    expect(h.mayAllowMore, isTrue);
    // Recorded ids keep their verdicts.
    expect(h.admit(_hex(2), _key(1)), KeyRefusal.none);
    expect(h.admit(_hex(1), _key(1)), KeyRefusal.tainted);
    expect(h.admit(_hex(2), _key(9)), KeyRefusal.tainted);
    expect(h.size, 256);

    // What was written reads back the same.
    final again = _read(h.encode());
    expect(again.unreadable, isFalse);
    expect(again.dirty, isFalse);
    expect(again.closed, isTrue);
    expect(again.size, 256);
    expect(_stored(again), _stored(h));
  });

  test('a closed history below its allowance still admits no new id', () {
    final h = _read(
      _json(_record(ids: {_hex(1): base64Encode(_key(1))}, closed: true)),
    );
    expect(h.admit(_hex(2), _key(1)), KeyRefusal.unrecorded);
    expect(h.dirty, isFalse);
    expect(h.size, 1);
  });

  test('decode checks the size against the stored allowance, not the '
      'constant', () {
    Map<String, String> ids(int n) => {
      for (var i = 0; i < n; i++) _hex(i): base64Encode(_key(1)),
    };
    expect(_read(_json(_record(ids: ids(256)))).unreadable, isFalse);
    expect(_read(_json(_record(ids: ids(257)))).unreadable, isTrue);
    final wide = _read(_json(_record(ids: ids(257), allow: 512)));
    expect(wide.unreadable, isFalse);
    expect(wide.allowance, 512);
    expect(_read(_json(_record(ids: ids(513), allow: 512))).unreadable, isTrue);
    // ids and changed count together.
    expect(
      _read(_json(_record(ids: ids(256), changed: [_hex(5000)]))).unreadable,
      isTrue,
    );
    for (final allow in [0, 255, 257, 300, 1280, -256]) {
      expect(
        _read(_json(_record(allow: allow))).unreadable,
        isTrue,
        reason: 'allow $allow',
      );
    }
    expect(_read(_json(_record(allow: 1024))).unreadable, isFalse);
  });

  test('the cross-check exempts an absent unattributed pin only while '
      'closed', () {
    final k1 = base64Encode(_key(1));
    Uint8List record({bool closed = false}) =>
        _json(_record(ids: {_hex(1): k1}, changed: [_hex(2)], closed: closed));
    // Consistent: a recorded pin on its key, a tainted pin on any key, this
    // device absent.
    expect(
      _read(
        record(),
        current: [
          _pin(_hex(1), _key(1), MemberSide.theirs),
          _pin(_hex(2), _key(7), MemberSide.unattributed),
          _pin(_hex(9), _key(9), MemberSide.mine),
        ],
        former: [_pin(_hex(1), _key(1), MemberSide.theirs)],
        thisHex: _hex(9),
      ).unreadable,
      isFalse,
    );
    // A pin recorded with another key (current or former).
    expect(
      _read(
        record(),
        current: [_pin(_hex(1), _key(3), MemberSide.unattributed)],
      ).unreadable,
      isTrue,
    );
    expect(
      _read(
        record(),
        former: [_pin(_hex(1), _key(3), MemberSide.theirs)],
      ).unreadable,
      isTrue,
    );
    // A pin absent from both lists: unreadable while open, whatever its
    // side.
    for (final side in [MemberSide.unattributed, MemberSide.theirs]) {
      expect(
        _read(record(), current: [_pin(_hex(3), _key(1), side)]).unreadable,
        isTrue,
      );
      expect(
        _read(record(), former: [_pin(_hex(3), _key(1), side)]).unreadable,
        isTrue,
      );
    }
    // Closed: only an unattributed absent pin is an overflow refusal.
    expect(
      _read(
        record(closed: true),
        current: [_pin(_hex(3), _key(1), MemberSide.unattributed)],
        former: [_pin(_hex(4), _key(1), MemberSide.unattributed)],
      ).unreadable,
      isFalse,
    );
    expect(
      _read(
        record(closed: true),
        current: [_pin(_hex(3), _key(1), MemberSide.theirs)],
      ).unreadable,
      isTrue,
    );
    // Only the pin of the device named as this one is left out.
    expect(
      _read(
        record(),
        current: [_pin(_hex(9), _key(9), MemberSide.mine)],
      ).unreadable,
      isTrue,
    );
  });

  test('a missing history is unreadable with state and empty and dirty '
      'without', () {
    final missing = _read(null);
    expect(missing.unreadable, isTrue);
    expect(missing.dirty, isFalse);
    final fresh = _read(null, hasState: false);
    expect(fresh.unreadable, isFalse);
    expect(fresh.dirty, isTrue);
    expect(fresh.size, 0);
  });

  test('a tainted id is refused on every key', () {
    final h = _empty();
    h.admit(_hex(1), _key(1));
    h.admit(_hex(1), _key(2));
    for (final k in [1, 2, 3]) {
      expect(h.refusal(_hex(1), _key(k)), KeyRefusal.tainted);
      expect(h.admit(_hex(1), _key(k)), KeyRefusal.tainted);
      expect(h.admissible(_hex(1), _key(k)), isFalse);
    }
    final again = _read(h.encode());
    for (final k in [1, 2, 3]) {
      expect(again.refusal(_hex(1), _key(k)), KeyRefusal.tainted);
    }
    // refusal is read-only: a recorded id asked with another key is refused
    // and stays recorded.
    final r = _empty()..admit(_hex(2), _key(1));
    final before = _stored(r);
    expect(r.refusal(_hex(2), _key(1)), KeyRefusal.none);
    expect(r.refusal(_hex(2), _key(5)), KeyRefusal.tainted);
    expect(r.refusal(_hex(3), _key(1)), KeyRefusal.unrecorded);
    expect(_stored(r), before);
  });

  test('admissible matches admit without writing', () {
    final h = _read(
      _json(_record(ids: {_hex(1): base64Encode(_key(1))}, changed: [_hex(2)])),
    );
    final before = _stored(h);
    final cases = [
      (_hex(1), _key(1)),
      (_hex(1), _key(2)),
      (_hex(2), _key(1)),
      (_hex(3), _key(1)),
    ];
    final said = [for (final c in cases) h.admissible(c.$1, c.$2)];
    expect(said, [true, false, false, true]);
    expect(h.dirty, isFalse);
    expect(_stored(h), before);
    for (var i = 0; i < cases.length; i++) {
      final fresh = _read(_json(before));
      expect(
        fresh.admit(cases[i].$1, cases[i].$2) == KeyRefusal.none,
        said[i],
        reason: 'case $i',
      );
    }
    // Closed, or at the allowance: a new id is not admissible.
    final closed = _read(_json(_record(closed: true)));
    expect(closed.admissible(_hex(3), _key(1)), isFalse);
    final full = _read(
      _json(
        _record(
          ids: {for (var i = 0; i < 256; i++) _hex(i): base64Encode(_key(1))},
        ),
      ),
    );
    expect(full.admissible(_hex(999), _key(1)), isFalse);
    expect(full.admissible(_hex(5), _key(1)), isTrue);
    expect(full.closed, isFalse);
    // Unreadable: nothing is admissible, admit changes nothing.
    final bad = KeyHistory.unreadableRecord();
    expect(bad.admissible(_hex(1), _key(1)), isFalse);
    expect(bad.admit(_hex(1), _key(1)), KeyRefusal.unreadable);
    expect(bad.refusal(_hex(1), _key(1)), KeyRefusal.unreadable);
    expect(bad.dirty, isFalse);
    expect(bad.mayAllowMore, isFalse);
  });

  test('this device is never recorded and never refused', () {
    final h = _read(null, hasState: false, thisHex: _hex(9));
    expect(h.admit(_hex(9), _key(1)), KeyRefusal.none);
    expect(h.admit(_hex(9), _key(2)), KeyRefusal.none);
    expect(h.refusal(_hex(9), _key(3)), KeyRefusal.none);
    expect(h.size, 0);
  });

  test('decode treats a bad version, key or id, an id in both lists, or an '
      'oversize record as unreadable', () {
    final k = base64Encode(_key(1));
    final bad = <Object?>[
      {..._record(), 'v': 2},
      {..._record()}..remove('v'),
      {..._record()}..remove('ids'),
      {..._record()}..remove('changed'),
      {..._record()}..remove('closed'),
      {..._record()}..remove('allow'),
      {..._record(), 'closed': 'no'},
      {..._record(), 'allow': '256'},
      _record(ids: {_hex(1): ''}),
      _record(ids: {_hex(1): 'not base64!'}),
      {
        ..._record(),
        'ids': {_hex(1): 7},
      },
      _record(ids: {'ABCD': k}),
      _record(ids: {'abc': k}),
      _record(ids: {'zz': k}),
      _record(changed: ['ABCD']),
      _record(changed: ['abc']),
      {
        ..._record(),
        'changed': [7],
      },
      _record(changed: [_hex(1), _hex(1)]),
      _record(ids: {_hex(1): k}, changed: [_hex(1)]),
      _record(ids: {for (var i = 0; i < 257; i++) _hex(i): k}),
      [1, 2],
      'text',
    ];
    for (var i = 0; i < bad.length; i++) {
      expect(
        _read(Uint8List.fromList(utf8.encode(jsonEncode(bad[i])))).unreadable,
        isTrue,
        reason: 'case $i',
      );
    }
    expect(_read(Uint8List.fromList(utf8.encode('{"v":1'))).unreadable, isTrue);
    expect(_read(Uint8List.fromList([0xff, 0xfe])).unreadable, isTrue);
    expect(_read(_json(_record(ids: {_hex(1): k}))).unreadable, isFalse);
  });

  test('allowing new devices raises the allowance by one step, admits the '
      'absent unattributed pins and stops at the maximum', () {
    final k = base64Encode(_key(1));
    final h = _read(
      _json(
        _record(
          ids: {for (var i = 0; i < 255; i++) _hex(i): k},
          changed: [_hex(900)],
          closed: true,
        ),
      ),
    );
    final current = [
      _pin(_hex(0), _key(1), MemberSide.theirs),
      _pin(_hex(900), _key(4), MemberSide.unattributed),
      _pin(_hex(1000), _key(1), MemberSide.unattributed),
    ];
    final former = [_pin(_hex(1001), _key(2), MemberSide.unattributed)];
    h.allowNewDevices(currentPins: current, formerPins: former);
    expect(h.closed, isFalse);
    expect(h.allowance, 512);
    expect(h.dirty, isTrue);
    expect(h.size, 258);
    expect(h.refusal(_hex(1000), _key(1)), KeyRefusal.none);
    expect(h.refusal(_hex(1001), _key(2)), KeyRefusal.none);
    // No id and no taint dropped.
    expect(h.refusal(_hex(900), _key(4)), KeyRefusal.tainted);
    for (var i = 0; i < 255; i++) {
      expect(h.refusal(_hex(i), _key(1)), KeyRefusal.none);
    }
    expect(
      _read(h.encode(), current: current, former: former).unreadable,
      isFalse,
    );

    h.allowNewDevices(currentPins: const [], formerPins: const []);
    h.allowNewDevices(currentPins: const [], formerPins: const []);
    expect(h.allowance, 1024);
    expect(h.mayAllowMore, isFalse);
    expect(
      () => h.allowNewDevices(currentPins: const [], formerPins: const []),
      throwsStateError,
    );
    expect(h.allowance, 1024);
    expect(
      () => KeyHistory.unreadableRecord().allowNewDevices(
        currentPins: const [],
        formerPins: const [],
      ),
      throwsStateError,
    );
  });

  test('toString prints no id or key', () {
    final h = _empty()
      ..admit(_hex(0xabcd), _key(1))
      ..admit(_hex(0xbcde), _key(2))
      ..admit(_hex(0xbcde), _key(3));
    final text = '$h ${KeyHistory.unreadableRecord()}';
    expect(text, isNot(contains(_hex(0xabcd))));
    expect(text, isNot(contains(_hex(0xbcde))));
    expect(text, isNot(contains(base64Encode(_key(1)))));
    expect(text, contains('size: 2'));
    for (final r in KeyRefusal.values) {
      expect('$r', startsWith('KeyRefusal.'));
    }
    expect('${DeviceKeyHistory()}', "Instance of 'DeviceKeyHistory'");
  });

  group('the store', () {
    late Directory dir;
    late RigDevice device;
    final reported = <Object>[];
    late DeviceKeyHistory store;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('e2ee_key_history');
      device = await RigDevice.create(dir: dir, clock: RigClock());
      reported.clear();
      store = DeviceKeyHistory(onUnexpectedError: (e, _) => reported.add(e));
    });

    tearDown(() async {
      await device.dispose();
      try {
        dir.deleteSync(recursive: true);
      } on Object {
        // Windows can hold the file briefly.
      }
    });

    Future<KeyHistory> of(
      String c, {
      List<MemberRecord> current = const [],
      List<MemberRecord> former = const [],
    }) => store.of(device.vault, c, currentPins: current, formerPins: former);

    test('writes one setting per conversation, only when dirty, and reads '
        'it back', () async {
      final v = device.vault;
      final h = await of(_c1);
      expect(h.dirty, isTrue);
      expect(h.admit(_hex(1), _key(1)), KeyRefusal.none);
      await v.transaction((tx) => store.writeIn(tx, _c1, h));
      expect(h.dirty, isFalse);
      final raw = await v.setting('$kVaultSettingKeyHistoryPrefix$_c1');
      expect(jsonDecode(utf8.decode(raw!)), {
        'v': 1,
        'ids': {_hex(1): base64Encode(_key(1))},
        'changed': <Object?>[],
        'closed': false,
        'allow': 256,
      });
      expect(await v.setting('$kVaultSettingKeyHistoryPrefix$_c2'), isNull);

      final again = await of(_c1);
      expect(again.dirty, isFalse);
      expect(again.refusal(_hex(1), _key(1)), KeyRefusal.none);
      // Not dirty: nothing is written.
      final before = await device.db
          .customSelect('SELECT * FROM vault_settings ORDER BY rowid')
          .get();
      await v.transaction((tx) => store.writeIn(tx, _c1, again));
      final after = await device.db
          .customSelect('SELECT * FROM vault_settings ORDER BY rowid')
          .get();
      expect(
        '${[for (final r in after) r.data]}',
        '${[for (final r in before) r.data]}',
      );
      // This device is excluded by its vault id.
      final own = await of(
        _c1,
        current: [
          MemberRecord(
            conversationId: _c1,
            deviceId: device.deviceId,
            signatureKey: device.signatureKey,
            side: MemberSide.mine,
            since: const MlsPair(1, 1),
          ),
        ],
      );
      expect(own.unreadable, isFalse);
      expect(reported, isEmpty);
    });

    test('an unreadable history is reported once per conversation and never '
        'written', () async {
      final v = device.vault;
      for (final c in [_c1, _c2]) {
        await v.transaction(
          (tx) => tx.putSetting(
            '$kVaultSettingKeyHistoryPrefix$c',
            rigBytes('{"v":1'),
          ),
        );
      }
      final h = await of(_c1);
      expect(h.unreadable, isTrue);
      expect((await of(_c1)).unreadable, isTrue);
      expect(reported, hasLength(1));
      expect((reported.single as E2eePipelineError).step, 'keyHistory.read');
      expect((await of(_c2)).unreadable, isTrue);
      expect(reported, hasLength(2));
      expect(h.admit(_hex(1), _key(1)), KeyRefusal.unreadable);
      await v.transaction((tx) => store.writeIn(tx, _c1, h));
      expect(
        utf8.decode((await v.setting('$kVaultSettingKeyHistoryPrefix$_c1'))!),
        '{"v":1',
      );
    });

    test('a missing history is unreadable once the conversation has a pin, '
        'a former pin, a group or a mark', () async {
      final v = device.vault;
      expect((await of(_c1)).unreadable, isFalse);
      expect(
        (await of(
          _c1,
          current: [_pin(_hex(1), _key(1), MemberSide.theirs)],
        )).unreadable,
        isTrue,
      );
      expect(
        (await of(
          _c1,
          former: [_pin(_hex(1), _key(1), MemberSide.theirs)],
        )).unreadable,
        isTrue,
      );
      await v.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            state: rigBytes('state'),
          ),
        ),
      );
      expect((await of(_c1)).unreadable, isTrue);
      await v.transaction((tx) => tx.setAfterPair(_c2, const MlsPair(1, 0)));
      expect((await of(_c2)).unreadable, isTrue);
      const c3 = '33333333333333333333333333333333';
      await v.transaction((tx) => tx.setJoinHighWater(c3, const MlsPair(1, 0)));
      expect((await of(c3)).unreadable, isTrue);
      // A sync record alone (waiting for a welcome) is no state.
      const c4 = '44444444444444444444444444444444';
      await v.transaction(
        (tx) => tx.putConversationSync(
          c4,
          const ConversationSync(firstSawGeneration: 1),
        ),
      );
      expect((await of(c4)).unreadable, isFalse);
    });
  });
}
