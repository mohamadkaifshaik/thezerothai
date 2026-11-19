import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_vault_world.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockTimeline extends Mock implements TimelineRepository {}

/// L-4: the auth-to-session bridge `bootstrap` installs. The review's
/// scenarios: the process died mid sign-out, and the auth stream going from A
/// straight to B. In both, B must never read A's cache.
void main() {
  late AppDatabase database;
  late _MockOnboarding onboarding;
  late StreamController<AuthState> auth;
  late List<String> log;
  late int signedOutCalls;
  late StreamSubscription<AuthState> subscription;

  AppUser user(String uid) =>
      AppUser(uid: uid, emailVerified: true, isPasswordProvider: true);
  AuthState signedIn(String uid) =>
      AuthState(status: AuthStatus.authenticated, user: user(uid));
  const signedOut = AuthState(status: AuthStatus.unauthenticated);

  Future<void> seedProfile(String uid) => database.upsertProfile(
    ProfileCacheEntriesCompanion.insert(
      userId: uid,
      handle: 'h$uid',
      displayName: 'N',
      cachedAt: DateTime.now(),
    ),
    epoch: database.sessionEpoch.value,
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  void wire({AppUser? initialUser}) {
    subscription = wireAuthSession(
      authStates: auth.stream,
      onboardingBloc: onboarding,
      database: database,
      timelineRepository: _MockTimeline(),
      onSignedOut: () => signedOutCalls++,
      initialUser: initialUser,
      onUnexpectedError: (e, s) => log.add('error:$e'),
    );
  }

  setUpAll(() => registerFallbackValue(const OnboardingUserSignedOut()));

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    onboarding = _MockOnboarding();
    auth = StreamController<AuthState>();
    log = [];
    signedOutCalls = 0;
    // The cache as user A left it.
    when(() => onboarding.add(any())).thenAnswer((invocation) async {
      final event = invocation.positionalArguments.single as OnboardingEvent;
      if (event is OnboardingUserAuthenticated) {
        // What a cache read would see at the moment B is handed the session.
        final stamp = await database.readSetting(kCacheOwnerKey);
        final a = await database.profileByUserId('a');
        log.add('authenticated:${event.user.uid} stamp=$stamp a=${a != null}');
      } else {
        log.add(event.runtimeType.toString());
      }
    });
  });

  tearDown(() async {
    await subscription.cancel();
    await auth.close();
    await database.close();
  });

  test('A straight to B: signed out, A\'s cache gone and B stamped before B '
      'is authenticated', () async {
    await database.claimCacheFor('a');
    await seedProfile('a');
    wire(initialUser: user('a'));
    await settle();
    log.clear();

    auth.add(signedIn('b'));
    await settle();

    expect(log, ['OnboardingUserSignedOut', 'authenticated:b stamp=b a=false']);
    expect(signedOutCalls, 1);
    expect(await database.profileByUserId('a'), isNull);
  });

  test('sign-out then a quick sign-in as another user runs in order', () async {
    await database.claimCacheFor('a');
    await seedProfile('a');
    wire(initialUser: user('a'));
    await settle();
    log.clear();

    auth
      ..add(signedOut)
      ..add(signedIn('b'));
    await settle();

    expect(log, ['OnboardingUserSignedOut', 'authenticated:b stamp=b a=false']);
  });

  test('a stale cache of another owner is wiped when the first user arrives '
      '(the process died mid sign-out)', () async {
    await database.claimCacheFor('a');
    await seedProfile('a');
    wire();

    auth.add(signedIn('b'));
    await settle();

    expect(log, ['authenticated:b stamp=b a=false']);
  });

  test(
    'the same user again (profile reload) neither wipes nor re-dispatches',
    () async {
      await database.claimCacheFor('a');
      await seedProfile('a');
      wire(initialUser: user('a'));
      await settle();
      log.clear();

      auth.add(signedIn('a'));
      await settle();

      expect(log, isEmpty);
      expect(await database.profileByUserId('a'), isNotNull);
    },
  );

  test(
    'an unverified user claims the cache but is not authenticated yet',
    () async {
      wire();

      auth.add(
        AuthState(status: AuthStatus.needsEmailVerification, user: user('b')),
      );
      await settle();

      expect(log, isEmpty);
      expect(await database.readSetting(kCacheOwnerKey), 'b');
    },
  );

  test('verifying the email (same uid, needsEmailVerification to '
      'authenticated) authenticates exactly once', () async {
    wire();
    final unverified = AuthState(
      status: AuthStatus.needsEmailVerification,
      user: AppUser(uid: 'b', emailVerified: false, isPasswordProvider: true),
    );

    auth
      ..add(unverified)
      // The resend / check buttons re-emit the same status.
      ..add(unverified.copyWith(isSubmitting: true))
      ..add(unverified);
    await settle();
    expect(log, isEmpty);

    auth
      ..add(signedIn('b'))
      // A later re-emit (isSubmitting, a failure, a reload) is not a new
      // sign-in.
      ..add(signedIn('b').copyWith(isSubmitting: true))
      ..add(signedIn('b'));
    await settle();

    expect(log, ['authenticated:b stamp=b a=false']);
    expect(signedOutCalls, 0);
  });

  group('the encrypted vault follows the session end reason', () {
    late FakeVaultWorld world;
    late VaultSession vault;

    void wireVault({AppUser? initialUser, bool flag = true}) {
      subscription = wireAuthSession(
        authStates: auth.stream,
        onboardingBloc: onboarding,
        database: database,
        timelineRepository: _MockTimeline(),
        onSignedOut: () => signedOutCalls++,
        initialUser: initialUser,
        onUnexpectedError: (e, s) => log.add('error:$e'),
        vaultSession: vault,
        readE2eeFlag: () => flag,
      );
    }

    setUp(() {
      world = FakeVaultWorld();
      vault = world.launch();
    });

    AuthState ended(SessionEnd reason) =>
        AuthState(status: AuthStatus.unauthenticated, lastSessionEnd: reason);

    for (final reason in SessionEnd.values) {
      final wipes = reason != SessionEnd.sessionLost;
      test('$reason: the cache is wiped as always; the vault is '
          '${wipes ? 'wiped with its key' : 'kept'}', () async {
        await database.claimCacheFor('a');
        await seedProfile('a');
        wireVault();
        auth.add(signedIn('a'));
        await settle();
        expect(vault.status.value, VaultStatus.ready);
        log.clear();

        auth.add(ended(reason));
        await settle();

        expect(log, ['OnboardingUserSignedOut']);
        expect(signedOutCalls, 1);
        expect(await database.profileByUserId('a'), isNull);
        expect(vault.status.value, VaultStatus.off);
        // Wiped: the rows are gone (the empty database may stay).
        expect(world.files['a']?.empty ?? true, wipes);
        expect(world.keys.containsKey('a'), !wipes);
      });
    }

    test('a state without a reason (older emitter) is a lost session: '
        'nothing wiped', () async {
      wireVault();
      auth.add(signedIn('a'));
      await settle();
      auth.add(signedOut);
      await settle();
      expect(world.files.containsKey('a'), isTrue);
    });

    test('a direct switch A to B is never explicit, even when the state '
        'still carries an earlier explicit reason; B\'s sign-in wipes A\'s '
        'vault as a different user', () async {
      wireVault();
      auth.add(
        signedIn('a').copyWith(lastSessionEnd: SessionEnd.userSignedOut),
      );
      await settle();
      world.calls.clear();
      auth.add(
        signedIn('b').copyWith(lastSessionEnd: SessionEnd.userSignedOut),
      );
      await settle();
      expect(world.calls, isNot(contains('vault.wipe:a')));
      expect(world.calls, containsAllInOrder(['vault.close:a', 'wipeFile:a']));
      expect(world.files.containsKey('a'), isFalse);
      // M1: B's flags are not known yet; B opens when they are.
      expect(vault.status.value, VaultStatus.off);
      await vault.onFlagChanged(true, uid: 'b');
      expect(world.files.keys, ['b']);
      expect(vault.status.value, VaultStatus.ready);
    });

    test(
      'M1: a direct switch A to B with a STALE flag (A\'s e2ee_dm still '
      'reads on) does not open B\'s vault; B\'s own flag answer does',
      () async {
        wireVault(); // readE2eeFlag answers true throughout (A's flags)
        auth.add(signedIn('a'));
        await settle();
        expect(vault.vault!.uid, 'a');
        world.calls.clear();
        auth.add(signedIn('b'));
        await settle();
        expect(world.calls, isNot(contains('open:b')));
        expect(world.calls, isNot(contains('cipher:b')));
        expect(vault.status.value, VaultStatus.off);
        // B's GetMe says off: still nothing for B.
        await vault.onFlagChanged(false, uid: 'b');
        expect(world.calls, isNot(contains('open:b')));
        await vault.onFlagChanged(true, uid: 'b');
        expect(vault.vault!.uid, 'b');
      },
    );

    test('a first sign-in (no previous user) still reads the flag', () async {
      wireVault();
      auth.add(signedIn('b'));
      await settle();
      expect(vault.status.value, VaultStatus.ready);
    });

    test('flag off at sign-in: the vault stays off', () async {
      wireVault(flag: false);
      auth.add(signedIn('a'));
      await settle();
      expect(vault.status.value, VaultStatus.off);
      expect(world.calls, isEmpty);
    });

    test('the initial user signs in to the vault too', () async {
      await database.claimCacheFor('a');
      wireVault(initialUser: user('a'));
      await settle();
      expect(vault.status.value, VaultStatus.ready);
    });
  });

  test('an initial authenticated user re-emitted as authenticated is not '
      'dispatched again', () async {
    await database.claimCacheFor('a');
    wire(initialUser: user('a'));
    await settle();
    expect(log, ['authenticated:a stamp=a a=false']);
    log.clear();

    auth
      ..add(signedIn('a').copyWith(isSubmitting: true))
      ..add(signedIn('a'));
    await settle();

    expect(log, isEmpty);
  });
}
