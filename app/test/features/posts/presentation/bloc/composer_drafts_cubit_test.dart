import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/drafts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// A store whose every call fails with a message that carries the draft text,
/// as a database error carrying bound values would.
class _LeakyRepository extends DraftsRepository {
  _LeakyRepository(super.database, this.secret);

  final String secret;

  @override
  void autosave(ComposerDraft draft) {}

  @override
  Future<DraftSaveResult> upsert(ComposerDraft draft) =>
      Future.error(StateError('INSERT failed for $secret'));

  @override
  Future<void> delete(String uid, Iterable<String> ids) =>
      Future.error(StateError('DELETE failed for $secret'));

  @override
  Future<ComposerDraft?> read(String uid, String draftId) =>
      Future.error(StateError('SELECT failed for $secret'));
}

/// The composer cubit over a REAL drafts store (in-memory drift): autosave,
/// "killed mid-typing", the leave decision, loading a saved draft, and one
/// account never reaching another's rows (W6-15, ADR-0029 F7).
void main() {
  late AppDatabase db;
  late DraftsRepository drafts;
  late _MockPostsRepository posts;
  late PendingPostsCubit pending;
  late List<Object> reported;

  setUp(() {
    reported = [];
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = DraftsRepository(
      db,
      autosaveDelay: const Duration(milliseconds: 10),
    );
    posts = _MockPostsRepository();
    pending = PendingPostsCubit();
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() async {
    drafts.cancelPending();
    await pending.close();
    await db.close();
  });

  ComposerCubit make({
    String uid = 'u1',
    ComposerDraft? initial,
    String quote = '',
    bool withDrafts = true,
    bool polls = true,
    bool engagement = true,
    bool schedule = false,
    DraftsRepository? store,
    AttachmentsCubit? attachments,
  }) {
    final cubit = ComposerCubit(
      postsRepository: posts,
      pending: pending,
      author: common.AuthorSnapshot(userId: uid, handle: 'me'),
      quoteOfPostId: quote,
      pollsFlag: polls,
      engagementOn: engagement,
      scheduleEnabled: schedule,
      attachments: attachments,
      onUnexpectedError: (error, _) => reported.add(error),
      drafts: withDrafts ? (store ?? drafts) : null,
      uid: uid,
      initialDraft: initial,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Future<List<ComposerDraft>> rows([String uid = 'u1']) =>
      drafts.watch(uid).first;

  /// Waits (polling the store) until [ok] holds for [uid]'s rows.
  Future<List<ComposerDraft>> until(
    bool Function(List<ComposerDraft>) ok, [
    String uid = 'u1',
  ]) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final list = await rows(uid);
      if (ok(list)) return list;
      if (DateTime.now().isAfter(deadline)) {
        fail('the store never reached the expected rows: $list');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  ComposerDraft stored(String id, String text, {String uid = 'u1'}) {
    final t = DateTime.now().toUtc();
    return ComposerDraft(
      id: id,
      uid: uid,
      text: text,
      paidPartnership: true,
      createdAt: t,
      updatedAt: t,
    );
  }

  group('autosave', () {
    test('killed mid-typing: the text is in the store afterwards', () async {
      final cubit = make();
      cubit.textChanged('half a thou');
      // No Save, no close: only the debounce ran.
      final list = await until((l) => l.length == 1);
      expect(list.single.text, 'half a thou');
      expect(list.single.uid, 'u1');
      expect(list.single.id, cubit.draftId);
    });

    test('a poll edit and an audience change are kept too', () async {
      final cubit = make();
      cubit.textChanged('question');
      cubit.pollAdded();
      cubit.pollChoiceChanged(0, 'yes');
      final list = await until((l) => l.isNotEmpty && l.single.poll != null);
      expect(list.single.poll!.choices.first, 'yes');
    });

    test('whitespace only is not a draft', () async {
      final cubit = make();
      cubit.textChanged('   ');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await rows(), isEmpty);
      expect(cubit.leaveAction, LeaveAction.none);
    });

    test('Discard deletes the row and stops autosaving', () async {
      final cubit = make();
      cubit.textChanged('draft me');
      await until((l) => l.length == 1);
      await cubit.discardDraft();
      expect(await rows(), isEmpty);
      cubit.textChanged('draft me, more');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await rows(), isEmpty);
    });

    test('with drafts off nothing is stored', () async {
      final cubit = make(withDrafts: false);
      cubit.textChanged('plain');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(cubit.draftsActive, isFalse);
      expect(cubit.leaveAction, LeaveAction.none);
      expect(await rows(), isEmpty);
    });

    test('a quote has no draft', () async {
      final cubit = make(quote: postId(7));
      cubit.textChanged('quoting');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(cubit.draftsActive, isFalse);
      expect(await rows(), isEmpty);
    });

    test('no uid, no drafts', () {
      expect(make(uid: '').draftsActive, isFalse);
    });
  });

  group('the leave decision', () {
    test('nothing typed: leave', () {
      expect(make().leaveAction, LeaveAction.none);
    });

    test('typed: ask; saved as it stands: leave; edited again: ask', () async {
      final cubit = make();
      cubit.textChanged('hello');
      expect(cubit.leaveAction, LeaveAction.savePrompt);
      expect(await cubit.saveDraft(), DraftSaveResult.saved);
      expect(cubit.leaveAction, LeaveAction.none);
      cubit.textChanged('hello again');
      expect(cubit.leaveAction, LeaveAction.savePrompt);
    });

    test('an opened draft left untouched: leave, the row stays', () async {
      await drafts.upsert(stored('00000000000000a1', 'old'));
      final cubit = make(initial: (await rows()).single);
      expect(cubit.state.draft.text, 'old');
      expect(cubit.leaveAction, LeaveAction.none);
      expect(await rows(), hasLength(1));
    });

    test('text cleared: leave, and the row is gone', () async {
      final cubit = make();
      cubit.textChanged('oops');
      await until((l) => l.length == 1);
      cubit.textChanged('');
      expect(cubit.leaveAction, LeaveAction.none);
      await until((l) => l.isEmpty);
    });
  });

  group('a saved draft', () {
    test('keeps its id and labels through edits', () async {
      await drafts.upsert(stored('00000000000000a1', 'old'));
      final cubit = make(initial: (await rows()).single);
      cubit.textChanged('old, edited');
      final list = await until((l) => l.single.text == 'old, edited');
      expect(list.single.id, '00000000000000a1');
      expect(list.single.paidPartnership, isTrue);
      expect(cubit.draftId, '00000000000000a1');
    });

    test('loading is not an edit: no write, no bump', () async {
      await drafts.upsert(stored('00000000000000a1', 'old'));
      final before = (await rows()).single.updatedAt;
      final cubit = make();
      cubit.textChanged('typed first');
      await until((l) => l.length == 2);
      expect(
        await cubit.loadSavedDraft('00000000000000a1'),
        DraftLoadResult.loaded,
      );
      expect(cubit.state.draft.text, 'old');
      expect(cubit.draftId, '00000000000000a1');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final list = await rows();
      expect(list, hasLength(2));
      expect(
        list.singleWhere((d) => d.id == '00000000000000a1').updatedAt,
        before,
      );
    });

    test("another account's draft cannot be loaded", () async {
      await drafts.upsert(stored('00000000000000b2', 'theirs', uid: 'u2'));
      final cubit = make(uid: 'u1');
      expect(
        await cubit.loadSavedDraft('00000000000000b2'),
        DraftLoadResult.gone,
      );
      expect(cubit.state.draft.text, isEmpty);
    });

    test('a poll the flag no longer offers is not loaded', () async {
      final d = stored('00000000000000a1', 'q').copyWith(
        poll: const DraftPoll(choices: ['a', 'b'], durationMinutes: 60),
      );
      final cubit = make(initial: d, polls: false);
      expect(cubit.state.poll, isNull);
    });
  });

  group('loading a draft with a poll follows the toolbar rules', () {
    ComposerDraft withPoll() => stored(
      '00000000000000c1',
      'which?',
    ).copyWith(poll: const DraftPoll(choices: ['a', 'b'], durationMinutes: 60));

    AttachmentsCubit attachmentsWith(FakeImagePicker picker) {
      final attachments = AttachmentsCubit(
        picker: picker,
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: MockMediaRepository()),
      );
      addTearDown(attachments.close);
      return attachments;
    }

    test('a schedule time is cleared (a scheduled post has no poll)', () async {
      await drafts.upsert(withPoll());
      final cubit = make(schedule: true);
      cubit.scheduleChanged(DateTime.now().add(const Duration(hours: 3)));
      expect(cubit.state.isScheduling, isTrue);
      expect(
        await cubit.loadSavedDraft('00000000000000c1'),
        DraftLoadResult.loaded,
      );
      expect(cubit.state.isScheduling, isFalse);
      expect(cubit.state.poll, isNotNull);
    });

    test('a plain draft keeps the schedule time', () async {
      await drafts.upsert(stored('00000000000000c2', 'plain'));
      final cubit = make(schedule: true);
      cubit.scheduleChanged(DateTime.now().add(const Duration(hours: 3)));
      await cubit.loadSavedDraft('00000000000000c2');
      expect(cubit.state.isScheduling, isTrue);
    });

    test('attached photos refuse it and nothing changes', () async {
      await drafts.upsert(withPoll());
      final picker = FakeImagePicker();
      final attachments = attachmentsWith(picker);
      final cubit = make(attachments: attachments);
      cubit.textChanged('my own text');
      picker.next = [imageBytes('a')];
      await attachments.pick();
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.hasAttachments, isTrue);
      expect(
        await cubit.loadSavedDraft('00000000000000c1'),
        DraftLoadResult.blockedByMedia,
      );
      expect(cubit.state.draft.text, 'my own text');
      expect(cubit.state.poll, isNull);
      expect(cubit.state.hasAttachments, isTrue);
      expect(cubit.draftId, isNot('00000000000000c1'));
    });

    test('photos do not stop a plain draft', () async {
      await drafts.upsert(stored('00000000000000c2', 'plain'));
      final picker = FakeImagePicker();
      final attachments = attachmentsWith(picker);
      final cubit = make(attachments: attachments);
      picker.next = [imageBytes('a')];
      await attachments.pick();
      await Future<void>.delayed(Duration.zero);
      expect(
        await cubit.loadSavedDraft('00000000000000c2'),
        DraftLoadResult.loaded,
      );
      expect(cubit.state.draft.text, 'plain');
    });

    test('without the polls or engagement flag the poll is left out', () async {
      for (final (polls, engagement) in [(false, true), (true, false)]) {
        await drafts.upsert(withPoll());
        final cubit = make(polls: polls, engagement: engagement);
        await cubit.loadSavedDraft('00000000000000c1');
        expect(cubit.state.poll, isNull, reason: '$polls $engagement');
        expect(cubit.state.draft.text, 'which?');
        final opened = make(
          polls: polls,
          engagement: engagement,
          initial: withPoll(),
        );
        expect(opened.state.poll, isNull, reason: '$polls $engagement');
      }
    });
  });

  group('a storage failure never leaks the text', () {
    const secret = 'my very private words';

    test('save, discard and load report without the message', () async {
      final cubit = make(store: _LeakyRepository(db, secret));
      cubit.textChanged(secret);
      expect(await cubit.saveDraft(), DraftSaveResult.skipped);
      await cubit.discardDraft();
      final other = make(store: _LeakyRepository(db, secret));
      expect(
        await other.loadSavedDraft('00000000000000d1'),
        DraftLoadResult.gone,
      );
      expect(reported, hasLength(3));
      for (final error in reported) {
        expect(error.toString(), isNot(contains(secret)));
      }
    });
  });

  group('DraftsCubit', () {
    ComposerDraft at(String id, String text, String uid) =>
        stored(id, text, uid: uid);

    Future<DraftsCubit> open(String? uid) async {
      final cubit = DraftsCubit(repository: drafts, uid: uid);
      addTearDown(cubit.close);
      return cubit;
    }

    Future<void> ready(DraftsCubit c) async {
      while (c.state.status == DraftsStatus.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('lists only the signed-in account', () async {
      await drafts.upsert(at('0000000000000001', 'mine', 'u1'));
      await drafts.upsert(at('0000000000000002', 'theirs', 'u2'));
      final cubit = await open('u1');
      await ready(cubit);
      expect(cubit.state.drafts.map((d) => d.text), ['mine']);
      cubit.watchUid('u2');
      await ready(cubit);
      expect(cubit.state.drafts.map((d) => d.text), ['theirs']);
    });

    test('no uid: an empty ready list', () async {
      final cubit = await open(null);
      expect(cubit.state.status, DraftsStatus.ready);
      expect(cubit.state.drafts, isEmpty);
    });

    test('select all, delete, and the rest stays', () async {
      for (var i = 1; i <= 3; i++) {
        await drafts.upsert(at('000000000000000$i', 'd$i', 'u1'));
      }
      final cubit = await open('u1');
      await ready(cubit);
      cubit.editStarted();
      cubit.toggled('0000000000000001');
      cubit.toggled('0000000000000002');
      cubit.toggled('0000000000000002');
      expect(cubit.state.selected, {'0000000000000001'});
      cubit.selectAll();
      expect(cubit.state.allSelected, isTrue);
      cubit.toggled('0000000000000003');
      expect(await cubit.deleteSelected(), 2);
      expect(cubit.state.editing, isFalse);
      expect(cubit.state.selected, isEmpty);
      final left = await until((l) => l.length == 1);
      expect(left.single.id, '0000000000000003');
    });

    test('a row deleted elsewhere leaves the selection', () async {
      await drafts.upsert(at('0000000000000001', 'a', 'u1'));
      await drafts.upsert(at('0000000000000002', 'b', 'u1'));
      final cubit = await open('u1');
      await ready(cubit);
      cubit.editStarted();
      cubit.selectAll();
      await drafts.delete('u1', ['0000000000000001']);
      while (cubit.state.drafts.length != 1) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(cubit.state.selected, {'0000000000000002'});
    });

    test('Edit ends when the last draft goes', () async {
      await drafts.upsert(at('0000000000000001', 'a', 'u1'));
      final cubit = await open('u1');
      await ready(cubit);
      cubit.editStarted();
      expect(cubit.state.editing, isTrue);
      await drafts.delete('u1', ['0000000000000001']);
      while (cubit.state.drafts.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(cubit.state.editing, isFalse);
    });
  });
}
