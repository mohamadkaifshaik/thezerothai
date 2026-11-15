import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_sender.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class MockPostsRepository extends Mock implements PostsRepository {}

PostSendJob _job({
  String text = 'hello',
  AttachmentsCubit? attachments,
  String? claimKey,
}) => PostSendJob(
  text: text,
  author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
  policy: ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
  attachments: attachments,
  claimKey: claimKey,
);

void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  late MockPostsRepository posts;
  late MockMediaRepository media;
  late PendingPostsCubit pending;
  late SessionEpoch epoch;
  late PostSender sender;
  late List<String> keys;
  late List<List<String>> mediaSent;

  setUp(() {
    posts = MockPostsRepository();
    media = MockMediaRepository();
    pending = PendingPostsCubit();
    epoch = SessionEpoch();
    keys = [];
    mediaSent = [];
    sender = PostSender(
      pending: pending,
      repository: posts,
      sessionEpoch: epoch,
      postedFor: const Duration(seconds: 3),
    );
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() async {
    await sender.dispose();
    await pending.close();
  });

  void stubCreate({Object? Function(int call)? failWith}) {
    var calls = 0;
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
      keys.add(i.namedArguments[#idempotencyKey] as String);
      mediaSent.add(i.namedArguments[#mediaIds] as List<String>);
      final failure = failWith?.call(calls++);
      if (failure != null) throw failure;
      return postView(1);
    });
  }

  Future<AttachmentsCubit> photos(int n) async {
    final picker = FakeImagePicker();
    final cubit = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
    );
    picker.next = [for (var i = 0; i < n; i++) imageBytes('p$i')];
    await cubit.pick();
    await Future<void>.delayed(Duration.zero);
    return cubit;
  }

  test('a text post goes out, shows Posted, then leaves the list', () {
    fakeAsync((async) {
      stubCreate();
      sender.start(_job());
      async.flushMicrotasks();

      expect(pending.state.single.status, PendingPostStatus.posted);
      expect(keys, hasLength(1));
      async.elapse(const Duration(seconds: 3));
      expect(pending.state, isEmpty);
    });
  });

  test('a failed CreatePost keeps its key: Retry sends the same one', () async {
    stubCreate(failWith: (n) => n == 0 ? const NetworkException('off') : null);

    await sender.start(_job());
    final row = pending.state.single;
    expect(row.status, PendingPostStatus.failed);
    expect(row.error, isNotEmpty);

    await sender.retry(row.localId);

    expect(pending.state.single.status, PendingPostStatus.posted);
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });

  test('a stored key is the one sent', () async {
    stubCreate();
    await sender.start(_job(claimKey: 'stored-key'));
    expect(keys.single, 'stored-key');
  });

  test('upload failure shows Retry; Retry uploads once and posts with the '
      'finished media', () async {
    stubHappyUpload(media);
    var failPut = true;
    when(() => media.putObject(any(), any())).thenAnswer((_) async {
      if (failPut) {
        failPut = false;
        throw const NetworkException('offline');
      }
    });
    stubCreate();
    final attachments = await photos(2);

    await sender.start(_job(attachments: attachments));
    expect(pending.state.single.status, PendingPostStatus.failed);
    expect(keys, isEmpty);

    await sender.retry(pending.state.single.localId);

    expect(pending.state.single.status, PendingPostStatus.posted);
    expect(mediaSent.single, ['m1', 'm2']);
    expect(keys, hasLength(1));
    verify(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).called(1);
    await attachments.close();
  });

  test('progress counts finished photos while uploading', () async {
    final gate = Completer<void>();
    var puts = 0;
    stubHappyUpload(
      media,
      onPut: (_) {
        // The first photo (full + thumb) passes, the second waits.
        puts++;
        return puts > 2 ? gate.future : Future<void>.value();
      },
    );
    stubCreate();
    final attachments = await photos(2);

    final done = sender.start(_job(attachments: attachments));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final row = pending.state.single;
    expect(row.status, PendingPostStatus.sending);
    expect(row.photosTotal, 2);
    expect(row.uploading, isTrue);
    gate.complete();
    await done;
    expect(pending.state.single.status, PendingPostStatus.posted);
    await attachments.close();
  });

  test('a refusal of CreatePost cannot be retried (Edit only)', () async {
    stubCreate(failWith: (_) => const ValidationException('bad'));

    await sender.start(_job());

    expect(pending.state.single.status, PendingPostStatus.failed);
    expect(pending.state.single.canRetry, isFalse);
  });

  test('a key the server knows with another body offers Edit only', () async {
    stubCreate(failWith: (_) => const IdempotencyKeyReusedException('reused'));

    await sender.start(_job());

    expect(pending.state.single.canRetry, isFalse);
  });

  test('sign-out mid-upload: no further request, no CreatePost, nothing '
      'lingers', () async {
    final gate = Completer<void>();
    stubHappyUpload(media, onPut: (_) => gate.future);
    stubCreate();
    final attachments = await photos(1);

    final done = sender.start(_job(attachments: attachments));
    await Future<void>.delayed(Duration.zero);
    expect(pending.state, hasLength(1));

    epoch.end();
    gate.complete();
    await done;

    expect(pending.state, isEmpty);
    verifyNever(
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
    );
    await attachments.close();
  });

  test('dismiss removes the row and releases the photos', () async {
    stubCreate(failWith: (_) => const NetworkException('off'));
    await sender.start(_job());

    final id = await sender.release(pending.state.single.localId);

    expect(id, isNull);
    expect(pending.state, isEmpty);
  });
}
