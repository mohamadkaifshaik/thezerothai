import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:dzeroth/features/articles/domain/articles_repository.dart';
import 'package:dzeroth/features/articles/presentation/articles_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/theme_harness.dart';

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _Repo implements ArticlesRepository {
  _Repo({this.pending = false, this.stored, this.canChoose = true});

  final bool pending;
  final ReplyPolicy? stored;
  final bool canChoose;

  late ArticleRecord record = ArticleRecord(
    draft: ArticleDraft(
      id: 'draft',
      authorId: 'owner',
      title: 'Harbour notes',
      blocks: [
        ArticleBlock(
          kind: ArticleBlockKind.paragraph,
          runs: [ArticleTextRun(text: 'Body')],
        ),
      ],
    ),
    updatedAt: DateTime.now().toUtc(),
    publicationPending: pending,
    publicationReplyPolicy: stored ?? ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
  );
  int gets = 0;
  int lists = 0;
  final published = <ReplyAudience>[];

  @override
  bool get canChooseReplyAudience => canChoose;

  @override
  Future<ArticleRecord> create() async => record;

  @override
  Future<ArticleRecord> get(String id) async {
    gets++;
    return record;
  }

  @override
  Future<ArticlePage> list({
    required bool published,
    String pageToken = '',
  }) async {
    lists++;
    return ArticlePage([record]);
  }

  @override
  Future<ArticleRecord> save(
    ArticleDraft draft, {
    required int expectedRevision,
  }) async => record = ArticleRecord(
    draft: draft.revise(expectedRevision: expectedRevision),
    updatedAt: DateTime.now().toUtc(),
  );

  @override
  Future<void> delete(ArticleRecord article) async {}

  @override
  Future<ArticleRecord> publish(
    ArticleRecord article, {
    required String idempotencyKey,
    String caption = '',
    ReplyAudience replyAudience = ReplyAudience.everyone,
  }) async {
    published.add(replyAudience);
    return record = ArticleRecord(
      draft: article.draft,
      updatedAt: article.updatedAt,
      postId: 'post',
    );
  }
}

const _tabletFlags = {kFeatureUiShell, kFeatureUiTablet};

const _modes = <String, Set<String>>{
  'neither': {},
  'ui_shell only': {kFeatureUiShell},
  'ui_tablet only': {kFeatureUiTablet},
  'ui_shell + ui_tablet': _tabletFlags,
};

const _editPath = '/compose/articles/edit/draft';

/// The article editor and library on the tablet layout (tablet plan section
/// 4.1, Article row; 5.4; 6 item 5): the library beside the page from 840
/// dp, `clamp(0.4 * W, 320, 400)` wide, with "Publish settings" on top of it
/// in band B (and then not in the publish dialog). Phones, band A, desktop
/// and either flag off keep today's 1200 dp / 350 library and the dialog's
/// settings.
void main() {
  Future<GoRouter> open(
    WidgetTester tester,
    _Repo repo, {
    String location = _editPath,
    double width = 1024,
    double height = 768,
    Set<String> flags = _tabletFlags,
    double textScale = 1,
    EdgeInsets padding = EdgeInsets.zero,
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    tester.view.padding = FakeViewPadding(
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
    );
    addTearDown(tester.view.reset);
    final onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
      ),
    );
    // The app's article routes (`AppRouter`), without the auth gate.
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
        for (final suffix in ['', '/edit/:id', '/edit/:id/focus'])
          GoRoute(
            path: '/compose/articles$suffix',
            builder: (_, state) => ArticlesScreen(
              articleId: state.pathParameters['id'],
              focus: suffix.endsWith('/focus'),
            ),
          ),
        GoRoute(
          path: '/articles/:id',
          builder: (_, state) => ArticlesScreen(
            articleId: state.pathParameters['id'],
            reader: true,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      RepositoryProvider<ArticlesRepository>.value(
        value: repo,
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(
            routerConfig: router,
            theme: appLightTheme,
            builder: (context, child) => Directionality(
              textDirection: textDirection,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> resize(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, tester.view.physicalSize.height);
    await tester.pumpAndSettle();
  }

  /// The library beside the page (its "Create article" button; the page's
  /// own header has none in the editor).
  Finder library() => find.byTooltip('Create article');

  /// The library's width: where the divider beside it starts.
  double libraryWidth(WidgetTester tester) =>
      tester.getTopLeft(find.byType(VerticalDivider)).dx;

  Finder paneSettings() => find.text('Publish settings');

  Finder dialog() => find.byType(AlertDialog);

  Finder inDialog(Finder finder) =>
      find.descendant(of: dialog(), matching: finder);

  Future<void> openPublish(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Publish').first);
    await tester.pumpAndSettle();
    expect(find.text('Publish Article'), findsOneWidget);
  }

  group('the library beside the editor, by width and flag mode', () {
    for (final MapEntry(key: mode, value: flags) in _modes.entries) {
      for (final width in <double>[
        599,
        600,
        839,
        840,
        1024,
        1199,
        1200,
        1440,
      ]) {
        final tablet = mode == 'ui_shell + ui_tablet' && width < 1200;
        final shown = tablet ? width >= 840 : width >= 1200;
        final paneWidth = tablet
            ? ShellGeometry.listPaneWidthFor(width)
            : AppSize.sideColumn;
        testWidgets('$mode at ${width.toInt()}: '
            '${shown ? 'library ${paneWidth.toInt()}' : 'no library'}', (
          tester,
        ) async {
          final repo = _Repo();
          await open(tester, repo, width: width, flags: flags);
          expect(tester.takeException(), isNull);
          expect(library(), shown ? findsOneWidget : findsNothing);
          if (shown) expect(libraryWidth(tester), paneWidth);
          // Publish settings in the pane only in band B on the tablet layout.
          expect(
            paneSettings(),
            tablet && width >= 840 ? findsOneWidget : findsNothing,
          );
        });
      }
    }
  });

  group('the library index (/compose/articles)', () {
    for (final (width, shown) in [
      (839.0, false),
      (840.0, true),
      (1199.0, true),
      (1440.0, true),
    ]) {
      testWidgets('${width.toInt()}: '
          '${shown ? 'list beside the writing pane' : 'the list only'}', (
        tester,
      ) async {
        await open(
          tester,
          _Repo(),
          location: '/compose/articles',
          width: width,
        );
        expect(
          find.widgetWithText(FilledButton, 'Write'),
          shown ? findsOneWidget : findsNothing,
        );
        if (shown) {
          expect(
            libraryWidth(tester),
            width < 1200
                ? ShellGeometry.listPaneWidthFor(width)
                : AppSize.sideColumn,
          );
        }
      });
    }

    for (final (name, control) in [
      ('Write', find.widgetWithText(FilledButton, 'Write')),
      ('Create article', find.byTooltip('Create article').first),
    ]) {
      testWidgets('$name opens a new article beside the library (band B)', (
        tester,
      ) async {
        final repo = _Repo();
        final router = await open(tester, repo, location: '/compose/articles');
        await tester.tap(control);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, _editPath);
        expect(library(), findsOneWidget);
        expect(paneSettings(), findsOneWidget);
      });
    }

    testWidgets('a row opens the editor beside the library (band B)', (
      tester,
    ) async {
      final router = await open(tester, _Repo(), location: '/compose/articles');
      await tester.tap(find.text('Harbour notes'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, _editPath);
      expect(library(), findsOneWidget);
      expect(paneSettings(), findsOneWidget);
    });
  });

  group('the reader and focus mode never show the library', () {
    testWidgets('reader at 1024', (tester) async {
      await open(tester, _Repo(), location: '/articles/draft');
      expect(library(), findsNothing);
      expect(paneSettings(), findsNothing);
    });

    testWidgets('focus at 1024: the dialog keeps the settings', (tester) async {
      await open(tester, _Repo(), location: '$_editPath/focus');
      expect(library(), findsNothing);
      await openPublish(tester);
      expect(inDialog(find.text('Who can reply?')), findsOneWidget);
      expect(inDialog(find.text('Choose your audience')), findsOneWidget);
    });
  });

  group('publish settings placement (tablet plan section 6, item 5)', () {
    testWidgets('band B: in the pane, not in the dialog; the pane choice is '
        'published', (tester) async {
      final repo = _Repo();
      await open(tester, repo);
      expect(paneSettings(), findsOneWidget);
      expect(find.text('Choose your audience'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<ReplyAudience>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ReplyAudience.following.optionLabel).last);
      await tester.pumpAndSettle();

      await openPublish(tester);
      expect(inDialog(find.text('Who can reply?')), findsNothing);
      expect(inDialog(find.text('Choose your audience')), findsNothing);
      expect(
        inDialog(find.text('Add a caption to your article')),
        findsOneWidget,
      );
      await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Publish')));
      await tester.pumpAndSettle();
      expect(repo.published, [ReplyAudience.following]);
    });

    for (final (name, width, flags) in [
      ('band A', 834.0, _tabletFlags),
      ('desktop', 1440.0, _tabletFlags),
      ('ui_shell only at 1024', 1024.0, {kFeatureUiShell}),
      ('a phone', 390.0, _tabletFlags),
    ]) {
      testWidgets('$name: in the dialog, not in a pane', (tester) async {
        // A phone's dialog (today's, unchanged) cannot fit the reply
        // dropdown's longest choice (a pre-existing overflow, reported in
        // T7): it is checked without the reply control.
        final phone = width < 600;
        final repo = _Repo(canChoose: !phone);
        await open(tester, repo, width: width, height: 900, flags: flags);
        expect(paneSettings(), findsNothing);
        await openPublish(tester);
        expect(
          inDialog(find.text('Who can reply?')),
          phone ? findsNothing : findsOneWidget,
        );
        expect(inDialog(find.text('Choose your audience')), findsOneWidget);
      });
    }

    testWidgets('the pane choice carries into the band A dialog', (
      tester,
    ) async {
      final repo = _Repo();
      await open(tester, repo);
      await tester.tap(find.byType(DropdownButtonFormField<ReplyAudience>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(ReplyAudience.mentionedOnly.optionLabel).last);
      await tester.pumpAndSettle();
      await resize(tester, 834);
      expect(paneSettings(), findsNothing);
      await openPublish(tester);
      expect(
        inDialog(find.text(ReplyAudience.mentionedOnly.optionLabel)),
        findsOneWidget,
      );
      await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Publish')));
      await tester.pumpAndSettle();
      expect(repo.published, [ReplyAudience.mentionedOnly]);
    });

    testWidgets('the open dialog follows the window across 840', (
      tester,
    ) async {
      await open(tester, _Repo(), width: 834);
      await openPublish(tester);
      expect(inDialog(find.text('Who can reply?')), findsOneWidget);
      await resize(tester, 1024);
      expect(inDialog(find.text('Who can reply?')), findsNothing);
      expect(paneSettings(), findsOneWidget);
      await resize(tester, 839);
      expect(inDialog(find.text('Who can reply?')), findsOneWidget);
    });

    testWidgets('a pending publication: the stored choice, read-only', (
      tester,
    ) async {
      final repo = _Repo(
        pending: true,
        stored: ReplyPolicy.REPLY_POLICY_FOLLOWING,
        canChoose: false,
      );
      await open(tester, repo);
      expect(paneSettings(), findsOneWidget);
      final field = tester.widget<DropdownButtonFormField<ReplyAudience>>(
        find.byType(DropdownButtonFormField<ReplyAudience>),
      );
      expect(field.onChanged, isNull);
      expect(find.text(ReplyAudience.following.optionLabel), findsOneWidget);
    });

    testWidgets('without reply_audience: Everyone only, no reply control', (
      tester,
    ) async {
      await open(tester, _Repo(canChoose: false));
      expect(paneSettings(), findsOneWidget);
      expect(find.text('Everyone'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<ReplyAudience>), findsNothing);
    });

    testWidgets('a published article has no publish settings', (tester) async {
      final repo = _Repo();
      repo.record = ArticleRecord(
        draft: repo.record.draft,
        updatedAt: repo.record.updatedAt,
        postId: 'post',
      );
      await open(tester, repo);
      expect(paneSettings(), findsNothing);
    });
  });

  group('the editor survives the library coming and going', () {
    testWidgets('839 -> 840 -> 1199 -> 1200 -> 839: same field, no reload', (
      tester,
    ) async {
      final repo = _Repo();
      await open(tester, repo, width: 839);
      final title = find.byType(EditableText).first;
      await tester.showKeyboard(title);
      await tester.enterText(title, 'Harbour notes, revised');
      await tester.pump();
      final state = tester.state<EditableTextState>(title);
      final gets = repo.gets;
      for (final width in <double>[840, 1199, 1200, 839]) {
        await resize(tester, width);
        expect(
          tester.state<EditableTextState>(find.byType(EditableText).first),
          same(state),
          reason: '$width',
        );
        expect(state.widget.focusNode.hasFocus, isTrue, reason: '$width');
        expect(find.text('Harbour notes, revised'), findsOneWidget);
      }
      expect(repo.gets, gets);
      // The library list was fetched once, the first time it showed.
      expect(repo.lists, 1);
    });
  });

  group('matrix (tablet plan section 5.5)', () {
    for (final width in kTabletMatrixWidths) {
      for (final scale in <double>[1.0, 2.0]) {
        testWidgets('${width.toInt()} x$scale', (tester) async {
          await open(
            tester,
            _Repo(),
            width: width,
            height: width == 1024 ? 1366 : 834,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          expect(library(), width >= 840 ? findsOneWidget : findsNothing);
        });
      }
    }

    testWidgets('a landscape phone in band B (932 x 430) at 2.0', (
      tester,
    ) async {
      await open(tester, _Repo(), width: 932, height: 430, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(paneSettings(), findsOneWidget);
    });

    // A landscape phone has a notch on one side (47 dp): the library at the
    // leading edge and the page at the trailing edge stay clear of it.
    for (final location in [_editPath, '/compose/articles']) {
      for (final direction in TextDirection.values) {
        testWidgets('932 x 430 with side insets, ${direction.name}: '
            '$location', (tester) async {
          await open(
            tester,
            _Repo(),
            location: location,
            width: 932,
            height: 430,
            padding: const EdgeInsets.only(left: 47, right: 47, bottom: 21),
            textDirection: direction,
          );
          expect(tester.takeException(), isNull);
          final row = tester.getRect(find.text('Harbour notes').first);
          final ltr = direction == TextDirection.ltr;
          // The library's row text clears the leading inset ...
          ltr
              ? expect(row.left, greaterThanOrEqualTo(47))
              : expect(row.right, lessThanOrEqualTo(932 - 47));
          // ... and the library is the plan's list pane of C = W - insets.
          final divider = tester.getRect(find.byType(VerticalDivider));
          final pane = ShellGeometry.listPaneWidthFor(932 - 94);
          ltr
              ? expect(divider.left, 47 + pane)
              : expect(divider.right, 932 - 47 - pane);
          // The page beside it clears the trailing inset.
          final write = location == _editPath
              ? find.byType(EditableText).first
              : find.widgetWithText(FilledButton, 'Write');
          final page = tester.getRect(write);
          ltr
              ? expect(page.right, lessThanOrEqualTo(932 - 47))
              : expect(page.left, greaterThanOrEqualTo(47));
        });
      }
    }
  });
}
