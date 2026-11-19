import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/vault/vault_markers.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_vault_world.dart';

const _a = 'user-a';
const _b = 'user-b';

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
        'the marker names the storage', () async {
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
      expect(world.calls, [
        'owner.create',
        'acquire:$_a',
        'cipher:$_a',
        'open:$_a',
        'markers.known:$_a',
        'ready:$_a',
      ]);
      final known = world.markers.knownByUid[_a]!;
      expect(known.storage, 'opfsLocks');
      expect(known.uid, _a);
    });

    test('marker absent + existing vault (first run of this build): opens '
        'and writes the marker', () async {
      world.files[_a] = FakeVaultFile('sharedIndexedDb', 1);
      world.keys[_a] = 1;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.ready);
      expect(world.markers.knownByUid[_a]!.storage, 'sharedIndexedDb');
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

    test('UNRULED CASE, behaviour pinned: marker present and the marked, '
        'listed database is empty (no sentinel, no rows), so the open '
        'creates a vault in it: the marker is rewritten and the vault is '
        'ready (nothing else exists to protect)', () async {
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      world.files[_a]!.stamped = false; // emptied outside the app
      world.calls.clear();
      await s.onSignedIn(_a, e2eeEnabled: true);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault!.createdThisOpen, isTrue);
      expect(world.calls, contains('markers.known:$_a'));
      expect(world.calls.where(_destructive), isEmpty);
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
      expect(world.markers.knownByUid[_a], isNotNull);
      expect(world.calls.where(_destructive), isEmpty);
    });

    test('markers that cannot persist (in-memory cache): unavailable, the '
        'vault is not opened and no collaborator is called', () async {
      world.markers.persistent = false;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      expect(world.calls, isEmpty);
    });

    test('the marker key prefixes are pinned (persistence of the real '
        'markers: vault_markers_test.dart)', () {
      expect(kVaultKnownPrefix, 'vault.known.');
      expect(kVaultKeyLostSeenPrefix, 'vault.keyLostSeen.');
      expect(kVaultWipeOwedPrefix, 'vault.wipeOwed.');
    });
  });

  group('flag and platform', () {
    test('flag off / unsupported, nothing known: no collaborator is ever '
        'called', () async {
      for (final supported in [true, false]) {
        world = FakeVaultWorld();
        final s = world.launch(supported: supported);
        await s.start();
        await s.onSignedIn(_a, e2eeEnabled: !supported);
        await s.onFlagChanged(!supported);
        await s.retry();
        await s.beforeExplicitSignOut();
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
      world.markers.knownByUid[_a] = const KnownVault(
        uid: _a,
        storage: 'opfsLocks',
        createdAtMicros: 1,
      );
      world.markers.owed.add(_b);
      final s = world.launch(supported: false);
      await s.start();
      await s.onSignedIn(_a, e2eeEnabled: true);
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
      await s.onFlagChanged(false);
      expect(s.status.value, VaultStatus.off);
      expect(s.vault, isNull);
      expect(world.calls, containsAllInOrder(['vault.close:$_a', 'release']));
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.markers.knownByUid[_a], isNotNull);
      await s.onFlagChanged(true);
      expect(s.status.value, VaultStatus.ready);
      expect(String.fromCharCodes((await s.vault!.setting('k'))!), 'v');
    });

    test('flag off + known vault + explicit sign-out: wiped', () async {
      final s = await signIn(_a);
      await s.onFlagChanged(false);
      world.calls.clear();
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.calls, containsAllInOrder(['wipeFile:$_a', 'key:$_a']));
      expect(world.files, isEmpty);
      expect(world.keys, isEmpty);
      expect(world.markers.knownByUid, isEmpty);
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
      test(
        '$reason: hook -> vault rows -> key -> markers -> release',
        () async {
          final s = world.launch(
            beforeExplicitWipe: (uid) async => world.calls.add('hook:$uid'),
          );
          await s.onSignedIn(_a, e2eeEnabled: true);
          world.calls.clear();
          await s.onSessionEnded(_a, reason);
          expect(world.calls, [
            'hook:$_a',
            'markers.owed:$_a',
            'vault.wipe:$_a',
            'key:$_a',
            'markers.clear:$_a',
            'release',
          ]);
          expect(noHistory(_a), isTrue);
          expect(world.keys, isEmpty);
          expect(world.markers.knownByUid, isEmpty);
          expect(world.markers.owed, isEmpty);
          expect(s.status.value, VaultStatus.off);
          expect(s.vault, isNull);
        },
      );
    }

    test('the hook run in beforeSignOut is not run again', () async {
      var hooks = 0;
      final s = world.launch(beforeExplicitWipe: (_) async => hooks++);
      await s.onSignedIn(_a, e2eeEnabled: true);
      await s.beforeExplicitSignOut();
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(hooks, 1);
      expect(noHistory(_a), isTrue);
    });

    test('an offline hook failure still wipes', () async {
      final s = world.launch(
        beforeExplicitWipe: (_) async => throw StateError('offline'),
      );
      await s.onSignedIn(_a, e2eeEnabled: true);
      await s.beforeExplicitSignOut();
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
      expect(world.markers.owed, {_a});
      expect(world.keys.containsKey(_a), isTrue);
      expect(world.files.containsKey(_a), isTrue);
      expect(world.calls, contains('vault.close:$_a'));
      world.vaultWipeFails.clear();
      world.calls.clear();
      final next = world.launch();
      unawaited(next.start());
      await next.onSignedIn(_b, e2eeEnabled: true);
      expect(world.calls.take(5), [
        'owner.create',
        'acquire:$_a',
        'wipeFile:$_a',
        'markers.owedFileDone:$_a',
        'key:$_a',
      ]);
      expect(
        world.calls.indexOf('markers.clear:$_a'),
        lessThan(world.calls.indexOf('open:$_b')),
      );
      expect(world.markers.owed, isEmpty);
      expect(world.keys.containsKey(_a), isFalse);
      expect(next.status.value, VaultStatus.ready);
    });

    test('a failing key delete after the rows are gone stays owed and is '
        'completed at the next launch', () async {
      world.keyDeleteFails.add(_a);
      final s = await signIn(_a);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.markers.owed, {_a});
      expect(s.status.value, VaultStatus.off);
      world.keyDeleteFails.clear();
      final next = world.launch();
      await next.start();
      expect(world.markers.owed, isEmpty);
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.files.containsKey(_a), isFalse);
    });

    test('an owed wipe whose file is already deleted (key delete failed '
        'after it) goes on with the key: the storage-marker check cannot '
        'block it for good', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      // Closed wipe (flag off): the file is erased, then the key fails.
      world.keyDeleteFails.add(_a);
      final s = await signIn(_a, flag: false);
      await s.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(world.files.containsKey(_a), isFalse, reason: 'file gone');
      expect(world.markers.owed, {_a});
      expect(world.markers.fileDone, {_a});
      expect(world.keys.containsKey(_a), isTrue);
      world.keyDeleteFails.clear();
      world.calls.clear();
      final next = world.launch();
      await next.start();
      expect(world.calls, isNot(contains('wipeFile:$_a')));
      expect(world.calls, containsAllInOrder(['key:$_a', 'markers.clear:$_a']));
      expect(world.keys.containsKey(_a), isFalse);
      expect(world.markers.owed, isEmpty);
      await next.onSignedIn(_a, e2eeEnabled: true);
      expect(next.status.value, VaultStatus.ready);
    });

    test('retry never opens a vault whose own wipe is still owed', () async {
      final first = await signIn(_a);
      await first.onSessionEnded(_a, SessionEnd.sessionLost);
      world.markers.owed.add(_a);
      world.wipeFileFails.add(_a);
      world.calls.clear();
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      await s.retry();
      await s.onFlagChanged(false);
      await s.onFlagChanged(true);
      expect(world.calls, isNot(contains('open:$_a')));
      expect(world.calls, isNot(contains('cipher:$_a')));
      expect(s.status.value, VaultStatus.unavailable);
      // Once the wipe can run, retry finishes it and opens a fresh vault.
      world.wipeFileFails.clear();
      await s.retry();
      expect(s.status.value, VaultStatus.ready);
      expect(world.markers.owed, isEmpty);
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
      expect(world.markers.owed, {_b});
      expect(world.keys.containsKey(_b), isTrue, reason: 'never the key first');
    });

    test('a direct switch (no session end first) closes the old vault and '
        'wipes it before the new one opens', () async {
      final s = await signIn(_a);
      await s.onSignedIn(_b, e2eeEnabled: true);
      expect(world.files.keys, [_b]);
      expect(s.vault!.uid, _b);
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

    test('first launch: keyLost, nothing wiped, marker written; the same '
        'launch again still wipes nothing', () async {
      final s = await keyLostLaunch();
      expect(s.status.value, VaultStatus.keyLost);
      expect(world.markers.keyLostByUid[_a], isNotNull);
      await s.onFlagChanged(false);
      await s.onFlagChanged(true);
      await s.retry();
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_a, e2eeEnabled: true);
      expect(s.status.value, VaultStatus.keyLost);
      expect(world.calls.where(_destructive), isEmpty);
      expect(world.files[_a]!.rows['k'], 'history');
    });

    test('next launch keyLost again: wipe file, THEN delete key, THEN a '
        'fresh vault', () async {
      await keyLostLaunch();
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
      expect(world.markers.keyLostByUid, isEmpty);
      expect(world.markers.knownByUid[_a], isNotNull);
    });

    test('Android-style key loss (the cipher reports it) needs two launches '
        'too', () async {
      // The stored key exists but no longer unwraps.
      world.keys[_a] = world.files[_a]!.key;
      world.cipherKeyLost.add(_a);
      final first = await keyLostLaunch();
      expect(first.status.value, VaultStatus.keyLost);
      expect(world.calls, isNot(contains('open:$_a')));
      expect(world.calls.where(_destructive), isEmpty);
      // The second launch confirms it; after the wipe a new key is made.
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
        expect(world.markers.keyLostByUid, isEmpty);
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
        expect(world.markers.keyLostByUid, isEmpty);
        world.openFails.clear();
        world.loseKey(_a);
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
      expect(world.markers.keyLostByUid, isEmpty);
    });

    test('the wipe fails on the second keyLost: key NOT deleted, wipe owed, '
        'completed at the next launch before anything else', () async {
      await keyLostLaunch();
      world.loseKey(_a);
      world.wipeFileFails.add(_a);
      world.calls.clear();
      final s = await keyLostLaunch();
      expect(s.status.value, VaultStatus.keyLost);
      expect(world.calls, contains('wipeFile:$_a'));
      expect(world.calls, isNot(contains('key:$_a')));
      expect(world.markers.owed, {_a});
      world.wipeFileFails.clear();
      world.calls.clear();
      final next = world.launch();
      await next.start();
      expect(world.calls, [
        'owner.create',
        'acquire:$_a',
        'wipeFile:$_a',
        'markers.owedFileDone:$_a',
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
          last = await signIn(_a);
          expect(last.status.value, VaultStatus.storageChanged);
          await last.retry();
          await last.onFlagChanged(false);
          await last.onFlagChanged(true);
        }
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.keys.containsKey(_a), isTrue);
        expect(world.markers.knownByUid[_a], isNotNull);
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
    });

    test('unavailable never escalates and is not reopened automatically in '
        'the same process; retry tries once', () async {
      world.openFails[_a] = VaultStatus.unavailable;
      final s = await signIn(_a);
      expect(s.status.value, VaultStatus.unavailable);
      world.calls.clear();
      await s.onFlagChanged(false);
      await s.onFlagChanged(true);
      await s.onSessionEnded(_a, SessionEnd.sessionLost);
      await s.onSignedIn(_a, e2eeEnabled: true);
      expect(world.calls, isNot(contains('open:$_a')));
      expect(s.status.value, VaultStatus.unavailable);
      world.openFails.clear();
      await s.retry();
      expect(s.status.value, VaultStatus.ready);
      expect(world.calls.where(_destructive), isEmpty);
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
      await s.onFlagChanged(false);
      await s.onFlagChanged(true);
      expect(world.calls, isNot(contains('acquire:$_a')));
      expect(world.calls.where(_destructive), isEmpty);
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
        await s.onFlagChanged(false);
        await s.onFlagChanged(true);
        await s.onSessionEnded(_a, SessionEnd.sessionLost);
        await s.onSignedIn(_a, e2eeEnabled: true);
        await s.close();
        expect(world.calls.where(_destructive), isEmpty);
        expect(world.files.containsKey(_a), isTrue);
      });
    }
  });
}
