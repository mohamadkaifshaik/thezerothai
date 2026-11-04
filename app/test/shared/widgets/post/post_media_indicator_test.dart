import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/embedded_post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_pager.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

// No thumbUrl: tiles show the placeholder, so no network is touched.
List<common.MediaRef> _images(int n) => [
  for (var i = 0; i < n; i++) common.MediaRef(mediaId: 'm$i', altText: ''),
];

final _current = find.byKey(const ValueKey('media-dot-current'));
final _others = find.byKey(const ValueKey('media-dot'));

Future<void> _pumpMedia(
  WidgetTester tester,
  int n, {
  bool indicator = true,
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  double textScale = 1,
}) => pumpThemed(
  tester,
  Center(
    child: PostMedia(media: _images(n), showPageIndicator: indicator),
  ),
  brightness: brightness,
  size: size,
  textScale: textScale,
);

/// Which dot is highlighted (0-based), by the position of the current dot
/// among all dots.
int _highlighted(WidgetTester tester) {
  final x = tester.getCenter(_current).dx;
  final others = [
    for (final e in _others.evaluate())
      tester.getCenter(find.byWidget(e.widget)).dx,
  ];
  return others.where((o) => o < x).length;
}

void main() {
  for (final n in [2, 3, 4]) {
    testWidgets('$n images without text show $n dots and follow swipes', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpMedia(tester, n);
      expect(_current, findsOneWidget);
      expect(_others, findsNWidgets(n - 1));
      expect(_highlighted(tester), 0);
      expect(find.bySemanticsLabel('Image 1 of $n'), findsOneWidget);

      await swipeToNextMediaPage(tester);
      expect(currentMediaPage(tester), 1);
      expect(_highlighted(tester), 1);
      expect(find.bySemanticsLabel('Image 2 of $n'), findsOneWidget);
      expect(find.bySemanticsLabel('Image 1 of $n'), findsNothing);

      await swipeToPreviousMediaPage(tester);
      expect(_highlighted(tester), 0);
      handle.dispose();
    });
  }

  testWidgets('the dots are not in the semantics tree, only the label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpMedia(tester, 3);
    final node = tester.getSemantics(find.bySemanticsLabel('Image 1 of 3'));
    var children = 0;
    node.visitChildren((_) {
      children++;
      return true;
    });
    expect(children, 0);
    expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  testWidgets('the indicator is off by default', (tester) async {
    await _pumpMedia(tester, 3, indicator: false);
    expect(_current, findsNothing);
    expect(_others, findsNothing);
    expect(mediaPageCount(tester), 3);
  });

  testWidgets('one image never has an indicator', (tester) async {
    await _pumpMedia(tester, 1);
    expect(_current, findsNothing);
    expect(_others, findsNothing);
    expect(mediaPageCount(tester), isNull);
  });

  test('hasNoText trims whitespace', () {
    expect(PostMedia.hasNoText(''), isTrue);
    expect(PostMedia.hasNoText(' \n\t '), isTrue);
    expect(PostMedia.hasNoText(' hi '), isFalse);
  });

  group('PostCard applies the rule', () {
    Future<void> pumpCard(WidgetTester tester, int n, String text) {
      final view = postView(1)
        ..post.text = text
        ..post.media.addAll(_images(n));
      return pumpThemed(
        tester,
        SingleChildScrollView(
          child: PostCard(view: view, graphActionsEnabled: false),
        ),
      );
    }

    testWidgets('no text: dots', (tester) async {
      await pumpCard(tester, 3, '');
      expect(_current, findsOneWidget);
    });

    testWidgets('whitespace-only text: dots', (tester) async {
      await pumpCard(tester, 3, '  \n ');
      expect(_current, findsOneWidget);
    });

    testWidgets('text with images: no dots', (tester) async {
      await pumpCard(tester, 3, 'caption');
      expect(_current, findsNothing);
      expect(mediaPageCount(tester), 3);
    });

    testWidgets('one image: no dots, with or without text', (tester) async {
      await pumpCard(tester, 1, '');
      expect(_current, findsNothing);
      await pumpCard(tester, 1, 'caption');
      expect(_current, findsNothing);
    });
  });

  group('quote embed uses the embedded post text', () {
    Future<void> pumpEmbed(WidgetTester tester, int n, String text) =>
        pumpThemed(
          tester,
          SingleChildScrollView(
            child: EmbeddedPostCard(
              embedded: pb.EmbeddedPost(
                postId: postId(2),
                text: text,
                author: common.AuthorSnapshot(userId: 'u', handle: 'orig'),
                media: _images(n),
              ),
            ),
          ),
        );

    testWidgets('no text: dots', (tester) async {
      await pumpEmbed(tester, 4, '');
      expect(_current, findsOneWidget);
      expect(_others, findsNWidgets(3));
    });

    testWidgets('whitespace-only text: dots', (tester) async {
      await pumpEmbed(tester, 2, '   ');
      expect(_current, findsOneWidget);
    });

    testWidgets('text: no dots', (tester) async {
      await pumpEmbed(tester, 4, 'quoted words');
      expect(_current, findsNothing);
    });

    testWidgets('one image: no dots', (tester) async {
      await pumpEmbed(tester, 1, '');
      expect(_current, findsNothing);
    });
  });

  forEachThemeAndWidth(
    'indicator does not overflow',
    (tester, env) async {
      await _pumpMedia(
        tester,
        4,
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(_current, findsOneWidget);
      // The viewport stays 16:9.
      final size = tester.getSize(find.byType(PageView));
      expect(size.width / size.height, closeTo(16 / 9, 0.05));
    },
    widths: const [320, 360],
    textScales: kMatrixTextScalesLarge,
  );
}
