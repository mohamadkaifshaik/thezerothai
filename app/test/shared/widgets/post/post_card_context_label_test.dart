import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraphRepository extends Mock implements GraphRepository {}

pb.PostView _view({bool community = true, bool repost = false}) {
  final author = common.AuthorSnapshot(
    userId: 'u1',
    handle: 'alice',
    displayName: 'Alice A',
  );
  return pb.PostView(
    post: pb.Post(
      postId: '0000000000000000001',
      text: 'hello',
      author: author,
      kind: repost ? PostKind.POST_KIND_REPOST : PostKind.POST_KIND_POST,
      embedded: repost
          ? pb.EmbeddedPost(
              postId: '0000000000000000002',
              text: 'original',
              author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
            )
          : null,
      community: community
          ? pb.CommunityRef(id: 'c1', name: 'Gardeners')
          : null,
    ),
  );
}

void main() {
  Future<GoRouter> pump(
    WidgetTester tester, {
    required pb.PostView view,
    Set<String> flags = const {'communities'},
    double width = 390,
    ThemeData? theme,
  }) async {
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
      ),
    );
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final graph = _MockGraphRepository();
    when(() => graph.cached(any())).thenReturn(null);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: SingleChildScrollView(
              child: PostCard(view: view, now: DateTime.now()),
            ),
          ),
        ),
        GoRoute(
          path: '/communities/:id',
          builder: (context, state) =>
              Scaffold(body: Text('community ${state.pathParameters['id']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graph,
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(
            routerConfig: router,
            theme: theme ?? appLightTheme,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  for (final dark in [false, true]) {
    for (final width in [320.0, 390.0, 800.0]) {
      testWidgets('community label shows, no overflow '
          '(${dark ? 'dark' : 'light'}, $width)', (tester) async {
        await pump(
          tester,
          view: _view(),
          width: width,
          theme: dark ? appDarkTheme : appLightTheme,
        );
        expect(find.text('Gardeners'), findsOneWidget);
        expect(find.byIcon(Icons.people_outline), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('communities on: tap opens /communities/:id', (tester) async {
    await pump(tester, view: _view());
    await tester.tap(find.text('Gardeners'));
    await tester.pumpAndSettle();
    expect(find.text('community c1'), findsOneWidget);
  });

  testWidgets('communities off: label shows but is not tappable', (
    tester,
  ) async {
    await pump(tester, view: _view(), flags: const {});
    expect(find.text('Gardeners'), findsOneWidget);
    await tester.tap(find.text('Gardeners'));
    await tester.pumpAndSettle();
    expect(find.text('community c1'), findsNothing);
    expect(
      tester.getSemantics(find.text('Gardeners')).flagsCollection.isButton,
      isFalse,
    );
  });

  testWidgets('semantics label is the community name', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, view: _view());
    expect(find.bySemanticsLabel('Gardeners'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a repost shows "reposted", not the community', (tester) async {
    await pump(tester, view: _view(repost: true));
    expect(find.text('Alice A reposted'), findsOneWidget);
    expect(find.text('Gardeners'), findsNothing);
  });

  testWidgets('no community: no label', (tester) async {
    await pump(tester, view: _view(community: false));
    expect(find.byIcon(Icons.people_outline), findsNothing);
  });
}
