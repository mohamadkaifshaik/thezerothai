import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_tap_area.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/dz_finders.dart';
import '../../../support/theme_harness.dart';

PostActionBar _bar({
  PostActionBarLayout layout = PostActionBarLayout.compact,
  int reply = 0,
  int repost = 0,
  int like = 0,
}) => PostActionBar(
  layout: layout,
  replyCount: reply,
  repostCount: repost,
  likeCount: like,
  actions: PostActions(
    onReply: () {},
    onRepost: () {},
    onLike: () {},
    onShare: () {},
    onBookmark: () {},
  ),
);

Future<void> _pump(
  WidgetTester tester,
  PostActionBar bar, {
  double width = 390,
  Brightness brightness = Brightness.light,
}) => pumpThemed(
  tester,
  // A 20 dp gutter, as on a phone card; the host lets taps reach the
  // row's bleed into it.
  AppTapAreaHost(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: bar,
    ),
  ),
  size: Size(width, 400),
  brightness: brightness,
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('DzHome compact row (${brightness.name}): 44 tall, content '
        'width 10 + 19 + 10, the row hung 10 dp into the gutter, save and '
        'share 44 x 44 at the end', (tester) async {
      await _pump(tester, _bar(), brightness: brightness);
      expect(tester.takeException(), isNull);

      final bar = tester.getRect(find.byType(PostActionBar));
      expect(bar.height, 44);
      final boxes = [for (final i in dzActionIcons) actionBoxOf(tester, i)];
      final glyphs = [for (final i in dzActionIcons) tester.getRect(findDz(i))];
      // margin: 0 -10px: the reply glyph sits on the text edge.
      expect(boxes.first.left, bar.left - 10);
      expect(glyphs.first.left, bar.left);
      for (final i in [0, 1, 2]) {
        expect(boxes[i].size, const Size(10 + 19 + 10, 44), reason: '$i');
        expect(glyphs[i].left - boxes[i].left, 10);
      }
      // Reply, repost and like touch.
      expect(boxes[1].left, boxes[0].right);
      expect(boxes[2].left, boxes[1].right);
      // Save and share: 44 x 44, touching, the last one 10 dp past the edge.
      expect(boxes[3].size, const Size.square(44));
      expect(boxes[4].size, const Size.square(44));
      expect(boxes[4].left, boxes[3].right);
      expect(boxes[4].right, bar.right + 10);
      // Every action keeps a 48 dp tap area around its drawn box.
      for (var i = 0; i < 5; i++) {
        final area = tapAreaOf(tester, findDz(dzActionIcons[i]));
        expect(area.height, AppSpacing.minTapTarget);
        expect(area.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
        expect(area.center, boxes[i].center);
      }
    });
  }

  testWidgets('a count: glyph, 5 dp, the count, 10 dp', (tester) async {
    await _pump(tester, _bar(reply: 12, like: 1500));
    final reply = actionBoxOf(tester, DzIcons.reply);
    final glyph = tester.getRect(findDz(DzIcons.reply));
    final count = tester.getRect(find.text('12'));
    expect(count.left - glyph.right, 5);
    expect(reply.right - count.right, 10);
    expect(reply.width, 10 + 19 + 5 + count.width + 10);
    expect(find.text('1.5K'), findsOneWidget);
  });

  testWidgets('taps reach an action 2 dp above and below its drawn box and '
      'in the gutter', (tester) async {
    final taps = <String>[];
    await pumpThemed(
      tester,
      AppTapAreaHost(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: PostActionBar(
            actions: PostActions(
              onReply: () => taps.add('reply'),
              onRepost: () => taps.add('repost'),
              onLike: () => taps.add('like'),
              onShare: () => taps.add('share'),
              onBookmark: () => taps.add('save'),
            ),
          ),
        ),
      ),
      size: const Size(390, 400),
    );
    final reply = actionBoxOf(tester, DzIcons.reply);
    final share = actionBoxOf(tester, DzIcons.share);
    final like = actionBoxOf(tester, DzIcons.like);
    await tester.tapAt(Offset(reply.center.dx, reply.top - 1.5));
    await tester.tapAt(Offset(like.center.dx, like.bottom + 1.5));
    // The reply box's padding in the gutter, left of the text edge.
    await tester.tapAt(Offset(reply.left + 2, reply.center.dy));
    await tester.tapAt(Offset(share.right + 1.5, share.center.dy));
    expect(taps, ['reply', 'like', 'reply', 'share']);
  });

  for (final width in const [800.0, 1280.0]) {
    testWidgets('tablet and desktop ($width): distributed 48 dp boxes, the '
        'first and last on the edges, same order', (tester) async {
      await _pump(
        tester,
        _bar(layout: PostActionBarLayout.distributed, reply: 3),
        width: width,
      );
      final bar = tester.getRect(find.byType(PostActionBar));
      final boxes = [for (final i in dzActionIcons) actionBoxOf(tester, i)];
      expect(boxes.first.left, bar.left);
      expect(boxes.last.right, bar.right);
      for (var i = 0; i < 5; i++) {
        expect(boxes[i].height, AppSpacing.minTapTarget);
        expect(boxes[i].width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      }
      final gaps = [
        for (var i = 1; i < 5; i++) boxes[i].left - boxes[i - 1].right,
      ];
      for (final gap in gaps) {
        expect(gap, closeTo(gaps.first, 0.5));
        expect(gap, greaterThan(0));
      }
    });
  }
}
