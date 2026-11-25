import 'package:dzeroth/core/icons/dz_icon_data.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
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

import '../../../support/dz_finders.dart';
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
    final bar = tester.getRect(find.byType(PostActionBar));
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
        // Every action keeps its tap box (44 tall, 40+ wide) and none overlaps
        // another.
        final boxes = [
          for (final icon in dzActionIcons)
            tester.getRect(
              find
                  .ancestor(
                    of: findDz(icon),
                    matching: find.byType(InkResponse),
                  )
                  .first,
            ),
        ];
        for (final box in boxes) {
          expect(box.height, greaterThanOrEqualTo(44));
          expect(box.width, greaterThanOrEqualTo(39.9));
        }
        for (var i = 1; i < boxes.length; i++) {
          // Beside the previous box, or on the next line when it flowed.
          final beside = boxes[i].left >= boxes[i - 1].right - 0.5;
          final below = boxes[i].top >= boxes[i - 1].bottom - 0.5;
          expect(beside || below, isTrue, reason: 'box $i overlaps');
        }
      });
    }
  }

  /// The 44 dp tap boxes of the given glyphs, in order.
  List<Rect> boxesOf(WidgetTester tester, List<DzIconData> icons) => [
    for (final icon in icons)
      tester.getRect(
        find
            .ancestor(of: findDz(icon), matching: find.byType(InkResponse))
            .first,
      ),
  ];

  const fiveIcons = dzActionIcons;

  testWidgets('the five actions sit in the artboards\' order: Reply, Repost, '
      'Like at the start, Save and Share at the end', (tester) async {
    for (final width in const [320.0, 360.0, 400.0, 700.0, 1100.0]) {
      await _pump(tester, _card(_view()), width: width);
      final icons = [
        for (final icon in fiveIcons) tester.getRect(findDz(icon)),
      ];
      final boxes = boxesOf(tester, fiveIcons);
      final bar = tester.getRect(find.byType(PostActionBar));
      expect(boxes.first.left, closeTo(bar.left, 0.5), reason: '$width');
      for (var i = 0; i < 5; i++) {
        expect(boxes[i].width, greaterThanOrEqualTo(44), reason: '$width');
        expect(boxes[i].height, greaterThanOrEqualTo(44), reason: '$width');
        if (i > 0) {
          expect(boxes[i].left, greaterThanOrEqualTo(boxes[i - 1].right - 0.5));
          expect(icons[i].left, greaterThan(icons[i - 1].left));
        }
      }
      expect(boxes.last.right, closeTo(bar.right, 1), reason: '$width');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('an item with a count is its glyph, 5 dp, the count, then the '
      'next 44 dp box', (tester) async {
    await _pump(tester, _card(_view()), width: 400);
    final reply = tester.getRect(findDz(DzIcons.reply));
    final count = tester.getRect(find.text('999'));
    final repost = tester.getRect(findDz(DzIcons.repost));
    expect(count.left - reply.right, closeTo(5, 0.5));
    // 10 dp of padding after the count and 10 before the next glyph.
    expect(repost.left - count.right, closeTo(20, 1));
  });

  testWidgets('a list card has no Bookmark without a callback: four visible '
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
    expect(findDz(DzIcons.save), findsNothing);
    final boxes = boxesOf(tester, const [
      DzIcons.repost,
      DzIcons.like,
      DzIcons.share,
    ]);
    // Repost and Like touch; Share is at the trailing edge.
    expect(boxes[1].left, closeTo(boxes[0].right, 0.5));
    expect(boxes[2].left, greaterThan(boxes[1].right));
  });

  testWidgets('with views re-enabled they are after the others, last', (
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
    final bookmark = tester.getRect(findDz(DzIcons.save));
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
