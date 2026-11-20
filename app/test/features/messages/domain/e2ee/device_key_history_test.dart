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
  Map<String, String> held = const {},
  bool closed = false,
  int allow = 256,
}) => {
  'v': 1,
  'ids': ids,
  'changed': changed,
  'held': held,
  'closed': closed,
  'allow': allow,
};

/// [n] ids from [from] on, each with the key of [key].
Map<String, String> _many(int n, {int from = 0, int key = 1}) => {
  for (var i = from; i < from + n; i++) _hex(i): base64Encode(_key(key)),
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

    // The next new id closes the record and is refused: remembered with its
    // key, outside the allowance.
    expect(h.admit(_hex(1000), _key(1)), KeyRefusal.unrecorded);
    expect(h.closed, isTrue);
    expect(h.size, 256);
    expect(h.total, 257);
    expect(_stored(h)['held'], {_hex(1000): base64Encode(_key(1))});
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
    expect(again.total, 257);
    expect(_stored(again), _stored(h));
  });

  test('a closed history below its allowance still admits no new id', () {
    final h = _read(
      _json(_record(ids: {_hex(1): base64Encode(_key(1))}, closed: true)),
    );
    expect(h.admit(_hex(2), _key(1)), KeyRefusal.unrecorded);
    // Not admitted, but remembered with its key.
    expect(h.dirty, isTrue);
    expect(h.size, 1);
    expect(_stored(h)['held'], {_hex(2): base64Encode(_key(1))});
    expect(h.closed, isTrue);
  });

  test('an id first seen while the history is closed is remembered with its '
      'key and not attributable', () {
    final x = _hex(1000);
    final h = _read(_json(_record(ids: _many(256))));
    expect(h.admit(x, _key(7)), KeyRefusal.unrecorded);
    expect(h.closed, isTrue);
    expect(h.dirty, isTrue);
    expect(_stored(h)['held'], {x: base64Encode(_key(7))});
    expect(_stored(h)['ids'], _many(256));
    expect(h.size, 256);
    expect(h.total, 257);
    // Held: refused on its own key, by every question.
    expect(h.refusal(x, _key(7)), KeyRefusal.unrecorded);
    expect(h.admissible(x, _key(7)), isFalse);
    expect(h.admissible(x, _key(8)), isFalse);

    // Read back: still held, and seeing it again on that key writes
    // nothing.
    final again = _read(
      h.encode(),
      current: [_pin(x, _key(7), MemberSide.unattributed)],
    );
    expect(again.unreadable, isFalse);
    expect(again.admit(x, _key(7)), KeyRefusal.unrecorded);
    expect(again.refusal(x, _key(7)), KeyRefusal.unrecorded);
    expect(again.dirty, isFalse);
    expect(_stored(again), _stored(h));
  });

  test('a key change of a held id never makes the history unreadable', () {
    final x = _hex(1000);
    final h = _read(_json(_record(ids: _many(256))));
    expect(h.admit(x, _key(1)), KeyRefusal.unrecorded);
    final closed = _read(h.encode());
    expect(closed.admit(x, _key(2)), KeyRefusal.tainted);
    expect(closed.dirty, isTrue);
    expect(_stored(closed)['changed'], [x]);
    expect(_stored(closed)['held'], isEmpty);

    final again = _read(
      closed.encode(),
      current: [_pin(x, _key(2), MemberSide.unattributed)],
    );
    expect(again.unreadable, isFalse);
    expect(again.closed, isTrue);
    expect(again.allowance, 256);
    expect(again.size, 257);
    expect(again.total, 257);
    for (final k in [1, 2, 3]) {
      expect(again.refusal(x, _key(k)), KeyRefusal.tainted);
      expect(again.admit(x, _key(k)), KeyRefusal.tainted);
    }
    // Recorded ids keep their verdicts.
    expect(again.refusal(_hex(5), _key(1)), KeyRefusal.none);
    expect(again.dirty, isFalse);
  });

  test('refusal on a held id with another key answers tainted and leaves the '
      'record bytes unchanged', () {
    final x = _hex(1000);
    final bytes = _json(
      _record(ids: _many(256), held: {x: base64Encode(_key(1))}, closed: true),
    );
    final h = _read(bytes);
    expect(h.unreadable, isFalse);
    expect(h.refusal(x, _key(2)), KeyRefusal.tainted);
    expect(h.refusal(x, _key(1)), KeyRefusal.unrecorded);
    expect(h.dirty, isFalse);
    expect(h.encode(), bytes);
    expect(_stored(h)['held'], {x: base64Encode(_key(1))});
    expect(_stored(h)['changed'], isEmpty);
  });

  test('a record without held decodes as an empty held', () {
    final k = base64Encode(_key(1));
    final old = {
      ..._record(ids: {_hex(1): k}, changed: [_hex(2)]),
    }..remove('held');
    final h = _read(_json(old));
    expect(h.unreadable, isFalse);
    expect(h.dirty, isFalse);
    expect(h.total, 2);
    expect(h.refusal(_hex(1), _key(1)), KeyRefusal.none);
    expect(h.refusal(_hex(2), _key(1)), KeyRefusal.tainted);
    expect(_stored(h), _record(ids: {_hex(1): k}, changed: [_hex(2)]));
  });

  test('an id in two of ids, changed and held makes the record '
      'unreadable', () {
    final k = base64Encode(_key(1));
    final x = _hex(1);
    final bad = [
      _record(ids: {x: k}, changed: [x]),
      _record(ids: {x: k}, held: {x: k}, closed: true),
      _record(changed: [x], held: {x: k}, closed: true),
      _record(ids: {x: k}, changed: [x], held: {x: k}, closed: true),
    ];
    for (var i = 0; i < bad.length; i++) {
      expect(_read(_json(bad[i])).unreadable, isTrue, reason: 'case $i');
    }
    // Each in one place: readable.
    expect(
      _read(
        _json(
          _record(
            ids: {x: k},
            changed: [_hex(2)],
            held: {_hex(3): k},
            closed: true,
          ),
        ),
      ).unreadable,
      isFalse,
    );
  });

  test('at the hard bound a new id is refused, is not recorded and is never '
      'admitted later', () {
    expect(kMaxKeyHistoryTotal, 2048);
    final x = _hex(9000);
    // 768 attributable ids and 1280 held: 2048 entries.
    final bytes = _json(
      _record(
        ids: _many(768),
        held: _many(1280, from: 1000, key: 2),
        closed: true,
        allow: 768,
      ),
    );
    final h = _read(bytes);
    expect(h.unreadable, isFalse);
    expect(h.total, 2048);
    expect(h.admissible(x, _key(3)), isFalse);
    expect(h.admit(x, _key(3)), KeyRefusal.unrecorded);
    expect(h.dirty, isFalse);
    expect(h.total, 2048);
    expect(h.encode(), bytes);
    expect(h.refusal(x, _key(3)), KeyRefusal.unrecorded);

    // Allowing new devices promotes held ids only: the id that could not be
    // recorded is in no list, so nothing ever reaches it.
    h.allowNewDevices();
    expect(h.allowance, 1024);
    expect(h.size, 1024);
    expect(h.total, 2048);
    expect(h.closed, isTrue);
    expect(h.mayAllowMore, isFalse);
    expect(h.refusal(x, _key(3)), KeyRefusal.unrecorded);
    expect(h.admit(x, _key(3)), KeyRefusal.unrecorded);
    expect(h.admissible(x, _key(3)), isFalse);
    final stored = _stored(h);
    for (final list in ['ids', 'held']) {
      expect((stored[list]! as Map).keys, isNot(contains(x)));
    }
    expect(stored['changed'], isEmpty);
    expect(h.total, 2048);

    // An open record at the bound (only taints of held ids can take one
    // there) closes on the new id and still does not record it.
    final open = _read(
      _json(_record(changed: [for (var i = 0; i < 2048; i++) _hex(i)])),
    );
    expect(open.unreadable, isFalse);
    expect(open.closed, isFalse);
    expect(open.admit(x, _key(3)), KeyRefusal.unrecorded);
    expect(open.closed, isTrue);
    expect(open.dirty, isTrue);
    expect(open.total, 2048);
    expect(_stored(open)['held'], isEmpty);
  });

  test('decode bounds the total, and the allowance is enforced when '
      'admitting', () {
    expect(_read(_json(_record(ids: _many(256)))).unreadable, isFalse);
    // Over the allowance, within the bound: it decodes (a taint of a held
    // id leaves such a record), and a new id is held, not admitted.
    final over = _read(
      _json(_record(ids: _many(256), changed: [_hex(5000)], closed: true)),
    );
    expect(over.unreadable, isFalse);
    expect(over.size, 257);
    expect(over.allowance, 256);
    expect(over.admissible(_hex(6000), _key(1)), isFalse);
    expect(over.admit(_hex(6000), _key(1)), KeyRefusal.unrecorded);
    expect(_stored(over)['held'], {_hex(6000): base64Encode(_key(1))});
    expect(over.size, 257);
    // The same while not closed: it closes.
    final open = _read(_json(_record(ids: _many(300))));
    expect(open.unreadable, isFalse);
    expect(open.admit(_hex(6000), _key(1)), KeyRefusal.unrecorded);
    expect(open.closed, isTrue);
    expect(_stored(open)['held'], {_hex(6000): base64Encode(_key(1))});
    final wide = _read(_json(_record(ids: _many(257), allow: 512)));
    expect(wide.unreadable, isFalse);
    expect(wide.allowance, 512);
    expect(wide.admit(_hex(6000), _key(1)), KeyRefusal.none);

    // The total: 2048 entries decode, 2049 do not, wherever they are.
    Map<String, Object?> sized(int ids, int changed, int held) => _record(
      ids: _many(ids),
      changed: [for (var i = 0; i < changed; i++) _hex(3000 + i)],
      held: _many(held, from: 6000),
      closed: held > 0,
      allow: 1024,
    );
    for (final (ids, changed, held) in [
      (2048, 0, 0),
      (0, 2048, 0),
      (0, 0, 2048),
      (1024, 24, 1000),
    ]) {
      expect(
        _read(_json(sized(ids, changed, held))).unreadable,
        isFalse,
        reason: '$ids $changed $held',
      );
    }
    for (final (ids, changed, held) in [
      (2049, 0, 0),
      (0, 2049, 0),
      (0, 0, 2049),
      (1024, 25, 1000),
    ]) {
      expect(
        _read(_json(sized(ids, changed, held))).unreadable,
        isTrue,
        reason: '$ids $changed $held',
      );
    }
    for (final allow in [0, 255, 257, 300, 1280, -256]) {
      expect(
        _read(_json(_record(allow: allow))).unreadable,
        isTrue,
        reason: 'allow $allow',
      );
    }
    expect(_read(_json(_record(allow: 1024))).unreadable, isFalse);
  });

  test('the cross-check accepts a held pin only unattributed on its key, and '
      'an absent pin only at the hard bound', () {
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
    // Closed changes nothing: an absent pin was never remembered, so the
    // record is not the one this vault wrote.
    for (final side in [MemberSide.unattributed, MemberSide.theirs]) {
      expect(
        _read(
          record(closed: true),
          current: [_pin(_hex(3), _key(1), side)],
        ).unreadable,
        isTrue,
      );
      expect(
        _read(
          record(closed: true),
          former: [_pin(_hex(4), _key(1), side)],
        ).unreadable,
        isTrue,
      );
    }
    // A held id: consistent only as an unattributed pin on the held key.
    final held = _json(
      _record(
        ids: {_hex(1): k1},
        held: {_hex(3): k1, _hex(4): base64Encode(_key(2))},
        closed: true,
      ),
    );
    expect(
      _read(
        held,
        current: [_pin(_hex(3), _key(1), MemberSide.unattributed)],
        former: [_pin(_hex(4), _key(2), MemberSide.unattributed)],
      ).unreadable,
      isFalse,
    );
    for (final side in [MemberSide.theirs, MemberSide.mine]) {
      expect(
        _read(held, current: [_pin(_hex(3), _key(1), side)]).unreadable,
        isTrue,
      );
      expect(
        _read(held, former: [_pin(_hex(3), _key(1), side)]).unreadable,
        isTrue,
      );
    }
    // A pin of a held id on another key cannot exist: the change would
    // have tainted the id.
    expect(
      _read(
        held,
        current: [_pin(_hex(3), _key(2), MemberSide.unattributed)],
      ).unreadable,
      isTrue,
    );
    expect(
      _read(
        held,
        former: [_pin(_hex(4), _key(1), MemberSide.unattributed)],
      ).unreadable,
      isTrue,
    );
    // The hard bound: an id met there could not be recorded, so its
    // unattributed pin is consistent; one entry short it is not.
    Uint8List sized(int n) => _json(
      _record(ids: _many(256), held: _many(n - 256, from: 1000), closed: true),
    );
    final lost = _hex(9000);
    expect(
      _read(
        sized(2048),
        current: [_pin(lost, _key(1), MemberSide.unattributed)],
        former: [_pin(_hex(9001), _key(1), MemberSide.unattributed)],
      ).unreadable,
      isFalse,
    );
    expect(
      _read(
        sized(2048),
        current: [_pin(lost, _key(1), MemberSide.theirs)],
      ).unreadable,
      isTrue,
    );
    expect(
      _read(
        sized(2047),
        current: [_pin(lost, _key(1), MemberSide.unattributed)],
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
    // A held id is not admissible on any key.
    final held = _read(
      _json(_record(held: {_hex(3): base64Encode(_key(1))}, closed: true)),
    );
    expect(held.admissible(_hex(3), _key(1)), isFalse);
    expect(held.admissible(_hex(3), _key(2)), isFalse);
    expect(held.dirty, isFalse);
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

  test('this device is never refused, also by an unreadable history', () {
    final unreadable = [
      // Missing with state, undecodable, and contradicted by a pin.
      _read(null, thisHex: _hex(9)),
      _read(Uint8List.fromList(utf8.encode('{"v":1')), thisHex: _hex(9)),
      _read(
        _json(_record()),
        current: [_pin(_hex(1), _key(1), MemberSide.theirs)],
        thisHex: _hex(9),
      ),
    ];
    for (var i = 0; i < unreadable.length; i++) {
      final h = unreadable[i];
      expect(h.unreadable, isTrue, reason: 'case $i');
      expect(h.admit(_hex(9), _key(1)), KeyRefusal.none, reason: 'case $i');
      expect(h.refusal(_hex(9), _key(2)), KeyRefusal.none, reason: 'case $i');
      expect(h.admissible(_hex(9), _key(3)), isTrue, reason: 'case $i');
      // Every other device is still refused, and nothing changes.
      expect(h.admit(_hex(1), _key(1)), KeyRefusal.unreadable);
      expect(h.refusal(_hex(1), _key(1)), KeyRefusal.unreadable);
      expect(h.admissible(_hex(1), _key(1)), isFalse);
      expect(h.dirty, isFalse);
    }
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
      _record(ids: {for (var i = 0; i < 2049; i++) _hex(i): k}),
      // `held` is checked like `ids`, and is never non-empty while open.
      {..._record(closed: true), 'held': <Object?>[]},
      _record(held: {_hex(1): ''}, closed: true),
      _record(held: {_hex(1): 'not base64!'}, closed: true),
      {
        ..._record(closed: true),
        'held': {_hex(1): 7},
      },
      _record(held: {'ABCD': k}, closed: true),
      _record(held: {'abc': k}, closed: true),
      _record(held: {_hex(1): k}),
      // An empty device id, in any of the three.
      _record(ids: {'': k}),
      _record(changed: ['']),
      _record(held: {'': k}, closed: true),
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

  test('allowing new devices admits a held id on the key it was first seen '
      'with', () {
    final h = _read(
      _json(
        _record(
          ids: _many(255),
          changed: [_hex(900)],
          held: {
            _hex(1000): base64Encode(_key(1)),
            _hex(1001): base64Encode(_key(2)),
          },
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
    h.allowNewDevices();
    expect(h.closed, isFalse);
    expect(h.allowance, 512);
    expect(h.dirty, isTrue);
    expect(h.size, 258);
    expect(h.total, 258);
    // On the key first seen, and on no other.
    expect(h.refusal(_hex(1000), _key(1)), KeyRefusal.none);
    expect(h.refusal(_hex(1001), _key(2)), KeyRefusal.none);
    expect(h.refusal(_hex(1000), _key(2)), KeyRefusal.tainted);
    expect(h.refusal(_hex(1001), _key(1)), KeyRefusal.tainted);
    final stored = _stored(h);
    expect(stored['held'], isEmpty);
    expect((stored['ids']! as Map)[_hex(1000)], base64Encode(_key(1)));
    expect((stored['ids']! as Map)[_hex(1001)], base64Encode(_key(2)));
    // No id and no taint dropped.
    expect(h.refusal(_hex(900), _key(4)), KeyRefusal.tainted);
    for (var i = 0; i < 255; i++) {
      expect(h.refusal(_hex(i), _key(1)), KeyRefusal.none);
    }
    expect(
      _read(h.encode(), current: current, former: former).unreadable,
      isFalse,
    );
    // A pin of a promoted id on another key contradicts the record.
    expect(
      _read(
        h.encode(),
        current: [_pin(_hex(1000), _key(2), MemberSide.unattributed)],
      ).unreadable,
      isTrue,
    );

    h.allowNewDevices();
    h.allowNewDevices();
    expect(h.allowance, 1024);
    expect(h.mayAllowMore, isFalse);
    expect(h.allowNewDevices, throwsStateError);
    expect(h.allowance, 1024);
    expect(KeyHistory.unreadableRecord().allowNewDevices, throwsStateError);
  });

  test('allowing new devices with more held ids than room stays closed and '
      'promotes in a fixed order', () {
    // 258 held ids, stored from the highest id down, each with its own key.
    final held = {
      for (var i = 257; i >= 0; i--)
        _hex(2000 + i): base64Encode(_key(i % 200 + 2)),
    };
    final h = _read(_json(_record(ids: _many(256), held: held, closed: true)));
    expect(h.unreadable, isFalse);
    h.allowNewDevices();
    expect(h.allowance, 512);
    expect(h.size, 512);
    expect(h.total, 514);
    // Still closed: two ids are still held.
    expect(h.closed, isTrue);
    expect(h.mayAllowMore, isTrue);
    final stored = _stored(h);
    // The 256 lowest ids, each on its held key; the two highest stay held.
    expect(stored['held'], {
      _hex(2256): held[_hex(2256)],
      _hex(2257): held[_hex(2257)],
    });
    expect(stored['ids'], {
      ..._many(256),
      for (var i = 0; i < 256; i++) _hex(2000 + i): held[_hex(2000 + i)],
    });
    expect(stored['changed'], isEmpty);
    expect(h.refusal(_hex(2000), _key(2)), KeyRefusal.none);
    expect(h.refusal(_hex(2257), _key(57 + 2)), KeyRefusal.unrecorded);
    // A new id while still closed is held, behind them.
    expect(h.admit(_hex(1), _key(1)), KeyRefusal.none);
    expect(h.admit(_hex(100), _key(1)), KeyRefusal.none);
    expect(h.admit(_hex(9000), _key(1)), KeyRefusal.unrecorded);
    expect(h.total, 515);

    // The next allowance takes the rest and reopens.
    final again = _read(h.encode());
    again.allowNewDevices();
    expect(again.allowance, 768);
    expect(again.size, 515);
    expect(again.total, 515);
    expect(again.closed, isFalse);
    expect(_stored(again)['held'], isEmpty);
    expect(again.refusal(_hex(2257), _key(57 + 2)), KeyRefusal.none);
  });

  test('allowing new devices over the allowance promotes nothing and stays '
      'closed', () {
    final x = _hex(9000);
    final taints = [for (var i = 0; i < 300; i++) _hex(3000 + i)];
    // 556 entries against an allowance of 256: 300 held ids were tainted.
    final h = _read(
      _json(
        _record(
          ids: _many(256),
          changed: taints,
          held: {x: base64Encode(_key(1))},
          closed: true,
        ),
      ),
    );
    expect(h.unreadable, isFalse);
    h.allowNewDevices();
    expect(h.allowance, 512);
    expect(h.dirty, isTrue);
    expect(h.closed, isTrue);
    expect(h.refusal(x, _key(1)), KeyRefusal.unrecorded);
    expect(_stored(h)['held'], {x: base64Encode(_key(1))});
    // Empty-handed too: no held id, but still no room.
    final none = _read(
      _json(_record(ids: _many(256), changed: taints, closed: true)),
    );
    none.allowNewDevices();
    expect(none.allowance, 512);
    expect(none.closed, isTrue);
    expect(none.admit(x, _key(1)), KeyRefusal.unrecorded);
    // With room at last, the held id is admitted and the record reopens.
    h.allowNewDevices();
    expect(h.allowance, 768);
    expect(h.size, 557);
    expect(h.closed, isFalse);
    expect(h.refusal(x, _key(1)), KeyRefusal.none);
    expect(_stored(h)['changed'], taints);
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
        'held': <String, Object?>{},
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
