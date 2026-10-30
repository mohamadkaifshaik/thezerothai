import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockTimeline extends Mock implements TimelineRepository {}

/// W7-35 (L-4): the auth-to-session bridge `bootstrap` installs. The review's
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
}
