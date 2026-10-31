import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockLists extends Mock implements ListsRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

pb.ListInfo _header({
  String ownerId = 'owner',
  bool isPrivate = false,
  int members = 3,
  String description = 'People I like to read',
}) => pb.ListInfo(
  listId: '77',
  name: 'Friends',
  description: description,
  isPrivate: isPrivate,
  memberCount: members,
  owner: common.AuthorSnapshot(
    userId: ownerId,
    handle: 'olivia',
    displayName: 'Olivia',
  ),
);

/// W5-12: `/lists/:id` at 360 / 600 / 1200 dp, light and dark, text scale
/// 1.0 / 1.3 / 2.0.
void main() {
  final feed = FeedKey.list('77');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockLists lists;
  late _MockTabs tabs;
  late _MockOnboarding onboarding;
  late StreamController<pb.ListInfo> headers;
  var pinned = false;
  var full = false;

  setUpAll(() {
    registerFallbackValue(HomeTabKind.list);
  });

  setUp(() {
    pinned = false;
    full = false;
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    lists = _MockLists();
    tabs = _MockTabs();
    onboarding = _MockOnboarding();
    headers = StreamController<pb.ListInfo>.broadcast(sync: true);
    addTearDown(headers.close);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => lists.header('77')).thenReturn(_header());
    when(() => lists.headerChanges).thenAnswer((_) => headers.stream);
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenAnswer((_) => pinned);
    when(() => tabs.isFull).thenAnswer((_) => full);
    when(() => tabs.writeUnavailable).thenReturn(false);
    when(() => tabs.pin(any(), any(), title: any(named: 'title')))
        .thenAnswer((_) async {
          pinned = true;
        });
    when(() => tabs.unpin(any(), any())).thenAnswer((_) async {
      pinned = false;
    });
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'viewer', handle: 'me'),
        enabledFeatures: const {'lists', 'posts'},
      ),
    );
  });

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
    tester,
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TimelineRepository>.value(value: timeline),
        RepositoryProvider<PostsRepository>.value(value: posts),
        RepositoryProvider<ListsRepository>.value(value: lists),
        RepositoryProvider<HomeTabsRepository>.value(value: tabs),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: const ListDetailScreen(listId: '77'),
      ),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  forEachThemeAndWidth(
    'header: name, description, owner, members, Pin; no Edit for a '
    'non-owner; empty timeline',
    (tester, env) async {
      final semantics = tester.ensureSemantics();
      await open(tester, env: env);

      expectNoOverflow(tester);
      expect(find.text('Friends'), findsWidgets);
      expect(find.text('People I like to read'), findsOneWidget);
      expect(find.text('Olivia'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.text('Pin to Home'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('No posts yet'), findsOneWidget);
      expect(find.bySemanticsLabel('List by Olivia, @olivia'), findsOneWidget);
      semantics.dispose();
    },
    textScales: kMatrixTextScalesLarge,
  );

  forEachThemeAndWidth(
    'owner sees Edit; a private List shows the lock',
    (tester, env) async {
      when(() => lists.header('77'))
          .thenReturn(_header(ownerId: 'viewer', isPrivate: true));
      await open(tester, env: env);

      expectNoOverflow(tester);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    },
    widths: const [360, 1200],
    textScales: kMatrixTextScalesLarge,
  );

  testWidgets('opening refreshes once and makes no GetList when the header '
      'is known', (tester) async {
    await open(tester);

    verify(() => timeline.refresh(feed)).called(1);
    verifyNever(() => lists.getList(any()));
  });

  testWidgets('no header yet: one GetList brings it', (tester) async {
    when(() => lists.header('77')).thenReturn(null);
    when(() => lists.getList('77')).thenAnswer((_) async => _header());

    await open(tester);
    await tester.pumpAndSettle();

    verify(() => lists.getList('77')).called(1);
    expect(find.text('3 members'), findsOneWidget);
  });

  testWidgets('no header and GetList fails: a Retry, never silent', (
    tester,
  ) async {
    when(() => lists.header('77')).thenReturn(null);
    when(() => lists.getList('77')).thenThrow(const NetworkException('off'));

    await open(tester);

    expect(find.textContaining('Retry'), findsOneWidget);
  });

  testWidgets('Pin saves one SetHomeTabs and the button becomes Unpin', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('Pin to Home'));
    await tester.pumpAndSettle();

    verify(() => tabs.pin(HomeTabKind.list, '77', title: 'Friends')).called(1);
    expect(find.text('Unpin from Home'), findsOneWidget);
  });

  testWidgets('5 pinned: Pin is disabled with the hint', (tester) async {
    full = true;
    await open(tester);

    expect(find.textContaining('pin up to 5'), findsOneWidget);
    await tester.tap(find.text('Pin to Home'), warnIfMissed: false);
    await tester.pumpAndSettle();
    verifyNever(() => tabs.pin(any(), any(), title: any(named: 'title')));
  });

  testWidgets('a failed pin shows the reason', (tester) async {
    when(() => tabs.pin(any(), any(), title: any(named: 'title')))
        .thenThrow(const LimitReachedException('x', quota: 'home_tabs'));
    await open(tester);

    await tester.tap(find.text('Pin to Home'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('pin up to 5'), findsOneWidget);
  });

  forEachThemeAndWidth(
    'NOT_FOUND: "This List is unavailable", Unpin when pinned',
    (tester, env) async {
      pinned = true;
      when(() => timeline.refresh(feed))
          .thenThrow(const NotFoundException('gone'));
      final semantics = tester.ensureSemantics();
      await open(tester, env: env);

      expectNoOverflow(tester);
      expect(find.text('This List is unavailable'), findsOneWidget);
      expect(find.text('Unpin from Home'), findsOneWidget);
      expect(find.text('Pin to Home'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      semantics.dispose();
    },
    textScales: kMatrixTextScalesLarge,
  );

  testWidgets('NOT_FOUND and not pinned: no Unpin', (tester) async {
    when(() => timeline.refresh(feed))
        .thenThrow(const NotFoundException('gone'));
    await open(tester);

    expect(find.text('This List is unavailable'), findsOneWidget);
    expect(find.text('Unpin from Home'), findsNothing);
  });

  testWidgets('GetListTimeline not deployed yet: header stays, calm message '
      'in the feed area', (tester) async {
    when(() => timeline.refresh(feed)).thenThrow(
      const FeatureDisabledException(
        "Lists aren't available yet.",
        feature: 'lists',
      ),
    );
    await open(tester);

    expect(find.text('3 members'), findsOneWidget);
    expect(find.text("This timeline isn't available yet"), findsOneWidget);
    expect(find.text('This List is unavailable'), findsNothing);
  });
}
