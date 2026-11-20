import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/vault_records.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

final DateTime _base = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

Uint8List _id(int n) =>
    Uint8List.fromList(utf8.encode('device-${n.toString().padLeft(12, '0')}'));
Uint8List _key(int n) => Uint8List.fromList(List.filled(32, n));
String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

DirectoryDevice _dev(int n, {int? key, bool inactive = false}) =>
    DirectoryDevice(
      deviceId: _id(n),
      signatureKey: _key(key ?? n),
      inactive: inactive,
    );

DeviceList _list(List<DirectoryDevice> d, {DateTime? at}) =>
    DeviceList(ListState.readable, d, at ?? _base);

const DeviceList _unreadable = DeviceList.unreadable();
final DeviceList _deferred = DeviceList(ListState.deferred, [
  _dev(1),
  _dev(2),
], _base);

MemberRecord _member(int n, String side, {int? key, String conv = 'c1'}) =>
    MemberRecord(
      conversationId: conv,
      deviceId: _id(n),
      signatureKey: _key(key ?? n),
      side: side,
      since: const MlsPair(0, 1),
    );

pb.ClaimedKeyPackage _claim(
  int n, {
  int? key,
  bool has = true,
  List<int>? package,
}) => pb.ClaimedKeyPackage(
  deviceId: utf8.decode(_id(n)),
  signaturePublicKey: _key(key ?? n),
  keyPackage: has ? (package ?? [n, 9, 9]) : const <int>[],
  hasKeyPackage_4: has,
);

KeyPackageInfo _info(int n, {int? key, int? id}) =>
    KeyPackageInfo(deviceId: _id(id ?? n), signaturePublicKey: _key(key ?? n));

typedef _Claims = ({List<UsableClaim> usable, List<Uint8List> emptyFor});

_Claims _check({
  ClaimSide side = ClaimSide.theirs,
  List<pb.ClaimedKeyPackage>? claimed,
  List<KeyPackageInfo?>? inspected,
  DeviceList? directory,
  DeviceList? ownList,
  List<MemberRecord> members = const [],
  int thisDevice = 99,
  bool forNewGroup = false,
}) {
  final c = claimed ?? [_claim(5)];
  return checkClaims(
    side: side,
    claimed: c,
    inspected: inspected ?? [for (final x in c) _info(int.parse(_n(x)))],
    directory: directory ?? _list([_dev(5)]),
    ownList: ownList ?? _list([_dev(1), _dev(99)]),
    members: members,
    thisDeviceId: _id(thisDevice),
    forNewGroup: forNewGroup,
  );
}

String _n(pb.ClaimedKeyPackage c) =>
    int.parse(c.deviceId.substring('device-'.length)).toString();

void main() {
  group('R3 checkClaims', () {
    test('a package passing every check is usable', () {
      final r = _check();
      expect(r.usable, hasLength(1));
      expect(r.usable.single.deviceId, _id(5));
      expect(r.usable.single.signatureKey, _key(5));
      expect(r.usable.single.keyPackage, [5, 9, 9]);
      expect(r.usable.single.side, ClaimSide.theirs);
      expect(r.emptyFor, isEmpty);
    });

    final cases = <String, _Claims Function()>{
      'inspection failed': () => _check(inspected: [null]),
      'id differs from the claim': () => _check(inspected: [_info(5, id: 6)]),
      'key differs from the claim': () => _check(inspected: [_info(5, key: 6)]),
      'key differs from the directory entry': () =>
          _check(directory: _list([_dev(5, key: 6)])),
      'device not in the directory list': () =>
          _check(directory: _list([_dev(7)])),
      'device inactive in the directory': () =>
          _check(directory: _list([_dev(5, inactive: true)])),
      'directory unreadable': () => _check(directory: _unreadable),
      'directory deferred': () =>
          _check(directory: DeviceList(ListState.deferred, [_dev(5)], _base)),
      'already a member': () =>
          _check(members: [_member(5, MemberSide.theirs)]),
      'this device': () => _check(
        claimed: [_claim(99)],
        directory: _list([_dev(99)]),
        side: ClaimSide.mine,
        thisDevice: 99,
      ),
      'repeated in the claim': () => _check(
        claimed: [_claim(5), _claim(5)],
        inspected: [_info(5), _info(5)],
      ),
      'key pinned to the other side': () =>
          _check(members: [_member(8, MemberSide.mine, key: 5)]),
      'key pinned to another device id': () =>
          _check(members: [_member(8, MemberSide.theirs, key: 5)]),
      'a peer claim for a device in the own list': () =>
          _check(ownList: _list([_dev(5)])),
      'a peer claim with the own list unreadable': () =>
          _check(ownList: _unreadable),
      'package bytes empty': () =>
          _check(claimed: [_claim(5, package: const <int>[])]),
    };
    test('each single failing check drops the package', () {
      for (final e in cases.entries) {
        final r = e.value();
        expect(r.usable, isEmpty, reason: e.key);
        expect(r.emptyFor, isEmpty, reason: e.key);
      }
    });

    test('has_key_package false goes to emptyFor', () {
      final r = _check(
        claimed: [_claim(5, has: false), _claim(6)],
        inspected: [null, _info(6)],
        directory: _list([_dev(5), _dev(6)]),
      );
      expect(r.emptyFor, [_id(5)]);
      expect(r.usable.map((u) => u.deviceId), [_id(6)]);
    });

    test('a device of the own side is allowed in the own list', () {
      final r = _check(
        side: ClaimSide.mine,
        claimed: [_claim(1)],
        inspected: [_info(1)],
        directory: _list([_dev(1)]),
      );
      expect(r.usable, hasLength(1));
      expect(r.usable.single.side, ClaimSide.mine);
    });

    test('forNewGroup skips the member check but not the pin checks', () {
      final old = [_member(5, MemberSide.theirs)];
      expect(_check(members: old, forNewGroup: true).usable, hasLength(1));
      final pinnedOther = [_member(8, MemberSide.theirs, key: 5)];
      expect(_check(members: pinnedOther, forNewGroup: true).usable, isEmpty);
      final pinnedSide = [_member(5, MemberSide.mine)];
      expect(_check(members: pinnedSide, forNewGroup: true).usable, isEmpty);
    });
  });

  group('R5 checkWelcome', () {
    const label = MlsPair(2, 4);
    final own = {_hex(_id(1))};
    GroupMember gm(int n, {int? key}) =>
        GroupMember(deviceId: _id(n), signaturePublicKey: _key(key ?? n));

    WelcomeVerdict verdict({
      String conv = 'c1',
      MlsPair lbl = label,
      Uint8List? groupId,
      int? epoch,
      List<GroupMember>? members,
      MlsPair? after,
      MlsPair? high,
      Set<String>? ownIds,
    }) => checkWelcome(
      conversationId: conv,
      label: lbl,
      joinedGroupId: groupId ?? mlsGroupId('c1', lbl.generation),
      joinedEpoch: epoch ?? lbl.epoch + 1,
      members: members ?? [gm(1), gm(2)],
      afterPair: after,
      joinHighWater: high,
      ownDeviceIdsHex: ownIds ?? own,
    );

    test('a welcome meeting every rule is accepted', () {
      expect(
        verdict(after: const MlsPair(2, 3), high: const MlsPair(1, 9)),
        WelcomeVerdict.accept,
      );
    });

    test('each single failing rule is permanent', () {
      final cases = <String, WelcomeVerdict>{
        'group id of another conversation': verdict(
          groupId: mlsGroupId('c2', 2),
        ),
        'group id of another generation': verdict(groupId: mlsGroupId('c1', 3)),
        'epoch not label + 1': verdict(epoch: 7),
        'epoch equal to label': verdict(epoch: 4),
        'label equal to the after-pair': verdict(after: label),
        'label below the after-pair': verdict(after: const MlsPair(2, 5)),
        'label equal to the join high-water': verdict(high: label),
        'label below the join high-water': verdict(high: const MlsPair(3, 0)),
        '11 members': verdict(members: [for (var i = 1; i <= 11; i++) gm(i)]),
        'no members': verdict(members: const []),
        'a repeated key': verdict(members: [gm(1), gm(2, key: 1)]),
        'only own devices': verdict(
          members: [gm(1), gm(2)],
          ownIds: {_hex(_id(1)), _hex(_id(2))},
        ),
      };
      for (final e in cases.entries) {
        expect(e.value, WelcomeVerdict.permanent, reason: e.key);
      }
    });

    test('10 members are accepted', () {
      expect(
        verdict(members: [for (var i = 1; i <= 10; i++) gm(i)]),
        WelcomeVerdict.accept,
      );
    });

    test('absent marks accept any pair', () {
      expect(verdict(lbl: const MlsPair(0, 0)), WelcomeVerdict.accept);
      expect(
        verdict(lbl: const MlsPair(0, 0), after: null, high: null),
        WelcomeVerdict.accept,
      );
    });
  });

  group('M2 attribute', () {
    test('own list wins when both lists have the device', () {
      expect(
        attribute(
          deviceId: _id(1),
          signatureKey: _key(1),
          ownList: _list([_dev(1)]),
          peerList: _list([_dev(1)]),
        ),
        MemberSide.mine,
      );
    });

    test('peer list match is theirs', () {
      expect(
        attribute(
          deviceId: _id(2),
          signatureKey: _key(2),
          ownList: _list([_dev(1)]),
          peerList: _list([_dev(2, inactive: true)]),
        ),
        MemberSide.theirs,
      );
    });

    test('key mismatch is unattributed', () {
      expect(
        attribute(
          deviceId: _id(2),
          signatureKey: _key(9),
          ownList: _list([_dev(1)]),
          peerList: _list([_dev(2)]),
        ),
        MemberSide.unattributed,
      );
    });

    test('an unreadable list contributes no match', () {
      for (final bad in [_unreadable, _deferred]) {
        expect(
          attribute(
            deviceId: _id(1),
            signatureKey: _key(1),
            ownList: bad,
            peerList: _list([_dev(3)]),
          ),
          MemberSide.unattributed,
        );
        expect(
          attribute(
            deviceId: _id(1),
            signatureKey: _key(1),
            ownList: _list([_dev(3)]),
            peerList: bad,
          ),
          MemberSide.unattributed,
        );
      }
    });

    test(
      'after a reset an unchanged member keeps its side without any list',
      () {
        final pinned = [
          _member(1, MemberSide.mine),
          _member(2, MemberSide.theirs),
        ];
        String after(int n, {int? key}) => attributeAfterReset(
          deviceId: _id(n),
          signatureKey: _key(key ?? n),
          pinnedAtEndOfPrevious: pinned,
          ownList: _unreadable,
          peerList: _unreadable,
        );
        expect(after(1), MemberSide.mine);
        expect(after(2), MemberSide.theirs);
        // A changed key under a known id is not the pinned device.
        expect(after(2, key: 7), MemberSide.unattributed);
        expect(after(3), MemberSide.unattributed);
        expect(
          attributeAfterReset(
            deviceId: _id(3),
            signatureKey: _key(3),
            pinnedAtEndOfPrevious: pinned,
            ownList: _list([_dev(3)]),
            peerList: _unreadable,
          ),
          MemberSide.mine,
        );
      },
    );
  });

  group('removal clock', () {
    final accepted = _base;
    test(
      'a fetch 59 s after acceptance does not count and one at 60 s does',
      () {
        expect(
          fetchCounts(
            fetchedAt: accepted.add(const Duration(seconds: 59)),
            acceptedSeenAt: accepted,
          ),
          isFalse,
        );
        expect(
          fetchCounts(
            fetchedAt: accepted.add(const Duration(seconds: 60)),
            acceptedSeenAt: accepted,
          ),
          isTrue,
        );
      },
    );

    test('a fetch before acceptance was seen never counts', () {
      expect(
        fetchCounts(
          fetchedAt: accepted.subtract(const Duration(hours: 1)),
          acceptedSeenAt: accepted,
        ),
        isFalse,
      );
    });

    test('an unaccepted conversation never allows a removal', () {
      final first = _base.add(const Duration(minutes: 5));
      final later = first.add(const Duration(minutes: 10));
      expect(fetchCounts(fetchedAt: later, acceptedSeenAt: null), isFalse);
      expect(
        mayRemovePeerDevice(
          member: _member(2, MemberSide.theirs),
          peerList: _list([_dev(3)], at: later),
          evidence: RemovalEvidence(firstMissAt: first),
          theirMemberCount: 2,
        ),
        isFalse,
      );
    });

    final t0 = _base.add(const Duration(minutes: 10));
    RemovalEvidence evidence({DateTime? first, DateTime? acc}) =>
        RemovalEvidence(acceptedSeenAt: acc ?? accepted, firstMissAt: first);
    bool peer({
      DeviceList? list,
      RemovalEvidence? ev,
      int count = 2,
      MemberRecord? member,
    }) => mayRemovePeerDevice(
      member: member ?? _member(2, MemberSide.theirs),
      peerList:
          list ?? _list([_dev(3)], at: t0.add(const Duration(minutes: 2))),
      evidence: ev ?? evidence(first: t0),
      theirMemberCount: count,
    );

    test('removal baseline is allowed', () {
      expect(peer(), isTrue);
    });

    test('one counting miss is not enough', () {
      expect(peer(ev: evidence()), isFalse);
      // The first miss itself did not count (before acceptance + 60 s).
      expect(
        peer(ev: evidence(first: accepted.add(const Duration(seconds: 30)))),
        isFalse,
      );
    });

    test('two misses 1 min 59 s apart are not enough and 2 min apart are', () {
      expect(
        peer(
          list: _list([
            _dev(3),
          ], at: t0.add(const Duration(minutes: 1, seconds: 59))),
        ),
        isFalse,
      );
      expect(
        peer(list: _list([_dev(3)], at: t0.add(const Duration(minutes: 2)))),
        isTrue,
      );
    });

    test('an empty readable list never removes', () {
      expect(
        peer(list: _list([], at: t0.add(const Duration(minutes: 3)))),
        isFalse,
      );
    });

    test('an unreadable or deferred second list never removes', () {
      expect(peer(list: _unreadable), isFalse);
      expect(
        peer(
          list: DeviceList(ListState.deferred, [
            _dev(3),
          ], t0.add(const Duration(minutes: 3))),
        ),
        isFalse,
      );
    });

    test('an inactive listed device is never removed', () {
      expect(
        peer(
          list: _list([
            _dev(2, inactive: true),
            _dev(3),
          ], at: t0.add(const Duration(minutes: 3))),
        ),
        isFalse,
      );
    });

    test('the peer\'s last device is never removed', () {
      expect(peer(count: 1), isFalse);
    });

    test('a peer removal needs a peer-side member', () {
      expect(peer(member: _member(2, MemberSide.mine)), isFalse);
      expect(peer(member: _member(2, MemberSide.unattributed)), isFalse);
    });

    test(
      'an own device absent from a readable own list is removed, an inactive '
      'one is kept, this device never',
      () {
        bool own(int n, DeviceList list, {int thisDevice = 99}) =>
            mayRemoveOwnDevice(
              member: _member(n, MemberSide.mine),
              ownList: list,
              thisDeviceId: _id(thisDevice),
            );
        expect(own(2, _list([_dev(1), _dev(99)])), isTrue);
        expect(own(2, _list([_dev(2, inactive: true), _dev(99)])), isFalse);
        expect(own(2, _list([_dev(2), _dev(99)])), isFalse);
        expect(own(99, _list([_dev(1)])), isFalse);
        expect(own(2, _unreadable), isFalse);
        expect(own(2, _deferred), isFalse);
        expect(own(2, _list([])), isFalse);
        expect(
          mayRemoveOwnDevice(
            member: _member(2, MemberSide.theirs),
            ownList: _list([_dev(1)]),
            thisDeviceId: _id(99),
          ),
          isFalse,
        );
      },
    );

    test(
      'an unattributed member is removed only after 2 minutes with both lists '
      'readable and counting',
      () {
        final seen = t0;
        final at = t0.add(const Duration(minutes: 2));
        bool un({
          DeviceList? own,
          DeviceList? peerList,
          DateTime? firstSeen,
          DateTime? acc,
          MemberRecord? member,
        }) => mayRemoveUnattributed(
          member: member ?? _member(7, MemberSide.unattributed),
          ownList: own ?? _list([_dev(1)], at: at),
          peerList: peerList ?? _list([_dev(2)], at: at),
          firstSeenUnattributedAt: firstSeen ?? seen,
          acceptedSeenAt: acc ?? accepted,
        );
        expect(un(), isTrue);
        expect(
          un(firstSeen: at.subtract(const Duration(minutes: 1, seconds: 59))),
          isFalse,
        );
        expect(un(own: _unreadable), isFalse);
        expect(un(peerList: _unreadable), isFalse);
        expect(un(own: _deferred), isFalse);
        expect(un(own: _list([], at: at)), isFalse);
        expect(un(peerList: _list([], at: at)), isFalse);
        expect(
          mayRemoveUnattributed(
            member: _member(7, MemberSide.unattributed),
            ownList: _list([_dev(1)], at: at),
            peerList: _list([_dev(2)], at: at),
            firstSeenUnattributedAt: seen,
            acceptedSeenAt: null,
          ),
          isFalse,
        );
        expect(un(acc: at), isFalse);
        expect(
          un(
            own: _list([
              _dev(1),
            ], at: accepted.add(const Duration(seconds: 59))),
          ),
          isFalse,
        );
        // A list that now attributes the member means it is no longer a ghost.
        expect(un(peerList: _list([_dev(2), _dev(7)], at: at)), isFalse);
        expect(un(member: _member(7, MemberSide.theirs)), isFalse);
      },
    );
  });

  group('M1 devicesToAdd', () {
    test('inactive devices are not added', () {
      final r = devicesToAdd(
        ownList: _list([_dev(1, inactive: true), _dev(99), _dev(2)]),
        peerList: _list([_dev(3, inactive: true), _dev(4)]),
        members: const [],
        thisDeviceId: _id(99),
      );
      expect(r.map((e) => e.deviceId), [_id(2), _id(4)]);
      expect(r.map((e) => e.side), [ClaimSide.mine, ClaimSide.theirs]);
    });

    test('unreadable lists add nothing and members are skipped', () {
      expect(
        devicesToAdd(
          ownList: _unreadable,
          peerList: _deferred,
          members: const [],
          thisDeviceId: _id(99),
        ),
        isEmpty,
      );
      final r = devicesToAdd(
        ownList: _list([_dev(1)]),
        peerList: _list([_dev(1), _dev(2)]),
        members: [_member(2, MemberSide.theirs)],
        thisDeviceId: _id(99),
      );
      expect(r.map((e) => e.deviceId), [_id(1)]);
      expect(r.single.side, ClaimSide.mine);
    });

    test('adds stop at 10 members, own side first', () {
      final r = devicesToAdd(
        ownList: _list([for (var i = 1; i <= 4; i++) _dev(i)]),
        peerList: _list([for (var i = 11; i <= 20; i++) _dev(i)]),
        members: [for (var i = 50; i < 55; i++) _member(i, MemberSide.mine)],
        thisDeviceId: _id(99),
      );
      expect(r, hasLength(5));
      expect(r.take(4).every((e) => e.side == ClaimSide.mine), isTrue);
      expect(r.last.side, ClaimSide.theirs);
      expect(r.last.deviceId, _id(11));
      expect(
        devicesToAdd(
          ownList: _list([_dev(1)]),
          peerList: _list([_dev(2)]),
          members: [for (var i = 50; i < 60; i++) _member(i, MemberSide.mine)],
          thisDeviceId: _id(99),
        ),
        isEmpty,
      );
    });
  });

  group('R4 codeParties', () {
    test('no parties while a member is unattributed', () {
      expect(
        codeParties('c1', [
          _member(1, MemberSide.mine),
          _member(2, MemberSide.theirs),
          _member(3, MemberSide.unattributed),
        ]),
        isNull,
      );
      expect(codeParties('c1', [_member(1, MemberSide.mine)]), isNull);
    });

    test('party ids differ between two conversations with the same keys', () {
      List<MemberRecord> ms(String c) => [
        _member(1, MemberSide.mine, conv: c),
        _member(2, MemberSide.theirs, conv: c),
      ];
      final a = codeParties('c1', ms('c1'))!;
      final b = codeParties('c2', ms('c2'))!;
      expect(a.mine.userId, isNot(b.mine.userId));
      expect(a.theirs.userId, isNot(b.theirs.userId));
      expect(a.mine.userId, isNot(a.theirs.userId));
    });

    test('this device is on my side', () {
      final p = codeParties('c1', [
        _member(99, MemberSide.mine),
        _member(1, MemberSide.mine),
        _member(2, MemberSide.theirs),
      ])!;
      expect(p.mine.deviceKeys, [_key(99), _key(1)]);
      expect(p.theirs.deviceKeys, [_key(2)]);
      expect(utf8.decode(p.mine.userId), partyId('c1', [_key(99), _key(1)]));
      expect(utf8.decode(p.theirs.userId), partyId('c1', [_key(2)]));
    });
  });
}
