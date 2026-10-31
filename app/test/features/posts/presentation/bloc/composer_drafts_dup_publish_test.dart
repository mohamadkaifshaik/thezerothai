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

/// W6-38: the drafts duplicate-publication matrix (ADR-0029 Amendment 1, A4).
///
/// S1-S4 pin what is safe today. G1-G6 are written as tests of the FIXED
/// behaviour and skipped until W6-39 persists the send key on the draft row;
/// each asserts only what the server saw (how many items it accepted), never
/// the cubit's internals, so it passes unchanged once the fix lands. Run them
/// with `flutter test --run-skipped` to see today's duplicates.
///
/// Every cell runs for CreatePost and SchedulePost, with no media, a photo
/// and a GIF. A GIF cannot be scheduled (the composer refuses the time, the
/// server refuses the item: `ErrGifNotSchedulable`), so that cell is asserted
/// once in its own test.
///
/// A "kill" closes the cubits, cancels the autosave timers (they die with the
/// process) and rebuilds everything from the same in-memory drift database
/// with a new [DraftsRepository], as a restart would.

enum _Kind { post, schedule }

enum _Media { none, photo, gif }

const _uid = 'u1';

/// A repository whose delete never finishes: the process is killed between the
/// server's answer and the local delete (G2).
class _DiesBeforeDelete extends DraftsRepository {
  _DiesBeforeDelete(super.database, {super.autosaveDelay});

  int deletes = 0;

  @override
  Future<void> delete(String uid, Iterable<String> ids) {
    deletes++;
    return Completer<void>().future;
  }
}

class _Composer {
  _Composer(this.cubit, this.attachments, this.picker, this.gifSource);

  final ComposerCubit cubit;
  final AttachmentsCubit attachments;
  final FakeImagePicker picker;
  final FakeGifSource gifSource;
}

void main() {
  setUpAll(registerMediaFallbacks);

  late AppDatabase db;
  late DraftsRepository repo;
  late FakePostsServer server;
  late MockMediaRepository media;
  late PendingPostsCubit pending;
  late DateTime at;
  late List<_Composer> opened;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = DraftsRepository(
      db,
      autosaveDelay: const Duration(milliseconds: 10),
    );
    server = FakePostsServer();
    media = MockMediaRepository();
    // One media repository for every composer: ids are unique per world.
    stubHappyUpload(media);
    pending = PendingPostsCubit();
    // Relative to the real clock (fixed_date_guard); the fake server does not
    // check the lead time.
    at = DateTime.now().toUtc().add(const Duration(days: 2));
    opened = [];
  });

  tearDown(() async {
    repo.cancelPending();
    for (final c in opened) {
      await c.cubit.close();
      await c.attachments.close();
    }
    await pending.close();
    await db.close();
  });

  _Composer open({
    ComposerDraft? initial,
    DraftsRepository? store,
    _Media withMedia = _Media.none,
  }) {
    final picker = FakeImagePicker();
    final gifSource = FakeGifSource();
    final attachments = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
      gifSource: gifSource,
      gifPreparer: FakeGifPreparer(),
    );
    final cubit = ComposerCubit(
      postsRepository: server,
      pending: pending,
      author: common.AuthorSnapshot(userId: _uid, handle: 'me'),
      attachments: attachments,
      scheduleEnabled: true,
      mediaOn: true,
      gifFlag: true,
      drafts: store ?? repo,
      uid: _uid,
      initialDraft: initial,
    );
    final c = _Composer(cubit, attachments, picker, gifSource);
    opened.add(c);
    return c;
  }

  /// Types [text], attaches [m], sets the schedule time for [kind] and saves
  /// the draft row (what the autosave would have done).
  Future<void> prepare(
    _Composer c,
    _Kind kind,
    _Media m, {
    String text = 'hello world',
    bool save = true,
  }) async {
    c.cubit.textChanged(text);
    switch (m) {
      case _Media.none:
        break;
      case _Media.photo:
        c.picker.next = [imageBytes('a')];
        await c.attachments.pick();
      case _Media.gif:
        c.gifSource.next = imageBytes('g');
        await c.attachments.pickGif();
    }
    await Future<void>.delayed(Duration.zero);
    if (kind == _Kind.schedule) c.cubit.scheduleChanged(at);
    if (save) await c.cubit.saveDraft();
  }

  Future<List<ComposerDraft>> rows() => repo.watch(_uid).first;

  Future<void> until(bool Function() ok, [String what = 'condition']) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!ok()) {
      if (DateTime.now().isAfter(deadline)) fail('never reached: $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> untilRows(bool Function(List<ComposerDraft>) ok) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final list = await rows();
      if (ok(list)) return;
      if (DateTime.now().isAfter(deadline)) fail('rows never matched: $list');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// The process dies: nothing more runs, the database stays.
  Future<void> kill(List<_Composer> cs) async {
    repo.cancelPending();
    for (final c in cs) {
      await c.cubit.close();
      await c.attachments.close();
    }
  }

  /// A restart: a new repository over the same database.
  DraftsRepository restart() {
    repo = DraftsRepository(
      db,
      autosaveDelay: const Duration(milliseconds: 10),
    );
    return repo;
  }

  /// The user reopens draft [id] and taps Post or Schedule (a reopened draft
  /// has no media, F8; the schedule time is not part of a draft).
  Future<_Composer> reopen(String id, _Kind kind) async {
    final draft = await repo.read(_uid, id);
    expect(draft, isNotNull, reason: 'the draft row must have survived');
    final c = open(initial: draft);
    expect(c.cubit.state.hasAttachments, isFalse, reason: 'F8: no media');
    if (kind == _Kind.schedule) c.cubit.scheduleChanged(at);
    return c;
  }

  // The matrix cells. A scheduled GIF is not a reachable cell.
  final cells = [
    for (final k in _Kind.values)
      for (final m in _Media.values)
        if (!(k == _Kind.schedule && m == _Media.gif)) (k, m),
  ];
  String label((_Kind, _Media) c) => '${c.$1.name} + ${c.$2.name}';

  group('a GIF cannot be scheduled', () {
    test('the composer refuses a time while a GIF is attached', () async {
      final c = open();
      await prepare(c, _Kind.post, _Media.gif, save: false);
      c.cubit.scheduleChanged(at);
      expect(c.cubit.state.scheduledAt, isNull);
    });
  });

  group('S1 a double tap sends once', () {
    for (final cell in cells) {
      test(label(cell), () async {
        final c = open();
        await prepare(c, cell.$1, cell.$2);
        server.script.add(ServerReply.hold);

        unawaited(c.cubit.submit());
        unawaited(c.cubit.submit());
        unawaited(c.cubit.submit());
        await until(() => server.received >= 1, 'first request');
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(server.received, 1);
        expect(c.cubit.state.isSubmitting, isTrue);
        if (cell.$2 != _Media.none) {
          verify(
            () => media.createUpload(
              idempotencyKey: any(named: 'idempotencyKey'),
              purpose: any(named: 'purpose'),
              images: any(named: 'images'),
            ),
          ).called(1);
        }
      });
    }
  });

  group('S2 a retry after a lost response reuses the key', () {
    for (final cell in cells) {
      test(label(cell), () async {
        final c = open();
        await prepare(c, cell.$1, cell.$2);
        server.script.add(ServerReply.drop);

        await c.cubit.submit();
        expect(c.cubit.state.error, isA<NetworkException>());
        expect(server.accepted, hasLength(1), reason: 'it did land');

        await c.cubit.submit();

        expect(server.received, 2);
        expect(server.receivedKeys[0], server.receivedKeys[1]);
        expect(server.accepted, hasLength(1), reason: 'replayed, not created');
        expect(c.cubit.state.error, isNull);
        if (cell.$1 == _Kind.post) {
          expect(c.cubit.state.status, ComposerStatus.posted);
        } else {
          expect(c.cubit.state.scheduledNotice, isNotNull);
        }
        if (cell.$2 != _Media.none) {
          // The retry reuses the finished uploads: no second reservation and
          // no second finalize (the media ids, and so the key, stay).
          verify(
            () => media.createUpload(
              idempotencyKey: any(named: 'idempotencyKey'),
              purpose: any(named: 'purpose'),
              images: any(named: 'images'),
            ),
          ).called(1);
          verify(
            () => media.finalizeUpload(
              idempotencyKey: any(named: 'idempotencyKey'),
              items: any(named: 'items'),
            ),
          ).called(1);
        }
      });
    }
  });

  group('S3 the draft row goes only after success', () {
    for (final cell in cells) {
      test('${label(cell)}: present in flight and after a failure', () async {
        final c = open();
        await prepare(c, cell.$1, cell.$2);
        final id = c.cubit.draftId;

        server.script.addAll([ServerReply.hold]);
        unawaited(c.cubit.submit());
        await until(() => server.received >= 1, 'first request');
        expect((await rows()).map((d) => d.id), [id], reason: 'in flight');
        await kill([c]);

        restart();
        final d = await repo.read(_uid, id);
        final c2 = open(initial: d);
        if (cell.$1 == _Kind.schedule) c2.cubit.scheduleChanged(at);
        final broken = FakePostsServer()..script.add(ServerReply.drop);
        final c3 = ComposerCubit(
          postsRepository: broken,
          pending: pending,
          author: common.AuthorSnapshot(userId: _uid, handle: 'me'),
          scheduleEnabled: true,
          drafts: repo,
          uid: _uid,
          initialDraft: d,
        );
        addTearDown(c3.close);
        if (cell.$1 == _Kind.schedule) c3.scheduleChanged(at);
        await c3.submit();
        expect(c3.state.error, isA<NetworkException>());
        expect((await rows()).map((r) => r.id), [id], reason: 'after failure');
      });

      test('${label(cell)}: gone after success', () async {
        final c = open();
        await prepare(c, cell.$1, cell.$2);
        expect(await rows(), hasLength(1));

        await c.cubit.submit();

        expect(server.accepted, hasLength(1));
        await untilRows((r) => r.isEmpty);
      });
    }
  });

  group('S4 the same images are not attached twice', () {
    for (final m in [_Media.photo, _Media.gif]) {
      test(
        'post + ${m.name}: an edited send under a new key is refused',
        () async {
          final c = open();
          await prepare(c, _Kind.post, m);
          server.script.add(ServerReply.drop);
          await c.cubit.submit();
          expect(server.accepted, hasLength(1));

          // The user edits and sends again: a new key, the same media ids.
          c.cubit.textChanged('hello world, edited');
          await c.cubit.submit();

          expect(server.accepted, hasLength(1), reason: 'media is single use');
          expect(c.cubit.state.error, isA<MediaNotReadyException>());
        },
      );
    }

    test(
      'schedule + photo: two items may exist, the media publishes once',
      () async {
        final c = open();
        await prepare(c, _Kind.schedule, _Media.photo);
        server.script.add(ServerReply.drop);
        await c.cubit.submit();
        c.cubit.textChanged('hello world, edited');
        await c.cubit.submit();

        // SchedulePost validates media but does not attach it, so both are
        // accepted (see G3); only the first can publish.
        server.publishDue();

        expect(server.published, hasLength(1));
        expect(server.published.single.mediaIds, ['m1']);
      },
    );
  });

  group('G1 killed after the request left, then the draft reopened', () {
    for (final cell in cells) {
      test(label(cell), () async {
        final c = open();
        await prepare(c, cell.$1, cell.$2);
        final id = c.cubit.draftId;
        server.script.add(ServerReply.hold);
        unawaited(c.cubit.submit());
        await until(() => server.accepted.isNotEmpty, 'the server commit');
        await kill([c]);

        restart();
        final again = await reopen(id, cell.$1);
        await again.cubit.submit();

        expect(
          server.accepted,
          hasLength(1),
          reason: 'the reopened draft must reuse the first send',
        );
      }, skip: 'W6-38 G1: fixed by W6-39');
    }
  });

  group('G2 killed after success, before the local delete', () {
    for (final cell in cells) {
      test(label(cell), () async {
        final dying = _DiesBeforeDelete(
          db,
          autosaveDelay: const Duration(milliseconds: 10),
        );
        final c = open(store: dying);
        await prepare(c, cell.$1, cell.$2);
        final id = c.cubit.draftId;

        await c.cubit.submit();
        expect(server.accepted, hasLength(1));
        if (cell.$1 == _Kind.post) {
          expect(c.cubit.state.status, ComposerStatus.posted);
        }
        expect(dying.deletes, 1, reason: 'the delete started and hung');
        await kill([c]);

        restart();
        final again = await reopen(id, cell.$1);
        await again.cubit.submit();

        expect(
          server.accepted,
          hasLength(1),
          reason: 'a row that outlived its success must not post again',
        );
      }, skip: 'W6-38 G2: fixed by W6-39');
    }
  });

  group('G3 an edit after a lost response', () {
    // post + photo / gif is S4: the server refuses the edited send, because
    // the media is already attached (no duplicate, but see G6).
    final g3 = [
      (_Kind.post, _Media.none),
      (_Kind.schedule, _Media.none),
      (_Kind.schedule, _Media.photo),
    ];
    for (final cell in g3) {
      test(label(cell), () async {
        final c = open();
        await prepare(c, cell.$1, cell.$2);
        server.script.add(ServerReply.drop);
        await c.cubit.submit();
        expect(c.cubit.state.error, isA<NetworkException>());
        expect(server.accepted, hasLength(1));

        c.cubit.textChanged('hello world, edited');
        await c.cubit.submit();

        expect(
          server.accepted,
          hasLength(1),
          reason: 'an edit after an ambiguous failure must not add an item',
        );
      }, skip: 'W6-38 G3: fixed by W6-39');
    }
  });

  group('G4 two composers on one draft', () {
    for (final cell in cells) {
      test(label(cell), () async {
        final seed = open();
        await prepare(seed, cell.$1, _Media.none);
        final id = seed.cubit.draftId;
        final draft = await repo.read(_uid, id);
        final a = open(initial: draft);
        final b = open(initial: draft);
        // Each composer attaches its own media (distinct ids).
        await prepare(a, cell.$1, cell.$2, text: draft!.text, save: false);
        await prepare(b, cell.$1, cell.$2, text: draft.text, save: false);

        server.script.add(ServerReply.hold);
        unawaited(a.cubit.submit());
        await until(() => server.accepted.isNotEmpty, 'the first commit');
        await b.cubit.submit();

        expect(
          server.accepted,
          hasLength(1),
          reason: 'both composers must send under one key',
        );
      }, skip: 'W6-38 G4: fixed by W6-39');
    }
  });

  group('G5 a stale composer posts a draft that was already posted', () {
    for (final cell in cells) {
      test(
        label(cell),
        () async {
          final seed = open();
          await prepare(seed, cell.$1, _Media.none);
          final id = seed.cubit.draftId;
          final draft = await repo.read(_uid, id);
          final a = open(initial: draft);
          final b = open(initial: draft);
          await prepare(a, cell.$1, cell.$2, text: draft!.text, save: false);
          await prepare(b, cell.$1, cell.$2, text: draft.text, save: false);

          await a.cubit.submit();
          await untilRows((r) => r.isEmpty);
          expect(server.accepted, hasLength(1));
          await b.cubit.submit();

          expect(
            server.accepted,
            hasLength(1),
            reason: 'the row is gone: the draft was already sent',
          );
        },
        skip:
            'W6-38 G5: fixed by W6-39 (the claim must refuse when the row '
            'is gone, see the report)',
      );
    }
  });

  group('G6 a send of the other kind after a lost response', () {
    for (final first in _Kind.values) {
      test('${first.name} first, then the other kind', () async {
        final c = open();
        await prepare(c, first, _Media.none);
        server.script.add(ServerReply.drop);
        await c.cubit.submit();
        expect(server.accepted, hasLength(1));

        // The user switches: Schedule -> Post now, or Post -> Schedule.
        c.cubit.scheduleChanged(first == _Kind.post ? at : null);
        await c.cubit.submit();

        expect(
          server.accepted,
          hasLength(1),
          reason: 'one tap after an ambiguous send must not add the other kind',
        );
      }, skip: 'W6-38 G6: fixed by W6-39 (the warning for the other kind)');
    }
  });
}
