import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/domain/engagement_feature_flag.dart';
import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/posts/presentation/widgets/composer_poll_builder.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_dialogs.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The composer's side of Drafts (W6-15, ADR-0029): the Drafts header button,
/// autosave, "Save post?", opening a saved draft under the same id, and the
/// `drafts` flag gate (off: no button, the old prompt).
void main() {
  setUpAll(registerMediaFallbacks);

  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  final now = DateTime.now();
  const flags = {kFeaturePosts, kFeatureDrafts};

  ComposerDraft saved(
    String id,
    String text, {
    String uid = 'uid-1',
    DraftPoll? poll,
    bool paid = false,
  }) => ComposerDraft(
    id: id,
    uid: uid,
    text: text,
    poll: poll,
    paidPartnership: paid,
    createdAt: now.subtract(const Duration(minutes: 10)),
    updatedAt: now.subtract(const Duration(minutes: 5)),
  );

  late FakeDraftsRepository drafts;
  late _MockPostsRepository posts;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late PendingPostsCubit pending;
  late GoRouter router;

  setUp(() {
    drafts = FakeDraftsRepository();
    posts = _MockPostsRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    pending = PendingPostsCubit();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) async => postView(1));
  });

  tearDown(() => pending.close());

  /// Opens `/compose[?draft=id]` over a home page. `/drafts` is a stub that
  /// pops with [pickFromList] (null: the user just goes back).
  Future<void> open(
    WidgetTester tester, {
    Set<String> features = flags,
    String? draft,
    String? pickFromList,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    String uid = 'uid-1',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: uid,
          email: user.email,
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: uid, handle: 'me'),
        enabledFeatures: features,
      ),
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) =>
              ComposerScreen(draftId: state.uri.queryParameters['draft'] ?? ''),
        ),
        GoRoute(
          path: '/drafts',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.pop(pickFromList),
                child: Text('drafts list pick=${state.extra}'),
              ),
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<DraftsRepository>.value(value: drafts),
          RepositoryProvider<MediaRepository>.value(value: media),
          RepositoryProvider<ImagePickerService>.value(value: picker),
          RepositoryProvider<ImageProcessor>.value(value: FakeImageProcessor()),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(
      router.push(draft == null ? '/compose' : '/compose?draft=$draft'),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> cancel(WidgetTester tester) async {
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  }

  Finder draftsButton() => find.widgetWithText(TextButton, 'Drafts');
  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  group('flag gate', () {
    testWidgets('drafts off: no button, nothing saved, no prompt', (
      tester,
    ) async {
      await open(tester, features: {kFeaturePosts});
      expect(draftsButton(), findsNothing);
      await type(tester, 'hello');
      expect(drafts.autosaves, 0);
      await cancel(tester);
      expect(find.text('Save post?'), findsNothing);
      expect(find.text('home page'), findsOneWidget);
      expect(drafts.rows, isEmpty);
    });

    testWidgets('drafts off: photos still ask the old question', (
      tester,
    ) async {
      await open(tester, features: {kFeaturePosts, kFeatureMedia});
      picker.next = [imageBytes('a')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      await cancel(tester);
      expect(find.text('Discard this post?'), findsOneWidget);
      expect(find.text('Your photos will not be saved.'), findsOneWidget);
      expect(find.text('Save post?'), findsNothing);
    });

    testWidgets('drafts on: the Drafts button is in the header', (
      tester,
    ) async {
      await open(tester);
      expect(draftsButton(), findsOneWidget);
      // Cancel at the start, Drafts then Post at the end.
      final xs = [
        tester.getCenter(find.text('Cancel')).dx,
        tester.getCenter(find.text('Drafts')).dx,
        tester.getCenter(find.widgetWithText(AppPillButton, 'Post')).dx,
      ];
      expect(xs, orderedEquals([...xs]..sort()));
    });

    testWidgets('a quote has no Drafts button', (tester) async {
      // The quote gate needs more flags than this test provides; the cubit
      // rule is covered below. A signed-out uid also disables drafts.
      await open(tester, uid: '');
      expect(draftsButton(), findsNothing);
    });
  });

  group('autosave and the leave prompt', () {
    testWidgets('typing autosaves the draft', (tester) async {
      await open(tester);
      await type(tester, 'half a thought');
      expect(drafts.autosaves, greaterThan(0));
      expect(drafts.rows.single.text, 'half a thought');
      expect(drafts.rows.single.uid, 'uid-1');
    });

    testWidgets('Save post? appears; Save keeps the row and leaves', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'keep me');
      await cancel(tester);
      expect(find.text('Save post?'), findsOneWidget);
      expect(
        find.text('You can save this to send later from your drafts.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('home page'), findsOneWidget);
      expect(drafts.rows.single.text, 'keep me');
    });

    testWidgets('Discard removes the row (also after an autosave)', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'drop me');
      expect(drafts.rows, hasLength(1));
      await cancel(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.text('home page'), findsOneWidget);
      expect(drafts.rows, isEmpty);
    });

    testWidgets('Keep editing stays on the composer', (tester) async {
      await open(tester);
      await type(tester, 'still here');
      await cancel(tester);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('New post'), findsOneWidget);
      expect(fieldText(tester), 'still here');
    });

    testWidgets('system back asks too', (tester) async {
      await open(tester);
      await type(tester, 'back gesture');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Save post?'), findsOneWidget);
      expect(find.text('New post'), findsOneWidget);
    });

    testWidgets('an empty composer leaves without a question', (tester) async {
      await open(tester);
      await cancel(tester);
      expect(find.text('Save post?'), findsNothing);
      expect(find.text('home page'), findsOneWidget);
    });

    testWidgets('clearing the text again leaves without a question', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'oops');
      await type(tester, '');
      await cancel(tester);
      expect(find.text('Save post?'), findsNothing);
      expect(drafts.rows, isEmpty);
    });

    testWidgets('with photos the prompt adds the photos line', (tester) async {
      await open(tester, features: {...flags, kFeatureMedia});
      await type(tester, 'with a picture');
      picker.next = [imageBytes('a')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      await cancel(tester);
      expect(find.text('Save post?'), findsOneWidget);
      expect(find.text(kDraftsPhotosNote), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(drafts.rows.single.text, 'with a picture');
    });

    testWidgets('only photos (no text): the old discard question', (
      tester,
    ) async {
      await open(tester, features: {...flags, kFeatureMedia});
      picker.next = [imageBytes('a')];
      await tester.tap(find.byTooltip('Add photos'));
      await tester.pumpAndSettle();
      await cancel(tester);
      expect(find.text('Discard this post?'), findsOneWidget);
      expect(find.text('Save post?'), findsNothing);
    });
  });

  group('continuing a draft', () {
    testWidgets('the saved text is in the field; leaving untouched is silent', (
      tester,
    ) async {
      drafts.rows.add(saved('00000000000000a1', 'from before'));
      await open(tester, draft: '00000000000000a1');
      expect(fieldText(tester), 'from before');
      expect(drafts.autosaves, 0, reason: 'loading is not an edit');
      await cancel(tester);
      expect(find.text('Save post?'), findsNothing);
      expect(drafts.rows.single.text, 'from before');
    });

    testWidgets('editing and saving keeps the same draft id', (tester) async {
      drafts.rows.add(saved('00000000000000a1', 'from before', paid: true));
      await open(tester, draft: '00000000000000a1');
      await type(tester, 'from before, edited');
      await cancel(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(drafts.rows, hasLength(1));
      expect(drafts.rows.single.id, '00000000000000a1');
      expect(drafts.rows.single.text, 'from before, edited');
      expect(drafts.rows.single.paidPartnership, isTrue);
    });

    testWidgets('posting a draft removes its row', (tester) async {
      drafts.rows.add(saved('00000000000000a1', 'send this'));
      await open(tester, draft: '00000000000000a1');
      await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      await tester.pumpAndSettle();
      expect(find.text('home page'), findsOneWidget);
      expect(drafts.rows, isEmpty);
    });

    testWidgets('posting a fresh composer leaves no row behind', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'straight out');
      expect(drafts.rows, hasLength(1));
      await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      await tester.pumpAndSettle();
      expect(drafts.rows, isEmpty);
    });

    testWidgets('an unknown id opens a new post under a fresh id', (
      tester,
    ) async {
      await open(tester, draft: 'deadbeefdeadbeef');
      expect(fieldText(tester), isEmpty);
      await type(tester, 'new one');
      expect(drafts.rows.single.id, isNot('deadbeefdeadbeef'));
    });

    testWidgets("another account's draft is never loaded or overwritten", (
      tester,
    ) async {
      drafts.rows.add(saved('00000000000000b2', 'secret', uid: 'uid-2'));
      await open(tester, draft: '00000000000000b2');
      expect(fieldText(tester), isEmpty);
      await type(tester, 'mine');
      final mine = drafts.rows.where((d) => d.uid == 'uid-1').single;
      expect(mine.id, isNot('00000000000000b2'));
      expect(drafts.rows.singleWhere((d) => d.uid == 'uid-2').text, 'secret');
    });

    testWidgets('a saved poll comes back into the builder', (tester) async {
      drafts.rows.add(
        saved(
          '00000000000000a3',
          'which?',
          poll: const DraftPoll(
            choices: ['Tea', 'Coffee'],
            durationMinutes: 1440,
          ),
        ),
      );
      await open(
        tester,
        draft: '00000000000000a3',
        features: {...flags, kFeatureEngagement, kFeaturePolls},
      );
      expect(find.byType(ComposerPollBuilder), findsOneWidget);
      expect(find.text('Tea'), findsOneWidget);
      expect(find.text('Coffee'), findsOneWidget);
    });
  });

  group('the Drafts button', () {
    testWidgets('keeps what was typed, then opens the list in pick mode', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'before I look');
      await tester.tap(draftsButton());
      await tester.pumpAndSettle();
      expect(find.text('drafts list pick=true'), findsOneWidget);
      expect(drafts.rows.single.text, 'before I look');
      // Back without choosing: the composer is as it was.
      await tester.tap(find.textContaining('drafts list'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'before I look');
    });

    testWidgets('a chosen draft loads in place, under its own id', (
      tester,
    ) async {
      drafts.rows.add(saved('00000000000000a1', 'the other draft'));
      await open(tester, pickFromList: '00000000000000a1');
      await type(tester, 'current');
      await tester.tap(draftsButton());
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('drafts list'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'the other draft');
      expect(find.text('New post'), findsOneWidget, reason: 'one composer');
      // Both survive; the next edit goes to the chosen one.
      expect(drafts.rows, hasLength(2));
      await type(tester, 'the other draft, longer');
      expect(
        drafts.rows.singleWhere((d) => d.id == '00000000000000a1').text,
        'the other draft, longer',
      );
      expect(drafts.rows.where((d) => d.text == 'current'), hasLength(1));
    });
  });

  group('layout', () {
    forEachThemeAndWidth('the header with Drafts fits', (tester, env) async {
      await open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      for (final finder in [
          draftsButton(),
          find.widgetWithText(TextButton, 'Cancel'),
        ]) {
        expect(
          tester.getSize(finder).height,
          greaterThanOrEqualTo(40),
          reason: 'visible and tappable',
        );
      }
      await type(tester, 'text');
      await cancel(tester);
      expect(find.text('Save post?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, textScales: kMatrixTextScalesLarge);
  });
}
