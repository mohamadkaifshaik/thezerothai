
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/data/unsent_posts_store.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_sender.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_network_type_service.dart';
import '../../../../support/fake_posts_server.dart';
import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _MockPosts extends Mock implements PostsRepository {}

const _uid = 'q7Zk3mV9aXb2LcD8eF1gH4iJ5kL6';
const _oldId = _uid;
const _newId = 'u0abcdefghijklmnopqrstuvw2';

common.AuthorSnapshot _author(String id) =>
    common.AuthorSnapshot(userId: id, handle: 'me');

PostSendJob _job(String text) => PostSendJob(
  text: text,
  author: _author(_oldId),
  policy: ReplyAudience.everyone.wire,
  uid: _uid,
);

/// A `public_ids` flip invalidates only the id-bearing cache writes
/// (`SessionEpoch.invalidateWrites`). The user's own work, which is bound to
/// the account session, goes on: an open composer, a post in the undo window,
/// restored "Not sent" rows.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  late AppDatabase db;
  late PendingPostsCubit pending;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    pending = PendingPostsCubit();
  });

  tearDown(() async {
    await pending.close();
    await db.close();
  });

  group('composer', () {
    late FakePostsServer server;
    late DraftsRepository repo;

    setUp(() {
      server = FakePostsServer();
      repo = DraftsRepository(
        db,
        autosaveDelay: const Duration(milliseconds: 10),
      );
    });

    tearDown(() => repo.cancelPending());

    ComposerCubit open({bool drafts = true}) {
      final cubit = ComposerCubit(
        postsRepository: server,
        pending: pending,
        author: _author(_oldId),
        scheduleEnabled: true,
        mediaOn: true,
        drafts: drafts ? repo : null,
        uid: _uid,
        sessionEpoch: db.sessionEpoch,
      );
      addTearDown(cubit.close);
      return cubit;
    }

    test('an open composer keeps autosaving across the flip', () async {
      final c = open()..textChanged('first');
      await c.saveDraft();

      db.sessionEpoch.invalidateWrites();
      c.textChanged('first and more');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final row = await (db.select(
        db.composerDraftEntries,
      )..where((t) => t.draftId.equals(c.draftId))).getSingleOrNull();
      expect(row?.draftText, 'first and more');
    });

    test('Send after the flip sends the typed post', () async {
      final c = open(drafts: false)..textChanged('typed before the flip');

      db.sessionEpoch.invalidateWrites();
      await c.submit();

      expect(server.received, 1);
    });

    test('control: a real session end still stops a send', () async {
      final c = open(drafts: false)..textChanged('from the old account');

      db.sessionEpoch.end();
      await c.submit();

      expect(server.received, 0);
    });
  });

  group('post sender', () {
    late _MockPosts posts;
    late List<String> sent;

    setUp(() {
      posts = _MockPosts();
      sent = [];
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
      ).thenAnswer((invocation) async {
        sent.add(invocation.namedArguments[#text] as String);
        return postView(1);
      });
    });

    test('a post in the undo window is sent after a flip', () async {
      final sender = PostSender(
        pending: pending,
        repository: posts,
        sessionEpoch: db.sessionEpoch,
        undoDelay: () => const Duration(milliseconds: 40),
        postedFor: const Duration(minutes: 10),
      );
      addTearDown(sender.dispose);

      final done = sender.start(_job('in the window'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      db.sessionEpoch.invalidateWrites();
      await done;

      expect(sent, ['in the window']);
    });

    group('kept on the device', () {
      late UnsentPostsStore store;
      late FakeNetworkTypeService net;

      PostSender make(PendingPostsCubit into, FakeNetworkTypeService n) =>
          PostSender(
            pending: into,
            repository: posts,
            sessionEpoch: db.sessionEpoch,
            network: n,
            unsent: store,
            postedFor: const Duration(minutes: 10),
          );

      setUp(() {
        store = UnsentPostsStore(db, keepsPhotoBytes: false);
        net = FakeNetworkTypeService();
      });

      tearDown(() => net.dispose());

      Future<(PostSender, PendingPostsCubit)> restored() async {
        net.setOnline(false);
        final first = make(pending, net);
        await first.start(_job('keep me'));
        await first.idle;
        await first.dispose();
        final pending2 = PendingPostsCubit();
        addTearDown(pending2.close);
        final net2 = FakeNetworkTypeService();
        addTearDown(net2.dispose);
        final second = make(pending2, net2);
        addTearDown(second.dispose);
        await second.restore(_uid);
        return (second, pending2);
      }

      test('restored "Not sent" rows can be retried after a flip', () async {
        final (sender, rows) = await restored();
        final row = rows.state.single;

        db.sessionEpoch.invalidateWrites();
        await sender.retry(row.localId);
        await sender.idle;

        expect(sent, ['keep me']);
      });

      test('the flip puts the new user id on the unsent rows, in memory, on '
          'disk and for rows restored later', () async {
        final (sender, rows) = await restored();
        expect(rows.state.single.author.userId, _oldId);

        sender.restampAuthor(_uid, _author(_newId));
        await sender.idle;
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(rows.state.single.author.userId, _newId);
        expect((await store.load(_uid)).single.author.userId, _newId);

        final later = PendingPostsCubit();
        addTearDown(later.close);
        final net3 = FakeNetworkTypeService();
        addTearDown(net3.dispose);
        final third = make(later, net3)..restampAuthor('', _author(_newId));
        addTearDown(third.dispose);
        await third.restore(_uid);
        expect(later.state.single.author.userId, _newId);
      });
    });
  });
}
