import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/widgets/composer_extras_buttons.dart';
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as media_pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/gif_badge.dart';
import 'package:dzeroth/shared/widgets/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/w6_composer_rig.dart';

class _MockPosts extends Mock implements PostsRepository {}

const _still = 'https://cdn.example/m/g1-abc_t.jpg';
const _full = 'https://cdn.example/m/g1-abc.gif';

/// W6-19: GIF attach in the composer -> upload -> CreatePost -> the feed row
/// shows a still with a GIF badge -> a tap plays it (and does not open the
/// post).
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  testWidgets('attach, post, see the still, tap to play', (tester) async {
    // The test binding cannot download; CachedNetworkImage shows its error.
    addTearDown(() => tester.takeException());
    final posts = _MockPosts();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    List<String>? sentMedia;
    final created = ValueNotifier<pb.PostView?>(null);
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
        poll: any(named: 'poll'),
      ),
    ).thenAnswer((invocation) async {
      sentMedia = invocation.namedArguments[#mediaIds] as List<String>;
      final view = postView(1, authorId: 'uid-1', text: 'moving picture')
        ..post.media.add(
          common.MediaRef(
            url: _full,
            thumbUrl: _still,
            width: 320,
            height: 240,
            contentType: 'image/gif',
          ),
        );
      created.value = view;
      return view;
    });

    final rig = await pumpW6Composer(
      tester,
      posts: posts,
      drafts: FakeDraftsRepository(),
      home: (context) => Scaffold(
        body: ValueListenableBuilder<pb.PostView?>(
          valueListenable: created,
          builder: (context, view, _) => view == null
              ? const Text('home page')
              : SingleChildScrollView(
                  child: FeedPostRow(
                    view: view,
                    viewerUserId: 'uid-1',
                    graphEnabled: false,
                    reportsEnabled: false,
                    engagementEnabled: false,
                  ),
                ),
        ),
      ),
    );
    final uploaded = <media_pb.SignedUpload>[];
    stubHappyUpload(rig.media, onPut: (t) async => uploaded.add(t));

    rig.gifSource.next = imageBytes('a');
    await tester.tap(
      find.descendant(
        of: find.byType(ComposerGifButton),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'moving picture');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
    await tester.pumpAndSettle();

    // One CreateUpload for one GIF, both objects PUT, the id sent on.
    final createCall = verify(
      () => rig.media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: captureAny(named: 'images'),
      ),
    )..called(1);
    final images = createCall.captured.single as List;
    expect(images, hasLength(1));
    expect(images.single.isGif, isTrue);
    expect(uploaded, hasLength(2));
    expect(sentMedia, ['m1']);

    // The feed row: a still, a GIF badge, nothing of the full file yet.
    Set<String> urls() => {
      for (final w in tester.widgetList<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      ))
        w.imageUrl,
    };
    expect(find.text('moving picture'), findsOneWidget);
    expect(find.byType(GifBadge), findsOneWidget);
    expect(urls(), {_still});

    await tester.tap(find.byType(PostMedia));
    await tester.pump();
    expect(urls(), contains(_full));
    expect(find.text('post detail page'), findsNothing);
  });
}
