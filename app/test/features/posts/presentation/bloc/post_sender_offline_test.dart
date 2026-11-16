import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/data/unsent_posts_store.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_sender.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:dzeroth/shared/widgets/post/pending_post_status_row.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_network_type_service.dart';
import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _MockPosts extends Mock implements PostsRepository {}

PostSendJob _job({
  String text = 'hello',
  AttachmentsCubit? attachments,
  String uid = 'u1',
}) => PostSendJob(
  text: text,
  author: common.AuthorSnapshot(userId: uid, handle: 'me'),
  policy: ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
  attachments: attachments,
  uid: uid,
);

/// The offline send queue: a post waits for a connection instead of failing,
/// goes out by itself and in order, backs off on network errors, and what is
/// still unsent survives a restart as "Not sent" (never sent by itself).
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  late _MockPosts posts;
  late MockMediaRepository media;
  late PendingPostsCubit pending;
  late FakeNetworkTypeService net;
  late List<String> sent;
  late List<String> keys;
  Object? Function(int call)? failWith;
  late List<List<String>> mediaSeen;
  late bool hang;
  late Completer<void> hangGate;

  void stubCreate() {
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
    ).thenAnswer((invocation) async {
      keys.add(invocation.namedArguments[#idempotencyKey] as String);
      mediaSeen.add(invocation.namedArguments[#mediaIds] as List<String>);
      // CreatePost that never answers (the app is killed meanwhile).
      if (hang) await hangGate.future;
      final error = failWith?.call(sent.length + keys.length);
      if (error != null) throw error;
      sent.add(invocation.namedArguments[#text] as String);
      return postView(1);
    });
  }

  setUp(() {
    posts = _MockPosts();
    media = MockMediaRepository();
    pending = PendingPostsCubit();
    net = FakeNetworkTypeService();
    sent = [];
    keys = [];
    failWith = null;
    mediaSeen = [];
    hang = false;
    hangGate = Completer<void>();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    stubCreate();
  });

  tearDown(() async {
    await pending.close();
    net.dispose();
  });

  group('waiting for a connection and backing off', () {
    late PostSender sender;

    // The sender and the fake connection are made inside the fake clock, so
    // the connection's callbacks run on it.
    void inZone(void Function(FakeAsync async) body) {
      fakeAsync((async) {
        net = FakeNetworkTypeService();
        sender = PostSender(
          pending: pending,
          repository: posts,
          sessionEpoch: SessionEpoch(),
          network: net,
          postedFor: const Duration(minutes: 10),
        );
        body(async);
        unawaited(sender.dispose());
      });
    }

    PendingPost row(String text) =>
        pending.state.firstWhere((p) => p.text == text);

    test('offline: the post waits, then goes out when the connection '
        'returns', () {
      inZone((async) {
        net.setOnline(false);
        sender.start(_job());
        async.flushMicrotasks();

        expect(row('hello').status, PendingPostStatus.waiting);
        expect(row('hello').waitingForConnection, isTrue);
        expect(
          PendingPostStatusRow.statusText(row('hello')),
          'Waiting for connection',
        );
        async.elapse(const Duration(minutes: 5));
        expect(sent, isEmpty);

        net.setOnline(true);
        async.elapse(const Duration(milliseconds: 10));
        expect(sent, ['hello']);
        expect(row('hello').status, PendingPostStatus.posted);
      });
    });

    test('several posts wait and go out in the order they were made', () {
      inZone((async) {
        net.setOnline(false);
        sender.start(_job(text: 'first'));
        sender.start(_job(text: 'second'));
        sender.start(_job(text: 'third'));
        async.flushMicrotasks();
        expect(pending.state.map((p) => p.status).toSet(), {
          PendingPostStatus.waiting,
        });

        net.setOnline(true);
        async.elapse(const Duration(milliseconds: 10));
        expect(sent, ['first', 'second', 'third']);
      });
    });

    test('a new post waits behind older posts that are queued', () {
      inZone((async) {
        net.setOnline(false);
        sender.start(_job(text: 'old'));
        async.flushMicrotasks();
        net.setOnline(true);
        // Back online the queue is sending; a post made now joins it.
        sender.start(_job(text: 'new'));
        async.elapse(const Duration(milliseconds: 10));
        expect(sent, ['old', 'new']);
      });
    });

    test('network errors back off 2s, 5s, 15s, 30s, then Retry is manual, '
        'always under the same key', () {
      inZone((async) {
        failWith = (_) => const NetworkException('down');
        sender.start(_job());
        async.flushMicrotasks();
        expect(keys, hasLength(1));
        expect(row('hello').status, PendingPostStatus.waiting);
        expect(row('hello').waitingForConnection, isFalse);

        async.elapse(const Duration(milliseconds: 1900));
        expect(keys, hasLength(1));
        async.elapse(const Duration(milliseconds: 100));
        expect(keys, hasLength(2));

        async.elapse(const Duration(seconds: 4, milliseconds: 900));
        expect(keys, hasLength(2));
        async.elapse(const Duration(milliseconds: 100));
        expect(keys, hasLength(3));

        async.elapse(const Duration(seconds: 14, milliseconds: 900));
        expect(keys, hasLength(3));
        async.elapse(const Duration(milliseconds: 100));
        expect(keys, hasLength(4));

        async.elapse(const Duration(seconds: 29, milliseconds: 900));
        expect(keys, hasLength(4));
        async.elapse(const Duration(milliseconds: 100));
        expect(keys, hasLength(5));

        // Used up: a failed row with Retry, and nothing more by itself.
        expect(row('hello').status, PendingPostStatus.failed);
        expect(row('hello').canRetry, isTrue);
        async.elapse(const Duration(minutes: 5));
        expect(keys, hasLength(5));
        expect(keys.toSet(), hasLength(1));

        // Retry starts the backoff over and sends.
        failWith = null;
        sender.retry(row('hello').localId);
        async.flushMicrotasks();
        expect(sent, ['hello']);
        expect(keys.toSet(), hasLength(1));
      });
    });

    test('a post made while an older one backs off goes after it', () {
      inZone((async) {
        var calls = 0;
        failWith = (_) => ++calls == 1 ? const NetworkException('down') : null;
        sender.start(_job(text: 'old'));
        async.flushMicrotasks();
        sender.start(_job(text: 'new'));
        async.flushMicrotasks();
        expect(sent, isEmpty);
        expect(row('new').status, PendingPostStatus.waiting);

        async.elapse(const Duration(seconds: 2));
        expect(sent, ['old', 'new']);
      });
    });

    test('Dismiss and Edit of a waiting post stop it for good', () {
      inZone((async) {
        net.setOnline(false);
        sender.start(_job(text: 'gone'));
        sender.start(_job(text: 'edited'));
        async.flushMicrotasks();

        sender.release(row('gone').localId);
        sender.edit(row('edited').localId);
        async.flushMicrotasks();
        expect(pending.state, isEmpty);

        net.setOnline(true);
        async.elapse(const Duration(minutes: 5));
        expect(sent, isEmpty);
        expect(keys, isEmpty);
      });
    });

    test('a refusal that is not a network error fails at once', () {
      inZone((async) {
        failWith = (_) => const ValidationException('no', field: 'text');
        sender.start(_job());
        async.flushMicrotasks();
        expect(row('hello').status, PendingPostStatus.failed);
        async.elapse(const Duration(minutes: 5));
        expect(keys, hasLength(1));
      });
    });

    test('the status row names the retry and the unsaved photos', () {
      final p = PendingPost(
        localId: 'a',
        text: 't',
        author: common.AuthorSnapshot(userId: 'u1'),
        createdAt: DateTime.now(),
        status: PendingPostStatus.waiting,
        waitingForConnection: false,
        photosNotSaved: true,
      );
      expect(
        PendingPostStatusRow.statusText(p),
        "Couldn't reach the server. Trying again soon. "
        'Photos are lost if you close the app.',
      );
      expect(
        PendingPostStatusRow.announcement(p),
        "Couldn't reach the server. Your post will be tried again. "
        'Photos are lost if you close the app',
      );
      // The warning appearing is announced again.
      expect(
        PendingPostStatusRow.announcement(p.copyWith(photosNotSaved: false)),
        isNot(PendingPostStatusRow.announcement(p)),
      );
      // Failed rows carry the warning too.
      expect(
        PendingPostStatusRow.statusText(
          p.copyWith(status: PendingPostStatus.failed, error: 'Nope.'),
        ),
        'Nope. Photos are lost if you close the app.',
      );
    });

    test('a post that waited keeps one announcement while it is tried '
        'again', () {
      final waiting = PendingPost(
        localId: 'a',
        text: 't',
        author: common.AuthorSnapshot(userId: 'u1'),
        createdAt: DateTime.now(),
        status: PendingPostStatus.waiting,
        wasQueued: true,
      );
      expect(
        PendingPostStatusRow.announcement(
          waiting.copyWith(status: PendingPostStatus.sending),
        ),
        PendingPostStatusRow.announcement(waiting),
      );
      expect(
        PendingPostStatusRow.announcement(
          waiting.copyWith(wasQueued: false, status: PendingPostStatus.sending),
        ),
        'Posting',
      );
    });
  });

  test('without a network service a network error fails the send at once', () {
    final sender = PostSender(
      pending: pending,
      repository: posts,
      sessionEpoch: SessionEpoch(),
    );
    addTearDown(sender.dispose);
    fakeAsync((async) {
      failWith = (_) => const NetworkException('down');
      sender.start(_job());
      async.flushMicrotasks();
      expect(pending.state.single.status, PendingPostStatus.failed);
      async.elapse(const Duration(minutes: 1));
      expect(keys, hasLength(1));
    });
  });

  group('kept on the device', () {
    late AppDatabase db;
    late UnsentPostsStore store;
    late PostSender sender;

    // The cubits the sender itself makes (loaded from disk).
    final made = <AttachmentsCubit>[];
    setUp(made.clear);
    AttachmentsCubit newCubit() {
      final cubit = AttachmentsCubit(
        picker: FakeImagePicker(),
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: media),
      );
      made.add(cubit);
      return cubit;
    }

    PostSender make(PendingPostsCubit into, FakeNetworkTypeService network) =>
        PostSender(
          pending: into,
          repository: posts,
          sessionEpoch: db.sessionEpoch,
          network: network,
          unsent: store,
          newAttachments: newCubit,
          postedFor: const Duration(minutes: 10),
        );

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

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = UnsentPostsStore(db, keepsPhotoBytes: true);
      sender = make(pending, net);
      stubHappyUpload(media);
    });

    tearDown(() async {
      await sender.dispose();
      await db.close();
    });

    test('a waiting post is stored with its processed photos, sent when '
        'the connection returns, and removed once it is posted', () async {
      net.setOnline(false);
      await sender.start(_job(attachments: await photos(2)));
      await sender.idle;
      final stored = (await store.load('u1')).single;
      expect(stored.text, 'hello');
      expect(stored.photos, hasLength(2));

      net.setOnline(true);
      await sender.idle;
      expect(sent, ['hello']);
      expect(await store.load('u1'), isEmpty);
      expect(await store.storedBytes('u1'), 0);
    });

    test('after a restart the post is a "Not sent" row, never sent by itself; '
        'Retry sends it, with its photos', () async {
      net.setOnline(false);
      await sender.start(_job(text: 'keep me', attachments: await photos(2)));
      await sender.idle;
      await sender.dispose();

      // The app starts again: a new sender over the same device storage.
      final pending2 = PendingPostsCubit();
      addTearDown(pending2.close);
      final net2 = FakeNetworkTypeService();
      addTearDown(net2.dispose);
      final sender2 = make(pending2, net2);
      addTearDown(sender2.dispose);
      await sender2.restore('u1');

      final row = pending2.state.single;
      expect(row.text, 'keep me');
      expect(row.status, PendingPostStatus.failed);
      expect(row.error, startsWith('Not sent'));
      expect(row.canRetry, isTrue);
      expect(row.thumbnails, hasLength(2));
      expect(row.photosTotal, 2);

      // A connection, in whatever way, does not send it.
      net2
        ..setOnline(false)
        ..setOnline(true);
      await sender2.idle;
      expect(keys, isEmpty);
      verifyNever(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      );

      await sender2.retry(row.localId);
      await sender2.idle;
      expect(sent, ['keep me']);
      verify(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(that: hasLength(2), named: 'images'),
        ),
      ).called(1);
      expect(await store.load('u1'), isEmpty);
    });

    test('an image-only post gets a row too, and comes back', () async {
      net.setOnline(false);
      await sender.start(_job(text: '', attachments: await photos(1)));
      await sender.idle;
      expect(pending.state.single.status, PendingPostStatus.waiting);
      expect((await store.load('u1')).single.photos, hasLength(1));

      final pending2 = PendingPostsCubit();
      addTearDown(pending2.close);
      final net2 = FakeNetworkTypeService();
      addTearDown(net2.dispose);
      final sender2 = make(pending2, net2);
      addTearDown(sender2.dispose);
      await sender2.restore('u1');
      expect(pending2.state.single.text, '');
      expect(pending2.state.single.thumbnails, hasLength(1));
      expect(pending2.state.single.status, PendingPostStatus.failed);
    });

    test('the key that may exist on the server travels with the post: Retry '
        'after a restart sends under the same key', () async {
      failWith = (_) {
        // The connection dropped during CreatePost.
        net.setOnline(false);
        return const NetworkException('down');
      };
      await sender.start(_job(text: 'once'));
      await sender.idle;
      expect(keys, hasLength(1));
      expect(pending.state.single.status, PendingPostStatus.waiting);
      final stored = (await store.load('u1')).single;
      expect(stored.key, keys.single);
      expect(stored.keyUsed, isTrue);
      expect(stored.ambiguous, isTrue);
      await sender.dispose();

      final pending2 = PendingPostsCubit();
      addTearDown(pending2.close);
      final net2 = FakeNetworkTypeService();
      addTearDown(net2.dispose);
      final sender2 = make(pending2, net2);
      addTearDown(sender2.dispose);
      await sender2.restore('u1');
      failWith = null;
      await sender2.retry(pending2.state.single.localId);
      await sender2.idle;
      expect(sent, ['once']);
      expect(keys, [keys.first, keys.first]);
    });

    test(
      'a used key past its window is not sent again after a restart',
      () async {
        // The store sweeps a row whose key is older than the window; a row
        // inside it is refused at Retry once the window has passed (only Edit
        // remains), before anything is loaded or uploaded.
        await store.save(
          UnsentPostRecord(
            uid: 'u1',
            postId: 'old',
            text: 'late',
            author: common.AuthorSnapshot(userId: 'u1'),
            createdAt: DateTime.now().subtract(const Duration(hours: 1)),
            key: 'k-old',
            keyStartedAt: DateTime.now().subtract(const Duration(hours: 22)),
            keyUsed: true,
            ambiguous: true,
            photos: [StoredPhoto(image: fakeProcessed('o'))],
          ),
          epoch: db.sessionEpoch.value,
        );
        // Three hours later the key is past its 23 hour window.
        final later = PostSender(
          pending: pending,
          repository: posts,
          sessionEpoch: db.sessionEpoch,
          network: net,
          unsent: store,
          newAttachments: newCubit,
          clock: () => DateTime.now().add(const Duration(hours: 3)),
        );
        addTearDown(later.dispose);
        await later.restore('u1');
        await later.retry(pending.state.single.localId);
        await later.idle;
        // Nothing was loaded or uploaded for a post that cannot be sent.
        verifyNever(
          () => media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(named: 'images'),
          ),
        );
        expect(keys, isEmpty);
        expect(pending.state.single.status, PendingPostStatus.failed);
        expect(pending.state.single.canRetry, isFalse);
      },
    );

    test('Dismiss deletes the stored post and its photos', () async {
      net.setOnline(false);
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      expect(await store.storedBytes('u1'), greaterThan(0));

      await sender.release(pending.state.single.localId);
      await sender.idle;
      expect(await store.load('u1'), isEmpty);
      expect(await store.storedBytes('u1'), 0);
    });

    test('Edit deletes the stored copy: the composer has the post', () async {
      net.setOnline(false);
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      final seed = await sender.edit(pending.state.single.localId);
      await sender.idle;
      expect(seed!.attachments, isNotNull);
      expect(await store.load('u1'), isEmpty);
    });

    test('sign-out deletes every stored post and photo', () async {
      net.setOnline(false);
      await sender.start(_job(attachments: await photos(2)));
      await sender.idle;
      expect(await store.storedBytes('u1'), greaterThan(0));

      db.sessionEpoch.end();
      await pumpEventQueue();
      await sender.idle;

      expect(pending.state, isEmpty);
      expect(await store.load('u1'), isEmpty);
      expect(await store.storedBytes('u1'), 0);
    });

    test('Delete unsent posts (discardUnsent) removes rows and stored '
        'bytes', () async {
      net.setOnline(false);
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      await sender.deleteUnsentPosts('u1');
      await sender.idle;
      expect(pending.state, isEmpty);
      expect(await store.load('u1'), isEmpty);
    });

    test('account B never sees or restores what account A left, and it is '
        'deleted at B\'s launch', () async {
      net.setOnline(false);
      await sender.start(
        _job(text: 'a secret', attachments: await photos(2), uid: 'A'),
      );
      await sender.idle;
      expect(await store.storedBytes('A'), greaterThan(0));
      await sender.dispose();

      final pendingB = PendingPostsCubit();
      addTearDown(pendingB.close);
      final netB = FakeNetworkTypeService();
      addTearDown(netB.dispose);
      final senderB = make(pendingB, netB);
      addTearDown(senderB.dispose);
      await senderB.restore('B');

      expect(pendingB.state, isEmpty);
      expect(await store.load('B'), isEmpty);
      // Nothing of A is left to read, not even by A.
      expect(await store.load('A'), isEmpty);
      expect(await store.storedBytes('A'), 0);
    });

    test('a restore that ends after a sign-out brings nothing back', () async {
      net.setOnline(false);
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      await sender.dispose();

      final pending2 = PendingPostsCubit();
      addTearDown(pending2.close);
      final net2 = FakeNetworkTypeService();
      addTearDown(net2.dispose);
      final sender2 = make(pending2, net2);
      addTearDown(sender2.dispose);
      final restoring = sender2.restore('u1');
      db.sessionEpoch.end();
      await restoring;
      await pumpEventQueue();
      await sender2.idle;
      expect(pending2.state, isEmpty);
      expect(await store.load('u1'), isEmpty);
    });

    test('over the size cap the post keeps its text only and the row says '
        'so', () async {
      final tiny = UnsentPostsStore(
        db,
        keepsPhotoBytes: true,
        maxPostsWithPhotos: 1,
      );
      final capped = PostSender(
        pending: pending,
        repository: posts,
        sessionEpoch: db.sessionEpoch,
        network: net,
        unsent: tiny,
        newAttachments: newCubit,
      );
      addTearDown(capped.dispose);
      net.setOnline(false);
      await capped.start(_job(text: 'one', attachments: await photos(1)));
      await capped.start(_job(text: 'two', attachments: await photos(1)));
      await capped.idle;

      final one = pending.state.firstWhere((p) => p.text == 'one');
      final two = pending.state.firstWhere((p) => p.text == 'two');
      expect(one.photosNotSaved, isFalse);
      expect(two.photosNotSaved, isTrue);
      expect(
        PendingPostStatusRow.statusText(two),
        'Waiting for connection. Photos are lost if you close the app.',
      );
      final stored = await tiny.load('u1');
      expect(stored.firstWhere((r) => r.postId == two.localId).photos, isEmpty);

      // After a restart that post has its text only, without a Retry that
      // would send it without its photos.
      final pending2 = PendingPostsCubit();
      addTearDown(pending2.close);
      final net2 = FakeNetworkTypeService();
      addTearDown(net2.dispose);
      final sender2 = PostSender(
        pending: pending2,
        repository: posts,
        sessionEpoch: db.sessionEpoch,
        network: net2,
        unsent: tiny,
        newAttachments: newCubit,
      );
      addTearDown(sender2.dispose);
      await sender2.restore('u1');
      final back = pending2.state.firstWhere((p) => p.text == 'two');
      expect(back.canRetry, isFalse);
      expect(back.thumbnails, isEmpty);
      expect(back.error, 'Not sent. Its photos could not be kept.');
      expect(back.photosTotal, 1);
      expect(back.keepsPhotos, isFalse);
      // The row still reads as a photo post, and Edit is text only.
      expect(PendingPostStatusRow.statusText(back), back.error);
    });

    Future<({PendingPostsCubit pending, PostSender sender})> relaunch() async {
      final pending2 = PendingPostsCubit();
      addTearDown(pending2.close);
      final net2 = FakeNetworkTypeService();
      addTearDown(net2.dispose);
      final sender2 = make(pending2, net2);
      addTearDown(sender2.dispose);
      await sender2.restore('u1');
      return (pending: pending2, sender: sender2);
    }

    test('write-ahead: the key is on disk before CreatePost, so a kill '
        'during the call never loses it', () async {
      net.setOnline(false);
      await sender.start(_job(text: 'stuck'));
      await sender.idle;
      final waiting = (await store.load('u1')).single;
      // Pinned at the first save, never null.
      expect(waiting.key, isNotNull);
      expect(waiting.keyUsed, isFalse);

      hang = true;
      net.setOnline(true);
      for (var i = 0; i < 100 && keys.isEmpty; i++) {
        await pumpEventQueue();
      }
      expect(keys, hasLength(1));
      final mid = (await store.load('u1')).single;
      expect(mid.key, keys.single);
      expect(mid.key, waiting.key);
      expect(mid.keyUsed, isTrue);
      expect(mid.ambiguous, isTrue);
      // The app is killed: CreatePost never answered.
      await sender.dispose();

      final again = await relaunch();
      final row = again.pending.state.single;
      expect(row.error, startsWith('We could not confirm this post was sent'));
      expect(row.canRetry, isTrue);
      hang = false;
      await again.sender.retry(row.localId);
      await again.sender.idle;
      expect(sent, ['stuck']);
      expect(keys, [keys.first, keys.first]);
    });

    Future<void> uploadedThenOffline() async {
      var first = true;
      failWith = (_) {
        if (!first) return null;
        first = false;
        net.setOnline(false);
        return const NetworkException('down');
      };
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      expect(pending.state.single.status, PendingPostStatus.waiting);
      expect((await store.load('u1')).single.photos.single.mediaId, 'm1');
      await sender.dispose();
      clearInteractions(media);
    }

    test('finished uploads are kept: after a restart Retry sends those media '
        'ids and uploads nothing', () async {
      await uploadedThenOffline();
      final again = await relaunch();
      expect(again.pending.state.single.canRetry, isTrue);
      await again.sender.retry(again.pending.state.single.localId);
      await again.sender.idle;
      expect(sent, ['hello']);
      expect(mediaSeen.last, ['m1']);
      verifyNever(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      );
    });

    test('MEDIA_NOT_READY on uploads kept from before a restart: Retry uploads '
        'the bytes again, under the same key', () async {
      await uploadedThenOffline();
      final again = await relaunch();
      var calls = 0;
      failWith = (_) =>
          calls++ == 0 ? const MediaNotReadyException('gone') : null;
      await again.sender.retry(again.pending.state.single.localId);
      await again.sender.idle;
      // The dead ids are not sent forever: the row can be retried.
      expect(again.pending.state.single.status, PendingPostStatus.failed);
      expect(again.pending.state.single.canRetry, isTrue);
      expect(mediaSeen.last, ['m1']);

      await again.sender.retry(again.pending.state.single.localId);
      await again.sender.idle;
      expect(sent, ['hello']);
      expect(mediaSeen.last, ['m2']);
      expect(keys.toSet(), hasLength(1));
      verify(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).called(1);
    });

    test('the dead ids are gone from the device too: a second restart does '
        'not bring them back', () async {
      await uploadedThenOffline();
      final again = await relaunch();
      failWith = (_) => const MediaNotReadyException('gone');
      await again.sender.retry(again.pending.state.single.localId);
      await again.sender.idle;
      await pumpEventQueue();
      final stored = (await store.load('u1')).single;
      expect(stored.photos.single.mediaId, isEmpty);
      expect(stored.canRetry, isTrue);
    });

    test('MEDIA_NOT_READY in one session: Retry uploads again instead of '
        'resending the dead ids', () async {
      var calls = 0;
      failWith = (_) =>
          calls++ == 0 ? const MediaNotReadyException('gone') : null;
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      expect(pending.state.single.status, PendingPostStatus.failed);
      expect(pending.state.single.canRetry, isTrue);

      await sender.retry(pending.state.single.localId);
      await sender.idle;
      expect(sent, ['hello']);
      expect(mediaSeen, [
        ['m1'],
        ['m2'],
      ]);
      expect(keys.toSet(), hasLength(1));
    });

    test('a restored post whose key was used says it was already sent when '
        'the server reports the key reused', () async {
      await uploadedThenOffline();
      final again = await relaunch();
      failWith = (_) => const IdempotencyKeyReusedException('same key');
      await again.sender.retry(again.pending.state.single.localId);
      await again.sender.idle;
      expect(again.pending.state.single.error, 'This post was already sent.');
      expect(again.pending.state.single.canRetry, isFalse);
    });

    test('the earliest start of the key is what is stored', () async {
      final started = DateTime.now().subtract(const Duration(hours: 5));
      net.setOnline(false);
      await sender.start(
        PostSendJob(
          text: 'old key',
          author: common.AuthorSnapshot(userId: 'u1'),
          policy: ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
          uid: 'u1',
          claimKey: 'k5',
          claimReused: true,
          claimStartedAt: started,
        ),
      );
      await sender.idle;
      final stored = (await store.load('u1')).single;
      expect(stored.key, 'k5');
      expect(stored.claimReused, isTrue);
      expect(
        stored.keyStartedAt!.difference(started).inSeconds.abs(),
        lessThan(2),
      );
    });

    test(
      'bytes on disk leave memory: a send and an Edit load them again',
      () async {
        net.setOnline(false);
        final a = await photos(2);
        await sender.start(_job(attachments: a));
        await sender.idle;
        // Online again: the photos come from disk and are uploaded.
        net.setOnline(true);
        await sender.idle;
        expect(sent, ['hello']);
        verify(
          () => media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(that: hasLength(2), named: 'images'),
          ),
        ).called(1);

        net.setOnline(false);
        await sender.start(_job(text: 'again', attachments: await photos(2)));
        await sender.idle;
        final seed = await sender.edit(
          pending.state.firstWhere((p) => p.text == 'again').localId,
        );
        final items = seed!.attachments!.state.items;
        expect(items, hasLength(2));
        expect(items.first.image!.fullBytes, isNotEmpty);
        expect(items.first.status, AttachmentStatus.ready);
      },
    );

    test('waiting posts count in the shed: the oldest lose their photos and '
        'are never sent without them', () async {
      final shedding = PostSender(
        pending: pending,
        repository: posts,
        sessionEpoch: db.sessionEpoch,
        network: net,
        maxFailedWithPhotos: 1,
      );
      addTearDown(shedding.dispose);
      net.setOnline(false);
      for (final t in ['a', 'b', 'c']) {
        await shedding.start(_job(text: t, attachments: await photos(1)));
      }
      PendingPost row(String t) => pending.state.firstWhere((p) => p.text == t);
      expect(row('a').keepsPhotos, isFalse);
      expect(row('b').keepsPhotos, isFalse);
      expect(row('c').keepsPhotos, isTrue);

      net.setOnline(true);
      await shedding.idle;
      expect(sent, ['c']);
      expect(row('a').status, PendingPostStatus.failed);
      expect(row('a').canRetry, isFalse);
    });

    test(
      'a restored row keeps how the send ended and what was refused',
      () async {
        failWith = (_) => const EmailNotVerifiedException('verify');
        await sender.start(_job(text: 'verify me'));
        await sender.idle;
        final before = pending.state.single;
        expect(before.needsVerify, isTrue);
        await sender.dispose();

        final again = await relaunch();
        final row = again.pending.state.single;
        expect(row.needsVerify, isTrue);
        expect(row.error, before.error);
        // A refusal that proved nothing was created is not "could not confirm".
        expect(row.error, isNot(startsWith('We could not confirm')));
      },
    );

    test('what the server refused is taken out when a restored post is '
        'edited', () async {
      failWith = (_) =>
          const FeatureDisabledException('off', feature: kFeaturePolls);
      await sender.start(
        PostSendJob(
          text: 'with poll',
          author: common.AuthorSnapshot(userId: 'u1'),
          policy: ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
          uid: 'u1',
          poll: const DraftPoll(choices: ['a', 'b'], durationMinutes: 60),
        ),
      );
      await sender.idle;
      await sender.dispose();

      final again = await relaunch();
      final seed = await again.sender.edit(again.pending.state.single.localId);
      expect(seed!.text, 'with poll');
      expect(seed.poll, isNull);
    });

    test(
      'a restored post with lost photos shows a photo post placeholder',
      () async {
        await store.save(
          UnsentPostRecord(
            uid: 'u1',
            postId: 'lost',
            text: '',
            author: common.AuthorSnapshot(userId: 'u1'),
            createdAt: DateTime.now(),
            photosKept: false,
            photoCount: 2,
          ),
          epoch: db.sessionEpoch.value,
        );
        final again = await relaunch();
        final row = again.pending.state.single;
        expect(row.error, 'Not sent. Its photos could not be kept.');
        expect(row.photosTotal, 2);
        expect(row.canRetry, isFalse);
        expect(row.keepsPhotos, isFalse);
      },
    );

    Future<void> uploadedThenCreateFails() async {
      var first = true;
      failWith = (_) {
        if (!first) return null;
        first = false;
        net.setOnline(false);
        return const NetworkException('down');
      };
    }

    test(
      'one session: uploads succeed, CreatePost fails on the network, the '
      'resend replays the same media ids and uploads nothing again',
      () async {
        await uploadedThenCreateFails();
        await sender.start(_job(attachments: await photos(2)));
        await sender.idle;
        expect(pending.state.single.status, PendingPostStatus.waiting);

        net.setOnline(true);
        await sender.idle;
        expect(sent, ['hello']);
        expect(mediaSeen, [
          ['m1', 'm2'],
          ['m1', 'm2'],
        ]);
        expect(keys.toSet(), hasLength(1));
        verify(
          () => media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(named: 'images'),
          ),
        ).called(1);
      },
    );

    test('Edit after the uploads keeps them: an unchanged resend has the same '
        'media ids', () async {
      await uploadedThenCreateFails();
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      final seed = await sender.edit(pending.state.single.localId);
      final items = seed!.attachments!.state.items;
      expect(items.single.status, AttachmentStatus.uploaded);
      expect(items.single.mediaId, 'm1');
      expect(items.single.image!.fullBytes, isNotEmpty);

      final again = await seed.attachments!.uploadAll();
      expect(again.mediaIds, ['m1']);
      verify(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).called(1);
    });

    test('a burst of offline photo posts keeps every post\'s photos', () async {
      final burst = PostSender(
        pending: pending,
        repository: posts,
        sessionEpoch: db.sessionEpoch,
        network: net,
        unsent: store,
        newAttachments: newCubit,
        maxFailedWithPhotos: 1,
      );
      addTearDown(burst.dispose);
      net.setOnline(false);
      final cubits = [for (var i = 0; i < 4; i++) await photos(1)];
      for (var i = 0; i < 4; i++) {
        unawaited(burst.start(_job(text: 'p$i', attachments: cubits[i])));
      }
      await burst.idle;
      expect(pending.state.every((p) => p.keepsPhotos), isTrue);
      expect(pending.state.every((p) => p.canRetry), isTrue);

      net.setOnline(true);
      await burst.idle;
      expect(sent, ['p0', 'p1', 'p2', 'p3']);
      verify(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).called(4);
    });

    test('a restored post whose claim was a reused one keeps the earlier '
        'version copy', () async {
      await store.save(
        UnsentPostRecord(
          uid: 'u1',
          postId: 'r',
          text: 'edited',
          author: common.AuthorSnapshot(userId: 'u1'),
          createdAt: DateTime.now(),
          key: 'k-r',
          keyStartedAt: DateTime.now().subtract(const Duration(hours: 1)),
          keyUsed: true,
          ambiguous: true,
          claimReused: true,
        ),
        epoch: db.sessionEpoch.value,
      );
      final again = await relaunch();
      failWith = (_) => const IdempotencyKeyReusedException('same key');
      await again.sender.retry(again.pending.state.single.localId);
      await again.sender.idle;
      expect(
        again.pending.state.single.error,
        startsWith('An earlier version'),
      );
    });

    test('cubits the sender loads from disk are closed, none leaks', () async {
      net.setOnline(false);
      await sender.start(_job(attachments: await photos(1)));
      await sender.idle;
      await uploadedThenCreateFails();
      net.setOnline(true);
      await sender.idle;
      // The upload finished, CreatePost failed offline; online again it replays.
      expect(sent, isEmpty);
      net.setOnline(true);
      await sender.idle;
      expect(sent, ['hello']);
      expect(made, isNotEmpty);
      expect(made.every((c) => c.isClosed), isTrue);
    });

    test('after Delete unsent posts an in-flight send that hits the network '
        'fails unsaved and does not send itself', () async {
      hang = true;
      unawaited(sender.start(_job(text: 'running')));
      for (var i = 0; i < 100 && keys.isEmpty; i++) {
        await pumpEventQueue();
      }
      expect(keys, hasLength(1));
      await sender.deleteUnsentPosts('u1');

      net.setOnline(false);
      hangGate.completeError(const NetworkException('gone'));
      await sender.idle;
      expect(pending.state.single.status, PendingPostStatus.failed);

      net.setOnline(true);
      await sender.idle;
      expect(keys, hasLength(1));
      expect(await store.load('u1'), isEmpty);
    });

    test('the web keeps no photo bytes: text only after a restart', () async {
      final web = UnsentPostsStore(db, keepsPhotoBytes: false);
      final webSender = PostSender(
        pending: pending,
        repository: posts,
        sessionEpoch: db.sessionEpoch,
        network: net,
        unsent: web,
        newAttachments: newCubit,
      );
      addTearDown(webSender.dispose);
      net.setOnline(false);
      await webSender.start(_job(attachments: await photos(1)));
      await webSender.idle;
      expect(pending.state.single.photosNotSaved, isTrue);
      expect(await web.storedBytes('u1'), 0);
    });
  });
}
