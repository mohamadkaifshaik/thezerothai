import 'dart:typed_data';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart';
import 'package:dzeroth/shared/widgets/post/article_cover_tint.dart';
import 'package:dzeroth/shared/widgets/post/article_preview_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

ArticlePreview _article({String cover = '', int readMinutes = 0}) =>
    ArticlePreview(
      articleId: 'a' * 32,
      title: 'A long article title',
      excerpt: 'The first lines of the article',
      coverUrl: cover,
      readMinutes: readMinutes,
    );

double _contrastWithWhite(Color c) => 1.05 / (c.computeLuminance() + 0.05);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    String cover = '',
    ArticleTintLoader? loader,
    Brightness brightness = Brightness.light,
    double width = 390,
    int readMinutes = 0,
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: ArticlePreviewCard(
                  article: _article(cover: cover, readMinutes: readMinutes),
                  tintLoader: loader ?? (_) async => null,
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
        routerConfig: router,
      ),
    );
    await tester.pump();
  }

  LinearGradient? gradientOf(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const ValueKey('article-card-overlay')),
        matching: find.byType(DecoratedBox),
      ),
    );
    return (box.decoration as BoxDecoration).gradient as LinearGradient?;
  }

  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      testWidgets('with a cover: 4:5 card, white text on the tinted overlay', (
        tester,
      ) async {
        await pump(
          tester,
          cover: 'https://example.test/cover.png',
          loader: (_) async => const Color(0xFF203040),
          brightness: brightness,
        );

        expect(find.text('ARTICLE'), findsOneWidget);
        expect(find.text('A long article title'), findsOneWidget);
        expect(find.text('The first lines of the article'), findsOneWidget);
        // The cover fills the whole card: 390 wide, 4:5 tall.
        final card = tester.getSize(find.byType(Card));
        expect(card.height, closeTo(390 / AppSize.postMediaPortraitAspect, 1));
        // The overlay covers the lower part, at least 55 %.
        final overlay = tester.getSize(
          find.byKey(const ValueKey('article-card-overlay')),
        );
        expect(
          overlay.height,
          greaterThanOrEqualTo(
            card.height * AppSize.articleCardOverlayFraction,
          ),
        );
        // The gradient: transparent to the tint at 90 %.
        final g = gradientOf(tester)!;
        expect(g.colors.first.a, 0);
        expect(
          g.colors.last.a,
          closeTo(AppSize.articleCardOverlayOpacity, 0.01),
        );
        expect(g.colors.last.withValues(alpha: 1), const Color(0xFF203040));
        // White title, the same in both themes.
        expect(
          tester.widget<Text>(find.text('A long article title')).style!.color,
          AppPalette.white,
        );
        expect(
          tester.widget<Text>(find.text('A long article title')).maxLines,
          3,
        );
        expect(
          tester
              .widget<Text>(find.text('The first lines of the article'))
              .maxLines,
          2,
        );
      });

      testWidgets('tint unknown or failed: a near-black scrim', (tester) async {
        await pump(
          tester,
          cover: 'https://example.test/cover.png',
          loader: (_) async => throw StateError('decode failed'),
          brightness: brightness,
        );
        await tester.pump();

        final g = gradientOf(tester)!;
        expect(g.colors.last.withValues(alpha: 1), AppPalette.navyDeep);
        expect(find.text('A long article title'), findsOneWidget);
      });

      testWidgets('without a cover: the text on the dark brand surface', (
        tester,
      ) async {
        await pump(tester, brightness: brightness);

        expect(find.byKey(const ValueKey('article-card-surface')), findsOne);
        expect(
          find.byKey(const ValueKey('article-card-overlay')),
          findsNothing,
        );
        expect(find.text('ARTICLE'), findsOneWidget);
        expect(find.text('The first lines of the article'), findsOneWidget);
        expect(
          tester.getSize(find.byType(Card)).height,
          greaterThanOrEqualTo(AppSize.articleCardMinHeight),
        );
      });
    });
  }

  testWidgets('the cover is capped in height on a wide column', (tester) async {
    await pump(
      tester,
      cover: 'https://example.test/cover.png',
      width: 800,
      loader: (_) async => const Color(0xFF203040),
    );
    expect(
      tester.getSize(find.byType(Card)).height,
      AppSize.postMediaMaxSingleHeight,
    );
  });

  testWidgets('tap opens the reader and the semantics label is kept', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, cover: 'https://example.test/cover.png');
    expect(
      find.bySemanticsLabel('Read article: A long article title'),
      findsOneWidget,
    );
    await tester.tap(find.text('A long article title'));
    await tester.pumpAndSettle();
    expect(find.text('reader ${'a' * 32}'), findsOneWidget);
    handle.dispose();
  });

  group('overlay tint', () {
    test('averages the pixels, weighted by alpha', () {
      final rgba = Uint8List.fromList([
        200, 0, 0, 255, //
        0, 0, 200, 255,
        0, 255, 0, 0, // transparent: ignored
      ]);
      expect(averageColorOfRgba(rgba), const Color(0xFF640064));
      expect(averageColorOfRgba(Uint8List.fromList([1, 2, 3, 0])), isNull);
    });

    test('is dark enough for white text (AA) whatever the cover colour', () {
      for (final c in const [
        Color(0xFFFFFFFF),
        Color(0xFFFFE600),
        Color(0xFF12B8A6),
        Color(0xFFF5C0C0),
        Color(0xFF000000),
      ]) {
        final tint = articleOverlayTint(c);
        expect(
          _contrastWithWhite(tint),
          greaterThanOrEqualTo(4.5),
          reason: '$c',
        );
      }
    });

    test('keeps the hue of a dark cover', () {
      expect(
        articleOverlayTint(const Color(0xFF102040)),
        const Color(0xFF102040),
      );
    });
  });

  group('read time label', () {
    test('bare label when the read time is unknown (0)', () {
      expect(articleCardLabel(0), 'ARTICLE');
    });

    test('adds the minutes when known', () {
      expect(articleCardLabel(1), 'ARTICLE · 1 MIN READ');
      expect(articleCardLabel(12), 'ARTICLE · 12 MIN READ');
    });

    testWidgets('the card shows and speaks the read time', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, readMinutes: 5);

      expect(find.text('ARTICLE · 5 MIN READ'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('5 minute read')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('an old post (0) shows the bare label', (tester) async {
      await pump(tester);

      expect(find.text('ARTICLE'), findsOneWidget);
      expect(find.textContaining('MIN READ'), findsNothing);
    });
  });
}
