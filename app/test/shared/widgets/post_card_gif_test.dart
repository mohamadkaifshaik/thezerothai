import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/gif_badge.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:dzeroth/shared/widgets/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/posts_fixtures.dart';

const _still = 'https://cdn.example/m/g1-abc_t.jpg';
const _full = 'https://cdn.example/m/g1-abc.gif';

/// A GIF inside a post row (W6-16): the tap on the GIF plays it, the tap
/// elsewhere on the row still opens the post.
void main() {
  Set<String> urls(WidgetTester tester) => {
    for (final w in tester.widgetList<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    ))
      w.imageUrl,
  };

  testWidgets('a tap on the GIF plays it and does not open the post', (
    tester,
  ) async {
    addTearDown(() => tester.takeException());
    final opened = <String>[];
    final view = postView(1)
      ..post.media.add(
        common.MediaRef(
          url: _full,
          thumbUrl: _still,
          width: 320,
          height: 240,
          contentType: 'image/gif',
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PostCard(
              view: view,
              graphActionsEnabled: false,
              onOpenPost: opened.add,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(GifBadge), findsOneWidget);
    expect(urls(tester), {_still}, reason: 'the full file is not fetched yet');

    await tester.tap(find.byType(PostMedia));
    await tester.pump();

    expect(urls(tester), contains(_full));
    expect(opened, isEmpty, reason: 'the tap belongs to the GIF');
  });

  testWidgets('in a quote the GIF plays; the rest of the quote still opens '
      'the original', (tester) async {
    addTearDown(() => tester.takeException());
    final opened = <String>[];
    final view = pb.PostView(
      post: pb.Post(
        postId: postId(60),
        kind: PostKind.POST_KIND_QUOTE,
        text: 'my take',
        author: common.AuthorSnapshot(userId: 'u-bob', handle: 'bob'),
        embedded: pb.EmbeddedPost(
          postId: postId(61),
          text: 'the original words',
          author: common.AuthorSnapshot(userId: 'u-amy', handle: 'amy'),
          media: [
            common.MediaRef(
              url: _full,
              thumbUrl: _still,
              width: 320,
              height: 240,
              contentType: 'image/gif',
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PostCard(
              view: view,
              graphActionsEnabled: false,
              onOpenPost: opened.add,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(PostMedia));
    await tester.pump();
    expect(urls(tester), contains(_full));
    expect(opened, isEmpty, reason: 'the GIF takes its own tap');

    await tester.tap(find.text('the original words'));
    await tester.pump();
    expect(opened, [postId(61)]);
  });
}
