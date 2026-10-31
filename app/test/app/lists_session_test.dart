import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_transport.dart';
import '../support/posts_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockTimeline extends Mock implements TimelineRepository {}

common.HomeTab _wire(String id, [String title = '']) => common.HomeTab(
  kind: common.HomeTabKind.HOME_TAB_KIND_LIST,
  id: id,
  title: title,
);

/// W5-16: Lists state on a shared device. The REAL `wireAuthSession`, a real
/// in-memory drift database, the real `TimelineStore` (list feeds are stored
/// under `FeedKey.list`), the real `HomeTabsRepository` (session epoch) and
/// the real `ListsRepository` (in-memory headers, no epoch). Plain `test()`:
/// drift does not complete in the fake-async zone of `testWidgets`.
void main() {
  late AppDatabase db;
  late TimelineStore store;
  late StreamController<AuthState> auth;
  StreamSubscription<AuthState>? subscription;
  late HomeTabsRepository tabs;
  late List<String> errors;

  AppUser user(String uid) =>
      AppUser(uid: uid, emailVerified: true, isPasswordProvider: true);
  AuthState signedIn(String uid) =>
      AuthState(status: AuthStatus.authenticated, user: user(uid));
  const signedOut = AuthState(status: AuthStatus.unauthenticated);

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  Future<void> wire(String initial) async {
    await db.claimCacheFor(initial);
    final onboarding = _MockOnboarding();
    when(() => onboarding.add(any())).thenReturn(null);
    subscription = wireAuthSession(
      authStates: auth.stream,
      onboardingBloc: onboarding,
      database: db,
      timelineRepository: _MockTimeline(),
      // As bootstrap.dart: only the graph cache is cleared here.
      onSignedOut: () {},
      initialUser: user(initial),
      onUnexpectedError: (e, s) => errors.add('$e'),
    );
  }

  ServiceFeatureGate on() =>
      ServiceFeatureGate(isEnabled: () => true, onUnexpectedError: (_, _) {});

  setUpAll(() => registerFallbackValue(const OnboardingUserSignedOut()));

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = TimelineStore(db);
    auth = StreamController<AuthState>.broadcast();
    errors = [];
    tabs = HomeTabsRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((_, _) async => tl.SetHomeTabsResponse()),
      ),
      gate: on(),
      epoch: db.sessionEpoch,
    );
  });

  tearDown(() async {
    await subscription?.cancel();
    await auth.close();
    await db.close();
  });

  Future<void> seedListFeed(String listId, List<int> ids) async {
    await store.applyColdOpen(
      FeedKey.list(listId),
      posts: [for (final n in ids) postView(n, text: 'secret $n')],
      sinceToken: 's',
      nextPageToken: '',
      session: db.sessionEpoch.value,
    );
  }

  Future<int> rows(String listId) async =>
      (await store.read(FeedKey.list(listId))).entries.length;

  group('drift: cached list timelines', () {
    test(
      'A signs out, B signs in: B has no rows of A\'s private list',
      () async {
        await wire('a');
        await seedListFeed('77', [3, 2, 1]);
        expect(await rows('77'), 3);

        auth.add(signedOut);
        await settle();
        expect(await rows('77'), 0, reason: 'wiped at sign-out');

        auth.add(signedIn('b'));
        await settle();
        expect(await rows('77'), 0);
        expect(errors, isEmpty);
      },
    );

    test(
      'direct A to B (no sign-out between): the rows are gone too',
      () async {
        await wire('a');
        await seedListFeed('77', [3, 2, 1]);
        await seedListFeed('88', [9]);

        auth.add(signedIn('b'));
        await settle();
        expect(await rows('77'), 0);
        expect(await rows('88'), 0);
      },
    );

    test(
      'a list-feed write that started for A is dropped after the switch',
      () async {
        await wire('a');
        final startedFor = db.sessionEpoch.value;
        auth.add(signedIn('b'));
        await settle();
        await store.applyColdOpen(
          FeedKey.list('77'),
          posts: [postView(1, text: 'late')],
          sinceToken: 's',
          nextPageToken: '',
          session: startedFor,
        );
        expect(
          await rows('77'),
          0,
          reason: 'a late page of A never lands in B',
        );
      },
    );
  });

  group('pinned Home tabs (SessionEpoch)', () {
    test('A\'s pins and A\'s title overrides are not B\'s after a direct '
        'switch', () async {
      await wire('a');
      tabs.adoptFromMe([
        _wire('L1', 'Server title'),
      ], epoch: db.sessionEpoch.value);
      tabs.noteListInfo(pb.ListInfo(listId: 'L1', name: 'A private name'));
      expect(tabs.tabs, hasLength(1));
      expect(tabs.labelFor(tabs.tabs.first), 'A private name');

      auth.add(signedIn('b'));
      await settle();
      expect(tabs.tabs, isEmpty);
      expect(tabs.isPinned(HomeTabKind.list, 'L1'), isFalse);
      expect(tabs.isFull, isFalse);

      // B pins the same list id (a public list both follow): the label is
      // the server's, not A's override.
      tabs.adoptFromMe([_wire('L1', 'B title')], epoch: db.sessionEpoch.value);
      expect(tabs.labelFor(tabs.tabs.first), 'B title');
    });

    test(
      'a GetMe that started for A is ignored once B has the session',
      () async {
        await wire('a');
        final startedFor = db.sessionEpoch.value;
        auth.add(signedIn('b'));
        await settle();
        tabs.adoptFromMe([_wire('L1', 'A')], epoch: startedFor);
        expect(tabs.tabs, isEmpty);
      },
    );
  });

  group('ListsRepository headers (in memory, no epoch)', () {
    late Completer<pb.GetListResponse> answer;
    late ListsRepository lists;

    setUp(() {
      answer = Completer<pb.GetListResponse>();
      lists = ListsRepository(
        apiClient: ApiClient.withTransport(
          FakeTransport((procedure, _) async => answer.future),
        ),
        gate: on(),
        onListSeen: tabs.noteListInfo,
      );
    });

    test('clearSession forgets every header (plain sign-out)', () async {
      lists.noteListInfo(pb.ListInfo(listId: '77', name: 'A private list'));
      expect(lists.header('77'), isNotNull);
      lists.clearSession();
      expect(lists.header('77'), isNull);
    });

    test(
      'a GetList answer that arrives AFTER sign-out is not kept for the '
      'next account',
      () async {
        await wire('a');
        final pending = lists.getList('77');
        auth.add(signedOut);
        await settle();
        lists.clearSession(); // what AppWidget does on `unauthenticated`
        answer.complete(
          pb.GetListResponse(
            list: pb.ListInfo(listId: '77', name: 'A private list'),
          ),
        );
        await pending;
        expect(
          lists.header('77'),
          isNull,
          reason: "B must not be handed the name of A's private list",
        );
      },
      skip:
          'W5-16 D2: ListsRepository has no SessionEpoch, so a response that '
          'was in flight at sign-out repopulates _headers '
          '(lists_repository.dart:244 _seen -> :87 noteListInfo) after '
          'clearSession (:95). Remove the skip when fixed.',
    );
  });
}
