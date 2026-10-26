import 'dart:ui' as ui;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post_action_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
    testWidgets('showDisabled false hides actions without a callback', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            showDisabled: false,
            actions: PostActions(onLike: () {}, onRepost: () {}),
          ),
        ),
      );

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      expect(find.byIcon(Icons.ios_share), findsNothing);
    });

    testWidgets('shows compact counts; counted actions are evenly spaced and '
        'Share is right-aligned', (tester) async {
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
      expect(find.byType(InkResponse), findsNWidgets(4));
      final lefts = [
        Icons.chat_bubble_outline,
        Icons.repeat,
        Icons.favorite_border,
      ].map((icon) => tester.getTopLeft(find.byIcon(icon)).dx).toList();
      // Equal slots: the 3 counted actions share the width left of Share.
      expect(lefts[1] - lefts[0], closeTo(lefts[2] - lefts[1], 1));
      final bar = tester.getRect(find.byType(PostActionBar));
      final share = tester.getRect(find.byIcon(Icons.ios_share));
      // Share's icon is flush with the right edge (the card's padding).
      expect(bar.right - share.right, closeTo(0, 1));
      expect(share.width, 16);
    });

    testWidgets('Bookmark appears only with a callback; right-aligned, '
        'outline then filled accent, labelled and selected', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        _host(PostActionBar(actions: PostActions(onLike: () {}))),
      );
      expect(find.byIcon(Icons.bookmark_border), findsNothing);

      await tester.pumpWidget(
        _host(
          PostActionBar(
            showDisabled: false,
            actions: PostActions(onLike: () {}, onBookmark: () => taps++),
          ),
        ),
      );
      final bar = tester.getRect(find.byType(PostActionBar));
      final icon = tester.getRect(find.byIcon(Icons.bookmark_border));
      expect(bar.right - icon.right, closeTo(0, 1));
      expect(icon.width, 16);
      final off = tester.getSemantics(find.bySemanticsLabel('Bookmark'));
      expect(off.rect.size.shortestSide, greaterThanOrEqualTo(48));
      await tester.tap(find.byIcon(Icons.bookmark_border));
      expect(taps, 1);

      await tester.pumpWidget(
        _host(
          PostActionBar(
            showDisabled: false,
            bookmarked: true,
            actions: PostActions(onLike: () {}, onBookmark: () {}),
          ),
        ),
      );
      expect(find.byIcon(Icons.bookmark_border), findsNothing);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.bookmark)).color,
        appDarkTheme.colorScheme.primary,
      );
      expect(find.bySemanticsLabel('Bookmarked'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Bookmark sits before Share when both are offered', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            actions: PostActions(
              onLike: () {},
              onBookmark: () {},
              onShare: () {},
            ),
          ),
        ),
      );
      final bookmark = tester.getRect(find.byIcon(Icons.bookmark_border));
      final share = tester.getRect(find.byIcon(Icons.ios_share));
      final like = tester.getRect(find.byIcon(Icons.favorite_border));
      expect(like.right, lessThan(bookmark.left));
      expect(bookmark.right, lessThan(share.left));
      final bar = tester.getRect(find.byType(PostActionBar));
      expect(bar.right - share.right, closeTo(0, 1));
    });

    testWidgets('liked and reposted use the like / repost colours and are '
        'announced as selected', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          PostActionBar(
            actions: PostActions(onLike: () {}, onRepost: () {}),
            liked: true,
            reposted: true,
            likeCount: 1,
          ),
        ),
      );

      final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
      expect(icons.map((i) => i.color), contains(AppColors.dark.like));
      expect(icons.map((i) => i.color), contains(AppColors.dark.repost));
      final like = tester.getSemantics(find.bySemanticsLabel('Unlike, 1'));
      expect(like.flagsCollection.isSelected, ui.Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('two visible actions share the left half, not the edges', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            showDisabled: false,
            actions: PostActions(onLike: () {}, onRepost: () {}),
          ),
        ),
      );

      final repost = tester.getTopLeft(find.byIcon(Icons.repeat)).dx;
      final like = tester.getTopLeft(find.byIcon(Icons.favorite_border)).dx;
      final bar = tester.getRect(find.byType(PostActionBar));
      expect(like - repost, closeTo(bar.width / 2, 1));
      expect(like, lessThan(bar.left + bar.width * 0.6));
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

    List<String?> shownUrls(WidgetTester tester) => [
      for (final w in tester.widgetList<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      ))
        w.imageUrl,
    ];

    final full = common.MediaRef(
      url: 'https://m.test/full.webp',
      thumbUrl: 'https://m.test/thumb.webp',
      width: 4,
      height: 3,
    );

    testWidgets('lists show the thumbnail, never the full image', (
      tester,
    ) async {
      await tester.pumpWidget(_host(PostMedia(media: [full, full])));
      expect(shownUrls(tester), everyElement('https://m.test/thumb.webp'));
      expect(shownUrls(tester), hasLength(2));
    });

    testWidgets('review #110 M2: a list tile with no thumbnail is a '
        'placeholder, not the full image', (tester) async {
      final noThumb = common.MediaRef(url: 'https://m.test/full.webp');
      await tester.pumpWidget(_host(PostMedia(media: [noThumb])));
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.byType(AspectRatio), findsOneWidget);
    });

    testWidgets('the detail view shows the full image', (tester) async {
      await tester.pumpWidget(
        _host(PostMedia(media: [full], useFullImage: true)),
      );
      expect(shownUrls(tester), ['https://m.test/full.webp']);
    });

    testWidgets('the detail view falls back to the thumbnail when url is '
        'missing', (tester) async {
      final onlyThumb = common.MediaRef(thumbUrl: 'https://m.test/t.webp');
      await tester.pumpWidget(
        _host(PostMedia(media: [onlyThumb], useFullImage: true)),
      );
      expect(shownUrls(tester), ['https://m.test/t.webp']);
    });
  });
}
