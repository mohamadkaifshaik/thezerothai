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
      testWidgets('real counts fit 328dp at text x$scale', (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: _host(
              width: 328,
              PostActionBar(
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

    testWidgets('open post: every action packed from the left, in order '
        '(Share, then Bookmark last), larger glyphs', (tester) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
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

      // The owner's order (2026-11-15): Share, then Bookmark last.
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
      // Compact and left-aligned: the first target starts the bar, each next
      // one starts where the last ends, and every target is 48 dp.
      final bar = tester.getRect(find.byType(PostActionBar));
      Rect box(IconData icon) => tester.getRect(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(InkResponse),
        ),
      );
      expect(box(icons.first).left, closeTo(bar.left, 0.5));
      for (var i = 0; i < icons.length; i++) {
        expect(box(icons[i]).width, greaterThanOrEqualTo(48));
        expect(box(icons[i]).height, greaterThanOrEqualTo(48));
        if (i > 0) {
          expect(box(icons[i]).left, closeTo(box(icons[i - 1]).right, 0.5));
        }
      }
      expect(box(Icons.bookmark_border).right, lessThan(bar.right - 100));
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

    testWidgets('shows compact counts; the four actions are packed, in '
        'order Reply, Repost, Like, Share', (tester) async {
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
      final bar = tester.getRect(find.byType(PostActionBar));
      final boxes = [
        for (final icon in const [
          Icons.chat_bubble_outline,
          Icons.repeat,
          Icons.favorite_border,
          Icons.ios_share,
        ])
          tester.getRect(
            find
                .ancestor(
                  of: find.byIcon(icon),
                  matching: find.byType(InkResponse),
                )
                .first,
          ),
      ];
      // Packed from the left: each glyph starts where the previous target
      // (glyph, count and the 20 dp gap, at least 48 dp) ends.
      expect(lefts[0], closeTo(bar.left, 1));
      for (var i = 1; i < 4; i++) {
        expect(lefts[i], closeTo(boxes[i - 1].right, 1));
        expect(boxes[i].width, greaterThanOrEqualTo(48));
      }
      // A counted item is glyph + 6 + count + 20 wide, not a fixed slot.
      expect(
        boxes[0].width,
        greaterThan(AppIconSize.action + AppSpacing.actionItemGap),
      );
      // 18 dp glyphs (dz.css `.acts`, R1 restyle; was 16).
      expect(
        tester.getSize(find.byIcon(Icons.ios_share)).width,
        AppIconSize.action,
      );
    });

    testWidgets('no press ripple or pressed circle behind the action icons '
        '(hover stays)', (tester) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            actions: PostActions(onLike: () {}, onBookmark: () {}),
          ),
        ),
      );
      final inks = tester.widgetList<InkResponse>(
        find.descendant(
          of: find.byType(PostActionBar),
          matching: find.byType(InkResponse),
        ),
      );
      expect(inks, isNotEmpty);
      for (final ink in inks) {
        expect(ink.splashColor, Colors.transparent);
        expect(ink.highlightColor, Colors.transparent);
        expect(ink.hoverColor, isNull, reason: 'the theme hover stays');
      }
    });

    testWidgets('Bookmark appears only with a callback; packs after '
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
      // Like and Bookmark are packed, 48 dp apart (no Share: it needs a
      // callback or showDisabled; no count, so each target is 48 dp).
      final bar = tester.getRect(find.byType(PostActionBar));
      final icon = tester.getRect(find.byIcon(Icons.bookmark_border));
      expect(icon.left, closeTo(bar.left + AppSpacing.minTapTarget, 1));
      expect(
        tester.getTopLeft(find.byIcon(Icons.favorite_border)).dx,
        closeTo(bar.left, 1),
      );
      expect(icon.width, AppIconSize.action);
      final off = tester.getSemantics(find.bySemanticsLabel('Bookmark'));
      expect(
        off.rect.size.shortestSide,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
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

    testWidgets('Share sits before Bookmark, last, packed '
        'after the counted actions', (tester) async {
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
      // The owner's order (2026-11-15): Like, Share, Bookmark.
      expect(like.right, lessThan(share.left));
      expect(share.right, lessThan(bookmark.left));
      final bar = tester.getRect(find.byType(PostActionBar));
      expect(like.left, closeTo(bar.left, 1));
      expect(share.left, closeTo(bar.left + AppSpacing.minTapTarget, 1));
      expect(bookmark.left, closeTo(bar.left + 2 * AppSpacing.minTapTarget, 1));
    });

    for (final width in const [320.0, 360.0, 400.0]) {
      testWidgets('five items at $width dp with text x1.3: every box is '
          'at least 40 wide and 48 tall, none overlaps', (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: _host(
              width: width - 32,
              PostActionBar(
                replyCount: 1234,
                repostCount: 5678,
                likeCount: 91011,
                shareCount: 1200,
                actions: PostActions(
                  onReply: () {},
                  onRepost: () {},
                  onLike: () {},
                  onShare: () {},
                  onBookmark: () {},
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final boxes = [
          for (final icon in const [
            Icons.chat_bubble_outline,
            Icons.repeat,
            Icons.favorite_border,
            Icons.ios_share,
            Icons.bookmark_border,
          ])
            tester.getRect(
              find.ancestor(
                of: find.byIcon(icon),
                matching: find.byType(InkResponse),
              ),
            ),
        ];
        for (var i = 0; i < boxes.length; i++) {
          expect(boxes[i].height, greaterThanOrEqualTo(48));
          expect(boxes[i].width, greaterThanOrEqualTo(40));
          if (i > 0) {
            expect(
              boxes[i].left,
              greaterThanOrEqualTo(boxes[i - 1].right - 0.5),
            );
          }
        }
      });
    }

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

    testWidgets('two visible actions are packed at the left, not the edges', (
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
      expect(repost, closeTo(bar.left, 1));
      expect(like - repost, closeTo(AppSpacing.minTapTarget, 1));
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

    Finder frames() => find.descendant(
      of: find.byType(PostMedia),
      matching: find.byType(ClipRRect),
    );

    testWidgets('one image keeps its aspect ratio, clamped to 9:16', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(PostMedia(media: [ref(w: 100, h: 1000, alt: 'tall')])),
      );
      final size = tester.getSize(frames());
      expect(size.width / size.height, closeTo(9 / 16, 0.001));
    });

    testWidgets('alt text becomes the semantics label on its own tile; '
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
      expect(find.bySemanticsLabel('a cat'), findsOneWidget);
      expect(find.bySemanticsLabel('Image'), findsOneWidget);
      handle.dispose();
    });

    // One image is a plain frame; 2-4 are a row of 4:5 tiles (six given,
    // four shown).
    for (final count in [1, 2, 3, 4, 6]) {
      testWidgets(
        '$count images lay out without overflow, as '
        '${count == 1 ? 'a single frame' : '${count > 4 ? 4 : count} tiles'}',
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
            final tile = tester.getSize(frames().first);
            expect(tile.width / tile.height, closeTo(4 / 5, 0.001));
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
      expect(frames(), findsNothing);
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
      // Thumbnails only, never the full files.
      expect(shownUrls(tester), [
        'https://m.test/thumb.webp',
        'https://m.test/thumb2.webp',
      ]);
    });

    testWidgets('review #110 M2: a list tile with no thumbnail is a '
        'placeholder, not the full image', (tester) async {
      final noThumb = common.MediaRef(url: 'https://m.test/full.webp');
      await tester.pumpWidget(_host(PostMedia(media: [noThumb])));
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(frames(), findsOneWidget);
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
