import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/embedded_post_card.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:dzeroth/shared/widgets/post_media.dart';
import 'package:dzeroth/shared/widgets/protected_post_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/geometry.dart';
import '../../support/posts_fixtures.dart';
import '../../support/theme_harness.dart';

const _message = 'This post is from an account that protects its posts.';

/// What a hostile or older server could still put in the embed: the card must
/// show none of it.
pb.EmbeddedPost _protectedEmbed() => pb.EmbeddedPost(
  postId: postId(1),
  text: 'secret words that must not show',
  author: common.AuthorSnapshot(
    userId: 'u-orig',
    handle: 'orig',
    displayName: 'Original Author',
    avatarUrl: 'https://cdn.example/avatar.jpg',
  ),
  media: [
    common.MediaRef(
      mediaId: 'm1',
      url: 'https://cdn.example/full.jpg',
      thumbUrl: 'https://cdn.example/thumb.jpg',
      width: 100,
      height: 100,
    ),
  ],
);

pb.PostView _viewOf(PostKind kind) => pb.PostView(
  post: pb.Post(
    postId: postId(60),
    kind: kind,
    text: kind == PostKind.POST_KIND_QUOTE ? 'my take' : '',
    author: common.AuthorSnapshot(
      userId: 'u-bob',
      handle: 'bob',
      displayName: 'Bob B',
    ),
    embedded: _protectedEmbed(),
  ),
  embedViewerState: pb.EmbedViewerState.EMBED_VIEWER_STATE_PROTECTED,
);

/// W3-33b: the PROTECTED embed shows the author and one sentence, and nothing
/// of the post, across the W3-21 matrix.
void main() {
  void expectNothingOfThePost(WidgetTester tester) {
    expect(find.text('secret words that must not show'), findsNothing);
    expect(find.byType(PostMedia), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.text('Original Author'), findsOneWidget);
    expect(find.text('@orig'), findsOneWidget);
    expect(find.text(_message), findsOneWidget);
  }

  forEachThemeAndWidth('a quote of a protected author', (tester, env) async {
    await pumpThemed(
      tester,
      SingleChildScrollView(
        child: PostCard(
          view: _viewOf(PostKind.POST_KIND_QUOTE),
          graphActionsEnabled: false,
        ),
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('my take'), findsOneWidget);
    expect(find.byType(ProtectedPostBox), findsOneWidget);
    expectNothingOfThePost(tester);
    expectInsideHorizontally(
      tester,
      find.byType(ProtectedPostBox),
      env.size.width,
    );
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('a repost row of a protected author shows the same box', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      SingleChildScrollView(
        child: PostCard(
          view: _viewOf(PostKind.POST_KIND_REPOST),
          graphActionsEnabled: false,
        ),
      ),
    );
    expect(find.byType(ProtectedPostBox), findsOneWidget);
    expectNothingOfThePost(tester);
  });

  testWidgets('the box is not tappable and is one labelled node', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      SingleChildScrollView(
        child: PostCard(
          view: _viewOf(PostKind.POST_KIND_QUOTE),
          graphActionsEnabled: false,
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(ProtectedPostBox),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    expect(
      tester.getSemantics(find.byType(ProtectedPostBox)).label,
      contains(_message),
    );
  });

  testWidgets('EmbeddedPostCard with the protected placeholder', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      EmbeddedPostCard(
        embedded: _protectedEmbed(),
        placeholder: EmbedPlaceholder.protected,
        onTap: () {},
      ),
    );
    expectNothingOfThePost(tester);
  });

  testWidgets('a handle-only author is shown once', (tester) async {
    await pumpThemed(
      tester,
      ProtectedPostBox(author: common.AuthorSnapshot(handle: 'quiet')),
    );
    expect(find.text('@quiet'), findsOneWidget);
  });
}
