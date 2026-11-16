import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// The action row is compact and left-aligned (Substack style): Replies,
/// Reposts, Likes, Shares, Bookmarks packed from the start with 20 dp between
/// items, the same on phone, tablet and desktop, every tap target 48 dp.

const _icons = [
  Icons.chat_bubble_outline,
  Icons.repeat,
  Icons.favorite_border,
  Icons.ios_share,
  Icons.bookmark_border,
];

void main() {
  for (final width in const [390.0, 800.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('at $width (${brightness.name}): packed left, in order, '
          '48 dp targets', (tester) async {
        await pumpThemed(
          tester,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: PostActionBar(
              replyCount: 12,
              repostCount: 3,
              likeCount: 1500,
              shareCount: 4,
              actions: PostActions(
                onReply: () {},
                onRepost: () {},
                onLike: () {},
                onShare: () {},
                onBookmark: () {},
              ),
            ),
          ),
          size: Size(width, 400),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);

        final bar = tester.getRect(find.byType(PostActionBar));
        final glyphs = [for (final i in _icons) tester.getRect(find.byIcon(i))];
        final targets = [
          for (final i in _icons)
            tester.getRect(
              find
                  .ancestor(
                    of: find.byIcon(i),
                    matching: find.byType(InkResponse),
                  )
                  .first,
            ),
        ];

        // Left-aligned: the first glyph starts the row.
        expect(glyphs.first.left, closeTo(bar.left, 0.5));
        for (var i = 0; i < _icons.length; i++) {
          expect(targets[i].width, greaterThanOrEqualTo(48));
          expect(targets[i].height, greaterThanOrEqualTo(48));
          if (i > 0) {
            // Order, and packed: the targets meet; nothing is spread.
            expect(glyphs[i].left, greaterThan(glyphs[i - 1].left));
            expect(targets[i].left, closeTo(targets[i - 1].right, 0.5));
          }
        }
        // Compact: the whole row is far narrower than the width on the
        // wider windows, and identical on all three.
        expect(targets.last.right - bar.left, lessThan(400));
        // 20 dp from the end of a count to the next glyph (Likes -> Shares).
        final likeCount = tester.getRect(find.text('1.5K'));
        expect(
          glyphs[3].left - likeCount.right,
          closeTo(AppSpacing.actionItemGap, 1),
        );
      });
    }
  }

  testWidgets('the row has the same geometry on phone, tablet and desktop', (
    tester,
  ) async {
    final lefts = <List<double>>[];
    for (final width in const [390.0, 800.0, 1280.0]) {
      await pumpThemed(
        tester,
        PostActionBar(
          replyCount: 12,
          actions: PostActions(
            onReply: () {},
            onRepost: () {},
            onLike: () {},
            onShare: () {},
            onBookmark: () {},
          ),
        ),
        size: Size(width, 400),
      );
      lefts.add([for (final i in _icons) tester.getRect(find.byIcon(i)).left]);
    }
    expect(lefts[1], lefts[0]);
    expect(lefts[2], lefts[0]);
  });
}
