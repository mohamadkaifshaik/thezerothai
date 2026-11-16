import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:dzeroth/shared/widgets/post/post_views_stat.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:fixnum/fixnum.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

pb.PostView _view({bool media = false, String text = 'hello there'}) =>
    pb.PostView(
      post: pb.Post(
        postId: postId(1),
        text: text,
        likeCount: Int64(12345),
        repostCount: Int64(1234567),
        replyCount: Int64(999),
        author: common.AuthorSnapshot(
          userId: 'u1',
          handle: 'a_very_long_handle_name_for_a_test',
          displayName: 'A very long display name that does not fit anywhere',
        ),
        media: media
            ? [
                for (var i = 0; i < 4; i++)
                  common.MediaRef(
                    url: 'https://cdn.example/$i.jpg',
                    width: 800,
                    height: 600,
                  ),
              ]
            : const [],
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  Widget card, {
  double width = 400,
  double textScale = 1,
}) => pumpThemed(
  tester,
  SingleChildScrollView(child: card),
  size: Size(width, 900),
  textScale: textScale,
);

PostCard _card(pb.PostView view, {bool indentBody = false}) => PostCard(
  view: view,
  indentBody: indentBody,
  graphActionsEnabled: false,
  actions: PostActions(
    onReply: () {},
    onRepost: () {},
    onLike: () {},
    onBookmark: () {},
    onShare: () {},
  ),
);

void main() {
  testWidgets('the body starts under the avatar circle, not beside it', (
    tester,
  ) async {
    await _pump(tester, _card(_view(media: true)));
    final avatar = tester.getRect(find.byType(AppAvatar));
    final text = tester.getRect(find.text('hello there'));
    final bar = tester.getRect(find.byIcon(Icons.chat_bubble_outline));
    expect(text.left, closeTo(avatar.left, 0.5));
    expect(bar.left, closeTo(avatar.left, 0.5));
    // Below the header row; the media row starts at the body's left edge.
    expect(text.top, greaterThan(avatar.bottom - 1));
    final card = tester.getRect(find.byType(PostCard));
    final frame = tester.getRect(
      find
          .descendant(
            of: find.byType(PostMedia),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(frame.left, closeTo(avatar.left, 0.5));
    expect(frame.right, lessThanOrEqualTo(card.right - postCardGutter(400)));
  });

  testWidgets('indentBody keeps the body beside the avatar (thread rail)', (
    tester,
  ) async {
    await _pump(tester, _card(_view(), indentBody: true));
    final avatar = tester.getRect(find.byType(AppAvatar));
    final text = tester.getRect(find.text('hello there'));
    expect(text.left, greaterThan(avatar.right));
  });

  testWidgets('the name line is centred on the avatar', (tester) async {
    await _pump(tester, _card(_view()));
    final avatar = tester.getRect(find.byType(AppAvatar));
    final name = tester.getRect(find.textContaining('A very long'));
    expect(name.center.dy, closeTo(avatar.center.dy, 2));
  });

  for (final width in const [320.0, 360.0, 400.0, 700.0, 1100.0]) {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('no overflow at ${width}dp, text x$scale (long names, 4 '
          'media, big counts)', (tester) async {
        await _pump(
          tester,
          _card(_view(media: true)),
          width: width,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        // Every action keeps its tap box (48 tall, 40+ wide) and none overlaps
        // another.
        final boxes = [
          for (final icon in const [
            Icons.chat_bubble_outline,
            Icons.repeat,
            Icons.favorite_border,
            Icons.ios_share,
            Icons.bookmark_border,
          ])
            tester.getRect(
              find
                  .ancestor(
                    of: find.byIcon(icon),
                    matching: find.byType(ConstrainedBox),
                  )
                  .first,
            ),
        ];
        for (final box in boxes) {
          expect(box.height, greaterThanOrEqualTo(48));
          expect(box.width, greaterThanOrEqualTo(39.9));
        }
        for (var i = 1; i < boxes.length; i++) {
          expect(boxes[i].left, greaterThanOrEqualTo(boxes[i - 1].right - 0.5));
        }
      });
    }
  }

  /// The 48 dp tap boxes of the given glyphs, in order.
  List<Rect> boxesOf(WidgetTester tester, List<IconData> icons) => [
    for (final icon in icons)
      tester.getRect(
        find
            .ancestor(of: find.byIcon(icon), matching: find.byType(InkResponse))
            .first,
      ),
  ];

  const fiveIcons = [
    Icons.chat_bubble_outline,
    Icons.repeat,
    Icons.favorite_border,
    Icons.ios_share,
    Icons.bookmark_border,
  ];

  testWidgets('the five actions are packed from the left, in the owner '
      'order: Reply, Repost, Like, Share, Bookmark', (tester) async {
    for (final width in const [320.0, 360.0, 400.0, 700.0, 1100.0]) {
      await _pump(tester, _card(_view()), width: width);
      final icons = [
        for (final icon in fiveIcons) tester.getRect(find.byIcon(icon)),
      ];
      final boxes = boxesOf(tester, fiveIcons);
      final bar = tester.getRect(find.byType(PostActionBar));
      // The first glyph starts the row (aligned with the text above), and the
      // same compact row is used at every width: it does not grow to fill.
      expect(icons.first.left, closeTo(bar.left, 0.5), reason: '$width');
      for (var i = 0; i < 5; i++) {
        expect(boxes[i].width, greaterThanOrEqualTo(48), reason: '$width');
        expect(boxes[i].height, greaterThanOrEqualTo(48), reason: '$width');
        if (i > 0) {
          // In order, and the tap boxes meet: nothing is spread.
          expect(boxes[i].left, closeTo(boxes[i - 1].right, 0.5));
          expect(icons[i].left, greaterThan(icons[i - 1].left));
        }
      }
      expect(boxes.last.right, lessThan(bar.left + 5 * 80), reason: '$width');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('an item with a count is its glyph, 6 dp, the count, then a '
      '20 dp gap to the next glyph', (tester) async {
    await _pump(tester, _card(_view()), width: 400);
    final reply = tester.getRect(find.byIcon(Icons.chat_bubble_outline));
    final count = tester.getRect(find.text('999'));
    final repost = tester.getRect(find.byIcon(Icons.repeat));
    expect(count.left - reply.right, closeTo(AppSpacing.actionGap, 0.5));
    // Reply has a count: the next glyph is 20 dp past it.
    expect(repost.left - count.right, closeTo(AppSpacing.actionItemGap, 1));
  });

  testWidgets('a list card has no Bookmark without a callback: four packed '
      'items', (tester) async {
    await _pump(
      tester,
      PostCard(
        view: _view(),
        graphActionsEnabled: false,
        actions: PostActions(
          onReply: () {},
          onRepost: () {},
          onLike: () {},
          onShare: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.bookmark_border), findsNothing);
    final boxes = boxesOf(tester, const [
      Icons.repeat,
      Icons.favorite_border,
      Icons.ios_share,
    ]);
    expect(boxes[1].left, closeTo(boxes[0].right, 0.5));
    expect(boxes[2].left, closeTo(boxes[1].right, 0.5));
  });

  testWidgets('with views re-enabled they are packed after the others, last', (
    tester,
  ) async {
    final view = _view()..post.viewCount = Int64(4321);
    await pumpThemed(
      tester,
      PostViewsVisibility(
        show: true,
        child: SingleChildScrollView(
          child: PostActionBar(
            actions: PostActions(
              onReply: () {},
              onRepost: () {},
              onLike: () {},
              onBookmark: () {},
              onShare: () {},
            ),
            viewCount: view.post.viewCount.toInt(),
          ),
        ),
      ),
      size: const Size(400, 400),
    );
    final bookmark = tester.getRect(find.byIcon(Icons.bookmark_border));
    final views = tester.getRect(find.byIcon(kPostViewsIcon));
    expect(views.left, greaterThan(bookmark.right));
    expect(tester.takeException(), isNull);
  });

  test('the views glyph is the single constant', () {
    expect(kPostViewsIcon, Icons.bar_chart_rounded);
  });

  testWidgets('the views stat draws kPostViewsIcon', (tester) async {
    await pumpThemed(tester, const PostViewsStat(count: 1200));
    expect(find.byIcon(kPostViewsIcon), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
  });
}
