import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:dzeroth/shared/widgets/post/embedded_post_card.dart';
import 'package:dzeroth/shared/widgets/post/poll_card.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_context_label.dart';
import 'package:dzeroth/shared/widgets/post/post_list_skeleton.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/poll_fixtures.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

/// The post card restyle (R1): the `.post` geometry of the approved designs
/// (42 dp avatar, a 12 dp gap, 20 dp gutters on phones and 16 dp from 600 up),
/// the `.acts` row (Reply, Repost, Like, Bookmark, Share spread across at most
/// 440 dp; no fourth count while view counts have no backend), the 20 dp
/// media and quote radius, and the opened post's wide header (56 dp avatar,
/// 21 sp text from 600 up).
const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200, 1440];

pb.PostView _view({String text = 'one line', bool quote = false}) =>
    pb.PostView(
      post: pb.Post(
        postId: postId(1),
        kind: quote ? PostKind.POST_KIND_QUOTE : PostKind.POST_KIND_POST,
        text: text,
        author: common.AuthorSnapshot(
          userId: 'u1',
          handle: 'alice',
          displayName: 'Alice Example',
        ),
        replyCount: Int64(6),
        embedded: quote
            ? pb.EmbeddedPost(
                postId: postId(2),
                text: 'quoted',
                author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
              )
            : null,
      ),
    );

PostActions _actions() => PostActions(
  onReply: () {},
  onRepost: () {},
  onLike: () {},
  onBookmark: () {},
  onShare: () {},
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  double textScale = 1.0,
  TextDirection direction = TextDirection.ltr,
}) => pumpThemed(
  tester,
  Directionality(
    textDirection: direction,
    child: SingleChildScrollView(child: child),
  ),
  size: Size(width, 900),
  textScale: textScale,
);

void main() {
  group('list card geometry', () {
    for (final width in _widths) {
      testWidgets('at $width the avatar is 42 dp after a '
          '${width < 600 ? 20 : 16} dp gutter, 12 dp before the body', (
        tester,
      ) async {
        await _pump(
          tester,
          PostCard(
            view: _view(),
            graphActionsEnabled: false,
            actions: _actions(),
          ),
          width: width,
        );

        final gutter = width < 600 ? 20.0 : 16.0;
        final avatar = tester.getRect(find.byType(AppAvatar));
        expect(avatar.size, const Size.square(AppSize.avatarPost));
        // The 42 dp circle is centred in its 48 dp tap box.
        expect(avatar.left, closeTo(gutter + 3, 0.5));
        expect(postCardGutter(width), gutter);
        final body = tester.getRect(find.byType(PostRichText));
        expect(body.left, closeTo(gutter + 48 + AppSpacing.smd, 0.5));
        expectNoOverflow(tester);
      });
    }

    testWidgets('RTL mirrors the gutter and the avatar column', (tester) async {
      await _pump(
        tester,
        PostCard(
          view: _view(),
          graphActionsEnabled: false,
          actions: _actions(),
        ),
        direction: TextDirection.rtl,
      );

      final avatar = tester.getRect(find.byType(AppAvatar));
      expect(avatar.right, closeTo(360 - 20 - 3, 0.5));
      expectNoOverflow(tester);
    });

    for (final width in const [360.0, 600.0, 1440.0]) {
      testWidgets('text x2.0 at $width: no overflow, targets stay 48 dp', (
        tester,
      ) async {
        await _pump(
          tester,
          PostCard(
            view: _view(text: 'A long line of text ' * 6),
            graphActionsEnabled: false,
            actions: _actions(),
          ),
          width: width,
          textScale: 2.0,
        );

        expectNoOverflow(tester);
        for (final label in const ['Reply, 6', 'Repost', 'Like', 'Share']) {
          expect(
            tester.getSize(find.bySemanticsLabel(label)).height,
            greaterThanOrEqualTo(AppSpacing.minTapTarget),
            reason: label,
          );
        }
      });
    }
  });

  group('action row', () {
    testWidgets('Reply, Repost, Like, Bookmark, Share: no fourth count', (
      tester,
    ) async {
      await _pump(
        tester,
        PostCard(
          view: _view(),
          graphActionsEnabled: false,
          actions: _actions(),
        ),
      );

      final icons = [
        Icons.chat_bubble_outline,
        Icons.repeat,
        Icons.favorite_border,
        Icons.bookmark_border,
        Icons.ios_share,
      ];
      final xs = [for (final i in icons) tester.getCenter(find.byIcon(i)).dx];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: '${icons[i]}');
      }
      // F1 (view counts) has no backend: nothing draws a fourth count.
      expect(find.byIcon(Icons.bar_chart), findsNothing);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.text('6'), findsOneWidget, reason: 'the reply count only');
    });

    for (final width in const [360.0, 600.0, 1440.0]) {
      testWidgets('at $width all five actions spread edge to edge within '
          '440 dp', (tester) async {
        await _pump(
          tester,
          PostCard(
            view: _view(),
            graphActionsEnabled: false,
            actions: _actions(),
          ),
          width: width,
        );

        final bar = tester.getRect(find.byType(PostActionBar));
        final row = bar.width < kPostActionsMaxWidth
            ? bar.width
            : kPostActionsMaxWidth;
        Rect box(IconData icon) => tester.getRect(
          find.ancestor(
            of: find.byIcon(icon),
            matching: find.byType(InkResponse),
          ),
        );
        // `.acts`: space-between. The first box starts the row, the last
        // (Share) ends it, at most 440 dp from the start.
        expect(box(Icons.chat_bubble_outline).left, closeTo(bar.left, 1));
        expect(box(Icons.ios_share).right, closeTo(bar.left + row, 1));
        final icons = [
          Icons.chat_bubble_outline,
          Icons.repeat,
          Icons.favorite_border,
          Icons.bookmark_border,
          Icons.ios_share,
        ];
        final gaps = [
          for (var i = 1; i < icons.length; i++)
            box(icons[i]).left - box(icons[i - 1]).right,
        ];
        for (final gap in gaps) {
          expect(gap, greaterThanOrEqualTo(0));
        }
      });

      testWidgets('at $width in RTL the row starts at the right', (
        tester,
      ) async {
        await _pump(
          tester,
          PostCard(
            view: _view(),
            graphActionsEnabled: false,
            actions: _actions(),
          ),
          width: width,
          direction: TextDirection.rtl,
        );

        final bar = tester.getRect(find.byType(PostActionBar));
        final reply = tester.getRect(find.byIcon(Icons.chat_bubble_outline));
        final share = tester.getRect(find.byIcon(Icons.ios_share));
        expect(reply.right, closeTo(bar.right, 1));
        expect(share.left, lessThan(reply.left));
        expect(bar.right - share.left, lessThanOrEqualTo(kPostActionsMaxWidth));
      });
    }

    testWidgets('glyphs are 18 dp, counts 13 sp', (tester) async {
      await _pump(
        tester,
        PostCard(
          view: _view(),
          graphActionsEnabled: false,
          actions: _actions(),
        ),
      );

      expect(
        tester.getSize(find.byIcon(Icons.chat_bubble_outline)),
        const Size.square(18),
      );
      final count = tester.widget<Text>(find.text('6'));
      expect(count.style?.fontSize, 13);
      expect(count.style?.fontWeight, FontWeight.w600);
    });
  });

  group('opened post', () {
    for (final width in _widths) {
      final wide = width >= 600;
      testWidgets(
        'at $width: ${wide ? '56 dp avatar, 21 sp' : '46 dp avatar, '
                  '17 sp'} text',
        (tester) async {
          await _pump(
            tester,
            PostCard(
              view: _view(),
              focal: true,
              graphActionsEnabled: false,
              actions: _actions(),
            ),
            width: width,
          );

          expect(
            tester.getSize(find.byType(AppAvatar)).width,
            wide ? AppSize.avatarLg : AppFocalPost.phoneAvatar,
          );
          final text = tester.widget<PostRichText>(find.byType(PostRichText));
          expect(
            text.style?.fontSize,
            wide ? AppFocalPost.bodySizeWide : AppFocalPost.bodySize,
          );
          expectNoOverflow(tester);
        },
      );
    }
  });

  testWidgets('an opened reply keeps the 42 dp avatar at 1200, so the '
      'thread rail meets its middle', (tester) async {
    final view = _view()..post.replyToPostId = postId(9);
    await _pump(
      tester,
      PostCard(
        view: view,
        focal: true,
        graphActionsEnabled: false,
        actions: _actions(),
      ),
      width: 1200,
    );

    expect(tester.getSize(find.byType(AppAvatar)).width, AppSize.avatarPost);
    final text = tester.widget<PostRichText>(find.byType(PostRichText));
    expect(text.style?.fontSize, AppFocalPost.bodySizeWide);
  });

  testWidgets('the opened post\'s name is 16 sp (the PostDetail designs)', (
    tester,
  ) async {
    await _pump(
      tester,
      PostCard(
        view: _view(),
        focal: true,
        graphActionsEnabled: false,
        actions: _actions(),
      ),
    );

    final name = tester.widget<Text>(find.text('Alice Example'));
    expect(name.style?.fontSize, 16);
  });

  for (final width in const [360.0, 1200.0]) {
    testWidgets('at $width a tappable community label is a 48 dp target', (
      tester,
    ) async {
      await _pump(
        tester,
        PostContextLabel.community(name: 'Coffee club', onTap: () {}),
        width: width,
      );

      final target = tester.getSize(
        find.ancestor(
          of: find.text('Coffee club'),
          matching: find.byType(InkWell),
        ),
      );
      expect(target.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    });
  }

  group('media and quote', () {
    testWidgets('the media frame has the 20 dp radius', (tester) async {
      await _pump(
        tester,
        PostMedia(
          media: [
            common.MediaRef(
              mediaId: 'm1',
              thumbUrl: '',
              width: 1600,
              height: 900,
            ),
          ],
        ),
      );

      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byType(PostMedia),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clip.borderRadius, BorderRadius.circular(AppRadius.cardSmall));
    });

    testWidgets('the quote embed has the 20 dp radius and a hairline', (
      tester,
    ) async {
      await _pump(
        tester,
        PostCard(
          view: _view(quote: true),
          graphActionsEnabled: false,
          actions: _actions(),
        ),
      );

      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(EmbeddedPostCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final decoration = box.decoration as BoxDecoration;
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppRadius.cardSmall),
      );
    });
  });

  testWidgets('a quoted poll is announced once in the embed label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final poll = pollOf();
    await _pump(
      tester,
      EmbeddedPostCard(
        embedded: pb.EmbeddedPost(
          postId: postId(2),
          text: 'Pick one',
          author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
          poll: poll,
        ),
        now: kPollNow,
        onTap: () {},
      ),
    );

    final label = tester
        .getSemantics(find.bySemanticsLabel(RegExp('^Quoted post by')))
        .label;
    final summary = PollEmbedSummary.summary(poll, kPollNow);
    expect(summary.allMatches(label).length, 1, reason: label);
    handle.dispose();
  });

  group('skeleton matches the card', () {
    for (final width in const [360.0, 599.0, 600.0, 1200.0]) {
      testWidgets('at $width the placeholder avatar sits where the card '
          'avatar does', (tester) async {
        await _pump(tester, const PostListSkeleton(rows: 1), width: width);
        final skeleton = tester.getRect(
          find
              .byWidgetPredicate(
                (w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration! as BoxDecoration).shape == BoxShape.circle,
              )
              .first,
        );
        expect(skeleton.width, AppSize.avatarPost);
        expect(skeleton.left, closeTo(postCardGutter(width) + 3, 0.5));
      });
    }
  });
}
