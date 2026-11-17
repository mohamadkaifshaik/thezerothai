import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart';
import 'package:dzeroth/shared/widgets/post/article_preview_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

ArticlePreview _article({
  String title = 'A long article title',
  String excerpt = 'The first lines of the article',
  String cover = '',
  int readMinutes = 0,
}) => ArticlePreview(
  articleId: 'a' * 32,
  title: title,
  excerpt: excerpt,
  coverUrl: cover,
  readMinutes: readMinutes,
);

const _cover = 'https://example.test/cover.png';

void main() {
  Future<void> pump(
    WidgetTester tester,
    ArticlePreview article, {
    double width = 390,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    TextDirection direction = TextDirection.ltr,
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: SizedBox(
                  width: width,
                  child: ArticlePreviewCard(article: article),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/articles/:id',
          builder: (_, state) =>
              Scaffold(body: Text('reader ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildAppTheme(brightness: brightness),
        builder: (context, child) => Directionality(
          textDirection: direction,
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        routerConfig: router,
      ),
    );
    await tester.pump();
  }

  Text text(WidgetTester tester, String s) => tester.widget<Text>(find.text(s));

  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      testWidgets('phone with a cover: 16:9 cover above the text', (
        tester,
      ) async {
        await pump(
          tester,
          _article(cover: _cover, readMinutes: 5),
          brightness: brightness,
        );
        expect(find.text('ARTICLE · 5 MIN READ'), findsOneWidget);
        expect(text(tester, 'A long article title').maxLines, 2);
        expect(text(tester, 'The first lines of the article').maxLines, 3);
        final card = tester.getSize(find.byType(Card));
        final cover = tester.getSize(find.byType(ArticleCoverFallback));
        expect(card.width, 390);
        expect(cover.height, closeTo(390 / AppSize.articleCardCoverAspect, 1));
        expect(cover.width, 390);
        expect(tester.takeException(), isNull);
      });

      testWidgets('without a cover: a compact text card, no image', (
        tester,
      ) async {
        await pump(tester, _article(), brightness: brightness);
        expect(find.byType(ArticleCoverFallback), findsNothing);
        expect(tester.getSize(find.byType(Card)).height, lessThan(140));
      });

      testWidgets('tablet/desktop column: cover beside the text', (
        tester,
      ) async {
        await pump(
          tester,
          _article(cover: _cover),
          width: 700,
          brightness: brightness,
        );
        final cover = tester.getRect(find.byType(ArticleCoverFallback));
        final title = tester.getRect(find.text('A long article title'));
        expect(
          cover.width,
          closeTo(700 * AppSize.articleCardWideCoverFraction, 1),
        );
        expect(title.left, greaterThanOrEqualTo(cover.right));
        expect(
          tester.getSize(find.byType(Card)).height,
          greaterThanOrEqualTo(AppSize.articleCardWideMinHeight),
        );
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('long title and excerpt are clamped, not overflowing', (
    tester,
  ) async {
    final longTitle = List.filled(30, 'An extremely long title').join(' ');
    final longExcerpt = List.filled(80, 'excerpt words').join(' ');
    for (final width in [280.0, 390.0, 700.0, 1100.0]) {
      await pump(
        tester,
        _article(title: longTitle, excerpt: longExcerpt, cover: _cover),
        width: width,
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull, reason: 'width $width');
      expect(tester.getSize(find.byType(Card)).width, width);
    }
  });

  testWidgets('very long unbroken text does not overflow', (tester) async {
    final blob = 'x' * 400;
    for (final cover in ['', _cover]) {
      for (final width in [220.0, 390.0, 700.0]) {
        await pump(
          tester,
          _article(title: blob, excerpt: blob, cover: cover),
          width: width,
        );
        expect(tester.takeException(), isNull, reason: '$cover $width');
      }
    }
  });

  testWidgets('RTL text and layout do not overflow', (tester) async {
    for (final width in [390.0, 700.0]) {
      await pump(
        tester,
        _article(
          title: 'عنوان مقال طويل جدا ' * 8,
          excerpt: 'ملخص ' * 60,
          cover: _cover,
        ),
        width: width,
        direction: TextDirection.rtl,
      );
      expect(tester.takeException(), isNull, reason: 'width $width');
    }
  });

  testWidgets('empty title and excerpt: fallback title, no excerpt line', (
    tester,
  ) async {
    await pump(tester, _article(title: '  ', excerpt: ' '));
    expect(find.text(articleCardUntitled), findsOneWidget);
    expect(find.text('ARTICLE'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Card), matching: find.byType(Text)),
      findsNWidgets(2),
    );
  });

  test('label: bare when the read time is unknown, minutes when known', () {
    expect(articleCardLabel(0), 'ARTICLE');
    expect(articleCardLabel(3), 'ARTICLE · 3 MIN READ');
  });

  testWidgets('tap opens the reader', (tester) async {
    await pump(tester, _article());
    await tester.tap(find.text('A long article title'));
    await tester.pumpAndSettle();
    expect(find.text('reader ${'a' * 32}'), findsOneWidget);
  });
}
