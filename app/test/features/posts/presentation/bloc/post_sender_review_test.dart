import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
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

/// The real store, counting [clearSend].
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
  bool claimReused = false,
  DateTime? claimStartedAt,
  String? draftId,
  String? deleteDraftId,
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
  claimReused: claimReused,
  claimStartedAt: claimStartedAt,
  uid: 'u1',
  draftId: draftId,
  deleteDraftId: deleteDraftId,
  poll: poll,
  communityId: communityId,
  beaconId: beaconId,
);

void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  late _MockPosts posts;
  late MockMediaRepository media;
  late PendingPostsCubit pending;
  late SessionEpoch epoch;
  late AppDatabase db;
  late _SpyDrafts drafts;
  late DateTime now;
  late PostSender sender;
  late List<String> keys;

  setUp(() {
    posts = _MockPosts();
    media = MockMediaRepository();
    pending = PendingPostsCubit();
    epoch = SessionEpoch();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = _SpyDrafts(db);
    now = DateTime.now().toUtc();
    keys = [];
    sender = PostSender(
      pending: pending,
      repository: posts,
      drafts: drafts,
      sessionEpoch: epoch,
      clock: () => now,
      postedFor: const Duration(seconds: 3),
    );
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() async {
    await sender.dispose();
    await pending.close();
    await db.close();
  });

  /// CreatePost: the n-th call fails with what `failures[n]` says (null: ok).
  void stubCreate(List<AppException?> failures, {Completer<void>? gate}) {
    var n = 0;
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
      if (gate != null) await gate.future;
      final f = n < failures.length ? failures[n] : null;
      n++;
      if (f != null) throw f;
      return postView(1);
    });
  }

  Future<AttachmentsCubit> photos(int count, {String tag = 'p'}) async {
    final picker = FakeImagePicker();
    final cubit = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
    );
    picker.next = [for (var i = 0; i < count; i++) imageBytes('$tag$i')];
    await cubit.pick();
    await Future<void>.delayed(Duration.zero);
    return cubit;
  }

  const offline = NetworkException('offline');

  group('B1: a reused stored key is never released', () {
    test('upload failure then dismiss keeps the stored key', () async {
      stubCreate([]);
      stubHappyUpload(media);
      when(() => media.putObject(any(), any()))
          .thenAnswer((_) async => throw const NetworkException('offline'));
      final a = await photos(1);

      await sender.start(
        _job(
          attachments: a,
          claimKey: 'stored',
          claimReused: true,
          draftId: 'd1',
        ),
      );
      await sender.release(pending.state.single.localId);

      expect(drafts.cleared, isEmpty);
    });

    test('a fresh key that nothing used is released on dismiss', () async {
      stubCreate([]);
      stubHappyUpload(media);
      when(() => media.putObject(any(), any()))
          .thenAnswer((_) async => throw const NetworkException('offline'));
      final a = await photos(1);

      await sender.start(
        _job(attachments: a, claimKey: 'fresh', draftId: 'd1'),
      );
      await sender.release(pending.state.single.localId);

      expect(drafts.cleared, ['fresh']);
    });
  });

  group('M1: a used key is kept', () {
    test('Retry past the stored key window after an ambiguous failure is '
        'refused', () async {
      stubCreate([offline]);
      await sender.start(
        _job(
          claimKey: 'k',
          draftId: 'd1',
          // Fresh when minted, a day old by the time of the retry.
          claimStartedAt: now.subtract(const Duration(hours: 22)),
        ),
      );
      expect(pending.state.single.canRetry, isTrue);

      now = now.add(const Duration(hours: 3));
      await sender.retry(pending.state.single.localId);

      expect(keys, hasLength(1), reason: 'no second CreatePost');
      expect(pending.state.single.canRetry, isFalse);
    });

    test('FeatureDisabled after an ambiguous failure keeps the key', () async {
      stubCreate([offline, const FeatureDisabledException('off')]);
      await sender.start(_job(claimKey: 'k', draftId: 'd1'));
      await sender.retry(pending.state.single.localId);
      expect(pending.state.single.canRetry, isFalse);

      await sender.edit(pending.state.single.localId);

      expect(drafts.cleared, isEmpty);
    });

    test('FeatureDisabled on the first use proves it: Edit releases the '
        'key', () async {
      stubCreate([const FeatureDisabledException('off')]);
      await sender.start(_job(claimKey: 'k', draftId: 'd1'));

      await sender.edit(pending.state.single.localId);

      expect(drafts.cleared, ['k']);
    });
  });

  test('M2: the key is pinned on the send, whatever else is sent meanwhile '
      '(no stored key, no draft)', () async {
    stubCreate([offline, for (var i = 0; i < 9; i++) offline]);
    await sender.start(_job(text: 'first'));
    final first = pending.state.single.localId;
    final key = keys.single;
    for (var i = 0; i < 9; i++) {
      await sender.start(_job(text: 'other $i'));
    }
    stubCreate([]);
    keys.clear();

    await sender.retry(first);

    expect(keys.single, key);
  });

  group('M3: Edit is always there', () {
    test('without a row the seed carries the post itself', () async {
      stubCreate([offline]);
      await sender.start(
        _job(
          text: 'my words',
          communityId: '1234567890123456789',
          audience: ReplyAudience.following,
        ),
      );

      final seed = await sender.edit(pending.state.single.localId);

      expect(seed!.text, 'my words');
      expect(seed.draftId, isNull);
      expect(seed.communityId, '1234567890123456789');
      expect(seed.replyAudience, ReplyAudience.following);
      expect(pending.state, isEmpty);
    });

    test('with a row the seed continues it', () async {
      stubCreate([offline]);
      await sender.start(_job(claimKey: 'k', draftId: 'd1'));

      final seed = await sender.edit(pending.state.single.localId);

      expect(seed!.draftId, 'd1');
      expect(drafts.cleared, isEmpty, reason: 'ambiguous: the key stays');
    });

    test('Edit and Dismiss do nothing while the send runs', () async {
      final gate = Completer<void>();
      stubCreate([], gate: gate);
      final done = sender.start(_job());
      await Future<void>.delayed(Duration.zero);
      final id = pending.state.single.localId;

      expect(await sender.edit(id), isNull);
      expect(await sender.release(id), isNull);
      expect(pending.state, hasLength(1));

      gate.complete();
      await done;
    });
  });

  group('M4: permanent refusals are cleared by Edit', () {
    Future<PostEditSeed> failAndEdit(
      AppException error,
      PostSendJob job,
    ) async {
      stubCreate([error]);
      await sender.start(job);
      expect(pending.state.single.canRetry, isFalse);
      return (await sender.edit(pending.state.single.localId))!;
    }

    test('community lost', () async {
      final seed = await failAndEdit(
        CommunityForbiddenException(CommunityForbiddenReason.notMember),
        _job(communityId: '1234567890123456789'),
      );
      expect(seed.communityId, '');
    });

    test('plan missing', () async {
      final seed = await failAndEdit(
        const NotFoundException('gone'),
        _job(beaconId: '1234567890123456789'),
      );
      expect(seed.beaconId, '');
    });

    test('poll refused', () async {
      final seed = await failAndEdit(
        const FeatureDisabledException('off', feature: 'polls'),
        _job(poll: const DraftPoll(choices: ['a', 'b'], durationMinutes: 60)),
      );
      expect(seed.poll, isNull);
      expect(seed.text, 'hello');
    });

    test('reply audience refused', () async {
      final seed = await failAndEdit(
        const FeatureDisabledException('off', feature: kFeatureReplyAudience),
        _job(audience: ReplyAudience.following),
      );
      expect(seed.replyAudience, ReplyAudience.everyone);
    });

    test('media refused: the photos are dropped, the row says so', () async {
      stubHappyUpload(media);
      stubCreate([
        const FeatureDisabledException('off', feature: kPostsSubFeatureMedia),
      ]);
      final a = await photos(1);
      await sender.start(_job(attachments: a));
      expect(pending.state.single.keepsPhotos, isFalse);

      final seed = await sender.edit(pending.state.single.localId);

      expect(seed!.attachments, isNull);
    });

    test('email not verified: Retry stays, the row offers Verify', () async {
      stubCreate([const EmailNotVerifiedException('verify')]);
      await sender.start(_job());
      final row = pending.state.single;
      expect(row.needsVerify, isTrue);
      expect(row.canRetry, isTrue);
    });

    test('Edit keeps the photos and their uploads', () async {
      stubHappyUpload(media);
      stubCreate([const NetworkException('offline')]);
      final a = await photos(2);
      await sender.start(_job(attachments: a));
      // The composer screen went away meanwhile: its close was deferred.
      await a.close();
      expect(a.isClosed, isFalse);

      final seed = await sender.edit(pending.state.single.localId);

      expect(seed!.attachments, same(a));
      expect(a.isClosed, isFalse);
      expect(
        a.state.items.map((i) => i.mediaId),
        everyElement(isNotEmpty),
        reason: 'uploads are kept',
      );
      await a.close();
      expect(a.isClosed, isTrue, reason: 'now the composer owns it');
    });
  });

  group('M5: lifecycle', () {
    test('sign-out during CreatePost: nothing lingers', () async {
      final gate = Completer<void>();
      stubCreate([], gate: gate);
      final done = sender.start(_job());
      await Future<void>.delayed(Duration.zero);

      epoch.end();
      gate.complete();
      await done;

      expect(pending.state, isEmpty);
    });

    test('retain defers the close until release', () async {
      final a = await photos(1);
      a.retain();

      await a.close();
      expect(a.isClosed, isFalse);
      await a.release();

      expect(a.isClosed, isTrue);
    });

    test('dispose stops the epoch listener and clears', () async {
      stubCreate([offline]);
      await sender.start(_job());

      await sender.dispose();

      expect(pending.state, isEmpty);
      epoch.end(); // no listener left: nothing throws
    });

    test('reset cancels the Posted timer', () {
      fakeAsync((async) {
        stubCreate([]);
        sender.start(_job());
        async.flushMicrotasks();
        expect(pending.state.single.status, PendingPostStatus.posted);
        expect(async.nonPeriodicTimerCount, 1);

        sender.reset();

        expect(async.nonPeriodicTimerCount, 0);
        expect(pending.state, isEmpty);
      });
    });

    test('a saved draft is deleted when an image-only post succeeds', () async {
      stubCreate([]);
      final row = ComposerDraft(
        id: 'a1a1a1a1a1a1a1a1',
        uid: 'u1',
        text: 'was typed',
        createdAt: now,
        updatedAt: now,
      );
      await drafts.upsert(row);

      await sender.start(_job(text: '', deleteDraftId: row.id));
      await Future<void>.delayed(Duration.zero);

      expect(await drafts.read('u1', row.id), isNull);
    });

    test('Retry works as soon as the row shows failed', () async {
      stubCreate([offline]);
      await sender.start(_job());

      await sender.retry(pending.state.single.localId);

      expect(pending.state.single.status, PendingPostStatus.posted);
    });
  });

  test('only the newest 3 failed rows keep their photo bytes; the older '
      'keep their uploads and Retry still posts', () async {
    stubHappyUpload(media);
    stubCreate([for (var i = 0; i < 4; i++) offline]);
    final cubits = <AttachmentsCubit>[];
    for (var i = 0; i < 4; i++) {
      final a = await photos(1, tag: 'x$i');
      cubits.add(a);
      await sender.start(_job(text: 'post $i', attachments: a));
      // The composer screen is gone: its close waits for the sender.
      await a.close();
    }

    final oldest = pending.state.last; // newest first
    expect(oldest.text, 'post 0');
    expect(oldest.keepsPhotos, isFalse);
    expect(oldest.canRetry, isTrue);
    expect(pending.state.first.keepsPhotos, isTrue);
    expect(cubits[0].isClosed, isTrue);

    stubCreate([]);
    keys.clear();
    await sender.retry(oldest.localId);

    expect(
      pending.state.firstWhere((p) => p.text == 'post 0').status,
      PendingPostStatus.posted,
    );
  });

  group('Edit carries a key that may exist on the server', () {
    test('ambiguous failure, Edit, Post unchanged: the original key goes '
        'out again', () async {
      stubCreate([offline, null]);
      await sender.start(_job(text: 'same words'));
      final original = keys.single;

      final seed = await sender.edit(pending.state.single.localId);

      expect(seed!.key, original);
      expect(seed.keyStartedAt, isNotNull);
      // What the composer then hands over: a reused claim under that key.
      await sender.start(
        _job(
          text: 'same words',
          claimKey: seed.key,
          claimReused: true,
          claimStartedAt: seed.keyStartedAt,
        ),
      );
      expect(keys, [original, original]);
    });

    test('a key that provably was not used is not carried', () async {
      stubCreate([const FeatureDisabledException('off')]);
      await sender.start(_job());

      final seed = await sender.edit(pending.state.single.localId);

      expect(seed!.key, isNull);
    });

    test('a pinned in-memory key expires too', () async {
      stubCreate([offline]);
      await sender.start(_job());
      expect(pending.state.single.canRetry, isTrue);

      now = now.add(kPostSendKeyWindow + const Duration(minutes: 1));
      await sender.retry(pending.state.single.localId);

      expect(keys, hasLength(1), reason: 'no second CreatePost');
      expect(pending.state.single.canRetry, isFalse);
    });
  });

  test(
    'sign-out while Edit releases the key: no seed, photos released',
    () async {
      stubHappyUpload(media);
      stubCreate([offline]);
      final a = await photos(1);
      await sender.start(_job(attachments: a, claimKey: 'k', draftId: 'd1'));
      await a.close();
      // A fresh unused key would be cleared; make that wait.
      final id = pending.state.single.localId;

      final editing = sender.edit(id);
      epoch.end();
      final seed = await editing;

      expect(seed, isNull);
      expect(a.isClosed, isTrue);
    },
  );

  test('a shed row whose media the server lost can only be edited', () async {
    stubHappyUpload(media);
    stubCreate([
      for (var i = 0; i < 4; i++) offline,
      const MediaNotReadyException('gone'),
    ]);
    final oldest = await photos(1, tag: 'x');
    await sender.start(_job(text: 'post 0', attachments: oldest));
    await oldest.close();
    for (var i = 1; i < 4; i++) {
      final a = await photos(1, tag: 'y$i');
      await sender.start(_job(text: 'post $i', attachments: a));
      await a.close();
    }
    final row = pending.state.firstWhere((p) => p.text == 'post 0');
    expect(row.keepsPhotos, isFalse);

    await sender.retry(row.localId);

    expect(
      pending.state.firstWhere((p) => p.text == 'post 0').canRetry,
      isFalse,
    );
  });

  test('a stale run never clears the new run\'s running flag', () async {
    final gate = Completer<void>();
    stubCreate([offline]);
    await sender.start(_job());
    final id = pending.state.single.localId;
    stubCreate([], gate: gate);

    final retrying = sender.retry(id);
    await Future<void>.delayed(Duration.zero);
    // A second Retry while the first runs does nothing.
    await sender.retry(id);
    expect(await sender.edit(id), isNull, reason: 'still running');

    gate.complete();
    await retrying;
    expect(pending.state.single.status, PendingPostStatus.posted);
  });
}
