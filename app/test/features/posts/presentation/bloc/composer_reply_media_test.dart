import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

/// A reply with photos (opened from the photo viewer's reply bar): the photos
/// upload first, then CreatePost carries the reply target and the media ids,
/// and a retry after a failed CreatePost reuses the key and the ids.
void main() {
  setUpAll(registerMediaFallbacks);

  late _Posts posts;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late AttachmentsCubit attachments;
  late ComposerCubit cubit;
  late List<Map<Symbol, Object?>> sent;
  late List<Object> reported;

  setUp(() {
    posts = _Posts();
    media = MockMediaRepository();
    picker = FakeImagePicker();
    sent = [];
    reported = [];
    attachments = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
    );
    cubit = ComposerCubit.reply(
      postsRepository: posts,
      replyToPostId: postId(7),
      attachments: attachments,
      mediaOn: true,
      onUnexpectedError: (error, _) => reported.add(error),
    );
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    stubHappyUpload(media);
  });

  tearDown(() async {
    await cubit.close();
    await attachments.close();
  });

  void stubCreate({bool failFirst = false}) {
    var fail = failFirst;
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((invocation) async {
      sent.add(invocation.namedArguments);
      if (fail) {
        fail = false;
        throw const NetworkException('offline');
      }
      return postView(1);
    });
  }

  Future<void> attach(List<String> tags) async {
    picker.next = [for (final t in tags) imageBytes(t)];
    await attachments.pick();
    await Future<void>.delayed(Duration.zero);
  }

  test('a photo with no text is a valid reply', () async {
    expect(cubit.state.canSubmit, isFalse);
    await attach(['a']);
    expect(cubit.state.hasAttachments, isTrue);
    expect(cubit.state.canSubmit, isTrue);
  });

  test('submit uploads, then creates the reply with the target, the media '
      'ids and the alt texts', () async {
    stubCreate();
    await attach(['a', 'b']);
    cubit.textChanged('nice shots');

    await cubit.submit();

    expect(cubit.state.status, ComposerStatus.posted);
    final call = sent.single;
    expect(call[#replyToPostId], postId(7));
    expect(call[#text], 'nice shots');
    expect(call[#mediaIds], ['m1', 'm2']);
    verify(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(greaterThanOrEqualTo(1));
  });

  test('a failed CreatePost retries with the same key and media ids', () async {
    stubCreate(failFirst: true);
    await attach(['a']);
    cubit.textChanged('look');

    await cubit.submit();
    expect(cubit.state.error, isA<NetworkException>());
    await cubit.submit();

    expect(cubit.state.status, ComposerStatus.posted);
    expect(sent, hasLength(2));
    expect(sent[0][#mediaIds], ['m1']);
    expect(sent[1][#mediaIds], ['m1']);
    expect(sent[1][#replyToPostId], postId(7));
    expect(sent[0][#idempotencyKey], sent[1][#idempotencyKey]);
  });

  test('a text-only reply still sends no media', () async {
    stubCreate();
    final plain = ComposerCubit.reply(
      postsRepository: posts,
      replyToPostId: postId(7),
    );
    addTearDown(plain.close);
    plain.textChanged('just words');

    await plain.submit();

    expect(sent.single[#mediaIds], isEmpty);
    expect(sent.single[#replyToPostId], postId(7));
  });
}
