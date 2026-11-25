import 'package:dzeroth/core/icons/dz_icon.dart';
import 'package:dzeroth/core/icons/dz_icon_data.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_views_stat.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/dz_finders.dart';
import '../../../support/theme_harness.dart';

/// The photo viewer's action row (ZPhotoViewer): order, even spacing and the
/// pink / green / teal states, with the feed's row unchanged.
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
      layout: style == PostActionBarStyle.photoViewer
          ? PostActionBarLayout.spread
          : PostActionBarLayout.compact,
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

DzIcon _icon(WidgetTester tester, DzIconData data) => dzIconOf(tester, data);

void main() {
  testWidgets('Action order: reply, repost, like, save, share, views', (
    tester,
  ) async {
    await _pump(tester);
    double x(Finder f) => tester.getCenter(f).dx;
    final xs = [
      x(findDz(DzIcons.reply)),
      x(findDz(DzIcons.repost)),
      x(findDz(DzIcons.like)),
      x(findDz(DzIcons.save)),
      x(findDz(DzIcons.share)),
      x(find.byIcon(kPostViewsIcon)),
    ];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(xs.toSet().length, 6);
  });

  testWidgets('idle glyphs are grey outlines, 22 dp, counts are 13 sp', (
    tester,
  ) async {
    await _pump(tester);
    for (final i in dzActionIcons) {
      expect(_icon(tester, i).color, AppPhotoPanel.muted);
      expect(tester.getSize(findDz(i)), const Size.square(22));
      expect(_icon(tester, i).fill, 0);
    }
    expect(AppPhotoPanel.muted, const Color(0xFF71767B));
    final count = tester.widget<Text>(find.text('3'));
    expect(count.style?.color, AppPhotoPanel.muted);
    expect(count.style?.fontSize, 13);
  });

  testWidgets('liked pink, reposted green, bookmarked teal and filled', (
    tester,
  ) async {
    await _pump(tester, liked: true, reposted: true, bookmarked: true);
    expect(_icon(tester, DzIcons.like).color, const Color(0xFFF91880));
    expect(_icon(tester, DzIcons.like).fill, 1);
    expect(_icon(tester, DzIcons.repost).color, const Color(0xFF00BA7C));
    expect(_icon(tester, DzIcons.save).color, AppPalette.tealElectric);
    expect(findDz(DzIcons.save, filled: false), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the bookmarked colour is the teal accent, not blue '
        '(${brightness.name})', (tester) async {
      await _pump(tester, bookmarked: true, brightness: brightness);
      // The photo viewer's dark panel: the dark theme's teal token.
      expect(_icon(tester, DzIcons.save).color, AppPhotoPanel.bookmarked);
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
      expect(_icon(tester, DzIcons.save).color, primary);
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
    expect(_icon(tester, DzIcons.like).color, isNot(AppPhotoPanel.liked));
    double x(Finder f) => tester.getCenter(f).dx;
    // The artboards put Save before Share at the trailing edge.
    expect(x(findDz(DzIcons.save)), lessThan(x(findDz(DzIcons.share))));
  });
}
