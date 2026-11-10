import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:dzeroth/features/articles/domain/articles_repository.dart';
import 'package:dzeroth/features/articles/presentation/article_text_controller.dart';
import 'package:dzeroth/features/articles/presentation/articles_screen.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/core/theme/app_theme.dart';

const _screenshots = bool.fromEnvironment('ARTICLE_SCREENSHOTS');
String _materialIconFont() {
  final override = Platform.environment['ARTICLE_ICON_FONT'];
  if (override != null) return override;
  final sdk = Platform.environment['FLUTTER_ROOT'];
  if (sdk != null) {
    return '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    final candidate = File(
      '${directory.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError(
    'Set ARTICLE_ICON_FONT to capture article screenshots on this host.',
  );
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name,
) async {
  if (!_screenshots) return;
  await tester.pumpAndSettle();
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _Repository implements ArticlesRepository {
  ArticleRecord record = ArticleRecord(
    draft: ArticleDraft(id: 'draft', authorId: 'owner'),
    updatedAt: DateTime.now().toUtc(),
  );
  ArticlePage? page;
  int saves = 0;
  int gets = 0;
  // When set, get() waits for it (a slow GetArticle).
  Completer<void>? getGate;
  String? publishKey;
  bool failSave = false;
  bool failGet = false;
  // Commit the save, then lose the reply (the client sees a network error).
  bool loseReply = false;
  // When set, create() is refused with it (e.g. the server's draft cap).
  Object? createError;
  int creates = 0;
  @override
  Future<ArticleRecord> create() async {
    creates++;
    if (createError case final error?) throw error;
    return record;
  }

  @override
  Future<ArticleRecord> get(String id) async {
    gets++;
    await getGate?.future;
    if (failGet) throw StateError('offline');
    return record;
  }

  @override
  Future<ArticlePage> list({
    required bool published,
    String pageToken = '',
  }) async => page ?? ArticlePage([record]);
  @override
  Future<void> delete(ArticleRecord article) async {}
  @override
  Future<ArticleRecord> save(
    ArticleDraft draft, {
    required int expectedRevision,
  }) async {
    saves++;
    if (failSave) throw StateError('offline');
    // The server's revision CAS.
    if (expectedRevision != record.draft.revision) {
      throw const ArticleRevisionConflict();
    }
    record = ArticleRecord(
      draft: draft.revise(expectedRevision: expectedRevision),
      updatedAt: DateTime.now().toUtc(),
    );
    if (loseReply) {
      loseReply = false;
      throw StateError('connection lost after commit');
    }
    return record;
  }

  @override
  bool canChooseReplyAudience = false;
  final publishedAudiences = <ReplyAudience>[];
  // When set, publish() is refused with it (and the record is unchanged).
  Object? publishError;

  @override
  Future<ArticleRecord> publish(
    ArticleRecord article, {
    required String idempotencyKey,
    String caption = '',
    ReplyAudience replyAudience = ReplyAudience.everyone,
  }) async {
    publishKey = idempotencyKey;
    publishedAudiences.add(replyAudience);
    if (publishError case final error?) {
      // What the real repository does with FEATURE_DISABLED reply_audience:
      // the posts gate remembers it until the next GetMe.
      if (error is FeatureDisabledException &&
          error.feature == kFeatureReplyAudience) {
        canChooseReplyAudience = false;
      }
      throw error;
    }
    record = ArticleRecord(
      draft: article.draft,
      updatedAt: article.updatedAt,
      postId: 'post',
    );
    return record;
  }
}

void main() {
  for (final pushed in [false, true]) {
    testWidgets('library Back leaves articles (pushed: $pushed)', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: pushed ? '/profile' : '/compose/articles',
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('Home')),
          ),
          GoRoute(
            path: '/profile',
            builder: (_, _) => const Scaffold(body: Text('Profile')),
          ),
          GoRoute(
            path: '/compose/articles',
            builder: (_, _) => const ArticlesScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepositoryProvider<ArticlesRepository>.value(
          value: _Repository(),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      if (pushed) router.push('/compose/articles');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        pushed ? '/profile' : '/home',
      );
    });
  }

  testWidgets('library rows show the server excerpt of body-less records', (
    tester,
  ) async {
    final repository = _Repository()
      ..page = ArticlePage([
        ArticleRecord(
          draft: ArticleDraft(id: 'listed', authorId: 'owner', title: 'Listed'),
          updatedAt: DateTime.now().toUtc(),
          excerpt: 'Only the excerpt travels in a list',
        ),
      ]);
    await tester.pumpWidget(
      RepositoryProvider<ArticlesRepository>.value(
        value: repository,
        child: const MaterialApp(home: ArticlesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Only the excerpt travels in a list'),
      findsOneWidget,
    );
  });

  testWidgets('wide library has a writing pane and collapses on phones', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepositoryProvider<ArticlesRepository>.value(
        value: _Repository(),
        child: const MaterialApp(home: ArticlesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Drafts'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Write'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('This is where you write')).dx,
      greaterThan(350),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    expect(find.text('Drafts'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Write'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor saves before publication and opens the reader', (
    tester,
  ) async {
    if (_screenshots) {
      final windowsDirectory = Platform.environment['WINDIR'];
      final textFont =
          Platform.environment['ARTICLE_TEXT_FONT'] ??
          (windowsDirectory == null
              ? throw StateError(
                  'Set ARTICLE_TEXT_FONT to capture article screenshots on this host.',
                )
              : '$windowsDirectory/Fonts/arial.ttf');
      final iconFont = _materialIconFont();
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(File(textFont).readAsBytesSync())),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(File(iconFont).readAsBytesSync())),
        );
      await icons.load();
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    final boundaryKey = GlobalKey();
    final repository = _Repository();
    final router = GoRouter(
      initialLocation: '/compose/articles/edit/draft',
      routes: [
        GoRoute(
          path: '/compose/articles/edit/:id',
          builder: (_, state) =>
              ArticlesScreen(articleId: state.pathParameters['id']),
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
        value: repository,
        child: RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: appLightTheme,
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('article-title')),
      'My article',
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.controller is ArticleTextController,
      ),
      'Article body',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repository.record.draft.title, 'My article');
    expect(repository.record.draft.plainText, 'Article body');
    expect(find.text('Saved'), findsOneWidget);
    await _capture(tester, boundaryKey, 'articles-editor-wide');
    if (_screenshots) {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await _capture(tester, boundaryKey, 'articles-editor-phone');
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Publish').first);
    await tester.pumpAndSettle();
    expect(find.text('Publish Article'), findsOneWidget);
    await _capture(tester, boundaryKey, 'articles-publish-wide');
    await tester.tap(find.widgetWithText(FilledButton, 'Publish').last);
    await tester.pumpAndSettle();
    expect(repository.publishKey, isNotEmpty);
    expect(router.routeInformationProvider.value.uri.path, '/articles/draft');
    expect(find.text('My article'), findsOneWidget);
    await _capture(tester, boundaryKey, 'articles-reader-wide');
    if (_screenshots) {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await _capture(tester, boundaryKey, 'articles-reader-phone');
    }
  });
  Future<void> pumpEditor(WidgetTester tester, _Repository repository) async {
    await tester.pumpWidget(
      RepositoryProvider<ArticlesRepository>.value(
        value: repository,
        child: const MaterialApp(home: ArticlesScreen(articleId: 'draft')),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder bodyField() => find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.controller is ArticleTextController,
  );

  testWidgets('a lost save reply adopts the server revision and continues', (
    tester,
  ) async {
    final repository = _Repository()..loseReply = true;
    await pumpEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('article-title')), 'Mine');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    // The save committed (revision 1) but the editor never heard back.
    expect(repository.record.draft.revision, 1);
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    // Retry was refused as stale; the server holds exactly what was sent.
    expect(repository.gets, 2);
    expect(find.byKey(const Key('article-conflict')), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
    // Editing continues from the adopted revision.
    await tester.enterText(find.byKey(const Key('article-title')), 'Mine 2');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repository.record.draft.revision, 2);
    expect(repository.record.draft.title, 'Mine 2');
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('typing while the conflict read is in flight saves once, '
      'on the adopted revision', (tester) async {
    final repository = _Repository()..loseReply = true;
    await pumpEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('article-title')), 'Mine');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repository.record.draft.revision, 1);
    repository.getGate = Completer<void>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    // The stale retry was refused; GetArticle is still in flight.
    await tester.enterText(
      find.byKey(const Key('article-title')),
      'Mine, continued',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(repository.saves, 2); // no save while the read is pending
    repository.getGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('article-conflict')), findsNothing);
    expect(repository.saves, 3);
    expect(repository.record.draft.revision, 2);
    expect(repository.record.draft.title, 'Mine, continued');
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a failed Reload keeps the conflict and the local text', (
    tester,
  ) async {
    final repository = _Repository();
    await pumpEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('article-title')), 'Mine');
    repository.record = ArticleRecord(
      draft: ArticleDraft(
        id: 'draft',
        authorId: 'owner',
        revision: 4,
        title: 'Theirs',
      ),
      updatedAt: DateTime.now().toUtc(),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('article-conflict')), findsOneWidget);
    repository.failGet = true;
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('article-conflict')), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Unsaved changes'), findsOneWidget);
  });

  testWidgets('a change elsewhere offers Keep mine without dropping blocks', (
    tester,
  ) async {
    final repository = _Repository();
    await pumpEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('article-title')), 'Mine');
    await tester.enterText(bodyField(), 'My local body');
    // Another device saves first.
    repository.record = ArticleRecord(
      draft: ArticleDraft(
        id: 'draft',
        authorId: 'owner',
        revision: 4,
        title: 'Theirs',
      ),
      updatedAt: DateTime.now().toUtc(),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('article-conflict')), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
    // Autosave pauses: further edits do not hammer the stale revision.
    final saves = repository.saves;
    await tester.enterText(bodyField(), 'My local body, edited');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repository.saves, saves);
    expect(find.text('My local body, edited'), findsOneWidget);
    await tester.tap(find.text('Keep mine'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('article-conflict')), findsNothing);
    expect(repository.record.draft.revision, 5);
    expect(repository.record.draft.title, 'Mine');
    expect(repository.record.draft.plainText, 'My local body, edited');
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a change elsewhere can be reloaded on request', (tester) async {
    final repository = _Repository();
    await pumpEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('article-title')), 'Mine');
    repository.record = ArticleRecord(
      draft: ArticleDraft(
        id: 'draft',
        authorId: 'owner',
        revision: 4,
        title: 'Theirs',
      ),
      updatedAt: DateTime.now().toUtc(),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('article-conflict')), findsOneWidget);
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('article-conflict')), findsNothing);
    expect(find.text('Theirs'), findsOneWidget);
    expect(repository.record.draft.revision, 4);
  });

  testWidgets('an over-limit body is kept locally and never sent', (
    tester,
  ) async {
    final repository = _Repository();
    await pumpEditor(tester, repository);
    // 60,001 CJK characters: under the code-point limit, over the byte cap.
    final long = '語' * 60001;
    await tester.enterText(bodyField(), long);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repository.saves, 0);
    expect(
      find.textContaining('of $articleMaxBodyBytes bytes'),
      findsOneWidget,
    );
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(find.text(long), findsOneWidget);
    // Shortening it saves normally.
    await tester.enterText(bodyField(), '語' * 100);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repository.saves, 1);
    expect(find.text('Saved'), findsOneWidget);
  });

  const draftCap = LimitReachedException(
    'server copy',
    quota: kArticleDraftsLimit,
  );

  testWidgets('the draft cap on New article shows the cap message and can '
      'be dismissed', (tester) async {
    final repository = _Repository()..createError = draftCap;
    await tester.pumpWidget(
      RepositoryProvider<ArticlesRepository>.value(
        value: repository,
        child: const MaterialApp(home: ArticlesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create article'));
    await tester.pumpAndSettle();
    expect(repository.creates, 1);
    expect(find.text(articleDraftLimitMessage), findsOneWidget);
    expect(
      articleDraftLimitMessage,
      'You have 50 drafts. Publish or delete one to start a new draft.',
    );
    // Retrying cannot help: the banner only dismisses.
    expect(find.text('Retry'), findsNothing);
    // Non-blocking: the library stays usable.
    expect(find.text('Drafts'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text(articleDraftLimitMessage), findsNothing);
  });

  testWidgets('the draft cap refusing New article from the editor keeps '
      'the text in the editor', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository()..createError = draftCap;
    await pumpEditor(tester, repository);
    await tester.enterText(find.byKey(const Key('article-title')), 'Mine');
    await tester.enterText(bodyField(), 'My unsaved body');
    // New article before the autosave fired: the open draft (an existing id,
    // never refused) saves first, then the new draft is refused.
    await tester.tap(find.byTooltip('Create article'));
    await tester.pumpAndSettle();
    expect(repository.creates, 1);
    expect(find.text(articleDraftLimitMessage), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('article-title')))
          .controller!
          .text,
      'Mine',
    );
    expect(find.text('My unsaved body'), findsOneWidget);
    expect(repository.record.draft.title, 'Mine');
    expect(repository.record.draft.plainText, 'My unsaved body');
    expect(find.text('Saved'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('other limits keep the server message', (tester) async {
    final repository = _Repository()
      ..createError = const LimitReachedException('server says no');
    await tester.pumpWidget(
      RepositoryProvider<ArticlesRepository>.value(
        value: repository,
        child: const MaterialApp(home: ArticlesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create article'));
    await tester.pumpAndSettle();
    expect(find.text('server says no'), findsOneWidget);
    expect(find.text(articleDraftLimitMessage), findsNothing);
  });

  testWidgets('failed autosave remains unsaved and offers retry', (
    tester,
  ) async {
    final repository = _Repository()..failSave = true;
    await tester.pumpWidget(
      RepositoryProvider<ArticlesRepository>.value(
        value: repository,
        child: const MaterialApp(home: ArticlesScreen(articleId: 'draft')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('article-title')), 'Unsaved');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    repository.failSave = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect(repository.record.draft.title, 'Unsaved');
  });

  group('publish reply audience', () {
    const restricted = ['Accounts you follow', 'Only accounts you mention'];
    _Repository publishable({
      bool pending = false,
      ReplyPolicy stored = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    }) => _Repository()
      ..record = ArticleRecord(
        draft: ArticleDraft(
          id: 'draft',
          authorId: 'owner',
          title: 'Title',
          blocks: [
            ArticleBlock(
              kind: ArticleBlockKind.paragraph,
              runs: [ArticleTextRun(text: 'Body')],
            ),
          ],
        ),
        updatedAt: DateTime.now().toUtc(),
        publicationPending: pending,
        publicationReplyPolicy: stored,
      );
    Future<GoRouter> pumpEditor(
      WidgetTester tester,
      _Repository repository,
    ) async {
      final router = GoRouter(
        initialLocation: '/compose/articles/edit/draft',
        routes: [
          GoRoute(
            path: '/compose/articles/edit/:id',
            builder: (_, state) =>
                ArticlesScreen(articleId: state.pathParameters['id']),
          ),
          GoRoute(
            path: '/articles/:id',
            builder: (_, _) => const Scaffold(body: Text('Reader')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepositoryProvider<ArticlesRepository>.value(
          value: repository,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('Publish').first);
      await tester.pumpAndSettle();
      expect(find.text('Publish Article'), findsOneWidget);
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Publish').last);
      await tester.pumpAndSettle();
    }

    final dropdown = find.byType(DropdownButtonFormField<ReplyAudience>);

    testWidgets('with reply_audience off the dialog offers no restricted '
        'choice and publishes as Everyone', (tester) async {
      // A refused earlier choice is still stored on the record.
      final repository = publishable(
        stored: ReplyPolicy.REPLY_POLICY_FOLLOWING,
      );
      final router = await pumpEditor(tester, repository);
      await openDialog(tester);
      // Like the composer: no reply control at all.
      expect(find.text('Who can reply?'), findsNothing);
      expect(dropdown, findsNothing);
      for (final label in restricted) {
        expect(find.text(label), findsNothing);
      }
      await confirm(tester);
      expect(repository.publishedAudiences, [ReplyAudience.everyone]);
      expect(router.routeInformationProvider.value.uri.path, '/articles/draft');
    });

    for (final audience in ReplyAudience.values) {
      testWidgets('with reply_audience on all three choices are offered and '
          '${audience.name} is published', (tester) async {
        final repository = publishable()..canChooseReplyAudience = true;
        await pumpEditor(tester, repository);
        await openDialog(tester);
        expect(find.text('Who can reply?'), findsOneWidget);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        for (final label in ['Everyone', ...restricted]) {
          expect(find.text(label), findsWidgets);
        }
        await tester.tap(find.text(audience.optionLabel).last);
        await tester.pumpAndSettle();
        await confirm(tester);
        expect(repository.publishedAudiences, [audience]);
      });
    }

    testWidgets('FEATURE_DISABLED reply_audience mid-session shows the '
        'reply-audience copy and the next try offers only Everyone', (
      tester,
    ) async {
      final repository = publishable()
        ..canChooseReplyAudience = true
        ..publishError = const FeatureDisabledException(
          'server says no',
          feature: kFeatureReplyAudience,
        );
      final router = await pumpEditor(tester, repository);
      await openDialog(tester);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accounts you follow').last);
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(find.text(kReplyAudienceUnavailableMessage), findsOneWidget);
      expect(find.text('server says no'), findsNothing);
      repository.publishError = null;
      await openDialog(tester);
      expect(dropdown, findsNothing);
      await confirm(tester);
      expect(repository.publishedAudiences, [
        ReplyAudience.following,
        ReplyAudience.everyone,
      ]);
      expect(router.routeInformationProvider.value.uri.path, '/articles/draft');
    });

    testWidgets('a pending publication shows its stored choice locked even '
        'with the capability gone', (tester) async {
      final repository = publishable(
        pending: true,
        stored: ReplyPolicy.REPLY_POLICY_FOLLOWING,
      );
      await pumpEditor(tester, repository);
      await openDialog(tester);
      expect(find.text('Accounts you follow'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<ReplyAudience>>(
              find.byType(DropdownButton<ReplyAudience>),
            )
            .onChanged,
        isNull,
      );
      await confirm(tester);
      expect(repository.publishedAudiences, [ReplyAudience.following]);
    });
  });
}
