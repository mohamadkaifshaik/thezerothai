import 'dart:ui' as ui;

import 'package:dzeroth/core/icons/dz_icon.dart';
import 'package:dzeroth/core/icons/dz_icon_data.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/dz_finders.dart';
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
  // Real Inter metrics: the one-line checks are about the design's text.
  setUpAll(loadAppFonts);

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
        expect(findDz(DzIcons.share), findsOneWidget);
        if (scale == 1.0) expect(find.text('272'), findsOneWidget);
      });
    }

    testWidgets('open post (spread layout): every action in a 48 dp box, '
        'spread evenly, in order (Save, then Share last), larger glyphs', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PostActionBar(
            iconSize: AppFocalPost.actionIcon,
            layout: PostActionBarLayout.spread,
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

      // The artboards' order (DzPost): reply, repost, like, save, share.
      final icons = dzActionIcons;
      final xs = [for (final i in icons) tester.getCenter(findDz(i)).dx];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]));
      }
      final bar = tester.getRect(find.byType(PostActionBar));
      Rect box(DzIconData icon) => tester.getRect(
        find.ancestor(of: findDz(icon), matching: find.byType(InkResponse)),
      );
      final gaps = [
        for (var i = 1; i < icons.length; i++)
          box(icons[i]).left - box(icons[i - 1]).right,
      ];
      for (var i = 0; i < icons.length; i++) {
        expect(box(icons[i]).width, 48);
        expect(box(icons[i]).height, 48);
      }
      for (final gap in gaps) {
        expect(gap, closeTo(gaps.first, 0.5));
      }
      // space-around: half a gap in from each edge.
      expect(box(icons.first).left - bar.left, closeTo(gaps.first / 2, 0.5));
      expect(bar.right - box(icons.last).right, closeTo(gaps.first / 2, 0.5));
      expect(
        tester.getSize(findDz(DzIcons.repost)).width,
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

      expect(findDz(DzIcons.like), findsOneWidget);
      expect(findDz(DzIcons.repost), findsOneWidget);
      expect(findDz(DzIcons.reply), findsNothing);
      expect(findDz(DzIcons.share), findsNothing);
    });

    testWidgets('shows compact counts; Reply, Repost, Like lead in order, '
        'Share trails (compact layout)', (tester) async {
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
      const icons = [
        DzIcons.reply,
        DzIcons.repost,
        DzIcons.like,
        DzIcons.share,
      ];
      final lefts = [
        for (final icon in icons) tester.getTopLeft(findDz(icon)).dx,
      ];
      final bar = tester.getRect(find.byType(PostActionBar));
      final boxes = [
        for (final icon in icons)
          tester.getRect(
            find
                .ancestor(of: findDz(icon), matching: find.byType(InkResponse))
                .first,
          ),
      ];
      // The row hangs 10 dp into the gutter on each side (margin: 0 -10px).
      expect(boxes.first.left, bar.left - 10);
      // The three counted actions sit edge to edge; Share is at the end.
      for (var i = 1; i < 3; i++) {
        expect(boxes[i].left, boxes[i - 1].right);
      }
      for (var i = 0; i < 4; i++) {
        if (i > 0) expect(lefts[i], greaterThan(lefts[i - 1]));
        expect(boxes[i].height, AppIconSize.actionTarget);
        // Drawn at 44, tapped at 48.
        final area = tapAreaOf(tester, findDz(icons[i]));
        expect(area.height, AppSpacing.minTapTarget);
        expect(area.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      }
      expect(boxes.last.right, bar.right + 10);
      expect(boxes.last.size, const Size.square(44));
      // Glyph, 5, count, 10 dp side padding.
      expect(
        boxes[0].width,
        10 +
            AppIconSize.postAction +
            5 +
            tester.getSize(find.text('3')).width +
            10,
      );
      // 19 dp glyphs (DzHome; was 18).
      expect(
        tester.getSize(findDz(DzIcons.share)).width,
        AppIconSize.postAction,
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

    testWidgets('Bookmark appears only with a callback; trails the counted '
        'actions, outline then filled accent, labelled and '
        'selected', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        _host(PostActionBar(actions: PostActions(onLike: () {}))),
      );
      expect(findDz(DzIcons.save), findsNothing);

      await tester.pumpWidget(
        _host(
          PostActionBar(
            showDisabled: false,
            actions: PostActions(onLike: () {}, onBookmark: () => taps++),
          ),
        ),
      );
      final bar = tester.getRect(find.byType(PostActionBar));
      final icon = tester.getRect(findDz(DzIcons.save));
      // Last in the row: its 44 dp box ends 10 dp past the bar's trailing
      // edge (the row's -10 margin).
      expect(icon.center.dx, bar.right + 10 - 22);
      expect(icon.width, AppIconSize.postAction);
      expect(dzIconOf(tester, DzIcons.save).fill, 0);
      // The accessibility node is the 48 dp tap area.
      final off = tester.getSemantics(find.bySemanticsLabel('Bookmark'));
      expect(off.rect.size, const Size.square(AppSpacing.minTapTarget));
      await tester.tap(findDz(DzIcons.save));
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
      expect(findDz(DzIcons.save, filled: false), findsNothing);
      expect(
        dzIconOf(tester, DzIcons.save, filled: true).color,
        AppColors.dark.accentText,
      );
      expect(find.bySemanticsLabel('Bookmarked'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Bookmark sits before Share, which is last, '
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
      final bookmark = tester.getRect(findDz(DzIcons.save));
      final share = tester.getRect(findDz(DzIcons.share));
      final like = tester.getRect(findDz(DzIcons.like));
      // The artboards' order (DzHome): Like, then Bookmark and Share at the
      // trailing edge (this supersedes the 2026-11-15 order Share, Bookmark).
      expect(like.right, lessThan(bookmark.left));
      expect(bookmark.right, lessThan(share.left));
      final bar = tester.getRect(find.byType(PostActionBar));
      // Two 44 dp boxes, the last 10 dp past the edge.
      expect(share.center.dx, bar.right + 10 - 22);
      expect(bookmark.center.dx, share.center.dx - 44);
    });

    // (width, counts, one line expected): feed-sized counts stay on one line
    // at 360 and 400 dp with 1.3x text; four-digit counts on every action
    // wrap only where the width runs out.
    for (final (width, counts, oneLine) in const [
      (320.0, (128, 34, 1500), null),
      (360.0, (128, 34, 1500), true),
      (400.0, (128, 34, 1500), true),
      (320.0, (1234, 5678, 91011), false),
      (360.0, (1234, 5678, 91011), null),
      (400.0, (1234, 5678, 91011), null),
    ]) {
      testWidgets('five items at $width dp, counts $counts, text x1.3: 44 '
          'tall drawn, 48 dp tap areas, ${switch (oneLine) {
            true => 'one line',
            false => 'wrapped',
            null => 'wrapped only if it must',
          }}', (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: _host(
              width: width - 32,
              PostActionBar(
                replyCount: counts.$1,
                repostCount: counts.$2,
                likeCount: counts.$3,
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
          for (final icon in dzActionIcons)
            tester.getRect(
              find.ancestor(
                of: findDz(icon),
                matching: find.byType(InkResponse),
              ),
            ),
        ];
        for (var i = 0; i < boxes.length; i++) {
          expect(boxes[i].height, AppIconSize.actionTarget);
          final area = tapAreaOf(tester, findDz(dzActionIcons[i]));
          expect(area.height, AppSpacing.minTapTarget);
          expect(area.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
        }
        final bar = tester.getRect(find.byType(PostActionBar));
        final flat = expectCompactRowFlow(bar, boxes);
        if (oneLine != null) expect(flat, oneLine);
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

      final icons = tester.widgetList<DzIcon>(find.byType(DzIcon)).toList();
      expect(icons.map((i) => i.color), contains(AppColors.dark.like));
      expect(icons.map((i) => i.color), contains(AppColors.dark.repost));
      final like = tester.getSemantics(find.bySemanticsLabel('Unlike, 1'));
      expect(like.flagsCollection.isSelected, ui.Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('two visible actions sit edge to edge at the leading side', (
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

      final repost = tester.getTopLeft(findDz(DzIcons.repost)).dx;
      final like = tester.getTopLeft(findDz(DzIcons.like)).dx;
      final bar = tester.getRect(find.byType(PostActionBar));
      // Repost's glyph sits on the content edge (the row's -10 margin and
      // its 10 dp padding); like follows its 10 + 19 + 10 box.
      expect(repost, bar.left);
      expect(like - repost, 10 + 19 + 10);
      expect(like, lessThan(bar.center.dx));
    });

    testWidgets('dispatches callbacks, has 48 dp tap areas and semantics', (
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
        // Drawn 44 tall; the tap area and its node are 48 dp.
        final ink = find.byWidget(target);
        expect(tester.getSize(ink).height, AppIconSize.actionTarget);
        final area = tapAreaOf(tester, ink);
        expect(area.height, AppSpacing.minTapTarget);
        expect(area.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      }
      for (final label in ['Unlike, 7', 'Repost']) {
        final rect = tester.getSemantics(find.bySemanticsLabel(label)).rect;
        expect(rect.height, AppSpacing.minTapTarget, reason: label);
        expect(
          rect.width,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
          reason: label,
        );
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

    // Two tiles fill the column. Larger galleries scroll through every photo.
    for (final count in [1, 2, 3, 6, 20]) {
      testWidgets('$count images lay out without overflow, as '
          '${count == 1 ? 'a single frame' : '$count tiles'}', (tester) async {
        await tester.pumpWidget(
          _host(PostMedia(media: [for (var i = 0; i < count; i++) ref()])),
        );
        expect(tester.takeException(), isNull);
        expect(mediaPageCount(tester), count == 1 ? isNull : count);
        if (count > 1) {
          expect(currentMediaPage(tester), 0);
          final tile = tester.getSize(frames().first);
          expect(tile.width / tile.height, closeTo(4 / 5, 0.001));
          for (var page = 1; count > 2 && page < count; page++) {
            await swipeToNextMediaPage(tester);
            expect(currentMediaPage(tester), page);
            expect(tester.takeException(), isNull);
          }
        }
      });
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
