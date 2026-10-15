import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class MockPostsRepository extends Mock implements PostsRepository {}

void main() {
  setUpAll(registerMediaFallbacks);

  late MockPostsRepository posts;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late PendingPostsCubit pending;
  late AttachmentsCubit attachments;
  late ComposerCubit cubit;
  late List<Object> reported;
  late List<List<String>> sentMediaIds;
  late List<String> sentKeys;

  setUp(() {
    posts = MockPostsRepository();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    pending = PendingPostsCubit();
    reported = [];
    sentMediaIds = [];
    sentKeys = [];
    attachments = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
    );
    cubit = ComposerCubit(
      postsRepository: posts,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      attachments: attachments,
      onUnexpectedError: (error, _) => reported.add(error),
    );
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((invocation) async {
      sentMediaIds.add(invocation.namedArguments[#mediaIds] as List<String>);
      sentKeys.add(invocation.namedArguments[#idempotencyKey] as String);
      return postView(1);
    });
  });

  tearDown(() async {
    await cubit.close();
    await attachments.close();
    await pending.close();
  });

  Future<void> attach(List<String> tags) async {
    picker.next = [for (final t in tags) imageBytes(t)];
    await attachments.pick();
    await Future<void>.delayed(Duration.zero);
  }

  test('an image-only post is valid (empty text, one photo)', () async {
    expect(cubit.state.canSubmit, isFalse);

    await attach(['a']);

    expect(cubit.state.hasAttachments, isTrue);
    expect(cubit.state.canSubmit, isTrue);
  });

  test('a photo does not rescue an over-long text', () async {
    await attach(['a']);

    cubit.textChanged('x' * 281);

    expect(cubit.state.canSubmit, isFalse);
  });

  test('an unusable photo disables Post until it is removed', () async {
    picker.next = [imageBytes('a'), badBytes];
    await attachments.pick();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.canSubmit, isFalse);

    attachments.remove(attachments.state.items.last.id);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.canSubmit, isTrue);
  });

  test(
    'submit uploads first, then creates the post with the media ids',
    () async {
      stubHappyUpload(media);
      await attach(['a', 'b']);
      cubit.textChanged('look');

      await cubit.submit();

      expect(sentMediaIds.single, ['m1', 'm2']);
      expect(cubit.state.status, ComposerStatus.posted);
    },
  );

  test('an upload failure keeps the draft, flags it as a photo error and '
      'never creates the post', () async {
    when(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenThrow(const DegradedModeException('nomedia'));
    await attach(['a']);
    cubit.textChanged('look');

    await cubit.submit();

    expect(cubit.state.status, ComposerStatus.editing);
    expect(cubit.state.uploadFailed, isTrue);
    expect(cubit.state.error, isA<DegradedModeException>());
    expect(cubit.state.draft.text, 'look');
    expect(pending.state, isEmpty);
    verifyNever(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    );
  });

  test('retry after a failed CreatePost reuses the same media ids and the '
      'same idempotency key (no second upload, no quota spent)', () async {
    stubHappyUpload(media);
    var fail = true;
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((invocation) async {
      sentMediaIds.add(invocation.namedArguments[#mediaIds] as List<String>);
      sentKeys.add(invocation.namedArguments[#idempotencyKey] as String);
      if (fail) throw const NetworkException('offline');
      return postView(1);
    });
    await attach(['a']);
    cubit.textChanged('look');

    await cubit.submit();
    expect(cubit.state.error, isA<NetworkException>());
    expect(cubit.state.uploadFailed, isFalse);
    fail = false;
    await cubit.submit();

    expect(cubit.state.status, ComposerStatus.posted);
    expect(sentMediaIds, [
      ['m1'],
      ['m1'],
    ]);
    expect(sentKeys.toSet(), hasLength(1));
    verify(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(1);
  });

  test(
    'changing the photos mints a new key (same text, different body)',
    () async {
      stubHappyUpload(media);
      when(
        () => posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      ).thenAnswer((invocation) async {
        sentKeys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (sentKeys.length == 1) throw const NetworkException('offline');
        return postView(1);
      });
      await attach(['a']);
      cubit.textChanged('look');
      await cubit.submit();

      await attach(['b']);
      await cubit.submit();

      expect(sentKeys, hasLength(2));
      expect(sentKeys[0], isNot(sentKeys[1]));
    },
  );

  test('alt texts travel with the media ids', () async {
    stubHappyUpload(media);
    await attach(['a']);
    attachments.setAltText(attachments.state.items.single.id, 'a cat');
    List<String>? alts;
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((invocation) async {
      alts = invocation.namedArguments[#mediaAltTexts] as List<String>;
      return pb.PostView();
    });

    await cubit.submit();

    expect(alts, ['a cat']);
  });
}
