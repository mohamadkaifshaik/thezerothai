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
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockTimeline extends Mock implements TimelineRepository {}

/// W6-19: unsent posts across the REAL sign-out path (ADR-0029 F7): the auth
/// stream goes through `wireAuthSession`, which ends the session epoch, wipes
/// the cache and claims it for the next uid, against a real drift database
/// and a real `DraftsRepository`. Plain `test()`: drift does not complete in
/// the fake-async zone of `testWidgets`.
void main() {
  late AppDatabase db;
  late DraftsRepository drafts;
  late StreamController<AuthState> auth;
  late StreamSubscription<AuthState> subscription;
  late List<String> errors;

  AppUser user(String uid) =>
      AppUser(uid: uid, emailVerified: true, isPasswordProvider: true);
  AuthState signedIn(String uid) =>
      AuthState(status: AuthStatus.authenticated, user: user(uid));
  const signedOut = AuthState(status: AuthStatus.unauthenticated);

  final base = DateTime.now().toUtc();

  ComposerDraft draft(String id, String uid, String text, {DraftPoll? poll}) =>
      ComposerDraft(
        id: id,
        uid: uid,
        text: text,
        poll: poll,
        createdAt: base,
        updatedAt: base,
      );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  Future<List<String>> ids(String uid) async => [
    for (final d in await drafts.watch(uid).first) d.id,
  ];

  Future<void> seedProfile(String uid) => db.upsertProfile(
    ProfileCacheEntriesCompanion.insert(
      userId: uid,
      handle: 'h$uid',
      displayName: 'N',
      cachedAt: DateTime.now(),
    ),
    epoch: db.sessionEpoch.value,
  );

  void wire({AppUser? initial}) {
    final onboarding = _MockOnboarding();
    when(() => onboarding.add(any())).thenReturn(null);
    subscription = wireAuthSession(
      authStates: auth.stream,
      onboardingBloc: onboarding,
      database: db,
      timelineRepository: _MockTimeline(),
      onSignedOut: () {},
      initialUser: initial,
      onUnexpectedError: (e, s) => errors.add('$e'),
    );
  }

  setUpAll(() => registerFallbackValue(const OnboardingUserSignedOut()));

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = DraftsRepository(
      db,
      autosaveDelay: const Duration(milliseconds: 20),
    );
    auth = StreamController<AuthState>();
    errors = [];
  });

  tearDown(() async {
    drafts.cancelPending();
    await subscription.cancel();
    await auth.close();
    await db.close();
  });

  test('A signs out, B signs in on the same device: B sees none of A, '
      'A gets the draft back', () async {
    await db.claimCacheFor('a');
    wire(initial: user('a'));
    await seedProfile('a');
    await drafts.upsert(
      draft(
        'da',
        'a',
        'A private thought',
        poll: DraftPoll(
          choices: const ['x', 'y'],
          durationMinutes: 1440,
        ),
      ),
    );

    auth.add(signedOut);
    await settle();
    // The cache is wiped, the unsent post is not.
    expect(await db.profileByUserId('a'), isNull);
    expect(await ids('a'), ['da']);

    auth.add(signedIn('b'));
    await settle();
    expect(await ids('b'), isEmpty, reason: 'B must not see A\'s draft');
    expect(await drafts.read('b', 'da'), isNull, reason: 'not by id either');

    // B writes; B deleting "da" removes nothing of A's.
    await drafts.upsert(draft('db', 'b', 'B words'));
    await drafts.delete('b', ['da']);
    expect(await ids('a'), ['da']);
    await drafts.deleteAll('b');
    expect(await ids('b'), isEmpty);
    expect(await ids('a'), ['da'], reason: 'deleting B never touches A');

    auth.add(signedOut);
    await settle();
    auth.add(signedIn('a'));
    await settle();
    final back = await drafts.read('a', 'da');
    expect(back?.text, 'A private thought');
    expect(back?.poll?.choices, ['x', 'y']);
    expect(errors, isEmpty);
  });

  test(
    'A straight to B (no signed-out state between): same isolation',
    () async {
      await db.claimCacheFor('a');
      wire(initial: user('a'));
      await drafts.upsert(draft('da', 'a', 'A text'));

      auth.add(signedIn('b'));
      await settle();

      expect(await ids('b'), isEmpty);
      expect(await ids('a'), ['da']);
      expect(errors, isEmpty);
    },
  );

  test('a sign-out that never ran (process died): the claim at the next '
      'start wipes the cache and keeps every uid\'s drafts', () async {
    await db.claimCacheFor('a');
    await seedProfile('a');
    await drafts.upsert(draft('da', 'a', 'A text'));
    // The app starts with B signed in and A's stamp still on the cache.
    wire(initial: user('b'));
    await db.claimCacheFor('b');

    expect(await db.profileByUserId('a'), isNull);
    expect(await ids('a'), ['da']);
    expect(await ids('b'), isEmpty);
  });

  test('an autosave pending at sign-out never lands, not under A and not '
      'under B', () async {
    await db.claimCacheFor('a');
    wire(initial: user('a'));
    drafts.autosave(draft('da', 'a', 'typed just before sign-out'));
    auth.add(signedIn('b'));
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(await ids('a'), isEmpty);
    expect(await ids('b'), isEmpty);
  });

  test('account deletion: deleteAll cancels the pending autosave of the '
      'deleted uid so nothing is resurrected', () async {
    await db.claimCacheFor('b');
    wire(initial: user('b'));
    await drafts.upsert(draft('d1', 'b', 'old'));
    drafts.autosave(draft('d2', 'b', 'typing while the account is deleted'));
    await drafts.deleteAll('b');
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(await ids('b'), isEmpty);
  });

  test('deleting an account leaves other uids\' rows on the device', () async {
    await db.claimCacheFor('b');
    wire(initial: user('b'));
    await drafts.upsert(draft('da', 'a', 'A text'));
    await drafts.upsert(draft('db', 'b', 'B text'));

    await drafts.deleteAll('b');

    expect(await ids('b'), isEmpty);
    expect(await ids('a'), ['da']);
  });
}
