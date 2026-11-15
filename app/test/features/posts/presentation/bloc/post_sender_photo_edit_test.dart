import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/photo_edit.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_sender.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _MockPosts extends Mock implements PostsRepository {}

/// The background send posts the photos as the user left them: reordered,
/// edited, with their alt texts, and never an upload of pixels that were
/// edited afterwards.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  late _MockPosts posts;
  late MockMediaRepository media;
  late PendingPostsCubit pending;
  late PostSender sender;
  late List<List<String>> mediaSent;
  late List<List<String>?> altsSent;
  late List<String> uploadedOrder;

  setUp(() {
    posts = _MockPosts();
    media = MockMediaRepository();
    pending = PendingPostsCubit();
    mediaSent = [];
    altsSent = [];
    uploadedOrder = [];
    sender = PostSender(
      pending: pending,
      repository: posts,
      sessionEpoch: SessionEpoch(),
      postedFor: const Duration(seconds: 3),
    );
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
        poll: any(named: 'poll'),
        communityId: any(named: 'communityId'),
        beaconId: any(named: 'beaconId'),
      ),
    ).thenAnswer((i) async {
      mediaSent.add(i.namedArguments[#mediaIds] as List<String>);
      altsSent.add(i.namedArguments[#mediaAltTexts] as List<String>?);
      return postView(1);
    });
  });

  tearDown(() async {
    await sender.dispose();
    await pending.close();
  });

  PostSendJob job(AttachmentsCubit attachments) => PostSendJob(
    text: 'hello',
    author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
    policy: ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    attachments: attachments,
  );

  test('edited and reordered photos are posted in order, edited pixels '
      'uploaded once', () async {
    stubHappyUpload(media);
    // Record which image each reservation holds, in order.
    when(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenAnswer((i) async {
      final images = i.namedArguments[#images] as List;
      uploadedOrder.addAll([for (final im in images) im.fullMd5 as String]);
      return [
        for (var n = 0; n < images.length; n++)
          uploadTarget(
            'm${uploadedOrder.length - images.length + n + 1}',
            expiresAt: DateTime.now().add(const Duration(minutes: 10)),
          ),
      ];
    });
    final processor = FakeImageProcessor();
    final picker = FakeImagePicker()
      ..next = [imageBytes('a'), imageBytes('b'), imageBytes('c')];
    final attachments = AttachmentsCubit(
      picker: picker,
      processor: processor,
      uploader: MediaUploader(repository: media),
    );
    await attachments.pick();
    final ids = [for (final a in attachments.state.items) a.id];

    // Edit the first photo, describe the second, then move the first last.
    attachments.applyEdit(ids[0], const PhotoEdit(quarterTurns: 1), '');
    attachments.setAltText(ids[1], 'the second');
    await pumpEventQueue();
    attachments.reorder(0, 2);
    expect(processor.edits, [
      null,
      null,
      null,
      const PhotoEdit(quarterTurns: 1),
    ]);

    await sender.start(job(attachments));

    expect(pending.state.single.status, PendingPostStatus.posted);
    // Picture order b, c, a: the media ids follow it.
    expect(uploadedOrder, ['full-b', 'full-c', 'full-a']);
    expect(mediaSent.single, ['m1', 'm2', 'm3']);
    expect(altsSent.single, ['the second', '', '']);
    await attachments.close();
  });

  test('a photo edited after a failed send is uploaded again with the new '
      'pixels on retry', () async {
    stubHappyUpload(media);
    var failPut = true;
    when(() => media.putObject(any(), any())).thenAnswer((_) async {
      if (failPut) {
        failPut = false;
        throw const NetworkException('offline');
      }
    });
    final processor = FakeImageProcessor();
    final attachments = AttachmentsCubit(
      picker: FakeImagePicker()..next = [imageBytes('a')],
      processor: processor,
      uploader: MediaUploader(repository: media),
    );
    await attachments.pick();
    await sender.start(job(attachments));
    expect(pending.state.single.status, PendingPostStatus.failed);

    // Edit (as Edit does after reclaim), then send again.
    final id = attachments.state.items.single.id;
    attachments.applyEdit(id, const PhotoEdit(quarterTurns: 2), '');
    await pumpEventQueue();
    expect(processor.edits.last, const PhotoEdit(quarterTurns: 2));
    await sender.retry(pending.state.single.localId);

    expect(pending.state.single.status, PendingPostStatus.posted);
    expect(mediaSent, hasLength(1));
    await attachments.close();
  });
}
