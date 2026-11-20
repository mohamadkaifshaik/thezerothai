import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_markers.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_vault_world.dart';

const _a = 'user-a';
const _b = 'user-b';
const _hour = Duration(hours: 1);

Uint8List _b8(String s) => Uint8List.fromList(s.codeUnits);

late FakeVaultWorld world;

/// [uid] has no history on the device: no database, or an empty one (what
/// `SecureVault.wipe()` leaves).
bool noHistory(String uid) => world.files[uid]?.empty ?? true;

/// The log tokens that destroy something.
bool _destructive(String call) =>
    call.startsWith('wipeFile:') ||
    call.startsWith('key:') ||
    call.startsWith('vault.wipe:');

void main() {
  setUp(() => world = FakeVaultWorld());

  Future<VaultSession> signIn(
    String uid, {
    E2eeFlag flag = E2eeFlag.on,
    VaultSession? session,
    List<Object>? reported,
  }) async {
    final s = session ?? world.launch(reported: reported);
    await s.onSignedIn(uid, flag: flag);
    return s;
  }

  group('open', () {
    test('flag on: owner -> cipher -> open -> marker -> ready -> hook, and '
        'the marker names the storage and the alias only', () async {
      final ready = <String>[];
      final s = world.launch(
        onVaultReady: (v) async {
          world.calls.add('ready:${v.uid}');
          ready.add(v.uid);
        },
      );
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault, isNotNull);
      expect(s.historyLostThisOpen, isFalse);
      expect(world.calls, [
        'owner.create',
        'acquire:$_a',
        'cipher:$_a',
        'open:$_a',
        'markers.known:$_a',
        'ready:$_a',
      ]);
      final known = world.known(_a)!;
      expect(known.storage, 'opfsLocks');
      expect(known.alias, vaultKeyAlias(_a));
      expect(world.markers.knownByAlias.keys.every(isVaultKeyAlias), isTrue);
    });

    test('onVaultReady runs after publishing, outside the queue: a failure '
        'is reported generically and the vault stays ready', () async {
      final reported = <Object>[];
      final s = world.launch(
        reported: reported,
        onVaultReady: (v) async {
          // Published before the hook runs.
          expect(v.uid, _a);
          throw StateError('directory down for $_a');
        },
      );
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      await pumpEventQueue();
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault, isNotNull);
      expect(reported, [isA<VaultSessionError>()]);
      expect(reported.single.toString(), 'VaultSessionError(ready)');
    });

    test('marker absent + existing vault (first run of this build): opens '
        'and writes the marker', () async {
      world.files[_a] = FakeVaultFile('sharedIndexedDb', 1);
      world.keys[_a] = 1;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.ready);
      expect(world.known(_a)!.storage, 'sharedIndexedDb');
      expect(s.historyLostThisOpen, isFalse);
    });

    test('marker present: its storage goes to the opener as '
        'expectedStorage; an existing vault does not rewrite it', () async {
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.calls.clear();
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(s.status.value, VaultStatus.ready);
      expect(world.calls, isNot(contains('markers.known:$_a')));
    });

    test('RULED: marker present and the marked, listed database is empty '
        '(no sentinel, no rows), so the open creates a vault in it: ready, '
        'marker rewritten, reported generically as recreated, and '
        'historyLostThisOpen is true', () async {
      final reported = <Object>[];
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.files[_a]!.stamped = false; // emptied outside the app
      world.calls.clear();
      final next = await signIn(_a, reported: reported);
      expect(next.status.value, VaultStatus.ready);
      expect(next.vault!.createdThisOpen, isTrue);
      expect(next.historyLostThisOpen, isTrue);
      expect(reported.map((e) => e.toString()), [
        'VaultSessionError(recreated)',
      ]);
      expect(world.calls, contains('markers.known:$_a'));
      expect(world.calls.where(_destructive), isEmpty);
      expect(next.historyLostThisOpen, isTrue);
      await next.close();
      expect(next.historyLostThisOpen, isFalse);
    });

    test('marker says storage X, the copy is not listed (the opener would '
        'create a new vault elsewhere): storageChanged, nothing created, '
        'nothing wiped', () async {
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.files[_a]!.hidden = true;
      world.currentStorage = 'sharedIndexedDb';
      world.calls.clear();
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(s.status.value, VaultStatus.storageChanged);
      expect(world.files[_a]!.storage, 'opfsLocks', reason: 'untouched');
      expect(world.files.length, 1, reason: 'no second copy');
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('the marker write fails after a new vault was created: closed, '
        'unavailable; the next launch finds the vault and writes the '
        'marker', () async {
      world.markers.failKnownWrites = true;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      expect(s.vault, isNull);
      expect(world.calls, contains('vault.close:$_a'));
      expect(world.calls.last, 'release');
      world.markers.failKnownWrites = false;
      final next = await signIn(_a);
      expect(next.status.value, VaultStatus.ready);
      expect(world.known(_a), isNotNull);
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('I1: the lock is lost during the tail of the open (while the '
        'marker is written): never published, closed, heldElsewhere', () async {
      late VaultSession s;
      world.markers.onWriteKnown = () async {
        world.owners.single.steal();
      };
      s = await signIn(_a);
      expect(s.status.value, VaultStatus.heldElsewhere);
      expect(s.vault, isNull);
      expect(world.calls, contains('vault.close:$_a'));
      await expectLater(s.runWrite((v) async => 1), throwsA(isA<StateError>()));
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('markers that cannot persist (in-memory cache): unavailable, the '
        'vault is not opened and no collaborator is called', () async {
      world.markers.persistent = false;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      expect(world.calls, isEmpty);
    });

    test('marker read failures in the open: unavailable, reported, nothing '
        'opened or destroyed', () async {
      final reported = <Object>[];
      final s = world.launch(reported: reported);
      await s.start(restoredUid: null, restoreDefinitive: true);
      world.markers.failReads = true;
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(s.status.value, VaultStatus.unavailable);
      expect(world.calls, isNot(contains('open:$_a')));
      expect(world.calls.where(_destructive), isEmpty);
      expect(reported, isNotEmpty);
      expect(reported.every((e) => e is VaultSessionError), isTrue);
    });

    test(
      'marker read failures at start-up: reported, nothing called',
      () async {
        final reported = <Object>[];
        world.setOwed(_b);
        world.markers.failReads = true;
        final s = world.launch(reported: reported);
        await s.start(restoredUid: null, restoreDefinitive: true);
        expect(world.calls, isEmpty);
        // Pending ends and owed wipes: each read failure reported.
        expect(reported.map((e) => e.toString()), [
          'VaultSessionError(markers)',
          'VaultSessionError(markers)',
        ]);
      },
    );

    test('the marker key prefixes are pinned (persistence of the real '
        'markers: vault_markers_test.dart)', () {
      expect(kVaultKnownPrefix, 'vault.known.');
      expect(kVaultKeyLostSeenPrefix, 'vault.keyLostSeen.');
      expect(kVaultWipeOwedPrefix, 'vault.wipeOwed.');
      expect(kVaultPendingEndPrefix, 'vault.pendingEnd.');
    });
  });

  group('flag and platform', () {
    test('no vault on this device, flag off or unknown, or unsupported: no '
        'collaborator is ever called', () async {
      for (final supported in [true, false]) {
        for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
          world = FakeVaultWorld();
          final s = world.launch(
            supported: supported,
            beforeExplicitWipe: (uid) async => world.calls.add('hook:$uid'),
          );
          await s.start(restoredUid: _a, restoreDefinitive: true);
          // An unsupported platform answers nothing, whatever the flag says.
          final answer = supported ? flag : E2eeFlag.on;
          await s.onSignedIn(_a, flag: answer);
          expect(s.vaultKnown, isFalse);
          await s.onFlagChanged(
            answer == E2eeFlag.off ? E2eeFlag.unknown : E2eeFlag.off,
            uid: _a,
          );
          await s.retry();
          await s.beforeExplicitSignOut(_a);
          await s.onSessionEnded(_a, SessionEnd.userSignedOut);
          await s.onSignedIn(_b, flag: answer);
          await s.onSessionEnded(_b, SessionEnd.accountDeleted);
          expect(await s.resetByUser(), isFalse);
          expect(
            world.calls,
            isEmpty,
            reason: 'supported: $supported, flag: $flag',
          );
          expect(world.ciphers, isEmpty);
          expect(world.owners, isEmpty);
          expect(
            s.status.value,
            supported ? VaultStatus.off : VaultStatus.unsupported,
          );
        }
      }
    });

    test('flag unknown with a known vault opens it without creating', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.createFlags.clear();
      final s = await signIn(_a, flag: E2eeFlag.unknown);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vaultKnown, isTrue);
      expect(s.mayStart, isFalse);
      expect(world.createFlags, [(cipher: false, vault: false)]);
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('flag off with a known vault opens it and stays open', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.createFlags.clear();
      final s = await signIn(_a, flag: E2eeFlag.off);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault, isNotNull);
      expect(s.flag, E2eeFlag.off);
      expect(world.createFlags, [(cipher: false, vault: false)]);
      await pumpEventQueue();
      expect(s.status.value, VaultStatus.ready);
    });

    test('flag on → off keeps the vault open and wipes nothing', () async {
      final s = await signIn(_a);
      world.calls.clear();
      await s.onFlagChanged(E2eeFlag.off, uid: _a);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault, isNotNull);
      expect(s.mayStart, isFalse);
      expect(s.vaultKnown, isTrue);
      expect(world.calls, isEmpty);
      await s.onFlagChanged(E2eeFlag.unknown, uid: _a);
      expect(s.flag, E2eeFlag.unknown);
      expect(s.status.value, VaultStatus.ready);
      expect(world.calls, isEmpty);
    });

    test('flag off → on with no vault creates one', () async {
      final s = await signIn(_a, flag: E2eeFlag.off);
      expect(s.status.value, VaultStatus.off);
      expect(world.calls, isEmpty);
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      expect(s.status.value, VaultStatus.ready);
      expect(s.mayStart, isTrue);
      expect(s.vaultKnown, isTrue);
      expect(world.createFlags, [(cipher: true, vault: true)]);
      expect(world.known(_a), isNotNull);
    });

    test('a marker without a file and the flag off or unknown is unavailable '
        'and nothing is created', () async {
      for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
        world = FakeVaultWorld();
        world.setKnown(_a, 'opfsLocks');
        world.keys[_a] = 1; // a stored key, but the file is gone
        final s = await signIn(_a, flag: flag);
        expect(s.status.value, VaultStatus.unavailable, reason: '$flag');
        expect(world.keys, {_a: 1}, reason: 'no key generated');
        expect(world.files, isEmpty, reason: 'no file created');
        expect(world.known(_a), isNotNull, reason: 'marker kept');
        expect(world.calls, isNot(contains('markers.known:$_a')));
        expect(world.calls.where(_destructive), isEmpty);
        expect(s.vault, isNull);
        expect(s.vaultKnown, isTrue, reason: 'the marker is a device fact');
      }
    });

    test('a marker without a key and the flag off is keyLost pending, then on '
        'a later launch 1 h on the wipe runs and status is off, nothing '
        're-created', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.loseKey(_a); // no stored key: create false reports keyLost
      final second = await signIn(_a, flag: E2eeFlag.off);
      expect(second.status.value, VaultStatus.keyLost);
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.keyLost(_a), isNotNull);
      world.advance(_hour);
      world.calls.clear();
      final third = await signIn(_a, flag: E2eeFlag.off);
      expect(third.status.value, VaultStatus.off);
      expect(third.vault, isNull);
      expect(third.vaultKnown, isFalse);
      expect(world.calls, containsAllInOrder(['wipeFile:$_a', 'key:$_a']));
      expect(world.files, isEmpty);
      expect(world.keys, isEmpty);
      expect(world.known(_a), isNull);
      expect(world.calls, isNot(contains('markers.known:$_a')));
    });

    test('a flag answer never causes a wipe', () async {
      const flags = E2eeFlag.values;
      // Every reachable status, each built from a vault an earlier launch
      // left behind (marker, key, file), signed in with every flag answer:
      // the status each set-up reaches is asserted, so the matrix covers the
      // states it names.
      Future<VaultSession> earlier() async {
        final first = await signIn(_a);
        await first.onSessionEnded(_a, SessionEnd.sessionLost);
        return first;
      }

      final setups =
          <String, (VaultStatus, Future<VaultSession> Function(E2eeFlag))>{
            'ready': (
              VaultStatus.ready,
              (f) async {
                await earlier();
                return signIn(_a, flag: f);
              },
            ),
            'keyLost': (
              VaultStatus.keyLost,
              (f) async {
                await earlier();
                world.loseKey(_a);
                return signIn(_a, flag: f);
              },
            ),
            'unavailable': (
              VaultStatus.unavailable,
              (f) async {
                await earlier();
                world.openFails[_a] = VaultStatus.unavailable;
                return signIn(_a, flag: f);
              },
            ),
            'storageChanged': (
              VaultStatus.storageChanged,
              (f) async {
                await earlier();
                // Listed, but under another storage than the marker names.
                world.files[_a] = FakeVaultFile(
                  'sharedIndexedDb',
                  world.keys[_a]!,
                );
                return signIn(_a, flag: f);
              },
            ),
            'heldElsewhere': (
              VaultStatus.heldElsewhere,
              (f) async {
                await earlier();
                world.heldElsewhere.add(_a);
                return signIn(_a, flag: f);
              },
            ),
          };
      var cells = 0;
      for (final setup in setups.entries) {
        for (final start in flags) {
          for (final to in flags) {
            for (final then in flags) {
              world = FakeVaultWorld();
              final s = await setup.value.$2(start);
              expect(
                s.status.value,
                setup.value.$1,
                reason: '${setup.key} signed in as $start',
              );
              final before = world.calls.length;
              await s.onFlagChanged(to, uid: _a);
              await s.onFlagChanged(then, uid: _a);
              await s.retry();
              final added = world.calls.skip(before).where(_destructive);
              expect(
                added,
                isEmpty,
                reason: '${setup.key}: $start -> $to -> $then',
              );
              cells++;
            }
          }
        }
      }
      // No vault at all: the flag answers touch nothing destructive either.
      for (final start in flags) {
        for (final to in flags) {
          for (final then in flags) {
            world = FakeVaultWorld();
            final s = await signIn(_a, flag: start);
            await s.onFlagChanged(to, uid: _a);
            await s.onFlagChanged(then, uid: _a);
            await s.retry();
            expect(world.calls.where(_destructive), isEmpty);
            cells++;
          }
        }
      }
      expect(cells, 6 * 27);
    });

    test('a marker whose open failed with create false stays blocked when '
        'the flag turns on; only retry reaches the open again', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.files.clear(); // the file is gone, the marker and key remain
      final s = await signIn(_a, flag: E2eeFlag.unknown);
      expect(s.status.value, VaultStatus.unavailable);
      world.calls.clear();
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      expect(s.status.value, VaultStatus.unavailable);
      expect(world.calls, isEmpty, reason: 'a flag answer opens nothing');
      await s.retry();
      // The retry opens with create true; the marked storage has no copy
      // (the fake world lists none), so the opener refuses before creating.
      expect(s.status.value, VaultStatus.storageChanged);
      expect(world.createFlags.last, (cipher: true, vault: true));
      expect(world.files, isEmpty, reason: 'nothing was created');
    });

    test('no vault on this device and markers that cannot be read: '
        'vaultKnown stays false and nothing is touched', () async {
      for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
        world = FakeVaultWorld();
        world.markers.failReads = true;
        final s = await signIn(_a, flag: flag);
        expect(s.vaultKnown, isFalse, reason: '$flag');
        expect(world.calls, isEmpty, reason: '$flag');
        expect(s.vault, isNull);
      }
    });

    test('a direct user switch signs in as unknown', () async {
      // One session, no session end between the users (a direct switch):
      // the wiring passes unknown, whatever the previous user's flag was.
      final s = await signIn(_a);
      expect(s.flag, E2eeFlag.on);
      world.calls.clear();
      await s.onSignedIn(_b, flag: E2eeFlag.unknown);
      expect(s.flag, E2eeFlag.unknown);
      expect(s.status.value, VaultStatus.off);
      expect(s.mayStart, isFalse);
      expect(s.vaultKnown, isFalse);
      expect(world.calls, isNot(contains('cipher:$_b')));
      expect(world.calls, isNot(contains('open:$_b')));
      await s.onFlagChanged(E2eeFlag.on, uid: _b);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault!.uid, _b);
    });

    test('retry opens a known vault with the flag unknown', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.openFails[_a] = VaultStatus.unavailable;
      final s = await signIn(_a, flag: E2eeFlag.unknown);
      expect(s.status.value, VaultStatus.unavailable);
      world.openFails.remove(_a);
      world.createFlags.clear();
      await s.retry();
      expect(s.status.value, VaultStatus.ready);
      expect(world.createFlags, [(cipher: false, vault: false)]);
    });

    test('vaultKnown is true after sign-in with a marker and false after '
        'sign-out', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      final s = world.launch();
      expect(s.vaultKnown, isFalse);
      await s.onSignedIn(_a, flag: E2eeFlag.off);
      expect(s.vaultKnown, isTrue);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      expect(s.vaultKnown, isFalse);
      await s.onSignedIn(_a, flag: E2eeFlag.off);
      expect(s.vaultKnown, isTrue);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(s.vaultKnown, isFalse);
    });

    test('vaultKnown is still true while the directory hook runs for a '
        'flag-off explicit end', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      final seen = <bool>[];
      late VaultSession s;
      s = world.launch(beforeExplicitWipe: (_) async => seen.add(s.vaultKnown));
      await s.onSignedIn(_a, flag: E2eeFlag.off);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(seen, [true]);
      expect(s.vaultKnown, isFalse);
    });

    test('two ready hooks run in order and the second runs when the first '
        'throws', () async {
      final order = <String>[];
      final reported = <Object>[];
      final s = world.launch(reported: reported);
      s.addVaultReadyHook((v) async {
        order.add('first');
        throw StateError('boom');
      });
      s.addVaultReadyHook((v) async {
        expect(identical(s.vault, v), isTrue);
        order.add('second');
      });
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      await pumpEventQueue();
      expect(order, ['first', 'second']);
      expect(reported.map((e) => e.toString()), ['VaultSessionError(ready)']);
      expect(s.status.value, VaultStatus.ready);
    });

    test('unsupported: even a known vault is never touched', () async {
      world.setKnown(_a, 'opfsLocks');
      world.setOwed(_b);
      final s = world.launch(supported: false);
      await s.start(restoredUid: null, restoreDefinitive: true);
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      await s.noteAccountDeleted(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.calls, isEmpty);
      expect(s.status.value, VaultStatus.unsupported);
    });

    test('flag turned off while open: nothing closes or wipes, the marker and '
        'data stay; back on needs no new open', () async {
      final s = await signIn(_a);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b8('v'))),
      );
      world.calls.clear();
      await s.onFlagChanged(E2eeFlag.off, uid: _a);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault, isNotNull);
      expect(world.calls, isEmpty);
      expect(world.known(_a), isNotNull);
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      expect(world.calls, isEmpty);
      expect(String.fromCharCodes((await s.vault!.setting('k'))!), 'v');
    });

    test('M2: a flag event for a user who is no longer signed in is '
        'ignored', () async {
      final s = await signIn(_a, flag: E2eeFlag.off);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_b, flag: E2eeFlag.off);
      world.calls.clear();
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      expect(world.calls, isEmpty);
      expect(s.status.value, VaultStatus.off);
      await s.onFlagChanged(E2eeFlag.on, uid: null);
      expect(world.calls, isEmpty);
      await s.onFlagChanged(E2eeFlag.on, uid: _b);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault!.uid, _b);
    });

    test('flag off + known vault + explicit sign-out: wiped', () async {
      final s = await signIn(_a);
      await s.onFlagChanged(E2eeFlag.off, uid: _a);
      world.calls.clear();
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      // The vault is still open: rows and key first, then the empty file.
      expect(
        world.calls,
        containsAllInOrder(['vault.wipe:$_a', 'key:$_a', 'wipeFile:$_a']),
      );
      expect(world.files, isEmpty);
      expect(world.keys, isEmpty);
      expect(world.markers.knownByAlias, isEmpty);
    });

    test('flag off + known vault from an earlier launch + explicit sign-out '
        'in a new launch: wiped', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      final s = await signIn(_a, flag: E2eeFlag.off);
      expect(s.status.value, VaultStatus.ready);
      await s.onSessionEnded(_a, SessionEnd.accountDeleted);
      expect(world.files, isEmpty);
      expect(world.keys, isEmpty);
    });

    test('flag off + a different user signs in: the previous user\'s vault '
        'is wiped', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.calls.clear();
      final s = await signIn(_b, flag: E2eeFlag.off);
      expect(world.calls, containsAllInOrder(['wipeFile:$_a', 'key:$_a']));
      expect(world.files.containsKey(_a), isFalse);
      expect(world.keys.containsKey(_a), isFalse);
      expect(s.status.value, VaultStatus.off);
      expect(world.calls, isNot(contains('cipher:$_b')));
    });
  });

  group('resetByUser', () {
    Future<VaultSession> inState(String state, E2eeFlag flag) async {
      switch (state) {
        case 'ready':
          final first = await signIn(_a);
          await first.onSessionEnded(_a, SessionEnd.sessionLost);
          return signIn(_a, flag: flag);
        case 'keyLost':
          final first = await signIn(_a);
          await first.onSessionEnded(_a, SessionEnd.sessionLost);
          world.loseKey(_a);
          return signIn(_a, flag: flag);
        default: // storageChanged
          final first = await signIn(_a);
          await first.onSessionEnded(_a, SessionEnd.sessionLost);
          world.files[_a] = FakeVaultFile('sharedIndexedDb', world.keys[_a]!);
          return signIn(_a, flag: flag);
      }
    }

    test('resetByUser from storageChanged, keyLost and ready wipes, and '
        're-creates only with the flag on', () async {
      for (final state in ['storageChanged', 'keyLost', 'ready']) {
        for (final flag in E2eeFlag.values) {
          world = FakeVaultWorld();
          final s = await inState(state, flag);
          final expected = switch (state) {
            'ready' => VaultStatus.ready,
            'keyLost' => VaultStatus.keyLost,
            _ => VaultStatus.storageChanged,
          };
          // Flag off with a marker opens the vault, so these three states
          // are the ones the set-up reaches for every flag except a lost
          // key with the flag on, which re-creates (keyLost pending).
          expect(s.status.value, expected, reason: '$state $flag');
          world.calls.clear();
          expect(await s.resetByUser(), isTrue, reason: '$state $flag');
          expect(world.calls, containsAllInOrder(['wipeFile:$_a', 'key:$_a']));
          expect(world.owedUids, isEmpty);
          if (flag == E2eeFlag.on) {
            expect(s.status.value, VaultStatus.ready, reason: '$state $flag');
            expect(s.vault!.createdThisOpen, isTrue);
            expect(world.createFlags.last, (cipher: true, vault: true));
          } else {
            expect(s.status.value, VaultStatus.off, reason: '$state $flag');
            expect(s.vault, isNull);
            expect(s.vaultKnown, isFalse);
            expect(world.keys, isEmpty);
            expect(world.known(_a), isNull);
            expect(world.calls, isNot(contains('cipher:$_a')));
          }
        }
      }
    });

    test('resetByUser runs the directory hook first and proceeds when it '
        'fails or times out', () {
      fakeAsync((async) {
        for (final mode in ['ok', 'throws', 'never']) {
          world = FakeVaultWorld();
          final never = Completer<void>();
          final s = world.launch(
            beforeExplicitWipe: (uid) async {
              world.calls.add('hook:$uid');
              if (mode == 'throws') throw StateError('offline');
              if (mode == 'never') await never.future;
            },
          );
          s.onSignedIn(_a, flag: E2eeFlag.off);
          async.flushMicrotasks();
          // A known vault is needed for the flag-off open.
          expect(s.status.value, VaultStatus.off);
          s.onFlagChanged(E2eeFlag.on, uid: _a);
          async.flushMicrotasks();
          expect(s.status.value, VaultStatus.ready);
          world.calls.clear();
          bool? result;
          s.resetByUser().then((r) => result = r);
          async.flushMicrotasks();
          if (mode == 'never') {
            expect(result, isNull);
            async.elapse(kVaultExplicitWipeHookTimeout);
            async.flushMicrotasks();
          }
          expect(result, isTrue, reason: mode);
          final hookAt = world.calls.indexOf('hook:$_a');
          expect(hookAt, isNonNegative, reason: mode);
          expect(world.calls.indexOf('wipeFile:$_a'), greaterThan(hookAt));
          expect(world.keys.containsKey(_a), isTrue, reason: 're-created');
        }
      });
    });

    test(
      'resetByUser without an open vault skips the directory hook',
      () async {
        final calls = <String>[];
        final first = await signIn(_a);
        await first.onSessionEnded(_a, SessionEnd.sessionLost);
        world.files[_a] = FakeVaultFile('sharedIndexedDb', world.keys[_a]!);
        final s = world.launch(
          beforeExplicitWipe: (uid) async => calls.add(uid),
        );
        await s.onSignedIn(_a, flag: E2eeFlag.off);
        expect(s.status.value, VaultStatus.storageChanged);
        expect(await s.resetByUser(), isTrue);
        expect(calls, isEmpty);
      },
    );

    test('resetByUser in status off or opening does nothing and returns '
        'false', () async {
      final s = await signIn(_a, flag: E2eeFlag.off);
      expect(s.status.value, VaultStatus.off);
      world.calls.clear();
      expect(await s.resetByUser(), isFalse);
      expect(world.calls, isEmpty);
      // Signed out.
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      expect(await s.resetByUser(), isFalse);
      expect(world.calls, isEmpty);
      // Opening: the call is queued behind the open, so it sees the result;
      // a status of opening is only visible from inside, so check the gate
      // with an unavailable vault that owes nothing.
      world.openFails[_a] = VaultStatus.unavailable;
      final u = await signIn(_a);
      expect(u.status.value, VaultStatus.unavailable);
      world.calls.clear();
      expect(await u.resetByUser(), isFalse);
      expect(world.calls, isEmpty);
    });

    test('a failed reset wipe stays owed', () async {
      final s = await signIn(_a);
      world.wipeFileFails.add(_a);
      world.calls.clear();
      expect(await s.resetByUser(), isFalse);
      expect(world.owed(_a)!.anyCopy, isTrue);
      expect(world.keys.containsKey(_a), isTrue);
      expect(s.vault, isNull, reason: 'closed for the wipe');
      expect(s.vaultKnown, isTrue, reason: 'still a device fact');
      expect(s.status.value, isNot(VaultStatus.ready));
      world.wipeFileFails.clear();
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.owedUids, isEmpty);
      expect(world.keys.containsKey(_a), isFalse);
    });
  });

  group('session end', () {
    for (final reason in [
      SessionEnd.userSignedOut,
      SessionEnd.accountDeleted,
    ]) {
      test('$reason: journal -> hook -> vault rows -> key -> the empty file '
          '-> markers -> release', () async {
        final s = world.launch(
          beforeExplicitWipe: (uid) async => world.calls.add('hook:$uid'),
        );
        await s.onSignedIn(_a, flag: E2eeFlag.on);
        world.calls.clear();
        await s.onSessionEnded(_a, reason);
        expect(world.calls, [
          'markers.owed:$_a',
          'hook:$_a',
          'vault.wipe:$_a',
          'key:$_a',
          'wipeFile:$_a',
          'markers.clear:$_a',
          'release',
        ]);
        expect(world.files.containsKey(_a), isFalse, reason: 'M7: no file');
        expect(world.keys, isEmpty);
        expect(world.markers.knownByAlias, isEmpty);
        expect(world.owedUids, isEmpty);
        expect(s.status.value, VaultStatus.off);
        expect(s.vault, isNull);
      });
    }

    test('the hook run in beforeSignOut is not run again', () async {
      var hooks = 0;
      final s = world.launch(beforeExplicitWipe: (_) async => hooks++);
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      await s.beforeExplicitSignOut(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(hooks, 1);
      expect(noHistory(_a), isTrue);
    });

    test('beforeExplicitSignOut with a hook and no facts: no hook, no '
        'marker, nothing called', () async {
      var hooks = 0;
      final s = world.launch(beforeExplicitWipe: (_) async => hooks++);
      await s.onSignedIn(_a, flag: E2eeFlag.off);
      world.calls.clear();
      await s.beforeExplicitSignOut(_a);
      expect(hooks, 0);
      expect(world.calls, isEmpty);
      expect(world.pending(_a), isFalse);
    });

    test('beforeExplicitSignOut for a uid that is not the session\'s user '
        'does nothing', () async {
      var hooks = 0;
      final s = world.launch(beforeExplicitWipe: (_) async => hooks++);
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      world.calls.clear();
      await s.beforeExplicitSignOut(_b);
      expect(hooks, 0);
      expect(world.calls, isEmpty);
    });

    test('an explicit sign-out where the only fact is a wipeOwed marker: '
        'the hook runs and the wipe completes', () async {
      final s = world.launch(
        beforeExplicitWipe: (uid) async => world.calls.add('hook:$uid'),
      );
      await s.start(restoredUid: _a, restoreDefinitive: true);
      await s.onSignedIn(_a, flag: E2eeFlag.off);
      // The key exists from an earlier vault whose wipe is owed (e.g. a
      // failed wipe after its known marker was cleared).
      world.keys[_a] = 9;
      world.setOwed(_a);
      expect(world.owedUids, {_a});
      expect(world.known(_a), isNull);
      world.calls.clear();
      await s.beforeExplicitSignOut(_a);
      await s.onSessionEnded(_a, SessionEnd.accountDeleted);
      expect(
        world.calls,
        containsAllInOrder([
          'markers.pending:$_a',
          'hook:$_a',
          'wipeFile:$_a',
          'key:$_a',
          'markers.clear:$_a',
        ]),
      );
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.owedUids, isEmpty);
      expect(world.pending(_a), isFalse);
    });

    test('M8: a failed sign-out forgets the pending end and the hook run: '
        'the next explicit end runs the hook again', () async {
      var hooks = 0;
      final s = world.launch(beforeExplicitWipe: (_) async => hooks++);
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      await s.beforeExplicitSignOut(_a);
      expect(world.pending(_a), isTrue);
      await s.explicitSignOutFailed(_a);
      expect(world.pending(_a), isFalse);
      expect(s.status.value, VaultStatus.ready);
      await s.onSessionEnded(_a, SessionEnd.accountDeleted);
      expect(hooks, 2);
      expect(noHistory(_a), isTrue);
    });

    test('M6: a failed journal write is reported and the explicit wipe '
        'still goes on', () async {
      final reported = <Object>[];
      final s = await signIn(_a, reported: reported);
      world.markers.failOwedWrites = true;
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(
        reported.map((e) => e.toString()),
        contains('VaultSessionError(journal)'),
      );
      expect(noHistory(_a), isTrue);
      expect(world.keys, isEmpty);
    });

    test('an offline hook failure still wipes', () async {
      final s = world.launch(
        beforeExplicitWipe: (_) async => throw StateError('offline'),
      );
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      await s.beforeExplicitSignOut(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(noHistory(_a), isTrue);
      expect(world.keys, isEmpty);
    });

    test('a hook that never answers is cut at the budget and the wipe goes '
        'on', () {
      fakeAsync((async) {
        final never = Completer<void>();
        final s = world.launch(beforeExplicitWipe: (_) => never.future);
        var done = false;
        s.onSignedIn(_a, flag: E2eeFlag.on);
        async.flushMicrotasks();
        expect(s.status.value, VaultStatus.ready, reason: '${world.calls}');
        s
            .onSessionEnded(_a, SessionEnd.accountDeleted)
            .then((_) => done = true);
        async.flushMicrotasks();
        expect(done, isFalse);
        async.elapse(kVaultExplicitWipeHookTimeout);
        async.flushMicrotasks();
        expect(done, isTrue, reason: '${world.calls} ${async.pendingTimers}');
        expect(noHistory(_a), isTrue);
      });
    });

    test('a failing wipe leaves "wipe owed" and the key; the next launch '
        'completes it before anything is opened', () async {
      world.vaultWipeFails.add(_a);
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.owedUids, {_a});
      expect(world.keys.containsKey(_a), isTrue);
      expect(world.files.containsKey(_a), isTrue);
      expect(world.calls, contains('vault.close:$_a'));
      world.vaultWipeFails.clear();
      world.calls.clear();
      final next = world.launch();
      unawaited(next.start(restoredUid: _b, restoreDefinitive: true));
      await next.onSignedIn(_b, flag: E2eeFlag.on);
      expect(world.calls.take(6), [
        'owner.create',
        'acquire:$_a',
        'markers.owed:$_a',
        'wipeFile:$_a',
        'markers.owed:$_a',
        'key:$_a',
      ]);
      expect(
        world.calls.indexOf('markers.clear:$_a'),
        lessThan(world.calls.indexOf('open:$_b')),
      );
      expect(world.owedUids, isEmpty);
      expect(world.keys.containsKey(_a), isFalse);
      expect(next.status.value, VaultStatus.ready);
    });

    test('a failing key delete after the rows are gone stays owed and is '
        'completed at the next launch', () async {
      world.keyDeleteFails.add(_a);
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.owedUids, {_a});
      expect(s.status.value, VaultStatus.off);
      world.keyDeleteFails.clear();
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: true);
      expect(world.owedUids, isEmpty);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.files.containsKey(_a), isFalse);
    });

    test('an owed wipe whose file is already deleted (key delete failed '
        'after it) goes on with the key', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      // Closed wipe (nothing open): the file is erased, then the key fails.
      world.keyDeleteFails.add(_a);
      await first.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.files.containsKey(_a), isFalse, reason: 'file gone');
      expect(world.owedUids, {_a});
      expect(world.owed(_a)!.fileDone, isTrue);
      expect(world.keys.containsKey(_a), isTrue);
      world.keyDeleteFails.clear();
      world.calls.clear();
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.calls, isNot(contains('wipeFile:$_a')));
      expect(world.calls, containsAllInOrder(['key:$_a', 'markers.clear:$_a']));
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.owedUids, isEmpty);
      await next.onSignedIn(_a, flag: E2eeFlag.on);
      expect(next.status.value, VaultStatus.ready);
    });

    test('retry never opens a vault whose own wipe is still owed', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.setOwed(_a);
      world.wipeFileFails.add(_a);
      world.calls.clear();
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      await s.retry();
      await s.onFlagChanged(E2eeFlag.off, uid: _a);
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      expect(world.calls, isNot(contains('open:$_a')));
      expect(world.calls, isNot(contains('cipher:$_a')));
      expect(s.status.value, VaultStatus.unavailable);
      // Once the wipe can run, retry finishes it and opens a fresh vault.
      world.wipeFileFails.clear();
      await s.retry();
      expect(s.status.value, VaultStatus.ready);
      expect(world.owedUids, isEmpty);
    });

    test('M4: the same uid signs in again with its vault OPEN and its own '
        'wipe owed (deletion accepted): the vault is closed before the '
        'wipe; a failed wipe leaves it closed and unavailable', () async {
      final s = await signIn(_a);
      await s.noteAccountDeleted(_a);
      world.wipeFileFails.add(_a);
      world.calls.clear();
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(world.calls.first, 'vault.close:$_a');
      expect(s.status.value, VaultStatus.unavailable);
      expect(s.vault, isNull);
      expect(world.keys.containsKey(_a), isTrue, reason: 'file failed first');
      // It can finish: the next attempt erases it and opens a fresh vault.
      world.wipeFileFails.clear();
      await s.retry();
      expect(world.owedUids, isEmpty);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault!.createdThisOpen, isTrue);
    });

    test('sessionLost closes and keeps everything; the same user finds the '
        'same vault', () async {
      final s = await signIn(_a);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b8('kept'))),
      );
      world.calls.clear();
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      expect(world.calls, ['vault.close:$_a', 'release']);
      expect(s.status.value, VaultStatus.off);
      // Same process and a new launch alike.
      for (final session in [s, world.launch()]) {
        await session.onSignedIn(_a, flag: E2eeFlag.on);
        expect(session.status.value, VaultStatus.ready);
        expect(
          String.fromCharCodes((await session.vault!.setting('k'))!),
          'kept',
        );
        await session.onSessionEnded(_a, SessionEnd.sessionLost);
      }
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('a different user: the previous user\'s file and key are wiped '
        'first; the new user\'s vault opens even if that wipe fails', () async {
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.calls.clear();
      await s.onSignedIn(_b, flag: E2eeFlag.on);
      expect(
        world.calls.indexOf('wipeFile:$_a'),
        lessThan(world.calls.indexOf('key:$_a')),
      );
      expect(
        world.calls.indexOf('key:$_a'),
        lessThan(world.calls.indexOf('open:$_b')),
      );
      expect(world.files.keys, [_b]);
      expect(s.status.value, VaultStatus.ready);

      // Now B is lost and C signs in while B's wipe fails.
      await s.onSessionEnded(_b, SessionEnd.sessionLost);
      world.wipeFileFails.add(_b);
      await s.onSignedIn('user-c', flag: E2eeFlag.on);
      expect(s.status.value, VaultStatus.ready);
      expect(world.owedUids, {_b});
      expect(world.keys.containsKey(_b), isTrue, reason: 'never the key first');
    });

    test('a refused temporary owner for another user\'s wipe never calls '
        'the file wipe (nor the key)', () async {
      final first = await signIn(_b);
      await first.onSessionEnded(_b, SessionEnd.sessionLost);
      world.heldElsewhere.add(_b); // B open in another tab
      world.calls.clear();
      final s = await signIn(_a);
      expect(world.calls, contains('acquire:$_b'));
      expect(world.calls, isNot(contains('wipeFile:$_b')));
      expect(world.calls, isNot(contains('key:$_b')));
      expect(world.files.containsKey(_b), isTrue);
      expect(world.owedUids, {_b});
      expect(s.status.value, VaultStatus.ready);
    });

    test('a direct switch (no session end first) closes the old vault and '
        'wipes it before the new one opens', () async {
      final s = await signIn(_a);
      await s.onSignedIn(_b, flag: E2eeFlag.on);
      expect(world.files.keys, [_b]);
      expect(s.vault!.uid, _b);
    });
  });

  group('I2: an owed wipe always finishes', () {
    test('a crash after the file delete and before "file done": the next '
        'launch completes it (the marked copy is gone)', () async {
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      // What the crash left: the file erased, the journal at "started".
      world.files.remove(_a);
      world.setOwed(_a, fileStarted: true);
      world.calls.clear();
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: true);
      expect(world.calls, containsAllInOrder(['wipeFile:$_a', 'key:$_a']));
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.owedUids, isEmpty);
      expect(world.markers.knownByAlias, isEmpty);
    });

    test('control: the same owed wipe WITHOUT "file started" is refused by '
        'the storage-marker check (keeps the key)', () async {
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.files.remove(_a);
      world.setOwed(_a);
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isTrue);
      expect(world.owed(_a)!.fileStarted, isTrue, reason: 'now started');
      // ...and so the launch after that completes it.
      await world.launch().start(restoredUid: null, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.owedUids, isEmpty);
    });

    test('a different user\'s wipe of an evicted copy completes at the next '
        'launch', () async {
      final first = await signIn(_b);
      await first.onSessionEnded(_b, SessionEnd.sessionLost);
      world.files[_b]!.hidden = true; // evicted / no longer listed
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.ready);
      expect(world.owed(_b)!.fileStarted, isTrue);
      expect(world.keys.containsKey(_b), isTrue);
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.keys.containsKey(_b), isFalse);
      expect(world.owedUids, isEmpty);
      expect(world.known(_b), isNull);
    });

    test('a failed reset stays owed (any copy) and the next launch '
        'completes it', () async {
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.files[_a]!.hidden = true;
      final changed = await signIn(_a);
      expect(changed.status.value, VaultStatus.storageChanged);
      world.wipeFileFails.add(_a);
      await changed.resetByUser();
      expect(changed.status.value, VaultStatus.storageChanged);
      expect(world.owed(_a)!.anyCopy, isTrue);
      expect(world.keys.containsKey(_a), isTrue);
      world.wipeFileFails.clear();
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.owedUids, isEmpty);
      await next.onSignedIn(_a, flag: E2eeFlag.on);
      expect(next.status.value, VaultStatus.ready);
    });

    test('the explicit reset is allowed when the user\'s own owed wipe is '
        'what blocks the session', () async {
      final s0 = await signIn(_a);
      await s0.onSessionEnded(_a, SessionEnd.sessionLost);
      world.setOwed(_a);
      world.wipeFileFails.add(_a); // the owed wipe cannot finish now
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      world.wipeFileFails.clear();
      await s.resetByUser();
      expect(s.status.value, VaultStatus.ready);
      expect(world.owedUids, isEmpty);
      expect(s.vault!.createdThisOpen, isTrue);
    });
  });

  group('N1/N2: pending ends resolve only on a definite session state', () {
    /// A launch that recorded a pending explicit end for A (with history)
    /// and was killed before the sign-out finished.
    Future<void> pendingForA() async {
      final s = await signIn(_a);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b8('history'))),
      );
      await s.beforeExplicitSignOut(_a);
      await s.close();
      expect(world.pending(_a), isTrue);
      world.calls.clear();
    }

    test('N1: a start whose restore is NOT definitive (slow web restore) '
        'leaves the pending end alone: nothing destroyed', () async {
      await pendingForA();
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: false);
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.pending(_a), isTrue);
      expect(world.owedUids, isEmpty);
      expect(world.keys.containsKey(_a), isTrue);
    });

    test('N1: ...and when A then signs in, A\'s own pending end is cleared '
        '(the sign-out did not happen): history intact', () async {
      await pendingForA();
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: false);
      await next.onSignedIn(_a, flag: E2eeFlag.on);
      expect(world.pending(_a), isFalse);
      expect(world.calls.where(_destructive), isEmpty);
      expect(next.status.value, VaultStatus.ready);
      expect(
        String.fromCharCodes((await next.vault!.setting('k'))!),
        'history',
      );
    });

    test('N1: ...and when B signs in instead, A is wiped', () async {
      await pendingForA();
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: false);
      await next.onSignedIn(_b, flag: E2eeFlag.off);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.files.containsKey(_a), isFalse);
      expect(world.pending(_a), isFalse);
      expect(world.owedUids, isEmpty);
    });

    test('N1: a definitive start with nobody restored wipes A', () async {
      await pendingForA();
      await world.launch().start(restoredUid: null, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.pending(_a), isFalse);
    });

    test('N1: two tabs: tab 2 starts (not definitive) inside tab 1\'s hook '
        'window, then tab 1\'s sign-out FAILS: A is never wiped', () async {
      final tab1 = await signIn(_a);
      await tab1.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b8('history'))),
      );
      await tab1.beforeExplicitSignOut(_a);
      final tab2 = world.launch();
      await tab2.start(restoredUid: null, restoreDefinitive: false);
      await tab1.explicitSignOutFailed(_a);
      // Tab 2's auth then restores A; later launches see A too.
      await tab2.onSignedIn(_a, flag: E2eeFlag.off);
      await world.launch().start(restoredUid: _a, restoreDefinitive: true);
      await world.launch().start(restoredUid: null, restoreDefinitive: false);
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.owedUids, isEmpty);
      expect(world.files[_a]!.rows['k'], 'history');
      expect(world.keys.containsKey(_a), isTrue);
    });

    test('N2: the owed write for a pending end fails at start: the pending '
        'marker is KEPT, and the next launch wipes', () async {
      await pendingForA();
      world.markers.failOwedWrites = true;
      await world.launch().start(restoredUid: null, restoreDefinitive: true);
      expect(world.pending(_a), isTrue, reason: 'not lost');
      expect(world.keys.containsKey(_a), isTrue);
      world.markers.failOwedWrites = false;
      await world.launch().start(restoredUid: null, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.pending(_a), isFalse);
    });

    test('N2: the same at sign-in of another user: the pending marker is '
        'kept when its owed write fails', () async {
      await pendingForA();
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: false);
      world.markers.failOwedWrites = true;
      // A's known marker would wipe A anyway (clearing every marker); make
      // that wipe fail too, so only the pending marker stands for A's end.
      world.wipeFileFails.add(_a);
      await next.onSignedIn(_b, flag: E2eeFlag.off);
      expect(world.pending(_a), isTrue);
      expect(world.keys.containsKey(_a), isTrue);
    });
  });

  group('fix round 2 minors', () {
    test('m2: the clock moved BACK before the first key-loss observation: '
        'the observation is rewritten (never blocked forever)', () async {
      final s0 = await signIn(_a);
      await s0.onSessionEnded(_a, SessionEnd.sessionLost);
      world.loseKey(_a);
      final first = await signIn(_a);
      expect(first.status.value, VaultStatus.keyLost);
      final seenAt = world.keyLost(_a)!.atMicros;
      world.nowMicros = seenAt - _hour.inMicroseconds; // clock moved back
      world.loseKey(_a);
      final second = await signIn(_a);
      expect(second.status.value, VaultStatus.keyLost);
      expect(world.keyLost(_a)!.atMicros, world.nowMicros);
      expect(world.keyLost(_a)!.launchId, 'launch-3');
      expect(world.calls.where(_destructive), isEmpty);
      // An hour after the REWRITTEN observation a later launch confirms.
      world.advance(_hour);
      world.loseKey(_a);
      final third = await signIn(_a);
      expect(third.status.value, VaultStatus.ready);
      expect(world.calls, contains('wipeFile:$_a'));
    });

    test('m3: noteAccountDeleted with no vault facts does nothing (a '
        'flag-off user causes no vault work)', () async {
      final s = world.launch();
      await s.start(restoredUid: _a, restoreDefinitive: true);
      await s.onSignedIn(_a, flag: E2eeFlag.off);
      world.calls.clear();
      await s.noteAccountDeleted(_a);
      expect(world.calls, isEmpty);
      expect(world.owedUids, isEmpty);
    });

    test(
      'm3: noteAccountDeleted with a known vault journals the wipe',
      () async {
        world.setKnown(_a, 'opfsLocks');
        await world.launch().noteAccountDeleted(_a);
        expect(world.owedUids, {_a});
      },
    );

    test('m3: noteAccountDeleted when the facts cannot be READ journals '
        '(fail towards wiping)', () async {
      world.markers.failKnownReads = true;
      await world.launch().noteAccountDeleted(_a);
      expect(world.calls, contains('markers.owed:$_a'));
    });

    test('m5: the open\'s own marker reads fail (the sign-in reads '
        'succeeded): unavailable, never opened', () async {
      for (final failKnown in [true, false]) {
        world = FakeVaultWorld();
        final s = await signIn(_a, flag: E2eeFlag.off);
        world.markers.failKnownReads = failKnown;
        world.markers.failOwedReads = !failKnown;
        world.calls.clear();
        await s.onFlagChanged(E2eeFlag.on, uid: _a);
        expect(
          s.status.value,
          VaultStatus.unavailable,
          reason: failKnown ? 'known()' : 'owedWipes()',
        );
        expect(world.calls, isNot(contains('open:$_a')));
        expect(
          world.owners.every((o) => o.owned == null),
          isTrue,
          reason: 'lock released',
        );
      }
    });

    test('m6: the lock is lost while the key loss is being confirmed: the '
        'wipe takes its own lock, which another tab holds, so nothing is '
        'destroyed', () async {
      final s0 = await signIn(_a);
      await s0.onSessionEnded(_a, SessionEnd.sessionLost);
      world.loseKey(_a);
      await signIn(_a); // first observation
      world.advance(_hour);
      world.loseKey(_a);
      world.markers.onKeyLostRead = () {
        world.markers.onKeyLostRead = null;
        world.owners.last.steal();
        world.heldElsewhere.add(_a);
      };
      world.calls.clear();
      final s = await signIn(_a);
      expect(world.calls.where(_destructive), isEmpty);
      expect(s.vault, isNull);
      expect(world.files[_a], isNotNull);
    });

    test('m7: beforeExplicitSignOut before the queue ran onSignedIn still '
        'records the pending end for the uid it is given', () async {
      world.setKnown(_a, 'opfsLocks');
      final s = world.launch();
      await s.start(restoredUid: _a, restoreDefinitive: true);
      // onSignedIn(_a) not run yet.
      await s.beforeExplicitSignOut(_a);
      expect(world.pending(_a), isTrue);
    });
  });

  group('I4: an explicit end survives the app being killed', () {
    test('killed after the pending marker (before the sign-out): the next '
        'launch with nobody restored wipes', () async {
      final s = await signIn(_a);
      await s.beforeExplicitSignOut(_a);
      expect(world.pending(_a), isTrue);
      // Killed. The next launch restores nobody.
      final next = world.launch();
      await next.start(restoredUid: null, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.files.containsKey(_a), isFalse);
      expect(world.pending(_a), isFalse);
      expect(world.owedUids, isEmpty);
    });

    test('...or with ANOTHER user restored: wiped too', () async {
      final s = await signIn(_a);
      await s.beforeExplicitSignOut(_a);
      await world.launch().start(restoredUid: _b, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
    });

    test('the same user restored (the sign-out never happened): the marker '
        'is cleared and nothing is wiped', () async {
      final s = await signIn(_a);
      await s.beforeExplicitSignOut(_a);
      world.calls.clear();
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.pending(_a), isFalse);
      expect(world.calls.where(_destructive), isEmpty);
      await next.onSignedIn(_a, flag: E2eeFlag.on);
      expect(next.status.value, VaultStatus.ready);
    });

    test('a deletion accepted by the server, then killed: the next launch '
        'wipes, even with the same user restored', () async {
      final s = await signIn(_a);
      await s.noteAccountDeleted(_a);
      expect(world.owedUids, {_a});
      expect(world.keys.containsKey(_a), isTrue, reason: 'journal only');
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.files.containsKey(_a), isFalse);
      expect(world.owedUids, isEmpty);
    });

    test('noteAccountDeleted keeps an owed record\'s progress', () async {
      world.setOwed(_a, fileStarted: true);
      await world.launch().noteAccountDeleted(_a);
      expect(world.owed(_a)!.fileStarted, isTrue);
    });
  });

  group('key loss across launches', () {
    Future<VaultSession> keyLostLaunch() async {
      final s = await signIn(_a);
      return s;
    }

    setUp(() async {
      final s = await signIn(_a);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b8('history'))),
      );
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.loseKey(_a);
      world.calls.clear();
    });

    test('first launch: keyLost, nothing wiped, marker written with the '
        'time; the same launch again still wipes nothing', () async {
      final s = await keyLostLaunch();
      expect(s.status.value, VaultStatus.keyLost);
      expect(world.keyLost(_a)!.atMicros, world.nowMicros);
      world.advance(_hour * 2);
      await s.onFlagChanged(E2eeFlag.off, uid: _a);
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      await s.retry();
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(s.status.value, VaultStatus.keyLost);
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.files[_a]!.rows['k'], 'history');
    });

    test('a DIFFERENT launch less than an hour later: still keyLost, '
        'nothing wiped, the first observation kept', () async {
      await keyLostLaunch();
      final first = world.keyLost(_a)!.atMicros;
      world.advance(_hour - const Duration(seconds: 1));
      world.loseKey(_a);
      final s = await keyLostLaunch();
      expect(s.status.value, VaultStatus.keyLost);
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.keyLost(_a)!.atMicros, first);
    });

    test('next launch an hour later, keyLost again: wipe file, THEN delete '
        'key, THEN a fresh vault', () async {
      await keyLostLaunch();
      world.advance(_hour);
      world.loseKey(_a);
      world.calls.clear();
      final s = await keyLostLaunch();
      expect(s.status.value, VaultStatus.ready);
      final wipe = world.calls.indexOf('wipeFile:$_a');
      final key = world.calls.indexOf('key:$_a');
      final clear = world.calls.indexOf('markers.clear:$_a');
      final reopen = world.calls.lastIndexOf('open:$_a');
      expect(wipe, greaterThanOrEqualTo(0));
      expect(key, greaterThan(wipe));
      expect(clear, greaterThan(key));
      expect(reopen, greaterThan(clear));
      expect(world.files[_a]!.rows, isEmpty, reason: 'a fresh vault');
      expect(world.markers.keyLostByAlias, isEmpty);
      expect(world.known(_a), isNotNull);
    });

    test('Android-style key loss (the cipher reports it) needs two launches '
        'an hour apart too', () async {
      // The stored key exists but no longer unwraps.
      world.keys[_a] = world.files[_a]!.key;
      world.cipherKeyLost.add(_a);
      final first = await keyLostLaunch();
      expect(first.status.value, VaultStatus.keyLost);
      expect(world.calls, isNot(contains('open:$_a')));
      expect(world.calls.where(_destructive), isEmpty);
      final soon = await keyLostLaunch();
      expect(soon.status.value, VaultStatus.keyLost);
      expect(world.calls.where(_destructive), isEmpty);
      // An hour later the next launch confirms it; a new key is then made.
      world.advance(_hour);
      world.calls.clear();
      final second = await keyLostLaunch();
      expect(
        world.calls.indexOf('wipeFile:$_a'),
        lessThan(world.calls.indexOf('key:$_a')),
      );
      expect(second.status.value, VaultStatus.ready);
    });

    test(
      'next launch succeeds instead: marker cleared, nothing wiped',
      () async {
        await keyLostLaunch();
        world.keys[_a] = world.files[_a]!.key; // the key came back
        final s = await keyLostLaunch();
        expect(s.status.value, VaultStatus.ready);
        expect(world.markers.keyLostByAlias, isEmpty);
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.files[_a]!.rows['k'], 'history');
      },
    );

    for (final status in [
      VaultStatus.unavailable,
      VaultStatus.storageChanged,
    ]) {
      test('next launch $status instead: marker cleared (the streak '
          'breaks), nothing wiped', () async {
        await keyLostLaunch();
        world.openFails[_a] = status;
        final s = await keyLostLaunch();
        expect(s.status.value, status);
        expect(world.markers.keyLostByAlias, isEmpty);
        world.openFails.clear();
        world.loseKey(_a);
        world.advance(_hour);
        final third = await keyLostLaunch();
        expect(third.status.value, VaultStatus.keyLost, reason: 'starts over');
        expect(world.calls.where(_destructive), isEmpty);
      });
    }

    test('a cipher that is unavailable on the next launch also breaks the '
        'streak', () async {
      await keyLostLaunch();
      world.cipherUnavailable.add(_a);
      final s = await keyLostLaunch();
      expect(s.status.value, VaultStatus.unavailable);
      expect(world.markers.keyLostByAlias, isEmpty);
    });

    // B-M3: EVERY unavailable launch breaks the streak.
    final unavailablePaths = <String, void Function()>{
      'the owed-wipe marker read fails': () =>
          world.markers.failOwedReads = true,
      'an owed wipe fails': () {
        world.setOwed(_a);
        world.wipeFileFails.add(_a);
      },
      'the lock acquire throws': () => world.acquireThrows.add(_a),
      'the known-marker read fails': () => world.markers.failKnownReads = true,
      'the keyLostSeen read fails': () => world.markers.failKeyLostReads = true,
      'the known-marker write fails': () {
        world.markers.knownByAlias.remove(vaultKeyAlias(_a));
        world.keys[_a] = world.files[_a]!.key; // the open succeeds
        world.markers.failKnownWrites = true;
      },
      'the keyLostSeen write fails (an observation from the future)': () {
        world.markers.keyLostByAlias[vaultKeyAlias(_a)] = KeyLostSeen(
          launchId: 'launch-x',
          atMicros: world.nowMicros + _hour.inMicroseconds,
        );
        world.markers.failKeyLostWrites = true;
      },
    };
    for (final e in unavailablePaths.entries) {
      test('B-M3: ${e.key} on the next launch: unavailable, and the streak '
          'is cleared', () async {
        await keyLostLaunch();
        expect(world.keyLost(_a), isNotNull);
        // A new launch whose open meets the fault (a known vault opens at
        // sign-in whatever the flag says).
        final s = world.launch();
        e.value();
        world.calls.clear();
        await s.onSignedIn(_a, flag: E2eeFlag.on);
        // A failing owed-wipe read stops the sign-in before the open; a
        // retry reaches the open.
        if (world.markers.keyLostByAlias.isNotEmpty) await s.retry();
        expect(s.status.value, VaultStatus.unavailable);
        expect(world.markers.keyLostByAlias, isEmpty);
        expect(world.files[_a]!.rows['k'], 'history');
        expect(world.calls, isNot(contains('key:$_a')));
      });
    }

    test('B-M3: the marker store fails AND the clear fails: tolerated, '
        'still unavailable, the marker failure reported once', () async {
      await keyLostLaunch();
      final reported = <Object>[];
      final s = world.launch(reported: reported);
      world.markers
        ..failKeyLostReads = true
        ..failKeyLostClears = true;
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(s.status.value, VaultStatus.unavailable);
      expect(world.calls, contains('markers.keyLostClear:$_a'));
      expect(
        reported
            .whereType<VaultSessionError>()
            .where((r) => r.step == 'markers')
            .length,
        1,
      );
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('the wipe fails on the second keyLost: key NOT deleted, wipe owed '
        '(file started), completed at the next launch before anything '
        'else', () async {
      await keyLostLaunch();
      world.advance(_hour);
      world.loseKey(_a);
      world.wipeFileFails.add(_a);
      world.calls.clear();
      final s = await keyLostLaunch();
      expect(s.status.value, VaultStatus.keyLost);
      expect(world.calls, contains('wipeFile:$_a'));
      expect(world.calls, isNot(contains('key:$_a')));
      expect(world.owedUids, {_a});
      expect(world.owed(_a)!.fileStarted, isTrue);
      world.wipeFileFails.clear();
      world.calls.clear();
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.calls, [
        'owner.create',
        'acquire:$_a',
        'wipeFile:$_a',
        'markers.owed:$_a',
        'key:$_a',
        'markers.clear:$_a',
        'release',
      ]);
      await next.onSignedIn(_a, flag: E2eeFlag.on);
      expect(next.status.value, VaultStatus.ready);
    });
  });

  group('storageChanged, unavailable, heldElsewhere', () {
    test(
      'storageChanged never wipes and never deletes the key across five '
      'launches; the explicit reset is the only caller of wipeVaultFile',
      () async {
        final s = await signIn(_a);
        await s.onSessionEnded(_a, SessionEnd.sessionLost);
        world.files[_a]!.hidden = true;
        world.calls.clear();
        VaultSession? last;
        for (var i = 0; i < 5; i++) {
          world.advance(_hour);
          last = await signIn(_a);
          expect(last.status.value, VaultStatus.storageChanged);
          await last.retry();
          await last.onFlagChanged(E2eeFlag.off, uid: _a);
          await last.onFlagChanged(E2eeFlag.on, uid: _a);
        }
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.keys.containsKey(_a), isTrue);
        expect(world.known(_a), isNotNull);
        // The person chooses the reset (it destroys the hidden history).
        world.calls.clear();
        await last!.resetByUser();
        expect(world.calls.where(_destructive), ['wipeFile:$_a', 'key:$_a']);
        expect(
          world.calls.indexOf('markers.clear:$_a'),
          greaterThan(world.calls.indexOf('key:$_a')),
        );
        expect(last.status.value, VaultStatus.ready);
      },
    );

    test('the reset does nothing in any other state', () async {
      // Held by another tab: not one of the reset's states.
      world.heldElsewhere.add(_a);
      final h = await signIn(_a);
      expect(h.status.value, VaultStatus.heldElsewhere);
      world.calls.clear();
      expect(await h.resetByUser(), isFalse);
      expect(world.calls, isEmpty);
      world.heldElsewhere.clear();
      // Nor for an unavailable vault with no owed wipe of its own.
      world.openFails[_a] = VaultStatus.unavailable;
      final u = await signIn(_a);
      expect(u.status.value, VaultStatus.unavailable);
      world.calls.clear();
      expect(await u.resetByUser(), isFalse);
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('unavailable never escalates and is not reopened automatically in '
        'the same process; retry tries once', () async {
      world.openFails[_a] = VaultStatus.unavailable;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      world.calls.clear();
      await s.onFlagChanged(E2eeFlag.off, uid: _a);
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_a, flag: E2eeFlag.on);
      expect(world.calls, isNot(contains('open:$_a')));
      expect(s.status.value, VaultStatus.unavailable);
      world.openFails.clear();
      await s.retry();
      expect(s.status.value, VaultStatus.ready);
      expect(world.calls.where(_destructive), isEmpty);
    });

    test(
      'a cipher opened for a failed open is closed, never destroyed',
      () async {
        final ready = await signIn(_a);
        expect(world.ciphers.single.closed, isFalse);
        await ready.onSessionEnded(_a, SessionEnd.sessionLost);
        world.ciphers.clear();
        world.calls.clear();

        for (final status in [
          VaultStatus.unavailable,
          VaultStatus.storageChanged,
          // The vault open says the key does not open it: the first launch
          // that sees this only records it (no hour has passed), so the
          // cipher ends closed, with the stored key still there.
          VaultStatus.keyLost,
        ]) {
          world.openFails[_a] = status;
          final before = world.ciphers.length;
          final s = await signIn(_a);
          expect(s.status.value, status);
          expect(world.ciphers.length, before + 1, reason: status.name);
          final cipher = world.ciphers.last;
          expect(cipher.closed, isTrue, reason: status.name);
          expect(cipher.closeCalls, 1, reason: status.name);
          expect(cipher.destroyed, isFalse, reason: status.name);
          expect(world.keys.containsKey(_a), isTrue, reason: status.name);
        }
        expect(world.calls.where(_destructive), isEmpty);
        world.openFails.clear();

        // Key lost, seen once: nothing is wiped and the cipher is still closed.
        world.cipherKeyLost.add(_a);
        final lost = await signIn(_a);
        expect(lost.status.value, VaultStatus.keyLost);
        world.cipherKeyLost.clear();
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.keys.containsKey(_a), isTrue);
        for (final c in world.ciphers) {
          expect(c.destroyed, isFalse);
        }
      },
    );

    test('a vault that is published keeps its cipher open until it closes, '
        'then the cipher is closed once', () async {
      final s = await signIn(_a);
      final cipher = world.ciphers.single;
      expect(s.status.value, VaultStatus.ready);
      expect(cipher.closed, isFalse);
      // A session lost without an explicit end closes the vault, and with it
      // the cipher exactly once; the stored key stays.
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      expect(cipher.closed, isTrue);
      expect(cipher.closeCalls, 1);
      expect(cipher.destroyed, isFalse);
      expect(world.keys.containsKey(_a), isTrue);
    });

    test('the cipher is closed exactly once, never destroyed, when the lock '
        'is lost while the storage marker is written', () async {
      world.markers.onWriteKnown = () async {
        world.markers.onWriteKnown = null;
        world.owners.single.steal();
      };
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.heldElsewhere);
      expect(s.vault, isNull);
      final cipher = world.ciphers.single;
      expect(cipher.closeCalls, 1);
      expect(cipher.closed, isTrue);
      expect(cipher.destroyed, isFalse);
      expect(world.keys.containsKey(_a), isTrue);
    });

    test('the cipher is closed exactly once, never destroyed, when the '
        'marker write fails', () async {
      world.markers.failKnownWrites = true;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      expect(s.vault, isNull);
      final cipher = world.ciphers.single;
      expect(cipher.closeCalls, 1);
      expect(cipher.closed, isTrue);
      expect(cipher.destroyed, isFalse);
      expect(world.keys.containsKey(_a), isTrue);
    });

    test('owner refused: heldElsewhere, the cipher is never opened', () async {
      world.heldElsewhere.add(_a);
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.heldElsewhere);
      expect(world.calls, ['owner.create', 'acquire:$_a']);
    });

    test('lost: writes stop at once, the vault is closed, no further write '
        'is accepted, never reopened in a loop', () async {
      final s = await signIn(_a);
      world.owners.single.steal();
      await pumpEventQueue();
      expect(s.status.value, VaultStatus.heldElsewhere);
      expect(s.vault, isNull);
      expect(world.calls, contains('vault.close:$_a'));
      await expectLater(s.runWrite((v) async => 1), throwsA(isA<StateError>()));
      world.calls.clear();
      await s.onFlagChanged(E2eeFlag.off, uid: _a);
      await s.onFlagChanged(E2eeFlag.on, uid: _a);
      expect(world.calls, isNot(contains('acquire:$_a')));
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('an explicit end after the lock was lost takes the closed path '
        '(its own lock): another tab holding it means nothing is '
        'destroyed now, the wipe is owed', () async {
      final s = await signIn(_a);
      world.owners.single.steal();
      await pumpEventQueue();
      world.heldElsewhere.add(_a);
      world.calls.clear();
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.calls, isNot(contains('vault.wipe:$_a')));
      expect(world.calls, isNot(contains('wipeFile:$_a')));
      expect(world.owedUids, {_a});
    });

    test(
      'a write in flight when the lock is lost finishes before close',
      () async {
        final s = await signIn(_a);
        final gate = Completer<void>();
        final write = s.runWrite((v) async {
          await gate.future;
          world.calls.add('write-done');
        });
        await pumpEventQueue();
        world.owners.single.steal();
        await pumpEventQueue();
        expect(world.calls, isNot(contains('vault.close:$_a')));
        gate.complete();
        await write;
        await pumpEventQueue();
        expect(
          world.calls.indexOf('write-done'),
          lessThan(world.calls.indexOf('vault.close:$_a')),
        );
      },
    );

    test('unexpected failures never throw into the UI and are reported '
        'without details', () async {
      final reported = <Object>[];
      world.markers.failWrites = true;
      final s = await signIn(_a, reported: reported);
      expect(s.status.value, VaultStatus.unavailable);
      expect(reported, isNotEmpty);
      for (final e in reported) {
        expect(e, isA<VaultSessionError>());
        expect(e.toString(), isNot(contains(_a)));
        expect(e.toString(), isNot(contains('markers down')));
      }
    });
  });

  group('status audit: no automatic wipe from any failure status', () {
    for (final status in [
      VaultStatus.unavailable,
      VaultStatus.storageChanged,
      VaultStatus.heldElsewhere,
      VaultStatus.keyLost,
    ]) {
      test('$status for one launch, then every non-explicit action: nothing '
          'destroyed', () async {
        final s0 = await signIn(_a);
        await s0.onSessionEnded(_a, SessionEnd.sessionLost);
        switch (status) {
          case VaultStatus.heldElsewhere:
            world.heldElsewhere.add(_a);
          case VaultStatus.keyLost:
            world.loseKey(_a);
          default:
            world.openFails[_a] = status;
        }
        world.calls.clear();
        final s = await signIn(_a);
        expect(s.status.value, status);
        await s.retry();
        await s.onFlagChanged(E2eeFlag.off, uid: _a);
        await s.onFlagChanged(E2eeFlag.on, uid: _a);
        await s.onSessionEnded(_a, SessionEnd.sessionLost);
        await s.onSignedIn(_a, flag: E2eeFlag.on);
        await s.close();
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.files.containsKey(_a), isTrue);
      });
    }
  });
}
