import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraphRepository extends Mock implements GraphRepository {}

/// W4-16: a hashtag in a post body opens `/search?q=%23tag` (Top) with the
/// `search` flag on; with it off, today's "coming soon" snackbar.
void main() {
  pb.PostView view(String text) => pb.PostView(
    post: pb.Post(
      postId: '0000000000000000001',
      text: text,
      author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
    ),
  );

  Future<GoRouter> pumpCard(
    WidgetTester tester, {
    required Set<String> flags,
    String text = 'ship it #Launch today',
    double textScale = 1,
    double width = 390,
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
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: SingleChildScrollView(
              child: PostCard(view: view(text), now: DateTime.now()),
            ),
          ),
        ),
        GoRoute(
          path: '/search',
          builder: (context, state) => Scaffold(
            body: Text('search page ${state.uri.queryParameters['q']}'),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: _MockGraphRepository(),
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(
            routerConfig: router,
            theme: appLightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('search on: the tap opens the results for the tag on Top', (
    tester,
  ) async {
    final router = await pumpCard(tester, flags: const {'search'});

    await tester.tapOnText(find.textRange.ofSubstring('#Launch'));
    await tester.pumpAndSettle();

    expect(find.text('search page #Launch'), findsOneWidget);
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/search?q=%23Launch',
    );
    expect(find.text('Hashtags are coming soon.'), findsNothing);
  });

  testWidgets('search off: the old snackbar and no navigation', (tester) async {
    final router = await pumpCard(tester, flags: const {'posts'});

    await tester.tapOnText(find.textRange.ofSubstring('#Launch'));
    await tester.pump();

    expect(find.text('Hashtags are coming soon.'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/');
  });

  testWidgets('the span is a link "Search #Launch" with search on', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCard(tester, flags: const {'search'});

    expect(find.semantics.byLabel(RegExp('Search #Launch')), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('Hashtag #Launch')), findsNothing);
    handle.dispose();
  });

  testWidgets('search off: the span keeps its "Hashtag" label', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCard(tester, flags: const {'posts'});

    expect(find.semantics.byLabel(RegExp('Hashtag #Launch')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('at 360 dp and text scale 2.0 the tap still lands', (
    tester,
  ) async {
    await pumpCard(
      tester,
      flags: const {'search'},
      width: 360,
      textScale: 2,
      text: '#Launch',
    );
    expect(tester.takeException(), isNull);

    await tester.tapOnText(find.textRange.ofSubstring('#Launch'));
    await tester.pumpAndSettle();

    expect(find.text('search page #Launch'), findsOneWidget);
  });
}
