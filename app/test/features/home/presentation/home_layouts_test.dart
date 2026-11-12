import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:dzeroth/features/home/presentation/widgets/home_composer_entry.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/context_pane_rig.dart';
import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/timeline_fixtures.dart';

const _screenshots = bool.fromEnvironment('FEED_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/feed/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockLists extends Mock implements ListsRepository {}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

void main() {
  const feed = FeedKey.home();
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late PendingPostsCubit pending;
  late PushCubit push;
  late PushOptInCubit optIn;
  late _MockTabs tabs;

  setUpAll(() async {
    registerFallbackValue(const HomeTabEntry(kind: HomeTabKind.list, id: 'L1'));
    if (_screenshots) await loadAppFonts();
  });

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    pending = PendingPostsCubit();
    final notifications = _MockNotifications();
    when(() => notifications.enabled).thenReturn(true);
    push = PushCubit(
      messaging: FakePushMessaging(supported: false),
      repository: notifications,
    );
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    tabs = _MockTabs();
    const pinned = [
      HomeTabEntry(kind: HomeTabKind.list, id: 'L1', title: 'Nearby'),
      HomeTabEntry(kind: HomeTabKind.list, id: 'L2', title: 'Coffee club'),
    ];
    when(() => tabs.tabs).thenReturn(pinned);
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.saving).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.needsLabel(any())).thenReturn(false);
    when(() => tabs.labelFor(any()))
        .thenAnswer((i) => (i.positionalArguments.first as HomeTabEntry).title);
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    final list = TimelineSnapshot(
      entries: [
        postEntry(
          4,
          text:
              'Anyone up for a sunrise walk at Cubbon Park tomorrow? Slow '
              'pace, good chats.',
        ),
        postEntry(3, text: 'Found the quietest cafe in Indiranagar.'),
        postEntry(2, text: 'Badminton doubles tonight. Need one more player.'),
        postEntry(1, text: 'New to Bengaluru. Where is a quiet Sunday brunch?'),
      ],
      sinceToken: 's',
      olderPageToken: '',
    );
    when(() => timeline.cached(feed)).thenAnswer((_) async => list);
    when(() => timeline.refresh(feed)).thenAnswer((_) async => list);
  });

  tearDown(() async {
    await pending.close();
    await optIn.close();
    await push.close();
  });

  Future<ContextPaneRig> open(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      width: size.width,
      height: size.height,
      brightness: brightness,
      textScale: textScale,
      flags: {...kContextPaneFlags, 'lists'},
      page: (path) => path == '/home'
          ? const HomeScreen()
          : Scaffold(
              appBar: const AppTopBar(title: 'Page'),
              body: Text('$path body'),
            ),
      wrap: (app) => MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
          RepositoryProvider<ListsRepository>.value(value: _MockLists()),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<PendingPostsCubit>.value(value: pending),
            BlocProvider<PushCubit>.value(value: push),
            BlocProvider<PushOptInCubit>.value(value: optIn),
          ],
          child: app,
        ),
      ),
    );
    return rig;
  }

  Finder inHome(Finder f) =>
      find.descendant(of: find.byType(HomeScreen), matching: f);

  group('the three looks', () {
    testWidgets('phone: the DZEROTH wordmark, no Post button', (tester) async {
      await open(tester, _sizes['phone']!);
      expect(find.text('DZEROTH'), findsOneWidget);
      expect(inHome(find.text('Home')), findsNothing);
      expect(inHome(find.byType(AppPillButton)), findsNothing);
      expect(find.text(HomeComposerEntry.promptLabel), findsOneWidget);
    });

    testWidgets('tablet: a Home title, the Post button, the inline card', (
      tester,
    ) async {
      await open(tester, _sizes['tablet']!);
      expect(inHome(find.text('Home')), findsOneWidget);
      expect(find.text('DZEROTH'), findsNothing);
      expect(
        inHome(find.widgetWithText(AppPillButton, 'Post')),
        findsOneWidget,
      );
      expect(find.byType(WhoToFollowCard), findsOneWidget);
    });

    testWidgets('desktop: the side column carries Who to follow', (
      tester,
    ) async {
      await open(tester, _sizes['desktop']!);
      expect(inHome(find.text('Home')), findsOneWidget);
      expect(
        inHome(find.widgetWithText(AppPillButton, 'Post')),
        findsOneWidget,
      );
      expect(inHome(find.byType(WhoToFollowCard)), findsNothing);
      expect(find.text('You might like'), findsOneWidget);
    });

    testWidgets('phone at text scale 2.0: nothing overflows', (tester) async {
      await open(tester, _sizes['phone']!, textScale: 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('$name ${brightness.name}', (tester) async {
          await open(tester, size, brightness: brightness);
          await _capture(tester, '$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
