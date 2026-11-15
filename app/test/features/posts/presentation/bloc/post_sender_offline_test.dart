import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/data/unsent_posts_store.dart';
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
        "Couldn't reach the server. Trying again soon... "
        'Photos are lost if you close the app.',
      );
      expect(
        PendingPostStatusRow.announcement(p),
        "Couldn't reach the server. Your post will be tried again",
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

    AttachmentsCubit newCubit() => AttachmentsCubit(
      picker: FakeImagePicker(),
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
    );

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
        // The store sweeps rows older than the window; a row inside it whose
        // key started long ago is refused at Retry (only Edit remains).
        await store.save(
          UnsentPostRecord(
            uid: 'u1',
            postId: 'old',
            text: 'late',
            author: common.AuthorSnapshot(userId: 'u1'),
            createdAt: DateTime.now().subtract(const Duration(hours: 1)),
            key: 'k-old',
            keyStartedAt: DateTime.now().subtract(const Duration(hours: 24)),
            keyUsed: true,
          ),
          epoch: db.sessionEpoch.value,
        );
        await sender.restore('u1');
        await sender.retry(pending.state.single.localId);
        await sender.idle;
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
      sender.discardUnsent();
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
        'Waiting for connection Photos are lost if you close the app.',
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
