import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/post_history_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/post_history_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/opened_posts_tab.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:drift/native.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/theme_harness.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _uid = 'u1';

pb.PostView _view(String id, {bool withheld = false}) => pb.PostView(
  post: pb.Post(postId: id),
  withheld: withheld,
);

void main() {
  late AppDatabase db;
  late PostHistoryRepository history;
  late _MockPostsRepository posts;
  late _MockOnboardingBloc onboarding;

  setUp(() {
    onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
    db = AppDatabase.forTesting(NativeDatabase.memory());
    history = PostHistoryRepository(db);
    posts = _MockPostsRepository();
  });

  tearDown(() async => db.close());

  PostHistoryCubit cubit() =>
      PostHistoryCubit(history: history, posts: posts, uid: _uid);

  group('PostHistoryCubit', () {
    test('lists the stored posts newest first, keeping that order', () async {
      await history.recordOpen(uid: _uid, postId: 'a');
      await history.recordOpen(uid: _uid, postId: 'b');
      when(() => posts.getPost('b')).thenAnswer((_) async => _view('b'));
      when(() => posts.getPost('a')).thenAnswer((_) async => _view('a'));

      final c = cubit();
      await c.load();
      expect(c.state.status, PostHistoryStatus.ready);
      expect(c.state.items.map((v) => v.post.postId), ['b', 'a']);
      await c.close();
    });

    test(
      'a gone post drops out and is removed from the stored history',
      () async {
        await history.recordOpen(uid: _uid, postId: 'gone');
        await history.recordOpen(uid: _uid, postId: 'kept');
        when(() => posts.getPost('gone'))
            .thenThrow(const NotFoundException('gone'));
        when(() => posts.getPost('kept'))
            .thenAnswer((_) async => _view('kept'));

        final c = cubit();
        await c.load();
        expect(c.state.items.map((v) => v.post.postId), ['kept']);
        expect(await history.recentPostIds(_uid), ['kept']);
        await c.close();
      },
    );

    test(
      'a withheld post drops out and is removed from the stored history',
      () async {
        await history.recordOpen(uid: _uid, postId: 'hidden');
        when(() => posts.getPost('hidden'))
            .thenAnswer((_) async => _view('hidden', withheld: true));

        final c = cubit();
        await c.load();
        expect(c.state.items, isEmpty);
        expect(c.state.status, PostHistoryStatus.ready);
        expect(await history.recentPostIds(_uid), isEmpty);
        await c.close();
      },
    );

    test(
      'another failure fails the load, and keeps the stored history',
      () async {
        await history.recordOpen(uid: _uid, postId: 'a');
        when(() => posts.getPost('a'))
            .thenThrow(const NetworkException('offline'));

        final c = cubit();
        await c.load();
        expect(c.state.status, PostHistoryStatus.error);
        expect(c.state.error, isA<NetworkException>());
        expect(await history.recentPostIds(_uid), ['a']);
        await c.close();
      },
    );

    test('clear empties the list and the stored history', () async {
      await history.recordOpen(uid: _uid, postId: 'a');
      when(() => posts.getPost('a')).thenAnswer((_) async => _view('a'));
      final c = cubit();
      await c.load();
      await c.clear();
      expect(c.state.items, isEmpty);
      expect(c.state.status, PostHistoryStatus.ready);
      expect(await history.recentPostIds(_uid), isEmpty);
      await c.close();
    });
  });

  group('OpenedPostsTab empty state', () {
    for (final width in kRedesignWidths) {
      for (final scale in kRedesignTextScales) {
        for (final dark in [false, true]) {
          testWidgets(
            'shows the empty copy at ${width.toInt()} dp, text x$scale, '
            '${dark ? 'dark' : 'light'}, with no overflow',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, kRedesignHeights[width]!);
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);

              await tester.pumpWidget(
                MaterialApp(
                  theme: dark ? appDarkTheme : appLightTheme,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: MultiRepositoryProvider(
                    providers: [
                      RepositoryProvider<PostHistoryRepository>.value(
                        value: history,
                      ),
                      RepositoryProvider<PostsRepository>.value(value: posts),
                      BlocProvider<OnboardingBloc>.value(value: onboarding),
                    ],
                    child: const Scaffold(body: OpenedPostsTab(uid: _uid)),
                  ),
                ),
              );
              await tester.pumpAndSettle();

              expect(
                MediaQuery.sizeOf(tester.element(find.byType(Scaffold))).width,
                width,
              );
              expect(find.text(kOpenedPostsEmptyTitle), findsOneWidget);
              expect(find.text(kOpenedPostsEmptyBody), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  });
}
