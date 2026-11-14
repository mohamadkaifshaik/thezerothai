import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/domain/impression_tracker.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../support/posts_fixtures.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

class _MockBookmarks extends Mock implements BookmarksRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

final _now = DateTime.utc(2026, 5, 1, 12);

pb.PostView _post({int? views, bool repost = false}) {
  final post = pb.Post(
    postId: postId(7),
    text: 'plain post',
    author: common.AuthorSnapshot(userId: 'u-a', handle: 'alice'),
    createdAt: Timestamp.fromDateTime(_now.subtract(const Duration(hours: 1))),
  );
  if (repost) {
    post
      ..kind = PostKind.POST_KIND_REPOST
      ..embedded = pb.EmbeddedPost(
        postId: postId(1),
        text: 'orig',
        author: common.AuthorSnapshot(userId: 'u-o', handle: 'orig'),
      );
  }
  if (views != null) post.viewCount = Int64(views);
  return pb.PostView(post: post);
}

void main() {
  late _MockGraph graph;
  late _MockPosts posts;
  late EngagementCubit engagement;
  late BookmarksCubit bookmarks;

  Widget wrap(
    Widget child, {
    required Set<String> flags,
    double width = 400,
    double textScale = 1,
    ImpressionTracker? tracker,
  }) {
    final onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
      ),
    );
    Widget app = MultiRepositoryProvider(
      providers: [
        RepositoryProvider<GraphRepository>.value(value: graph),
        RepositoryProvider<PostsRepository>.value(value: posts),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<EngagementCubit>.value(value: engagement),
          BlocProvider<BookmarksCubit>.value(value: bookmarks),
        ],
        child: MaterialApp(
          theme: appDarkTheme,
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: app!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: child),
              ),
            ),
          ),
        ),
      ),
    );
    if (tracker != null) {
      app = RepositoryProvider<ImpressionTracker>.value(
        value: tracker,
        child: app,
      );
    }
    return app;
  }

  setUp(() {
    graph = _MockGraph();
    when(() => graph.cached(any())).thenReturn(null);
    posts = _MockPosts();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    engagement = EngagementCubit(repository: _MockEngagement());
    final bookmarkRepo = _MockBookmarks();
    when(() => bookmarkRepo.events).thenAnswer((_) => const Stream.empty());
    bookmarks = BookmarksCubit(repository: bookmarkRepo);
  });
  tearDown(() async {
    await engagement.close();
    await bookmarks.close();
  });

  PostCard card(pb.PostView view, {bool focal = false}) =>
      PostCard(view: view, now: _now, engagementEnabled: true, focal: focal);

  final eye = find.byIcon(Icons.visibility_outlined);
  final on = {'engagement', 'post_views'};

  group('list card', () {
    testWidgets('shown with view_count and post_views on, compact', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(card(_post(views: 1234)), flags: on));
      expect(eye, findsOneWidget);
      expect(find.text('1.23K'), findsOneWidget);
      expect(find.bySemanticsLabel('1.23K views'), findsOneWidget);
    });

    testWidgets('flag on without a view_count: hidden', (tester) async {
      await tester.pumpWidget(wrap(card(_post()), flags: on));
      expect(eye, findsNothing);
    });

    testWidgets('view_count with the flag off: hidden', (tester) async {
      await tester.pumpWidget(
        wrap(card(_post(views: 5000)), flags: {'engagement'}),
      );
      expect(eye, findsNothing);
      expect(find.text('5K'), findsNothing);
    });

    testWidgets('a REPOST row never shows the count', (tester) async {
      await tester.pumpWidget(
        wrap(card(_post(views: 5000, repost: true)), flags: on),
      );
      expect(eye, findsNothing);
    });

    testWidgets('updates when the row is replaced with a newer count', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(card(_post(views: 1000)), flags: on));
      expect(find.text('1K'), findsOneWidget);
      await tester.pumpWidget(wrap(card(_post(views: 2500)), flags: on));
      expect(find.text('2.5K'), findsOneWidget);
    });

    for (final width in [320.0, 400.0, 700.0, 1100.0]) {
      testWidgets('no overflow at $width dp with big counts and large text', (
        tester,
      ) async {
        final view = _post(views: 12345678)
          ..post.likeCount = Int64(1234567)
          ..post.replyCount = Int64(9876)
          ..post.repostCount = Int64(4567);
        await tester.pumpWidget(
          wrap(
            card(view),
            flags: {...on, 'bookmarks'},
            width: width,
            textScale: 1.5,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(eye, findsOneWidget);
      });
    }
  });

  group('opened post', () {
    testWidgets('shows the views beside the time, once', (tester) async {
      await tester.pumpWidget(
        wrap(card(_post(views: 1234), focal: true), flags: on),
      );
      expect(eye, findsOneWidget);
      expect(find.text('1.23K'), findsOneWidget);
    });

    testWidgets('hidden without view_count or with the flag off', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(card(_post(), focal: true), flags: on));
      expect(eye, findsNothing);
      await tester.pumpWidget(
        wrap(card(_post(views: 99), focal: true), flags: {'engagement'}),
      );
      expect(eye, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('counts as seen at once', (tester) async {
      final sent = <List<String>>[];
      final tracker = ImpressionTracker(
        send: (ids) async => sent.add(ids),
        isEnabled: () => true,
      );
      addTearDown(tracker.dispose);
      await tester.pumpWidget(
        wrap(card(_post(), focal: true), flags: on, tracker: tracker),
      );
      await tester.pump();
      await tracker.flush();
      expect(sent, [
        [postId(7)],
      ]);
    });
  });

  group('impressions', () {
    testWidgets('a REPOST card reports the original after 1 s', (tester) async {
      final sent = <List<String>>[];
      final tracker = ImpressionTracker(
        send: (ids) async => sent.add(ids),
        isEnabled: () => true,
      );
      addTearDown(tracker.dispose);
      await tester.pumpWidget(
        wrap(card(_post(repost: true)), flags: on, tracker: tracker),
      );
      await tester.pump(const Duration(seconds: 2));
      await tracker.flush();
      expect(sent, [
        [postId(1)],
      ]);
    });
  });
}
