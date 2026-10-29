import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/feature_flags.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_state.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/protected_post_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/geometry.dart';
import '../../../../support/owner_placeholder_fixtures.dart';
import '../../../../support/posts_fixtures.dart';
import '../../../../support/theme_harness.dart';

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _message = 'This post is from an account that protects its posts.';

/// W3-41b: the caller's own REPOST of a protected author's post, on their own
/// profile tabs (`FeedPostRow` -> `PostCard`): the protected box, "You
/// reposted" and one Undo repost action that acts on the ORIGINAL's id, with
/// no reply, share or thread entry; the row leaves at once and returns, with
/// the existing error copy, when the undo fails.
void main() {
  late _MockEngagementRepository repository;
  late EngagementCubit cubit;
  late _MockOnboardingBloc onboarding;

  setUp(() {
    repository = _MockEngagementRepository();
    cubit = EngagementCubit(repository: repository);
    onboarding = _MockOnboardingBloc();
    // `private_accounts` is deliberately absent: an undo is never gated on it.
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {kFeatureEngagement},
      ),
    );
  });

  tearDown(() => cubit.close());

  /// Scripts `UndoRepost`: [error] is thrown, [gate] holds the answer back.
  /// The default answer is the missing-post shape W3-40a returns for a post
  /// the caller may no longer see: the post id, zero counts, not reposted.
  void scriptUndo({Object? error, Completer<void>? gate}) {
    when(
      () => repository.undoRepost(
        postId: any(named: 'postId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((invocation) async {
      await gate?.future;
      if (error != null) throw error;
      return eng.PostEngagement(
        postId: invocation.namedArguments[#postId] as String,
      );
    });
  }

  GoRouter routerFor(
    pb.PostView view, {
    String? viewer,
    bool? engagement,
    Future<void> Function(String postId)? onDelete,
  }) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: MultiBlocProvider(
              providers: [
                BlocProvider<OnboardingBloc>.value(value: onboarding),
                BlocProvider<EngagementCubit>.value(value: cubit),
              ],
              child: SingleChildScrollView(
                child: Builder(
                  builder: (context) => FeedPostRow(
                    view: view,
                    viewerUserId: viewer,
                    graphEnabled: false,
                    reportsEnabled: false,
                    onDelete: onDelete,
                    engagementEnabled:
                        engagement ??
                        isFeatureEnabled(context, kFeatureEngagement),
                  ),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) =>
              Scaffold(body: Text('post page ${state.pathParameters['id']}')),
        ),
      ],
    );
    return router;
  }

  Future<void> open(
    WidgetTester tester,
    pb.PostView view, {
    String? viewer = 'me',
    bool? engagement,
    Future<void> Function(String postId)? onDelete,
    Brightness brightness = Brightness.light,
    Size size = const Size(400, 800),
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        routerConfig: routerFor(
          view,
          viewer: viewer,
          engagement: engagement,
          onDelete: onDelete,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder undoButton() => find.widgetWithText(OutlinedButton, 'Undo repost');

  forEachThemeAndWidth(
    'the own protected repost: box, You reposted, one 48dp Undo repost',
    (tester, env) async {
      await open(
        tester,
        ownProtectedRepostView(leak: true),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('You reposted'), findsOneWidget);
      expect(find.byType(ProtectedPostBox), findsOneWidget);
      expect(find.text('Locked Author'), findsOneWidget);
      expect(find.text('@locked'), findsOneWidget);
      expect(find.text(_message), findsOneWidget);
      // Nothing of the post, no reply / share / like row, no overflow menu.
      expect(find.text('secret words that must not show'), findsNothing);
      expect(find.byType(PostActionBar), findsNothing);
      expect(find.byTooltip('More options'), findsNothing);
      expect(undoButton(), findsOneWidget);
      expectMinTarget(tester, undoButton());
      expectInsideHorizontally(tester, undoButton(), env.size.width);
      expectInsideHorizontally(
        tester,
        find.byType(ProtectedPostBox),
        env.size.width,
      );
    },
    textScales: kMatrixTextScalesLarge,
  );

  testWidgets('the button is one labelled node naming the original author', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester, ownProtectedRepostView());
    expect(
      tester.getSemantics(find.byType(OutlinedButton)),
      matchesSemantics(
        label: "Undo repost of @locked's post",
        isButton: true,
        isEnabled: true,
        hasTapAction: true,
        hasEnabledState: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('tapping the row opens nothing (no /post/:id)', (tester) async {
    await open(tester, ownProtectedRepostView());
    await tester.tap(find.text('Locked Author'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('You reposted'));
    await tester.pumpAndSettle();
    expect(find.textContaining('post page'), findsNothing);
    expect(find.byType(ProtectedPostBox), findsOneWidget);
  });

  testWidgets('Undo repost acts on the ORIGINAL id, the row leaves at once '
      'and stays gone once the server answers', (tester) async {
    final gate = Completer<void>();
    scriptUndo(gate: gate);
    await open(tester, ownProtectedRepostView(original: 7, repost: 70));

    await tester.tap(undoButton());
    await tester.pump();

    // Optimistic: gone while the request is still running, divider included.
    expect(find.byType(ProtectedPostBox), findsNothing);
    expect(find.text('You reposted'), findsNothing);
    expect(find.byType(Divider), findsNothing);
    verify(
      () => repository.undoRepost(
        postId: postId(7),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    verifyNever(
      () => repository.undoRepost(
        postId: postId(70),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ProtectedPostBox), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the missing-post answer (zero counts, not reposted) is a '
      'success: the row stays gone, no error', (tester) async {
    scriptUndo();
    await open(tester, ownProtectedRepostView());

    await tester.tap(undoButton());
    await tester.pumpAndSettle();

    expect(find.byType(ProtectedPostBox), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(cubit.state.failure, isNull);
  });

  testWidgets('a failed undo puts the row back and says why, once', (
    tester,
  ) async {
    const error = NetworkException('offline');
    final gate = Completer<void>();
    scriptUndo(error: error, gate: gate);
    await open(tester, ownProtectedRepostView());

    await tester.tap(undoButton());
    await tester.pump();
    expect(find.byType(ProtectedPostBox), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(ProtectedPostBox), findsOneWidget);
    expect(undoButton(), findsOneWidget);
    expect(
      find.text(
        engagementErrorMessage(error, action: EngagementAction.undoRepost),
      ),
      findsOneWidget,
    );
    expect(cubit.state.failure, isNull, reason: 'shown, then cleared');

    // Tapping again is a retry of the same intent: the row can go again.
    scriptUndo();
    await tester.tap(undoButton());
    await tester.pumpAndSettle();
    expect(find.byType(ProtectedPostBox), findsNothing);
  });

  testWidgets('NOT_FOUND from the server rolls back with the existing copy', (
    tester,
  ) async {
    const error = NotFoundException('not found');
    scriptUndo(error: error);
    await open(tester, ownProtectedRepostView());

    await tester.tap(undoButton());
    await tester.pumpAndSettle();

    expect(find.byType(ProtectedPostBox), findsOneWidget);
    expect(
      find.text(
        engagementErrorMessage(error, action: EngagementAction.undoRepost),
      ),
      findsOneWidget,
    );
  });

  group('flags', () {
    testWidgets('`private_accounts` absent from GetMe: the placeholder and '
        'its undo still work', (tester) async {
      scriptUndo();
      // The harness reads `engagement` from the onboarding state above, which
      // has no `private_accounts`.
      expect(
        onboarding.state.enabledFeatures.contains('private_accounts'),
        isFalse,
      );
      await open(tester, ownProtectedRepostView());

      expect(undoButton(), findsOneWidget);
      await tester.tap(undoButton());
      await tester.pumpAndSettle();
      expect(find.byType(ProtectedPostBox), findsNothing);
      verify(
        () => repository.undoRepost(
          postId: postId(7),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    testWidgets('`engagement` off: the box still shows, with no Undo repost; '
        'the overflow menu keeps Delete, an equivalent server-side undo', (
      tester,
    ) async {
      final deleted = <String>[];
      await open(
        tester,
        ownProtectedRepostView(repost: 70),
        engagement: false,
        onDelete: (id) async => deleted.add(id),
      );

      expect(find.byType(ProtectedPostBox), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byTooltip('More options'), findsOneWidget);
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      // The confirmation dialog.
      expect(find.text('Delete this post?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      // Delete acts on the REPOST row's own id (the server releases the
      // reposts doc and the count in the same batch).
      expect(deleted, [postId(70)]);
      await tester.tap(find.text('Locked Author'));
      await tester.pumpAndSettle();
      expect(find.textContaining('post page'), findsNothing);
      verifyZeroInteractions(repository);
    });
  });

  group('other rows are unchanged', () {
    testWidgets('a protected repost that is not the viewers own gets no '
        'action and opens nothing', (tester) async {
      await open(tester, ownProtectedRepostView(viewerId: 'someone-else'));

      expect(find.byType(ProtectedPostBox), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      await tester.tap(find.text('Locked Author'));
      await tester.pumpAndSettle();
      expect(find.textContaining('post page'), findsNothing);
    });

    testWidgets('an own protected repost the server does not mark as '
        'reposted has no action (there is nothing to undo)', (tester) async {
      await open(tester, ownProtectedRepostView(reposted: false));

      expect(find.byType(ProtectedPostBox), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('a QUOTE with a protected embed keeps its tap and gets no '
        'undo', (tester) async {
      final quote = ownProtectedRepostView();
      quote.post
        ..kind = PostKind.POST_KIND_QUOTE
        ..text = 'my take';
      await open(tester, quote);

      expect(find.text('my take'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      await tester.tap(find.text('my take'));
      await tester.pumpAndSettle();
      expect(find.textContaining('post page'), findsOneWidget);
    });
  });

  testWidgets('two quick taps on Undo repost send ONE request', (tester) async {
    final gate = Completer<void>();
    scriptUndo(gate: gate);
    await open(tester, ownProtectedRepostView(original: 7));

    // No frame between the taps: the second lands on the same button.
    await tester.tap(undoButton());
    await tester.tap(undoButton());
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    verify(
      () => repository.undoRepost(
        postId: postId(7),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.byType(ProtectedPostBox), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  group('a gone original is not the protected case', () {
    test('isProtectedRepost and canUndoProtectedRepost need a live embed', () {
      final live = ownProtectedRepostView();
      final gone = ownProtectedRepostView(unavailable: true);
      expect(isProtectedRepost(live), isTrue);
      expect(isProtectedRepost(gone), isFalse);
      expect(
        canUndoProtectedRepost(
          live,
          viewerUserId: 'me',
          engagementEnabled: true,
        ),
        isTrue,
      );
      expect(
        canUndoProtectedRepost(
          gone,
          viewerUserId: 'me',
          engagementEnabled: true,
        ),
        isFalse,
      );
    });

    testWidgets('PostCard answers it with the unavailable box first: no '
        'protected box and no Undo repost', (tester) async {
      await open(tester, ownProtectedRepostView(unavailable: true));

      expect(find.byType(ProtectedPostBox), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('This post is unavailable'), findsOneWidget);
    });
  });
}
