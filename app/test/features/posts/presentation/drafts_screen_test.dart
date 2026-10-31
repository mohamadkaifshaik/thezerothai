import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/drafts_screen.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_row.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/theme_harness.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockPostsRepository extends Mock implements PostsRepository {}

/// `/drafts` (W6-15, ADR-0029): the Unsent posts tab over the device's drafts,
/// the Scheduled tab around the CMP-D6 list, Edit mode with bulk delete, the
/// empty state, opening a draft, and layout across widths, themes and text
/// scales.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  // Dates are built from the real clock, never fixed (the fixed-date guard).
  final now = DateTime.now();

  ComposerDraft draft(
    String id,
    String text, {
    int minutesAgo = 5,
    String uid = 'uid-1',
    DraftPoll? poll,
  }) => ComposerDraft(
    id: id,
    uid: uid,
    text: text,
    poll: poll,
    createdAt: now.subtract(Duration(minutes: minutesAgo + 1)),
    updatedAt: now.subtract(Duration(minutes: minutesAgo)),
  );

  late FakeDraftsRepository drafts;
  late _MockPostsRepository posts;
  late _MockAuthBloc auth;
  late GoRouter router;
  String? picked;

  setUp(() {
    drafts = FakeDraftsRepository();
    posts = _MockPostsRepository();
    auth = _MockAuthBloc();
    picked = null;
    when(
      () => posts.listScheduledPosts(
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((_) async => pb.ListScheduledPostsResponse());
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool scheduledTab = false,
    bool pickMode = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('came from')),
        ),
        GoRoute(
          path: '/drafts',
          builder: (context, state) => DraftsScreen(
            scheduledTab: scheduledTab,
            pickMode: pickMode,
            now: () => now,
          ),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => Scaffold(
            body: Text('composer ${state.uri.queryParameters['draft']}'),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<DraftsRepository>.value(value: drafts),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: BlocProvider<AuthBloc>.value(
          value: auth,
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
      router.push<String>('/drafts', extra: pickMode).then((id) => picked = id),
    );
    await tester.pumpAndSettle();
  }

  void seed() => drafts.rows.addAll([
    draft('0000000000000001', 'First thought', minutesAgo: 3),
    draft(
      '0000000000000002',
      'Lunch?',
      minutesAgo: 90,
      poll: const DraftPoll(choices: ['Tacos', 'Soup'], durationMinutes: 1440),
    ),
    draft('0000000000000003', 'Someone else', uid: 'uid-2'),
  ]);

  group('Unsent posts tab', () {
    testWidgets('lists this account only, newest edit first, keyed rows', (
      tester,
    ) async {
      seed();
      await open(tester);
      expect(find.byType(DraftRow), findsNWidgets(2));
      expect(find.text('First thought'), findsOneWidget);
      expect(find.text('Lunch?'), findsOneWidget);
      expect(find.text('Someone else'), findsNothing);
      final ys = [
        tester.getTopLeft(find.text('First thought')).dy,
        tester.getTopLeft(find.text('Lunch?')).dy,
      ];
      expect(ys[0], lessThan(ys[1]));
      expect(find.byKey(const ValueKey('draft-0000000000000001')), findsOne);
    });

    testWidgets('a row shows a poll badge and the relative time', (
      tester,
    ) async {
      seed();
      await open(tester);
      expect(find.text('Poll'), findsOneWidget);
      expect(find.text('3m'), findsOneWidget);
      expect(find.text('1h'), findsOneWidget);
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(RegExp('Lunch\\?\\. Poll\\. Edited .* ago')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('tapping a row opens the composer on that draft id', (
      tester,
    ) async {
      seed();
      await open(tester);
      await tester.tap(find.text('First thought'));
      await tester.pumpAndSettle();
      expect(find.text('composer 0000000000000001'), findsOneWidget);
    });

    testWidgets('from the composer (pick mode) a tap pops with the id', (
      tester,
    ) async {
      seed();
      await open(tester, pickMode: true);
      await tester.tap(find.text('Lunch?'));
      await tester.pumpAndSettle();
      expect(picked, '0000000000000002');
      expect(find.text('came from'), findsOneWidget);
    });

    testWidgets('empty: our own words, no Edit button', (tester) async {
      await open(tester);
      expect(find.text(kDraftsEmptyTitle), findsOneWidget);
      expect(find.text(kDraftsEmptyBody), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
    });

    testWidgets('does not call the server for the Unsent tab', (tester) async {
      seed();
      await open(tester);
      verifyNever(
        () => posts.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      );
    });

    testWidgets('Back leaves the screen', (tester) async {
      seed();
      await open(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('came from'), findsOneWidget);
    });
  });

  group('Edit mode', () {
    Finder checkboxes() => find.byType(Checkbox);

    testWidgets('Edit shows checkboxes; Done hides them', (tester) async {
      seed();
      await open(tester);
      expect(checkboxes(), findsNothing);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(checkboxes(), findsNWidgets(2));
      expect(find.text('Select all'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(checkboxes(), findsNothing);
    });

    testWidgets('a tap selects instead of opening; Delete needs a choice', (
      tester,
    ) async {
      seed();
      await open(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      FilledButton delete() =>
          tester.widget(find.widgetWithText(FilledButton, 'Delete'));
      expect(delete().onPressed, isNull);
      await tester.tap(find.text('Lunch?'));
      await tester.pumpAndSettle();
      expect(find.text('composer 0000000000000002'), findsNothing);
      expect(
        tester.widget<Checkbox>(checkboxes().last).value,
        isTrue,
        reason: 'the second row is selected',
      );
      expect(delete().onPressed, isNotNull);
    });

    testWidgets('Select all, then Delete asks "Discard unsent posts?"', (
      tester,
    ) async {
      seed();
      await open(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('Deselect all'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Discard unsent posts?'), findsOneWidget);
      // Keep: nothing is removed.
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(drafts.rows.where((d) => d.uid == 'uid-1'), hasLength(2));
      // Discard: both go, and the other account's row stays.
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(drafts.rows.map((d) => d.id), ['0000000000000003']);
      expect(find.text(kDraftsEmptyTitle), findsOneWidget);
      expect(find.text('2 unsent posts discarded.'), findsOneWidget);
    });

    testWidgets('deleting one keeps the rest and leaves Edit mode', (
      tester,
    ) async {
      seed();
      await open(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First thought'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.text('First thought'), findsNothing);
      expect(find.text('Lunch?'), findsOneWidget);
      expect(find.text('Unsent post discarded.'), findsOneWidget);
      expect(checkboxes(), findsNothing);
    });

    testWidgets('targets are at least 48dp', (tester) async {
      seed();
      await open(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      for (final finder in [
        find.widgetWithText(TextButton, 'Done'),
        find.widgetWithText(TextButton, 'Select all'),
        find.widgetWithText(FilledButton, 'Delete'),
      ]) {
        final size = tester.getSize(finder);
        expect(size.height, greaterThanOrEqualTo(48), reason: '$finder');
        expect(size.width, greaterThanOrEqualTo(48), reason: '$finder');
      }
    });
  });

  group('Scheduled tab', () {
    testWidgets('opens on Scheduled when asked and loads the list', (
      tester,
    ) async {
      seed();
      await open(tester, scheduledTab: true);
      expect(find.text('Nothing scheduled'), findsOneWidget);
      expect(find.byType(DraftRow), findsNothing);
      verify(
        () => posts.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).called(1);
    });

    testWidgets('switching tabs swaps the list; Edit belongs to Unsent', (
      tester,
    ) async {
      seed();
      await open(tester);
      expect(find.text('Edit'), findsOneWidget);
      await tester.tap(find.widgetWithText(InkWell, kDraftsTabScheduled).first);
      await tester.pumpAndSettle();
      expect(find.text('Nothing scheduled'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      await tester.tap(find.text(kDraftsTabUnsent));
      await tester.pumpAndSettle();
      expect(find.text('First thought'), findsOneWidget);
    });

    testWidgets('the tab bar names both tabs', (tester) async {
      await open(tester);
      final bar = tester.widget<AppTabBar>(find.byType(AppTabBar));
      expect(bar.tabs.map((t) => t.label), [
        kDraftsTabUnsent,
        kDraftsTabScheduled,
      ]);
    });
  });

  group('layout', () {
    forEachThemeAndWidth('Unsent posts and Edit mode fit', (tester, env) async {
      seed();
      drafts.rows.add(
        draft(
          '0000000000000004',
          'A much longer unsent post that goes on and on about nothing in '
              'particular so that the preview has to be cut after three lines '
              'of text at every width and every text size we support.',
          minutesAgo: 2000,
        ),
      );
      await open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('the empty state and the Scheduled tab fit', (
      tester,
      env,
    ) async {
      await open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      expect(find.text(kDraftsEmptyTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(InkWell, kDraftsTabScheduled).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, textScales: kMatrixTextScalesLarge);
  });
}
