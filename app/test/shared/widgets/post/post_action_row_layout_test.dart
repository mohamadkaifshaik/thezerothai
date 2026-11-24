import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

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
      testWidgets('at $width (${brightness.name}): even gaps, in order, '
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

        expect(targets.first.left, closeTo(bar.left, 0.5));
        for (var i = 0; i < _icons.length; i++) {
          expect(targets[i].width, greaterThanOrEqualTo(48));
          expect(targets[i].height, greaterThanOrEqualTo(48));
          if (i > 0) {
            expect(glyphs[i].left, greaterThan(glyphs[i - 1].left));
            expect(targets[i].left, closeTo(targets[i - 1].right + 4, 0.5));
          }
        }
        expect(targets.last.right, closeTo(bar.right, .5));
        expect(targets[2].width, greaterThan(targets.last.width));
      });
    }
  }
}
