import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
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

class _MockPosts extends Mock implements PostsRepository {}

class _SpyDrafts extends DraftsRepository {
  _SpyDrafts(super.database);
  final List<String> cleared = [];

  @override
  Future<void> clearSend(String uid, String draftId, String key) {
    cleared.add(key);
    return super.clearSend(uid, draftId, key);
  }
}

PostSendJob _job({
  String text = 'hello',
  AttachmentsCubit? attachments,
  String? claimKey,
  String? draftId,
  DraftPoll? poll,
  String communityId = '',
  String beaconId = '',
  ReplyAudience audience = ReplyAudience.everyone,
}) => PostSendJob(
  text: text,
  author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
  policy: audience.wire,
  replyAudience: audience,
  attachments: attachments,
  claimKey: claimKey,
  uid: 'u1',
  draftId: draftId,
  poll: poll,
  communityId: communityId,
  beaconId: beaconId,
);

/// The Undo send window: nothing is uploaded or sent until it closes; Undo
/// reopens the composer with everything.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  const window = Duration(seconds: 5);
  late _MockPosts posts;
  late MockMediaRepository media;
  late PendingPostsCubit pending;
  late SessionEpoch epoch;
  late AppDatabase db;
  late _SpyDrafts drafts;
  late PostSender sender;
  late int created;

  setUp(() {
    posts = _MockPosts();
    media = MockMediaRepository();
    pending = PendingPostsCubit();
    epoch = SessionEpoch();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = _SpyDrafts(db);
    created = 0;
    sender = PostSender(
      pending: pending,
      repository: posts,
      drafts: drafts,
      sessionEpoch: epoch,
      undoDelay: () => window,
      postedFor: const Duration(minutes: 10),
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
    ).thenAnswer((_) async {
      created++;
      return postView(1);
    });
  });

  tearDown(() async {
    await sender.dispose();
    await pending.close();
    await db.close();
  });

  Future<AttachmentsCubit> photos(int count) async {
    final picker = FakeImagePicker();
    final cubit = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
    );
    picker.next = [for (var i = 0; i < count; i++) imageBytes('p$i')];
    await cubit.pick();
    await Future<void>.delayed(Duration.zero);
    return cubit;
  }

  test('nothing is sent until the window closes, then it goes', () {
    fakeAsync((async) {
      sender.start(_job());
      async.flushMicrotasks();
      final row = pending.state.single;
      expect(row.status, PendingPostStatus.holding);
      expect(row.holdSeconds, 5);

      async.elapse(const Duration(milliseconds: 4900));
      expect(created, 0);
      expect(pending.state.single.status, PendingPostStatus.holding);

      async.elapse(const Duration(milliseconds: 200));
      expect(created, 1);
      expect(pending.state.single.status, PendingPostStatus.posted);
    });
  });

  test('no upload starts during the window', () async {
    stubHappyUpload(media);
    final a = await photos(2);
    fakeAsync((async) {
      sender.start(_job(attachments: a));
      async.elapse(const Duration(seconds: 4));
      verifyNever(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      );
      verifyNever(() => media.putObject(any(), any()));
      expect(created, 0);
    });
  });

  test('Undo reopens everything and releases the unused key', () async {
    final a = await photos(1);
    final job = _job(
      text: 'take it back',
      attachments: a,
      claimKey: 'fresh',
      draftId: 'd1',
      poll: const DraftPoll(choices: ['a', 'b'], durationMinutes: 60),
      communityId: '1234567890123456789',
      beaconId: '9876543210987654321',
      audience: ReplyAudience.following,
    );
    unawaited(sender.start(job));
    final seed = await sender.undo(pending.state.single.localId);

    expect(seed!.text, 'take it back');
    expect(seed.poll!.choices, ['a', 'b']);
    expect(seed.replyAudience, ReplyAudience.following);
    expect(seed.communityId, '1234567890123456789');
    expect(seed.beaconId, '9876543210987654321');
    expect(seed.draftId, 'd1');
    expect(seed.attachments, same(a));
    expect(seed.key, isNull);
    expect(drafts.cleared, ['fresh']);
    expect(pending.state, isEmpty);
    expect(created, 0);
  });

  test('after Undo nothing is sent when the window would have closed', () {
    fakeAsync((async) {
      sender.start(_job());
      async.elapse(const Duration(seconds: 2));
      sender.undo(pending.state.single.localId);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));

      expect(created, 0);
      expect(pending.state, isEmpty);
    });
  });

  test('Undo after the window closed does nothing', () {
    fakeAsync((async) {
      sender.start(_job());
      async.elapse(const Duration(seconds: 6));
      final id = pending.state.single.localId;
      PostEditSeed? seed = PostEditSeed(text: 'x');
      sender.undo(id).then((s) => seed = s);
      async.flushMicrotasks();
      expect(seed, isNull);
      expect(created, 1);
    });
  });

  test('sign-out during the window drops everything', () async {
    final a = await photos(1);
    fakeAsync((async) {
      sender.start(_job(attachments: a));
      async.elapse(const Duration(seconds: 2));
      epoch.end();
      async.elapse(const Duration(seconds: 10));

      expect(pending.state, isEmpty);
      expect(created, 0);
    });
  });

  test('a zero window sends at once (the setting is off)', () {
    final now = PostSender(
      pending: pending,
      repository: posts,
      sessionEpoch: epoch,
      postedFor: const Duration(minutes: 10),
    );
    addTearDown(now.dispose);
    fakeAsync((async) {
      now.start(_job());
      async.flushMicrotasks();
      expect(created, 1);
    });
  });
}
