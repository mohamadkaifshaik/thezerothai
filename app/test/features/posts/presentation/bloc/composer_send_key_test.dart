import 'package:drift/native.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_posts_server.dart';

/// W6-39: what the composer does with the send key stored on the draft row,
/// beyond the duplicate matrix (`composer_drafts_dup_publish_test.dart`): the
/// clear rules, IDEMPOTENCY_KEY_REUSED, the explicit "send anyway", the other
/// kind, and the 23 h window.
const _uid = 'u1';

void main() {
  late AppDatabase db;
  late DraftsRepository repo;
  late FakePostsServer server;
  late PendingPostsCubit pending;
  late DateTime clock;
  late DateTime at;
  late List<ComposerCubit> opened;

  setUp(() {
    clock = DateTime.now().toUtc();
    at = clock.add(const Duration(days: 2));
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = DraftsRepository(
      db,
      autosaveDelay: const Duration(milliseconds: 10),
      now: () => clock,
    );
    server = FakePostsServer();
    pending = PendingPostsCubit();
    opened = [];
  });

  tearDown(() async {
    repo.cancelPending();
    for (final c in opened) {
      await c.close();
    }
    await pending.close();
    await db.close();
  });

  ComposerCubit open({ComposerDraft? initial}) {
    final cubit = ComposerCubit(
      postsRepository: server,
      pending: pending,
      author: common.AuthorSnapshot(userId: _uid, handle: 'me'),
      scheduleEnabled: true,
      drafts: repo,
      uid: _uid,
      initialDraft: initial,
    );
    opened.add(cubit);
    return cubit;
  }

  Future<ComposerCubit> saved(String text) async {
    final c = open()..textChanged(text);
    await c.saveDraft();
    return c;
  }

  Future<ComposerDraftRow> row(String id) => (db.select(
    db.composerDraftEntries,
  )..where((t) => t.draftId.equals(id))).getSingle();

  Future<void> untilCleared(String id) async {
    for (var i = 0; i < 200; i++) {
      if ((await row(id)).sendKey == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('the key was never cleared');
  }

  group('what clears the stored key', () {
    for (final refusal in <AppException>[
      const ValidationException('bad'),
      const FeatureDisabledException('off'),
      const EmailNotVerifiedException('verify'),
    ]) {
      test(
        '${refusal.runtimeType} on a fresh key proves nothing was made',
        () async {
          final c = await saved('hello');
          server.refusals.add(refusal);

          await c.submit();

          expect(c.state.error, isA<AppException>());
          await untilCleared(c.draftId);
          expect(server.accepted, isEmpty);
        },
      );
    }

    test(
      'the same answer on a REUSED key keeps it (it may have landed)',
      () async {
        final c = await saved('hello');
        server.script.add(ServerReply.drop);
        await c.submit();
        final key = (await row(c.draftId)).sendKey;
        expect(key, isNotNull);

        server.refusals.add(const ValidationException('bad'));
        await c.submit();

        expect((await row(c.draftId)).sendKey, key);
        expect(server.accepted, hasLength(1));
      },
    );

    for (final ambiguous in <AppException>[
      const MediaNotReadyException('gone'),
      const QuotaExceededException('quota'),
      const LimitReachedException('limit'),
      const NetworkException('lost'),
      const UnknownApiException('?'),
    ]) {
      test('${ambiguous.runtimeType} keeps the key', () async {
        final c = await saved('hello');
        server.refusals.add(ambiguous);

        await c.submit();

        final r = await row(c.draftId);
        expect(r.sendKey, isNotNull);
        expect(r.sendKind, 'post');
      });
    }

    test('success removes the row, and its key with it', () async {
      final c = await saved('hello');
      await c.submit();
      expect(c.state.status, ComposerStatus.posted);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await repo.read(_uid, c.draftId), isNull, reason: 'row deleted');
    });
  });

  group('IDEMPOTENCY_KEY_REUSED', () {
    test(
      'an edit after a landed send says an earlier version was sent',
      () async {
        final c = await saved('hello');
        server.script.add(ServerReply.drop);
        await c.submit();
        expect(server.accepted, hasLength(1));

        c.textChanged('hello, edited');
        await c.submit();

        expect(c.state.sendConflict, SendConflict.earlierVersionSent);
        expect(
          c.state.error,
          isNull,
          reason: 'the dialog speaks, not a snackbar',
        );
        expect(c.state.status, ComposerStatus.editing);
        expect(c.state.draft.text, 'hello, edited', reason: 'the text stays');
        expect(server.accepted, hasLength(1));
        expect((await row(c.draftId)).sendKey, isNotNull, reason: 'kept');
      },
    );

    test('"post this version too" sends under a new key, once', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      final first = (await row(c.draftId)).sendKey;
      c.textChanged('hello, edited');
      await c.submit();
      c.sendConflictShown();
      expect(c.state.sendConflict, isNull);

      await c.sendAnyway();

      expect(server.accepted, hasLength(2));
      expect(server.accepted.last.key, isNot(first));
      expect(server.accepted.last.text, 'hello, edited');
      expect(c.state.status, ComposerStatus.posted);
    });

    test('sendAnyway applies to one send only', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      c.textChanged('hello, edited');
      await c.submit();
      c.sendConflictShown();
      server.refusals.add(const NetworkException('lost'));
      await c.sendAnyway();
      final minted = (await row(c.draftId)).sendKey;

      await c.submit();

      expect(server.receivedKeys.last, minted, reason: 'the new key is reused');
    });
  });

  group('the other kind (G6)', () {
    test('Post now after a lost schedule names the pending schedule', () async {
      final c = await saved('hello');
      c.scheduleChanged(at);
      server.script.add(ServerReply.drop);
      await c.submit();
      c.scheduleChanged(null);

      await c.submit();

      expect(c.state.sendConflict, SendConflict.pendingSchedule);
      expect(server.received, 1, reason: 'nothing was sent');
      expect(c.state.status, ComposerStatus.editing);
    });

    test('Schedule after a lost post names the pending post', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      c.scheduleChanged(at);

      await c.submit();

      expect(c.state.sendConflict, SendConflict.pendingPost);
      expect(server.received, 1);
    });

    test('"send anyway" sends the new kind under a new key', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      c.scheduleChanged(at);
      await c.submit();

      await c.sendAnyway();

      expect(server.accepted.map((a) => a.kind), ['post', 'schedule']);
      expect(c.state.scheduledNotice, isNotNull);
    });

    test('going back to the first kind replays the first send', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      c.scheduleChanged(at);
      await c.submit();
      c.sendConflictShown();
      c.scheduleChanged(null);

      await c.submit();

      expect(server.accepted, hasLength(1));
      expect(server.receivedKeys.first, server.receivedKeys.last);
      expect(c.state.status, ComposerStatus.posted);
    });
  });

  group('G5: the draft is gone', () {
    test('a stale composer is told, and sends nothing', () async {
      final seed = await saved('hello');
      final draft = (await repo.read(_uid, seed.draftId))!;
      final a = open(initial: draft);
      final b = open(initial: draft);
      await a.submit();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await b.submit();

      expect(b.state.sendConflict, SendConflict.draftGone);
      expect(SendConflict.draftGone.canSendAnyway, isFalse);
      expect(server.received, 1);
      expect(await repo.read(_uid, seed.draftId), isNull, reason: 'no row');
    });
  });

  group('the 23 h window', () {
    test('inside it a lost post is replayed with the same key', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      clock = clock.add(const Duration(hours: 22));

      await c.submit();

      expect(server.accepted, hasLength(1));
      expect(server.receivedKeys.first, server.receivedKeys.last);
    });

    test('after it the composer asks before minting a new key', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      clock = clock.add(const Duration(hours: 23, minutes: 1));

      await c.submit();

      expect(c.state.sendConflict, SendConflict.unconfirmed);
      expect(server.received, 1, reason: 'nothing was sent');
    });

    test('"post anyway" then sends under a new key', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      clock = clock.add(const Duration(hours: 24));
      await c.submit();

      await c.sendAnyway();

      expect(server.accepted, hasLength(2));
      expect(server.receivedKeys.first, isNot(server.receivedKeys.last));
    });
  });

  test('a send does not bump updatedAt (W6-45)', () async {
    final c = await saved('hello');
    final before = (await row(c.draftId)).updatedAt;
    clock = clock.add(const Duration(hours: 3));
    server.script.add(ServerReply.drop);

    await c.submit();

    expect((await row(c.draftId)).updatedAt, before);
  });

  test('a composer without a draft row keeps the in-memory keys', () async {
    final c = ComposerCubit(
      postsRepository: server,
      pending: pending,
      author: common.AuthorSnapshot(userId: _uid, handle: 'me'),
    )..textChanged('no drafts');
    addTearDown(c.close);
    server.script.add(ServerReply.drop);

    await c.submit();
    await c.submit();

    expect(server.accepted, hasLength(1));
    expect(server.receivedKeys.first, server.receivedKeys.last);
  });
}
