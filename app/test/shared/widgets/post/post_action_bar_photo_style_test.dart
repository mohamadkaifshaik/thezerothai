import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_views_stat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// The photo viewer's action row (X's phone app): order, even spacing and the
/// pink / green / blue states, with the feed's row unchanged.
PostActions _all() => PostActions(
  onReply: () {},
  onRepost: () {},
  onLike: () {},
  onBookmark: () {},
  onShare: () {},
);

Future<void> _pump(
  WidgetTester tester, {
  PostActionBarStyle style = PostActionBarStyle.photoViewer,
  bool liked = false,
  bool reposted = false,
  bool bookmarked = false,
  Brightness brightness = Brightness.light,
}) => pumpThemed(
  tester,
  Padding(
    padding: const EdgeInsets.all(16),
    child: PostActionBar(
      style: style,
      iconSize: AppPhotoPanel.actionIcon,
      actions: _all(),
      replyCount: 3,
      repostCount: 4,
      likeCount: 5,
      viewCount: 5,
      liked: liked,
      reposted: reposted,
      bookmarked: bookmarked,
    ),
  ),
  size: const Size(390, 200),
  brightness: brightness,
);

Icon _icon(WidgetTester tester, IconData data) =>
    tester.widget<Icon>(find.byIcon(data));

void main() {
  testWidgets('X order: reply, repost, like, views, bookmark, share', (
    tester,
  ) async {
    await _pump(tester);
    double x(IconData i) => tester.getCenter(find.byIcon(i)).dx;
    final xs = [
      x(Icons.chat_bubble_outline),
      x(Icons.repeat),
      x(Icons.favorite_border),
      x(kPostViewsIcon),
      x(Icons.bookmark_border),
      x(Icons.ios_share),
    ];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(xs.toSet().length, 6);
  });

  testWidgets('idle glyphs are grey outlines, 18 dp, counts are 13 sp', (
    tester,
  ) async {
    await _pump(tester);
    for (final i in [
      Icons.chat_bubble_outline,
      Icons.repeat,
      Icons.favorite_border,
      Icons.bookmark_border,
      Icons.ios_share,
    ]) {
      expect(_icon(tester, i).color, AppPhotoPanel.muted);
      expect(_icon(tester, i).size, 18);
    }
    expect(AppPhotoPanel.muted, const Color(0xFF71767B));
    final count = tester.widget<Text>(find.text('3'));
    expect(count.style?.color, AppPhotoPanel.muted);
    expect(count.style?.fontSize, 13);
  });

  testWidgets('liked pink, reposted green, bookmarked blue and filled', (
    tester,
  ) async {
    await _pump(tester, liked: true, reposted: true, bookmarked: true);
    expect(_icon(tester, Icons.favorite).color, const Color(0xFFF91880));
    expect(_icon(tester, Icons.repeat).color, const Color(0xFF00BA7C));
    expect(_icon(tester, Icons.bookmark).color, AppPalette.tealElectric);
    expect(find.byIcon(Icons.bookmark_border), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the bookmarked colour is the teal accent, not blue '
        '(${brightness.name})', (tester) async {
      await _pump(tester, bookmarked: true, brightness: brightness);
      // The photo viewer's dark panel: the dark theme's teal token.
      expect(_icon(tester, Icons.bookmark).color, AppPhotoPanel.bookmarked);
      expect(AppPhotoPanel.bookmarked, AppPalette.tealElectric);
      expect(AppPhotoPanel.bookmarked, isNot(const Color(0xFF1D9BF0)));
      // The feed's row: the theme's primary, the teal of links and actions.
      await _pump(
        tester,
        style: PostActionBarStyle.feed,
        bookmarked: true,
        brightness: brightness,
      );
      final primary = Theme.of(tester.element(find.byType(PostActionBar)))
          .colorScheme
          .primary;
      expect(_icon(tester, Icons.bookmark).color, primary);
      expect(
        primary,
        brightness == Brightness.light
            ? AppPalette.tealText
            : AppPalette.tealElectric,
      );
    });
  }

  testWidgets('the feed style keeps its own order and colours', (tester) async {
    await _pump(tester, style: PostActionBarStyle.feed, liked: true);
    expect(_icon(tester, Icons.favorite).color, isNot(AppPhotoPanel.liked));
    double x(IconData i) => tester.getCenter(find.byIcon(i)).dx;
    // The feed puts Share before Bookmark.
    expect(x(Icons.ios_share), lessThan(x(Icons.bookmark_border)));
  });
}
