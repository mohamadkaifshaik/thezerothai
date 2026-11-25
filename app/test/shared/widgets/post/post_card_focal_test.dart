import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:dzeroth/shared/format/relative_time.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../support/dz_finders.dart';
import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

final _created = DateTime.utc(2026, 11, 1, 15, 41);

pb.PostView _view(String text) => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    text: text,
    createdAt: ts.Timestamp.fromDateTime(_created),
    author: common.AuthorSnapshot(
      userId: 'u1',
      handle: 'alice',
      displayName: 'Alice A',
    ),
  ),
);

/// The open post of a thread laid out like X's post page (captured
/// 2026-11-02).
void main() {
  Future<void> pumpCard(
    WidgetTester tester,
    MatrixEnv env,
    String text, {
    bool focal = true,
    PostActions? actions,
  }) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: _MockGraphRepository(),
      child: SingleChildScrollView(
        child: PostCard(
          view: _view(text),
          focal: focal,
          graphActionsEnabled: false,
          now: _created.add(const Duration(hours: 22)),
          actions: actions,
        ),
      ),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
  );

  const phone = MatrixEnv(
    brightness: Brightness.dark,
    size: Size(400, 800),
    textScale: 1,
  );

  forEachThemeAndWidth('focal layout never overflows', (tester, env) async {
    await pumpCard(
      tester,
      env,
      'a long focal post ' * 20,
      actions: PostActions(onReply: () {}, onLike: () {}, onShare: () {}),
    );
    expectNoOverflow(tester);
  }, textScales: const [1.0, 1.3, 2.0]);

  testWidgets('name over handle, no relative time, full time below', (
    tester,
  ) async {
    await pumpCard(tester, phone, 'hello');

    expect(find.text('22h'), findsNothing);
    expect(
      tester.getTopLeft(find.text('@alice')).dy,
      greaterThan(tester.getTopLeft(find.text('Alice A')).dy),
    );
    final stamp = find.text(formatPostTimestamp(_created));
    expect(stamp, findsOneWidget);
    expect(
      tester.getTopLeft(stamp).dy,
      greaterThan(tester.getTopLeft(find.byType(PostRichText)).dy),
    );
  });

  testWidgets('text runs the full width in the focal type, unclamped', (
    tester,
  ) async {
    await pumpCard(tester, phone, List.filled(12, 'line').join('\n'));

    final text = tester.widget<PostRichText>(find.byType(PostRichText));
    expect(text.style!.fontSize, AppFocalPost.bodySize);
    expect(
      text.style!.height! * text.style!.fontSize!,
      closeTo(AppFocalPost.bodyLineHeight, 0.01),
    );
    expect(text.maxLines, isNull);
    // Starts at the card's left padding, under the avatar, not beside it
    // (the phone gutter is 20 dp since the R1 restyle; was 16).
    expect(
      tester.getTopLeft(find.byType(PostRichText)).dx,
      postCardGutter(phone.size.width),
    );
  });

  testWidgets('the action row is evenly spaced with larger glyphs', (
    tester,
  ) async {
    await pumpCard(
      tester,
      phone,
      'hello',
      actions: PostActions(onReply: () {}, onLike: () {}, onShare: () {}),
    );

    final bar = tester.widget<PostActionBar>(find.byType(PostActionBar));
    // 21 dp (the DzPost artboard) on every width; it was 18 below 600 and 20
    // from 600 up before the Dz redesign.
    expect(bar.iconSize, AppFocalPost.actionIconPhone);
    expect(bar.layout, PostActionBarLayout.spread);
    final shareBox = tester.getRect(
      find.ancestor(
        of: findDz(DzIcons.share),
        matching: find.byType(InkResponse),
      ),
    );
    final replyBox = tester.getRect(
      find.ancestor(
        of: findDz(DzIcons.reply),
        matching: find.byType(InkResponse),
      ),
    );
    // The phone gutter is 20 dp since the R1 restyle (was 16). The opened
    // post spreads its 48 dp boxes (space-around), so the outer boxes sit
    // half a gap inside the gutters, the same on both sides.
    final gutter = postCardGutter(phone.size.width);
    expect(replyBox.left, greaterThan(gutter));
    expect(
      replyBox.left - gutter,
      closeTo(phone.size.width - gutter - shareBox.right, 1),
    );
    expect(
      tester.getTopLeft(findDz(DzIcons.share)).dx,
      greaterThan(shareBox.left),
    );
    expect(tester.getRect(findDz(DzIcons.like)).right, lessThan(shareBox.left));
  });

  pb.PostView withEmbedded(PostKind kind, {String text = 'my take'}) =>
      pb.PostView(
        post: pb.Post(
          postId: postId(2),
          kind: kind,
          text: text,
          createdAt: ts.Timestamp.fromDateTime(_created),
          author: common.AuthorSnapshot(
            userId: 'u1',
            handle: 'alice',
            displayName: 'Alice A',
          ),
          media: [
            common.MediaRef(
              url: 'https://cdn.example/m/a.jpg',
              thumbUrl: 'https://cdn.example/m/a_t.jpg',
              width: 1200,
              height: 800,
              contentType: 'image/jpeg',
            ),
          ],
          embedded: pb.EmbeddedPost(
            postId: postId(3),
            text: 'the original words ' * 8,
            createdAt: ts.Timestamp.fromDateTime(_created),
            author: common.AuthorSnapshot(
              userId: 'u2',
              handle: 'bob',
              displayName: 'Bob B',
            ),
            media: [
              common.MediaRef(
                url: 'https://cdn.example/m/b.jpg',
                thumbUrl: 'https://cdn.example/m/b_t.jpg',
                width: 800,
                height: 1200,
                contentType: 'image/jpeg',
              ),
            ],
          ),
        ),
      );

  testWidgets(
    'focal quote with an image and an embed fits at 360dp, text 2.0',
    (tester) async {
      addTearDown(() => tester.takeException()); // test images never load
      await pumpThemed(
        tester,
        RepositoryProvider<GraphRepository>.value(
          value: _MockGraphRepository(),
          child: SingleChildScrollView(
            child: PostCard(
              view: withEmbedded(
                PostKind.POST_KIND_QUOTE,
                text: 'my take ' * 20,
              ),
              focal: true,
              graphActionsEnabled: false,
              now: _created.add(const Duration(hours: 22)),
              actions: PostActions(
                onReply: () {},
                onLike: () {},
                onShare: () {},
              ),
            ),
          ),
        ),
        size: const Size(360, 800),
        textScale: 2.0,
      );

      expectNoOverflow(tester);
      expect(find.text(formatPostTimestamp(_created)), findsOneWidget);
      expect(find.text('Bob B'), findsOneWidget, reason: 'the quote embed');
      expect(
        tester.widget<PostActionBar>(find.byType(PostActionBar)).iconSize,
        AppFocalPost.actionIconPhone,
      );
    },
  );

  testWidgets('a focal REPOST keeps the list layout (the original, relative '
      'time, list-size glyphs)', (tester) async {
    addTearDown(() => tester.takeException());
    await pumpThemed(
      tester,
      RepositoryProvider<GraphRepository>.value(
        value: _MockGraphRepository(),
        child: SingleChildScrollView(
          child: PostCard(
            view: withEmbedded(PostKind.POST_KIND_REPOST),
            focal: true,
            graphActionsEnabled: false,
            now: _created.add(const Duration(hours: 22)),
            actions: PostActions(onReply: () {}, onLike: () {}),
          ),
        ),
      ),
      size: const Size(400, 800),
    );

    expect(find.text('22h'), findsOneWidget);
    expect(find.text(formatPostTimestamp(_created)), findsNothing);
    expect(
      tester.widget<PostActionBar>(find.byType(PostActionBar)).iconSize,
      AppIconSize.postAction,
    );
    final text = tester.widget<PostRichText>(find.byType(PostRichText));
    expect(text.style?.fontSize, isNot(AppFocalPost.bodySize));
    expect(text.maxLines, isNull, reason: "a focal repost shows all of it");
  });

  testWidgets('list rows keep the one-line author and the relative time', (
    tester,
  ) async {
    await pumpCard(tester, phone, 'hello', focal: false);

    expect(find.text('22h'), findsOneWidget);
    expect(find.text(formatPostTimestamp(_created)), findsNothing);
    expect(
      tester.getTopLeft(find.text('@alice')).dy,
      closeTo(tester.getTopLeft(find.text('Alice A')).dy, 2),
    );
  });
}
