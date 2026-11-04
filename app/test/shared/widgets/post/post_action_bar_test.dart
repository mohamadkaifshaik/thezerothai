import 'dart:ui' as ui;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_pager.dart';

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
    for (final scale in const [1.0, 2.0]) {
      testWidgets('spread with real counts fits 328dp at text x$scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: _host(
              width: 328,
              PostActionBar(
                spread: true,
                iconSize: AppFocalPost.actionIcon,
                replyCount: 272,
                repostCount: 38,
                likeCount: 134,
                bookmarked: true,
                actions: PostActions(
                  onReply: () {},
                  onRepost: () {},
                  onLike: () {},
                  onBookmark: () {},
                  onShare: () {},
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.ios_share), findsOneWidget);
        if (scale == 1.0) expect(find.text('272'), findsOneWidget);
      });
    }

    testWidgets('spread (open post): every action across the width, in order '
        '(Share, then Bookmark last), larger glyphs', (tester) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            spread: true,
            iconSize: AppFocalPost.actionIcon,
            actions: PostActions(
              onReply: () {},
              onRepost: () {},
              onLike: () {},
              onBookmark: () {},
              onShare: () {},
            ),
          ),
        ),
      );

      final icons = [
        Icons.chat_bubble_outline,
        Icons.repeat,
        Icons.favorite_border,
        Icons.ios_share,
        Icons.bookmark_border,
      ];
      final xs = [for (final i in icons) tester.getCenter(find.byIcon(i)).dx];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]));
      }
      // The bar spreads its buttons edge to edge: the first button's box
      // starts at the left edge and the last one (Bookmark) ends at the right.
      final bar = tester.getRect(find.byType(PostActionBar));
      Rect box(IconData icon) => tester.getRect(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(InkResponse),
        ),
      );
      expect(box(Icons.chat_bubble_outline).left, closeTo(bar.left, 0.5));
      expect(box(Icons.bookmark_border).right, closeTo(bar.right, 0.5));
      // Share is no longer the last button: Bookmark follows it.
      expect(
        box(Icons.ios_share).right,
        lessThanOrEqualTo(box(Icons.bookmark_border).left),
      );
      expect(
        tester.getSize(find.byIcon(Icons.repeat)).width,
        AppFocalPost.actionIcon,
      );
    });

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

    testWidgets('shows compact counts; counted actions and Share are evenly '
        'spaced slots, Share is not pushed to the right edge', (tester) async {
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
        Icons.ios_share,
      ].map((icon) => tester.getTopLeft(find.byIcon(icon)).dx).toList();
      // Equal slots: Share takes the fourth, in the same left-aligned place.
      final bar = tester.getRect(find.byType(PostActionBar));
      final slot = bar.width / 4;
      for (var i = 0; i < 4; i++) {
        expect(lefts[i], closeTo(bar.left + i * slot, 1));
      }
      final share = tester.getRect(find.byIcon(Icons.ios_share));
      expect(bar.right - share.right, closeTo(slot - 16, 1));
      expect(share.width, 16);
    });

    testWidgets('Bookmark appears only with a callback; takes the slot after '
        'the other actions, outline then filled accent, labelled and '
        'selected', (tester) async {
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
      // Like and Bookmark: two equal slots, Bookmark in the second (not flush
      // right with a gap in between, as when it was right-aligned).
      final bar = tester.getRect(find.byType(PostActionBar));
      final icon = tester.getRect(find.byIcon(Icons.bookmark_border));
      expect(icon.left - bar.left, closeTo(bar.width / 2, 1));
      expect(
        tester.getTopLeft(find.byIcon(Icons.favorite_border)).dx,
        closeTo(bar.left, 1),
      );
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

    testWidgets('Share sits before Bookmark, each in its own slot after the '
        'counted actions', (tester) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            showDisabled: false,
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
      expect(like.right, lessThan(share.left));
      expect(share.right, lessThan(bookmark.left));
      // Three equal slots (Like, Share, Bookmark), left-aligned in each.
      final bar = tester.getRect(find.byType(PostActionBar));
      final slot = bar.width / 3;
      expect(like.left, closeTo(bar.left, 1));
      expect(share.left, closeTo(bar.left + slot, 1));
      expect(bookmark.left, closeTo(bar.left + 2 * slot, 1));
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

    testWidgets('alt text becomes the semantics label on its own page; '
        'fallback is Image', (tester) async {
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
      // Only the visible page is in the tree, so the second image's label
      // appears once the first has been swiped away.
      expect(currentMediaPage(tester), 0);
      expect(find.bySemanticsLabel('a cat'), findsOneWidget);
      expect(find.bySemanticsLabel('Image'), findsNothing);

      await swipeToNextMediaPage(tester);
      expect(currentMediaPage(tester), 1);
      expect(find.bySemanticsLabel('Image'), findsOneWidget);
      expect(find.bySemanticsLabel('a cat'), findsNothing);
      handle.dispose();
    });

    // One image is a plain tile; 2-4 are pages of a 16:9 viewport (six
    // given, four shown).
    for (final count in [1, 2, 3, 4, 6]) {
      testWidgets(
        '$count images lay out without overflow, as '
        '${count == 1 ? 'a single tile' : '${count > 4 ? 4 : count} pages'}',
        (tester) async {
          await tester.pumpWidget(
            _host(PostMedia(media: [for (var i = 0; i < count; i++) ref()])),
          );
          expect(tester.takeException(), isNull);
          expect(
            mediaPageCount(tester),
            count == 1 ? isNull : (count > 4 ? 4 : count),
          );
          if (count > 1) {
            expect(currentMediaPage(tester), 0);
            expect(
              tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
              closeTo(16 / 9, 0.001),
            );
            for (var page = 1; page < (count > 4 ? 4 : count); page++) {
              await swipeToNextMediaPage(tester);
              expect(currentMediaPage(tester), page);
              expect(tester.takeException(), isNull);
            }
          }
        },
      );
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
      final second = common.MediaRef(
        url: 'https://m.test/full2.webp',
        thumbUrl: 'https://m.test/thumb2.webp',
        width: 4,
        height: 3,
      );
      await tester.pumpWidget(_host(PostMedia(media: [full, second])));
      // Only the visible page is built: its thumbnail, nothing else.
      expect(shownUrls(tester), ['https://m.test/thumb.webp']);

      await swipeToNextMediaPage(tester);
      expect(currentMediaPage(tester), 1);
      expect(shownUrls(tester), ['https://m.test/thumb2.webp']);
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
