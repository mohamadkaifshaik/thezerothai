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
    bool flag = true,
    VaultSession? session,
    List<Object>? reported,
  }) async {
    final s = session ?? world.launch(reported: reported);
    await s.onSignedIn(uid, e2eeEnabled: flag);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await next.onFlagChanged(false, uid: _a);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
    test('flag off / unsupported, nothing known: no collaborator is ever '
        'called', () async {
      for (final supported in [true, false]) {
        world = FakeVaultWorld();
        final s = world.launch(
          supported: supported,
          beforeExplicitWipe: (uid) async => world.calls.add('hook:$uid'),
        );
        await s.start(restoredUid: _a, restoreDefinitive: true);
        await s.onSignedIn(_a, e2eeEnabled: !supported);
        await s.onFlagChanged(!supported, uid: _a);
        await s.retry();
        await s.beforeExplicitSignOut(_a);
        await s.onSessionEnded(_a, SessionEnd.userSignedOut);
        await s.onSignedIn(_b, e2eeEnabled: !supported);
        await s.onSessionEnded(_b, SessionEnd.accountDeleted);
        await s.resetVaultForStorageChange();
        expect(world.calls, isEmpty, reason: 'supported: $supported');
        expect(
          s.status.value,
          supported ? VaultStatus.off : VaultStatus.unsupported,
        );
      }
    });

    test('unsupported: even a known vault is never touched', () async {
      world.setKnown(_a, 'opfsLocks');
      world.setOwed(_b);
      final s = world.launch(supported: false);
      await s.start(restoredUid: null, restoreDefinitive: true);
      await s.onSignedIn(_a, e2eeEnabled: true);
      await s.noteAccountDeleted(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.calls, isEmpty);
      expect(s.status.value, VaultStatus.unsupported);
    });

    test('flag turned off while open: closed, NOT wiped, marker kept; back '
        'on re-opens the same vault', () async {
      final s = await signIn(_a);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b8('v'))),
      );
      await s.onFlagChanged(false, uid: _a);
      expect(s.status.value, VaultStatus.off);
      expect(s.vault, isNull);
      expect(world.calls, containsAllInOrder(['vault.close:$_a', 'release']));
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.known(_a), isNotNull);
      await s.onFlagChanged(true, uid: _a);
      expect(s.status.value, VaultStatus.ready);
      expect(String.fromCharCodes((await s.vault!.setting('k'))!), 'v');
    });

    test('M2: a flag event for a user who is no longer signed in is '
        'ignored', () async {
      final s = await signIn(_a, flag: false);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_b, e2eeEnabled: false);
      world.calls.clear();
      await s.onFlagChanged(true, uid: _a);
      expect(world.calls, isEmpty);
      expect(s.status.value, VaultStatus.off);
      await s.onFlagChanged(true, uid: null);
      expect(world.calls, isEmpty);
      await s.onFlagChanged(true, uid: _b);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault!.uid, _b);
    });

    test('flag off + known vault + explicit sign-out: wiped', () async {
      final s = await signIn(_a);
      await s.onFlagChanged(false, uid: _a);
      world.calls.clear();
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.calls, containsAllInOrder(['wipeFile:$_a', 'key:$_a']));
      expect(world.files, isEmpty);
      expect(world.keys, isEmpty);
      expect(world.markers.knownByAlias, isEmpty);
    });

    test('flag off + known vault from an earlier launch + explicit sign-out '
        'in a new launch: wiped', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      final s = await signIn(_a, flag: false);
      expect(s.status.value, VaultStatus.off);
      await s.onSessionEnded(_a, SessionEnd.accountDeleted);
      expect(world.files, isEmpty);
      expect(world.keys, isEmpty);
    });

    test('flag off + a different user signs in: the previous user\'s vault '
        'is wiped', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.calls.clear();
      final s = await signIn(_b, flag: false);
      expect(world.calls, containsAllInOrder(['wipeFile:$_a', 'key:$_a']));
      expect(world.files.containsKey(_a), isFalse);
      expect(world.keys.containsKey(_a), isFalse);
      expect(s.status.value, VaultStatus.off);
      expect(world.calls, isNot(contains('cipher:$_b')));
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
        await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
      await s.beforeExplicitSignOut(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(hooks, 1);
      expect(noHistory(_a), isTrue);
    });

    test('beforeExplicitSignOut with a hook and no facts: no hook, no '
        'marker, nothing called', () async {
      var hooks = 0;
      final s = world.launch(beforeExplicitWipe: (_) async => hooks++);
      await s.onSignedIn(_a, e2eeEnabled: false);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onSignedIn(_a, e2eeEnabled: false);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
        s.onSignedIn(_a, e2eeEnabled: true);
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
      await next.onSignedIn(_b, e2eeEnabled: true);
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
      // Closed wipe (flag off): the file is erased, then the key fails.
      world.keyDeleteFails.add(_a);
      final s = await signIn(_a, flag: false);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
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
      await next.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onFlagChanged(false, uid: _a);
      await s.onFlagChanged(true, uid: _a);
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
      await s.onSignedIn(_a, e2eeEnabled: true);
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
        await session.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onSignedIn(_b, e2eeEnabled: true);
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
      await s.onSignedIn('user-c', e2eeEnabled: true);
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
      await s.onSignedIn(_b, e2eeEnabled: true);
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
      await changed.resetVaultForStorageChange();
      expect(changed.status.value, VaultStatus.storageChanged);
      expect(world.owed(_a)!.anyCopy, isTrue);
      expect(world.keys.containsKey(_a), isTrue);
      world.wipeFileFails.clear();
      final next = world.launch();
      await next.start(restoredUid: _a, restoreDefinitive: true);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.owedUids, isEmpty);
      await next.onSignedIn(_a, e2eeEnabled: true);
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
      await s.resetVaultForStorageChange();
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
      await next.onSignedIn(_a, e2eeEnabled: true);
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
      await next.onSignedIn(_b, e2eeEnabled: false);
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
      await tab2.onSignedIn(_a, e2eeEnabled: false);
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
      await next.onSignedIn(_b, e2eeEnabled: false);
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
      await s.onSignedIn(_a, e2eeEnabled: false);
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
        final s = await signIn(_a, flag: false);
        world.markers.failKnownReads = failKnown;
        world.markers.failOwedReads = !failKnown;
        world.calls.clear();
        await s.onFlagChanged(true, uid: _a);
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
      await next.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onFlagChanged(false, uid: _a);
      await s.onFlagChanged(true, uid: _a);
      await s.retry();
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_a, e2eeEnabled: true);
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
        final s = await signIn(_a, flag: false);
        e.value();
        world.calls.clear();
        await s.onFlagChanged(true, uid: _a);
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
      await s.onSignedIn(_a, e2eeEnabled: false);
      world.markers
        ..failKeyLostReads = true
        ..failKeyLostClears = true;
      await s.onFlagChanged(true, uid: _a);
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
      await next.onSignedIn(_a, e2eeEnabled: true);
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
          await last.onFlagChanged(false, uid: _a);
          await last.onFlagChanged(true, uid: _a);
        }
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.keys.containsKey(_a), isTrue);
        expect(world.known(_a), isNotNull);
        // The person chooses the reset (it destroys the hidden history).
        world.calls.clear();
        await last!.resetVaultForStorageChange();
        expect(world.calls.where(_destructive), ['wipeFile:$_a', 'key:$_a']);
        expect(
          world.calls.indexOf('markers.clear:$_a'),
          greaterThan(world.calls.indexOf('key:$_a')),
        );
        expect(last.status.value, VaultStatus.ready);
      },
    );

    test('the reset does nothing in any other state', () async {
      final s = await signIn(_a);
      world.calls.clear();
      await s.resetVaultForStorageChange();
      expect(world.calls, isEmpty);
      expect(s.status.value, VaultStatus.ready);
      // Nor for an unavailable vault with no owed wipe of its own.
      world.openFails[_a] = VaultStatus.unavailable;
      final u = await signIn(_a);
      expect(u.status.value, VaultStatus.unavailable);
      world.calls.clear();
      await u.resetVaultForStorageChange();
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('unavailable never escalates and is not reopened automatically in '
        'the same process; retry tries once', () async {
      world.openFails[_a] = VaultStatus.unavailable;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      world.calls.clear();
      await s.onFlagChanged(false, uid: _a);
      await s.onFlagChanged(true, uid: _a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onFlagChanged(false, uid: _a);
      await s.onFlagChanged(true, uid: _a);
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
        await s.onFlagChanged(false, uid: _a);
        await s.onFlagChanged(true, uid: _a);
        await s.onSessionEnded(_a, SessionEnd.sessionLost);
        await s.onSignedIn(_a, e2eeEnabled: true);
        await s.close();
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.files.containsKey(_a), isTrue);
      });
    }
  });
}
