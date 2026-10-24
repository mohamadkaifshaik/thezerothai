import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../support/posts_fixtures.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class MockEngagementRepository extends Mock implements EngagementRepository {}

class MockPostsRepository extends Mock implements PostsRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

final _now = DateTime.utc(2026, 5, 1, 12);

common.AuthorSnapshot _author(String id, String handle, String name) =>
    common.AuthorSnapshot(userId: id, handle: handle, displayName: name);

pb.EmbeddedPost _embed({
  bool unavailable = false,
  String authorId = 'u-orig',
  String text = 'the original words',
}) => unavailable
    ? pb.EmbeddedPost(postId: postId(1), unavailable: true)
    : pb.EmbeddedPost(
        postId: postId(1),
        text: text,
        author: _author(authorId, 'orig', 'Original Author'),
        createdAt: Timestamp.fromDateTime(
          _now.subtract(const Duration(hours: 3)),
        ),
      );

pb.PostView _repost({pb.EmbeddedPost? embedded, String reposterId = 'u-bob'}) =>
    pb.PostView(
      post: pb.Post(
        postId: postId(50),
        kind: PostKind.POST_KIND_REPOST,
        author: _author(reposterId, 'bob', 'Bob B'),
        embedded: embedded ?? _embed(),
        createdAt: Timestamp.fromDateTime(
          _now.subtract(const Duration(minutes: 1)),
        ),
      ),
    );

pb.PostView _quote({pb.EmbeddedPost? embedded}) => pb.PostView(
  post: pb.Post(
    postId: postId(60),
    kind: PostKind.POST_KIND_QUOTE,
    text: 'my take',
    author: _author('u-bob', 'bob', 'Bob B'),
    embedded: embedded ?? _embed(),
    createdAt: Timestamp.fromDateTime(
      _now.subtract(const Duration(minutes: 5)),
    ),
  ),
);

pb.PostView _plain() => pb.PostView(
  post: pb.Post(
    postId: postId(7),
    text: 'plain post',
    author: _author('u-a', 'alice', 'Alice A'),
  ),
);

void main() {
  late MockGraphRepository graphRepository;
  late MockEngagementRepository engagementRepository;
  late MockOnboardingBloc onboarding;
  late MockPostsRepository posts;
  late EngagementCubit engagement;

  setUp(() {
    graphRepository = MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
    engagementRepository = MockEngagementRepository();
    engagement = EngagementCubit(repository: engagementRepository);
    posts = MockPostsRepository();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    onboarding = MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {'engagement'},
      ),
    );
  });

  tearDown(() => engagement.close());

  Widget wrap(Widget child, {double width = 400, double textScale = 1}) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<GraphRepository>.value(value: graphRepository),
        RepositoryProvider<PostsRepository>.value(value: posts),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<EngagementCubit>.value(value: engagement),
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
  }

  group('engagement row', () {
    testWidgets('flag off: no action row and no engagement dependency', (
      tester,
    ) async {
      // No EngagementCubit / OnboardingBloc / PostsRepository provided: the
      // card must not even look them up while the flag is off.
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme,
          home: Scaffold(
            body: PostCard(view: _plain(), now: _now),
          ),
        ),
      );

      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.byIcon(Icons.repeat), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('flag on: shows the row for a plain post', (tester) async {
      await tester.pumpWidget(
        wrap(PostCard(view: _plain(), now: _now, engagementEnabled: true)),
      );

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
    });
  });

  group('REPOST item', () {
    testWidgets('shows "X reposted" over the original author and text', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(PostCard(view: _repost(), now: _now)));

      expect(find.text('Bob B reposted'), findsOneWidget);
      expect(find.text('Original Author'), findsOneWidget);
      expect(find.text('@orig'), findsOneWidget);
      expect(find.text('the original words'), findsOneWidget);
      expect(find.text('3h'), findsOneWidget, reason: 'the original time');
    });

    testWidgets('the viewer\'s own repost reads "You reposted"', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(PostCard(view: _repost(), now: _now, viewerUserId: 'u-bob')),
      );

      expect(find.text('You reposted'), findsOneWidget);
    });

    testWidgets('a tombstoned original shows only a placeholder', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _repost(embedded: _embed(unavailable: true)),
            now: _now,
            engagementEnabled: true,
          ),
        ),
      );

      expect(find.text('Bob B reposted'), findsOneWidget);
      expect(find.text('This post is unavailable'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
    });

    testWidgets('a blocked or muted original author shows no snapshot', (
      tester,
    ) async {
      when(() => graphRepository.cached('u-orig'))
          .thenReturn(graph.Relationship(userId: 'u-orig', blocking: true));
      await tester.pumpWidget(wrap(PostCard(view: _repost(), now: _now)));

      expect(find.text('You blocked this account'), findsOneWidget);
      expect(find.text('the original words'), findsNothing);
      expect(find.text('Original Author'), findsNothing);

      when(() => graphRepository.cached('u-orig'))
          .thenReturn(graph.Relationship(userId: 'u-orig', muting: true));
      await tester.pumpWidget(wrap(PostCard(view: _repost(), now: _now)));
      await tester.pump();

      expect(find.text('You muted this account'), findsOneWidget);
      expect(find.text('the original words'), findsNothing);
    });

    testWidgets('with graph off the relationship cache is not consulted', (
      tester,
    ) async {
      when(() => graphRepository.cached('u-orig'))
          .thenReturn(graph.Relationship(userId: 'u-orig', blocking: true));
      await tester.pumpWidget(
        wrap(PostCard(view: _repost(), now: _now, graphActionsEnabled: false)),
      );

      expect(find.text('the original words'), findsOneWidget);
    });

    testWidgets(
      'a server embed_viewer_state hides the snapshot with a cold cache',
      (tester) async {
        when(() => graphRepository.cached('u-orig')).thenReturn(null);
        final blocked = _repost()
          ..embedViewerState = pb.EmbedViewerState.EMBED_VIEWER_STATE_BLOCKED;
        await tester.pumpWidget(wrap(PostCard(view: blocked, now: _now)));

        expect(find.text('You blocked this account'), findsOneWidget);
        expect(find.text('the original words'), findsNothing);

        final muted = _repost()
          ..embedViewerState = pb.EmbedViewerState.EMBED_VIEWER_STATE_MUTED;
        await tester.pumpWidget(wrap(PostCard(view: muted, now: _now)));
        await tester.pump();

        expect(find.text('You muted this account'), findsOneWidget);
        expect(find.text('the original words'), findsNothing);
      },
    );

    testWidgets('an unspecified embed_viewer_state falls back to the cache', (
      tester,
    ) async {
      when(() => graphRepository.cached('u-orig'))
          .thenReturn(graph.Relationship(userId: 'u-orig', muting: true));
      await tester.pumpWidget(wrap(PostCard(view: _repost(), now: _now)));

      expect(find.text('You muted this account'), findsOneWidget);
    });

    testWidgets('the repost header has a spoken label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(PostCard(view: _repost(), now: _now)));

      expect(find.bySemanticsLabel('Bob B reposted'), findsOneWidget);
      handle.dispose();
    });
  });

  group('QUOTE item', () {
    testWidgets('shows the comment and a compact embed of the quoted post', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(PostCard(view: _quote(), now: _now)));

      expect(find.text('my take'), findsOneWidget);
      expect(find.text('Original Author'), findsOneWidget);
      expect(find.text('the original words'), findsOneWidget);
      expect(find.text('Bob B'), findsOneWidget);
    });

    testWidgets('tapping the embed opens the quoted post', (tester) async {
      String? opened;
      await tester.pumpWidget(
        wrap(
          PostCard(view: _quote(), now: _now, onOpenPost: (id) => opened = id),
        ),
      );

      await tester.tap(find.text('the original words'));

      expect(opened, postId(1));
    });

    testWidgets('the embed is a labelled button', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(PostCard(view: _quote(), now: _now)));

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('^Quoted post by Original Author')),
      );
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.label, contains('the original words'));
      handle.dispose();
    });

    testWidgets('a deleted original leaves the comment and a placeholder', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PostCard(
            view: _quote(embedded: _embed(unavailable: true)),
            now: _now,
          ),
        ),
      );

      expect(find.text('my take'), findsOneWidget);
      expect(find.text('This post is unavailable'), findsOneWidget);
    });

    testWidgets('a server embed_viewer_state hides a quote embed too', (
      tester,
    ) async {
      when(() => graphRepository.cached('u-orig')).thenReturn(null);
      final view = _quote()
        ..embedViewerState = pb.EmbedViewerState.EMBED_VIEWER_STATE_BLOCKED;
      await tester.pumpWidget(wrap(PostCard(view: view, now: _now)));

      expect(find.text('my take'), findsOneWidget);
      expect(find.text('You blocked this account'), findsOneWidget);
      expect(find.text('the original words'), findsNothing);
    });

    testWidgets('a blocked quoted author shows no snapshot', (tester) async {
      when(() => graphRepository.cached('u-orig'))
          .thenReturn(graph.Relationship(userId: 'u-orig', blocking: true));
      await tester.pumpWidget(wrap(PostCard(view: _quote(), now: _now)));

      expect(find.text('my take'), findsOneWidget);
      expect(find.text('You blocked this account'), findsOneWidget);
      expect(find.text('the original words'), findsNothing);
    });

    testWidgets('the viewer\'s own quoted post is never hidden', (
      tester,
    ) async {
      when(() => graphRepository.cached('u-orig'))
          .thenReturn(graph.Relationship(userId: 'u-orig', blocking: true));
      await tester.pumpWidget(
        wrap(PostCard(view: _quote(), now: _now, viewerUserId: 'u-orig')),
      );

      expect(find.text('the original words'), findsOneWidget);
    });
  });

  testWidgets('narrow width and 2x text: no overflow for a quote with row', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        PostCard(view: _quote(), now: _now, engagementEnabled: true),
        width: 320,
        textScale: 2,
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow width and 2x text: no overflow for a repost', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        PostCard(view: _repost(), now: _now, engagementEnabled: true),
        width: 320,
        textScale: 2,
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
