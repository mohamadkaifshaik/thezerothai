import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:dzeroth/features/articles/domain/articles_repository.dart';
import 'package:dzeroth/features/articles/presentation/article_text_controller.dart';
import 'package:dzeroth/features/articles/presentation/articles_screen.dart';
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
  int saves = 0;
  String? publishKey;
  bool failSave = false;
  @override
  Future<ArticleRecord> create() async => record;
  @override
  Future<ArticleRecord> get(String id) async => record;
  @override
  Future<ArticlePage> list({
    required bool published,
    String pageToken = '',
  }) async => ArticlePage([record]);
  @override
  Future<void> delete(ArticleRecord article) async {}
  @override
  Future<ArticleRecord> save(
    ArticleDraft draft, {
    required int expectedRevision,
  }) async {
    saves++;
    if (failSave) throw StateError('offline');
    expect(expectedRevision, record.draft.revision);
    record = ArticleRecord(
      draft: draft.revise(expectedRevision: expectedRevision),
      updatedAt: DateTime.now().toUtc(),
    );
    return record;
  }

  @override
  Future<ArticleRecord> publish(
    ArticleRecord article, {
    required String idempotencyKey,
    String caption = '',
    String replyPolicy = 'everyone',
  }) async {
    publishKey = idempotencyKey;
    record = ArticleRecord(
      draft: article.draft,
      updatedAt: article.updatedAt,
      postId: 'post',
    );
    return record;
  }
}

void main() {
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
}
