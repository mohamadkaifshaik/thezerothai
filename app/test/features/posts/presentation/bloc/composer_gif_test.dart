import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// Posting a GIF through the composer cubit (W6-16): the GIF's media id is
/// sent like a photo's, and a gate that learned `gif` is off stops the upload.
void main() {
  setUpAll(registerMediaFallbacks);

  late _MockPostsRepository posts;
  late MockMediaRepository media;
  late FakeGifSource source;
  late PendingPostsCubit pending;
  late AttachmentsCubit attachments;
  late ComposerCubit cubit;
  late List<List<String>> sent;

  setUp(() async {
    posts = _MockPostsRepository();
    media = MockMediaRepository();
    source = FakeGifSource();
    pending = PendingPostsCubit();
    sent = [];
    attachments = AttachmentsCubit(
      picker: FakeImagePicker(),
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
      gifSource: source,
      gifPreparer: FakeGifPreparer(),
    );
    cubit = ComposerCubit(
      postsRepository: posts,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      attachments: attachments,
    );
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((invocation) async {
      sent.add(invocation.namedArguments[#mediaIds] as List<String>);
      return postView(1);
    });
    stubHappyUpload(media);
    source.next = imageBytes('a');
    await attachments.pickGif();
    await Future<void>.delayed(Duration.zero); // the composer hears the stream
  });

  tearDown(() async {
    await cubit.close();
    await attachments.close();
    await pending.close();
  });

  test('a GIF post sends its media id; an image-only post is valid', () async {
    expect(cubit.state.hasAttachments, isTrue);

    await cubit.submit();

    expect(cubit.state.status, ComposerStatus.posted);
    expect(sent, [
      ['m1'],
    ]);
  });

  test(
    'gif learned to be off: nothing is uploaded and the error says so',
    () async {
      when(() => posts.subFeatureEnabled('gif')).thenReturn(false);
      cubit.textChanged('look');

      await cubit.submit();

      expect(cubit.state.status, ComposerStatus.editing);
      final error = cubit.state.error;
      expect(error, isA<FeatureDisabledException>());
      expect((error! as FeatureDisabledException).feature, 'gif');
      expect(cubit.state.uploadFailed, isTrue);
      verifyNever(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      );
      expect(sent, isEmpty);
    },
  );
}
