import 'dart:async';

import 'package:drift/native.dart';
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

/// The real drafts store, holding each claim until [gate] completes.
class _HeldDrafts extends DraftsRepository {
  _HeldDrafts(super.database)
    : super(autosaveDelay: const Duration(milliseconds: 10));

  Completer<void>? gate;
  final Completer<void> started = Completer<void>();
  final Completer<String> cleared = Completer<String>();
  int claims = 0;

  /// The texts handed to [autosave], in order.
  final List<String> autosaved = [];

  @override
  void autosave(ComposerDraft draft) {
    autosaved.add(draft.text);
    super.autosave(draft);
  }

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
    if (!cleared.isCompleted) cleared.complete(key);
  }
}

/// P1-2: the send is bound to the session it started in. The session ending
/// (a sign-out, an A to B switch: `wipeSessionData` ends the epoch first)
/// while the key is claimed or the photos upload sends nothing.
void main() {
  setUpAll(registerMediaFallbacks);

  late AppDatabase db;
  late _HeldDrafts repo;
  late FakePostsServer server;
  late PendingPostsCubit pending;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = _HeldDrafts(db);
    server = FakePostsServer();
    pending = PendingPostsCubit();
  });

  tearDown(() async {
    repo.cancelPending();
    await pending.close();
    await db.close();
  });

  ComposerCubit open({
    AttachmentsCubit? attachments,
    bool drafts = true,
    bool bound = true,
  }) {
    final cubit = ComposerCubit(
      postsRepository: server,
      pending: pending,
      author: common.AuthorSnapshot(userId: _uid, handle: 'me'),
      scheduleEnabled: true,
      mediaOn: true,
      attachments: attachments,
      drafts: drafts ? repo : null,
      uid: _uid,
      sessionEpoch: bound ? db.sessionEpoch : null,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Future<ComposerCubit> saved(String text) async {
    final c = open()..textChanged(text);
    await c.saveDraft();
    return c;
  }

  Future<String?> storedText(String id) async => (await (db.select(
    db.composerDraftEntries,
  )..where((t) => t.draftId.equals(id))).getSingleOrNull())?.draftText;

  Future<String?> storedKey(String id) async => (await (db.select(
    db.composerDraftEntries,
  )..where((t) => t.draftId.equals(id))).getSingle()).sendKey;

  test('post: the session ends while the claim is pending', () async {
    final c = await saved('from the old account');
    repo.gate = Completer<void>();

    final sent = c.submit();
    await repo.started.future;
    db.sessionEpoch.end();
    repo.gate!.complete();
    await sent;

    expect(server.received, 0);
    expect(pending.state, isEmpty, reason: 'no optimistic row either');
    expect(c.state.status, ComposerStatus.editing, reason: 'not stuck');
    await repo.cleared.future;
    expect(await storedKey(c.draftId), isNull, reason: 'fresh key released');
  });

  test('schedule: the session ends while the claim is pending', () async {
    final c = await saved('from the old account');
    c.scheduleChanged(DateTime.now().add(const Duration(days: 1)));
    repo.gate = Completer<void>();

    final sent = c.submit();
    await repo.started.future;
    db.sessionEpoch.end();
    repo.gate!.complete();
    await sent;

    expect(server.received, 0);
    expect(c.state.status, ComposerStatus.editing);
  });

  group('with photos', () {
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

    test('the session ends during the upload: no RPC', () async {
      final put = Completer<void>();
      stubHappyUpload(media, onPut: (_) => put.future);
      final c = open(attachments: attachments, drafts: false);
      await attach();

      final sent = c.submit();
      await untilCalled(() => media.putObject(any(), any()));
      db.sessionEpoch.end();
      put.complete();
      await sent;

      expect(server.received, 0);
      expect(pending.state, isEmpty);
      expect(c.state.status, ComposerStatus.editing);
    });

    test('the session ends during the claim: no upload starts', () async {
      stubHappyUpload(media);
      final c = open(attachments: attachments)..textChanged('look');
      await attach();
      await c.saveDraft();
      repo.gate = Completer<void>();

      final sent = c.submit();
      await repo.started.future;
      db.sessionEpoch.end();
      repo.gate!.complete();
      await sent;

      verifyNever(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      );
      expect(server.received, 0);
    });

    test('an idle photo post whose session ended starts no upload', () async {
      stubHappyUpload(media);
      final c = open(attachments: attachments, drafts: false);
      await attach();
      db.sessionEpoch.end();

      await c.submit();

      verifyNever(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      );
      expect(server.received, 0);
    });
  });

  group('bound to the session it was opened in (A to B with it open)', () {
    test(
      'an idle composer sends nothing, on the first tap or the next',
      () async {
        final c = await saved('from the old account');
        db.sessionEpoch.end();

        await c.submit();
        await c.submit();

        expect(server.received, 0);
        expect(repo.claims, 0, reason: 'no key is claimed for it');
        expect(pending.state, isEmpty, reason: 'no optimistic row');
        expect(c.state.status, ComposerStatus.editing);
      },
    );

    test('an idle schedule sends nothing', () async {
      final c = await saved('from the old account');
      c.scheduleChanged(DateTime.now().add(const Duration(days: 1)));
      db.sessionEpoch.end();

      await c.submit();
      await c.submit();

      expect(server.received, 0);
      expect(repo.claims, 0);
    });

    test('a draft edit after the switch is not written', () async {
      final c = await saved('from the old account');
      db.sessionEpoch.end();

      c.textChanged('typed after the switch');
      final result = await c.saveDraft();

      expect(repo.autosaved, isNot(contains('typed after the switch')));
      expect(result, DraftSaveResult.skipped);
      expect(await storedText(c.draftId), 'from the old account');
    });

    test('a composer with no session epoch behaves as before', () async {
      final c = open(bound: false)..textChanged('hello');
      expect(await c.saveDraft(), DraftSaveResult.saved);
      db.sessionEpoch.end();

      c.textChanged('hello again');
      await c.submit();

      expect(repo.autosaved, contains('hello again'));
      expect(server.accepted, hasLength(1));
      expect(c.state.status, ComposerStatus.posted);
    });
  });

  test('an unchanged session still posts', () async {
    final c = await saved('hello');

    await c.submit();

    expect(server.accepted, hasLength(1));
    expect(c.state.status, ComposerStatus.posted);
  });
}
