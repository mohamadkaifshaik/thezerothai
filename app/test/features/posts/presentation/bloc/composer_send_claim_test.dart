import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_posts_server.dart';
import '../../../../support/media_fixtures.dart';

const _uid = 'u1';

/// The real drafts store with two levers: [broken] makes every claim fail
/// the way a locked or full database does, and [gate] holds a claim until the
/// test lets it go ([started] says it is in flight).
class _ControlledDrafts extends DraftsRepository {
  _ControlledDrafts(super.database, {super.now})
    : super(autosaveDelay: const Duration(milliseconds: 10));

  bool broken = false;
  Completer<void>? gate;
  Completer<void> started = Completer<void>();
  int claims = 0;

  /// The keys [clearSend] was asked to forget, in order.
  final List<String> cleared = [];
  Completer<String> clearedOne = Completer<String>();

  @override
  Future<SendClaim> claimSend({
    required ComposerDraft draft,
    required SendKind kind,
    required String Function() newKey,
    DateTime? publishAt,
    bool forceNew = false,
  }) async {
    claims++;
    if (!started.isCompleted) started.complete();
    final hold = gate;
    if (hold != null) await hold.future;
    if (broken) throw StateError('database is locked');
    return super.claimSend(
      draft: draft,
      kind: kind,
      newKey: newKey,
      publishAt: publishAt,
      forceNew: forceNew,
    );
  }

  @override
  Future<void> clearSend(String uid, String draftId, String key) async {
    await super.clearSend(uid, draftId, key);
    cleared.add(key);
    if (!clearedOne.isCompleted) clearedOne.complete(key);
  }
}

/// P1 regressions of the draft-backed send: a storage failure must never send
/// under a key the draft row does not hold, and a composer that closed while
/// its claim (or upload) was pending sends nothing.
void main() {
  setUpAll(registerMediaFallbacks);

  late AppDatabase db;
  late _ControlledDrafts repo;
  late FakePostsServer server;
  late PendingPostsCubit pending;
  late DateTime clock;
  late DateTime at;
  late List<Object> reported;

  setUp(() {
    clock = DateTime.now().toUtc();
    at = clock.add(const Duration(days: 2));
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = _ControlledDrafts(db, now: () => clock);
    server = FakePostsServer();
    pending = PendingPostsCubit();
    reported = [];
  });

  tearDown(() async {
    repo.cancelPending();
    await pending.close();
    await db.close();
  });

  ComposerCubit open({
    ComposerDraft? initial,
    AttachmentsCubit? attachments,
    bool drafts = true,
  }) {
    final cubit = ComposerCubit(
      postsRepository: server,
      pending: pending,
      author: common.AuthorSnapshot(userId: _uid, handle: 'me'),
      scheduleEnabled: true,
      mediaOn: true,
      attachments: attachments,
      onUnexpectedError: (error, _) => reported.add(error),
      drafts: drafts ? repo : null,
      uid: _uid,
      initialDraft: initial,
    );
    addTearDown(cubit.close);
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

  group('P1-1: a storage failure never sends under an unproven key', () {
    test(
      'post: a retry after a lost response reuses K1, never a new key',
      () async {
        final c = await saved('hello');
        server.script.add(ServerReply.drop);
        await c.submit();
        expect(server.accepted, hasLength(1));
        final k1 = server.receivedKeys.single;
        expect((await row(c.draftId)).sendKey, k1);

        repo.broken = true;
        await c.submit();

        expect(
          server.receivedKeys.where((k) => k != k1),
          isEmpty,
          reason: 'a second key would create a second post',
        );
        expect(server.accepted, hasLength(1));
        expect(server.receivedKeys, [k1, k1], reason: 'K1 was replayed');
        expect(c.state.status, ComposerStatus.posted);
      },
    );

    test('schedule: a retry after a lost response reuses K1', () async {
      final c = await saved('hello');
      c.scheduleChanged(at);
      server.script.add(ServerReply.drop);
      await c.submit();
      expect(server.accepted.map((a) => a.kind), ['schedule']);
      final k1 = server.receivedKeys.single;

      repo.broken = true;
      await c.submit();

      expect(server.receivedKeys.where((k) => k != k1), isEmpty);
      expect(server.accepted, hasLength(1));
      expect(c.state.scheduledNotice, isNotNull, reason: 'K1 was replayed');
    });

    test('post: a reopened composer that cannot read the row refuses, with '
        'no RPC', () async {
      final first = await saved('hello');
      server.script.add(ServerReply.drop);
      await first.submit();
      expect(server.accepted, hasLength(1));
      final draft = (await repo.read(_uid, first.draftId))!;
      await first.close();

      final c = open(initial: draft);
      repo.broken = true;
      await c.submit();

      expect(server.received, 1, reason: 'nothing was sent');
      expect(c.state.status, ComposerStatus.editing);
      expect(c.state.error, isA<UnknownApiException>());
      expect(c.state.draft.text, 'hello', reason: 'the text stays');
      expect(c.state.canSubmit, isTrue, reason: 'the user can retry');
    });

    test('schedule: a reopened composer that cannot read the row refuses, '
        'with no RPC', () async {
      final first = await saved('hello');
      first.scheduleChanged(at);
      server.script.add(ServerReply.drop);
      await first.submit();
      final draft = (await repo.read(_uid, first.draftId))!;
      await first.close();

      final c = open(initial: draft)..scheduleChanged(at);
      repo.broken = true;
      await c.submit();

      expect(server.received, 1);
      expect(c.state.status, ComposerStatus.editing);
      expect(c.state.error, isA<UnknownApiException>());
      expect(c.state.scheduledAt, isNotNull, reason: 'the time stays');
    });

    test('schedule: a key claimed for another time is not reused', () async {
      final c = await saved('hello');
      c.scheduleChanged(at);
      server.script.add(ServerReply.drop);
      await c.submit();

      c.scheduleChanged(at.add(const Duration(hours: 1)));
      repo.broken = true;
      await c.submit();

      expect(server.received, 1);
      expect(c.state.error, isA<UnknownApiException>());
    });

    test('a first send that cannot claim refuses, with no RPC', () async {
      final c = await saved('hello');
      repo.broken = true;

      await c.submit();

      expect(server.received, 0);
      expect(c.state.status, ComposerStatus.editing);
      expect(c.state.error, isA<UnknownApiException>());
      expect(reported, isNotEmpty, reason: 'the storage failure is reported');
      expect(pending.state, isEmpty, reason: 'no optimistic row');
    });

    test('"send anyway" that cannot store its new key refuses', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      c.textChanged('hello, edited');
      await c.submit();
      expect(c.state.sendConflict, SendConflict.earlierVersionSent);
      c.sendConflictShown();

      repo.broken = true;
      await c.sendAnyway();

      expect(server.accepted, hasLength(1));
      expect(c.state.error, isA<UnknownApiException>());
    });

    test('a remembered key with an edited body, store broken: the server '
        'refuses it and the earlier version is named', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      final k1 = server.receivedKeys.single;

      c.textChanged('hello, edited');
      repo.broken = true;
      await c.submit();

      expect(server.receivedKeys, [k1, k1], reason: 'K1, never a new key');
      expect(server.accepted, hasLength(1));
      expect(c.state.sendConflict, SendConflict.earlierVersionSent);
      expect(c.state.error, isNull);
      expect(c.state.draft.text, 'hello, edited');
    });

    test('a key proven unused is forgotten with the row\'s', () async {
      final c = await saved('hello');
      server.refusals.add(const ValidationException('bad'));
      await c.submit();
      final k1 = await repo.clearedOne.future;

      repo.broken = true;
      await c.submit();

      expect(server.receivedKeys, [k1], reason: 'no send after the refusal');
      expect(c.state.error, isA<UnknownApiException>());
    });
  });

  group('P1-2: a composer that closed while claiming sends nothing', () {
    test('post: closed while claimSend is pending', () async {
      final c = await saved('hello');
      repo.gate = Completer<void>();

      final sent = c.submit();
      await repo.started.future;
      await c.close();
      repo.gate!.complete();
      await sent;

      expect(server.received, 0);
      expect(pending.state, isEmpty);
      final key = await repo.clearedOne.future;
      expect(
        (await row(c.draftId)).sendKey,
        isNull,
        reason: 'the fresh key $key was released',
      );
    });

    test('schedule: closed while claimSend is pending', () async {
      final c = await saved('hello');
      c.scheduleChanged(at);
      repo.gate = Completer<void>();

      final sent = c.submit();
      await repo.started.future;
      await c.close();
      repo.gate!.complete();
      await sent;

      expect(server.received, 0);
      await repo.clearedOne.future;
      expect((await row(c.draftId)).sendKey, isNull);
    });

    test('a reused key is kept when the composer closes', () async {
      final c = await saved('hello');
      server.script.add(ServerReply.drop);
      await c.submit();
      final k1 = server.receivedKeys.single;
      repo
        ..gate = Completer<void>()
        ..started = Completer<void>();

      final sent = c.submit();
      await repo.started.future;
      await c.close();
      repo.gate!.complete();
      await sent;

      expect(server.received, 1);
      expect((await row(c.draftId)).sendKey, k1, reason: 'it may have landed');
    });
  });

  group('P1-2: an image post that closed', () {
    late FakeImagePicker picker;
    late MockMediaRepository media;
    late AttachmentsCubit attachments;

    setUp(() {
      picker = FakeImagePicker();
      media = MockMediaRepository();
      attachments = AttachmentsCubit(
        picker: picker,
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: media),
      );
    });

    tearDown(() => attachments.close());

    Future<void> attach() async {
      picker.next = [imageBytes('a')];
      await attachments.pick();
      await Future<void>.delayed(Duration.zero);
    }

    void verifyNoUpload() => verifyNever(
      () => media.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    );

    test(
      'closed while the claim is pending: no upload starts, no RPC',
      () async {
        stubHappyUpload(media);
        final c = open(attachments: attachments)..textChanged('look');
        await attach();
        await c.saveDraft();
        repo.gate = Completer<void>();

        final sent = c.submit();
        await repo.started.future;
        await c.close();
        repo.gate!.complete();
        await sent;

        verifyNoUpload();
        expect(server.received, 0);
      },
    );

    test(
      'closed during the upload: no RPC, the fresh key is released',
      () async {
        final put = Completer<void>();
        stubHappyUpload(media, onPut: (_) => put.future);
        final c = open(attachments: attachments)..textChanged('look');
        await attach();
        await c.saveDraft();

        final sent = c.submit();
        await repo.started.future;
        await untilCalled(() => media.putObject(any(), any()));
        await c.close();
        put.complete();
        await sent;

        expect(server.received, 0);
        expect(pending.state, isEmpty);
        await repo.clearedOne.future;
        expect((await row(c.draftId)).sendKey, isNull);
      },
    );

    test('an image-only post never claims: in-memory key, unchanged', () async {
      stubHappyUpload(media);
      final c = open(attachments: attachments);
      await attach();
      repo.broken = true;
      server.script.add(ServerReply.drop);

      await c.submit();
      await c.submit();

      expect(repo.claims, 0, reason: 'no row to keep a key on');
      expect(server.accepted, hasLength(1));
      expect(server.receivedKeys, hasLength(2));
      expect(server.receivedKeys.first, server.receivedKeys.last);
      expect(c.state.status, ComposerStatus.posted);
    });
  });

  test(
    'a composer without drafts keeps the in-memory key, unchanged',
    () async {
      final c = open(drafts: false)..textChanged('no drafts');
      server.script.add(ServerReply.drop);

      await c.submit();
      await c.submit();

      expect(repo.claims, 0);
      expect(server.accepted, hasLength(1));
      expect(server.receivedKeys.first, server.receivedKeys.last);
      expect(c.state.status, ComposerStatus.posted);
    },
  );
}
