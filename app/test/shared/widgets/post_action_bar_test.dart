import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {double width = 360}) => MaterialApp(
  theme: appDarkTheme,
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  group('PostActionBar', () {
    testWidgets('shows compact counts and spreads four actions evenly', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            actions: PostActions(onLike: () {}, onReply: () {}),
            replyCount: 3,
            repostCount: 1200,
            likeCount: 2500000,
          ),
        ),
      );

      expect(find.text('3'), findsOneWidget);
      expect(find.text('1.2K'), findsOneWidget);
      expect(find.text('2.5M'), findsOneWidget);
      final row = tester.widget<Row>(find.byType(Row).first);
      expect(row.mainAxisAlignment, MainAxisAlignment.spaceBetween);
      expect(find.byType(InkResponse), findsNWidgets(4));
    });

    testWidgets('dispatches callbacks, has 48dp targets and semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var likes = 0;
      var reposts = 0;
      await tester.pumpWidget(
        _host(
          PostActionBar(
            actions: PostActions(
              onLike: () => likes++,
              onRepost: () => reposts++,
            ),
            likeCount: 7,
            liked: true,
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Unlike, 7'));
      await tester.tap(find.bySemanticsLabel('Repost'));
      expect((likes, reposts), (1, 1));
      for (final target in tester.widgetList<InkResponse>(
        find.byType(InkResponse),
      )) {
        final size = tester.getSize(find.byWidget(target));
        expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
        expect(size.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      }
      handle.dispose();
    });

    testWidgets('no overflow at 320dp with 2x text', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _host(
            PostActionBar(
              actions: const PostActions(),
              replyCount: 999,
              repostCount: 999,
              likeCount: 999,
            ),
            width: 280,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('PostMedia', () {
    common.MediaRef ref({int w = 0, int h = 0, String alt = ''}) =>
        common.MediaRef(width: w, height: h, altText: alt);

    testWidgets('one image keeps its aspect ratio, clamped', (tester) async {
      await tester.pumpWidget(
        _host(PostMedia(media: [ref(w: 100, h: 1000, alt: 'tall')])),
      );
      final aspect = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(aspect.aspectRatio, closeTo(4 / 5, 0.001));
    });

    testWidgets('alt text becomes the semantics label; fallback is Image', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          PostMedia(
            media: [
              ref(alt: 'a cat'),
              ref(),
            ],
          ),
        ),
      );
      expect(find.bySemanticsLabel('a cat'), findsOneWidget);
      expect(find.bySemanticsLabel('Image'), findsOneWidget);
      handle.dispose();
    });

    for (final count in [1, 2, 3, 4, 6]) {
      testWidgets('$count images lay out without overflow', (tester) async {
        await tester.pumpWidget(
          _host(PostMedia(media: [for (var i = 0; i < count; i++) ref()])),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('empty list renders nothing', (tester) async {
      await tester.pumpWidget(_host(const PostMedia(media: [])));
      expect(find.byType(AspectRatio), findsNothing);
    });
  });
}
