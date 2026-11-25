import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/dz_finders.dart';
import '../../../support/theme_harness.dart';

void main() {
  for (final width in const [390.0, 800.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('at $width (${brightness.name}): edge to edge, in order, '
          '44 dp targets, save and share at the trailing edge', (tester) async {
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
        final glyphs = [
          for (final i in dzActionIcons) tester.getRect(findDz(i)),
        ];
        final targets = [
          for (final i in dzActionIcons)
            tester.getRect(
              find
                  .ancestor(of: findDz(i), matching: find.byType(InkResponse))
                  .first,
            ),
        ];

        expect(targets.first.left, closeTo(bar.left, 0.5));
        for (var i = 0; i < dzActionIcons.length; i++) {
          expect(targets[i].width, greaterThanOrEqualTo(44));
          expect(targets[i].height, greaterThanOrEqualTo(44));
          if (i > 0) {
            expect(glyphs[i].left, greaterThan(glyphs[i - 1].left));
          }
        }
        // Reply, repost and like touch; save and share touch at the end.
        for (final i in [1, 2]) {
          expect(targets[i].left, closeTo(targets[i - 1].right, 0.5));
        }
        expect(targets[4].left, closeTo(targets[3].right, 0.5));
        expect(targets.last.right, closeTo(bar.right, .5));
        expect(targets[2].width, greaterThan(targets[3].width));
      });
    }
  }
}
