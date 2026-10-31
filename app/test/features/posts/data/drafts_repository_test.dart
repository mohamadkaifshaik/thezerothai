import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:flutter_test/flutter_test.dart';

// Relative to the real clock, whole seconds (the column stores seconds).
final kBase = DateTime.fromMillisecondsSinceEpoch(
  DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
  isUtc: true,
);

void main() {
  late AppDatabase db;
  late DraftsRepository repo;
  late DateTime clock;
  var failures = 0;

  DateTime tick() => clock = clock.add(const Duration(seconds: 1));

  ComposerDraft draft(
    String id, {
    String uid = 'u1',
    String text = 'hello',
    DraftPoll? poll,
  }) => ComposerDraft(
    id: id,
    uid: uid,
    text: text,
    poll: poll,
    createdAt: kBase,
    updatedAt: kBase,
  );

  setUp(() {
    clock = DateTime.now().toUtc();
    failures = 0;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = DraftsRepository(
      db,
      autosaveDelay: const Duration(milliseconds: 20),
      now: tick,
      onAutosaveFailed: () => failures++,
    );
  });
  tearDown(() async {
    repo.cancelPending();
    await db.close();
  });

  Future<List<ComposerDraft>> list([String uid = 'u1']) =>
      repo.watch(uid).first;

  test('stores every field and reads it back', () async {
    final d = ComposerDraft(
      id: 'a',
      uid: 'u1',
      text: 'Which one? #poll',
      poll: const DraftPoll(
        choices: ['Tea', 'Coffee', ''],
        durationMinutes: 90,
      ),
      replyAudience: ReplyAudience.mentionedOnly,
      paidPartnership: true,
      madeWithAi: true,
      createdAt: kBase,
      updatedAt: kBase,
    );
    expect(await repo.upsert(d), DraftSaveResult.saved);
    final got = (await repo.read('u1', 'a'))!;
    expect(got.text, d.text);
    expect(got.poll, d.poll);
    expect(got.replyAudience, ReplyAudience.mentionedOnly);
    expect(got.paidPartnership, isTrue);
    expect(got.madeWithAi, isTrue);
    expect(got.createdAt.isAtSameMomentAs(kBase), isTrue);
  });

  test('lists newest edit first and keeps createdAt on an update', () async {
    await repo.upsert(draft('a'));
    await repo.upsert(draft('b'));
    await repo.upsert(draft('a', text: 'edited'));
    final rows = await list();
    expect(rows.map((d) => d.id), ['a', 'b']);
    expect(rows.first.text, 'edited');
    expect(rows.first.createdAt.isAtSameMomentAs(kBase), isTrue);
  });

  test('each account sees only its own drafts', () async {
    await repo.upsert(draft('a', uid: 'u1'));
    await repo.upsert(draft('b', uid: 'u2'));
    expect((await list('u1')).map((d) => d.id), ['a']);
    expect((await list('u2')).map((d) => d.id), ['b']);
    expect(await repo.read('u1', 'b'), isNull);
    // Deleting another account's id removes nothing.
    await repo.delete('u1', ['b']);
    expect(await list('u2'), hasLength(1));
  });

  test('drafts survive clearAll (sign-out) and stay with their uid', () async {
    await repo.upsert(draft('a', uid: 'u1'));
    await repo.upsert(draft('b', uid: 'u2'));
    db.sessionEpoch.end();
    await db.clearAll();
    expect((await list('u1')).map((d) => d.id), ['a']);
    expect((await list('u2')).map((d) => d.id), ['b']);
    // A third account signing in on this device sees none of them.
    expect(await list('u3'), isEmpty);
  });

  test('the 51st draft removes the oldest and says so', () async {
    for (var i = 0; i < kMaxDrafts; i++) {
      expect(await repo.upsert(draft('d$i')), DraftSaveResult.saved);
    }
    await repo.upsert(draft('other', uid: 'u2'));
    expect(await repo.upsert(draft('new')), DraftSaveResult.savedDroppedOldest);
    final rows = await list();
    expect(rows, hasLength(kMaxDrafts));
    expect(rows.first.id, 'new');
    expect(rows.any((d) => d.id == 'd0'), isFalse);
    expect(rows.any((d) => d.id == 'd1'), isTrue);
    expect(await list('u2'), hasLength(1));
  });

  test('text is cut to kMaxDraftCodePoints code points', () async {
    await repo.upsert(
      draft('a', text: '\u{1F600}' * (kMaxDraftCodePoints + 5)),
    );
    final got = (await repo.read('u1', 'a'))!;
    expect(got.text.runes.length, kMaxDraftCodePoints);
  });

  test('an empty draft is not kept and removes its row', () async {
    await repo.upsert(draft('a'));
    expect(await repo.upsert(draft('a', text: '  ')), DraftSaveResult.skipped);
    expect(await list(), isEmpty);
    await repo.upsert(
      draft(
        'p',
        text: '',
        poll: const DraftPoll(choices: ['', ''], durationMinutes: 60),
      ),
    );
    expect(await list(), isEmpty);
  });

  test('delete and deleteAll remove only that uid rows', () async {
    await repo.upsert(draft('a'));
    await repo.upsert(draft('b'));
    await repo.upsert(draft('c', uid: 'u2'));
    await repo.delete('u1', ['a']);
    expect((await list()).map((d) => d.id), ['b']);
    await repo.deleteAll('u1');
    expect(await list(), isEmpty);
    expect(await list('u2'), hasLength(1));
  });

  test('a damaged poll or policy loads as no poll / everyone', () async {
    await repo.upsert(draft('a'));
    await db.customStatement(
      "UPDATE composer_draft_entries SET poll_json = '{bad', reply_policy = 'x'",
    );
    final got = (await repo.read('u1', 'a'))!;
    expect(got.poll, isNull);
    expect(got.replyAudience, ReplyAudience.everyone);
  });

  group('autosave', () {
    // For "nothing was written" checks only: waits well past the 20 ms delay.
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 150));

    test('debounces: only the last text of a burst is written', () async {
      repo.autosave(draft('a', text: 'h'));
      repo.autosave(draft('a', text: 'he'));
      repo.autosave(draft('a', text: 'hel'));
      expect(await list(), isEmpty);
      final rows = await repo
          .watch('u1')
          .firstWhere((r) => r.isNotEmpty)
          .timeout(const Duration(seconds: 5));
      expect(rows.single.text, 'hel');
    });

    test('an explicit upsert cancels the pending autosave', () async {
      repo.autosave(draft('a', text: 'old'));
      await repo.upsert(draft('a', text: 'saved'));
      await settle();
      expect((await repo.read('u1', 'a'))!.text, 'saved');
    });

    test('delete cancels a pending autosave (posted draft)', () async {
      repo.autosave(draft('a'));
      await repo.delete('u1', ['a']);
      await settle();
      expect(await list(), isEmpty);
    });

    test('writes nothing when the session ended before it fired', () async {
      repo.autosave(draft('a'));
      db.sessionEpoch.end();
      await settle();
      expect(await list(), isEmpty);
      expect(failures, 0);
    });

    test('a write after the epoch moved on uses the new epoch', () async {
      repo.autosave(draft('a'));
      db.sessionEpoch.end();
      await settle();
      expect(await repo.upsert(draft('b')), DraftSaveResult.saved);
      expect((await list()).map((d) => d.id), ['b']);
    });

    test('a storage failure is reported without any details', () async {
      await db.customStatement('DROP TABLE composer_draft_entries');
      final broken = DraftsRepository(
        db,
        autosaveDelay: const Duration(milliseconds: 5),
        onAutosaveFailed: () => failures++,
      )..autosave(draft('a', text: 'secret words'));
      await settle();
      broken.cancelPending();
      expect(failures, 1);
    });
  });

  // W6-45 (L-5): drafts expire 30 days after the user's last edit. The clock
  // is injected and built from the real one, never a fixed date.
  group('expiry (30 days after the last user edit)', () {
    late DateTime t;
    late DraftsRepository timed;

    DateTime ago(Duration d) => t.subtract(d);

    setUp(() {
      t = kBase;
      timed = DraftsRepository(db, now: () => t);
    });

    Future<List<String>> ids(String uid) async => [
      for (final d in await timed.watch(uid).first) d.id,
    ];

    test('29d23h is kept, 30d and more is removed', () async {
      t = ago(const Duration(days: 29, hours: 23));
      await timed.upsert(draft('keep'));
      t = ago(const Duration(days: 30));
      await timed.upsert(draft('edge'));
      t = ago(const Duration(days: 31));
      await timed.upsert(draft('old'));
      t = kBase;
      // Never shown or opened, even before the purge ran.
      expect(await ids('u1'), ['keep']);
      expect(await timed.read('u1', 'edge'), isNull);
      expect(await timed.read('u1', 'old'), isNull);
      expect(await timed.read('u1', 'keep'), isNotNull);
      // The purge removes the rows themselves.
      expect(await timed.purgeExpired('u1'), 2);
      expect(await db.select(db.composerDraftEntries).get(), hasLength(1));
    });

    test('an autosave without changes does not extend the life', () async {
      t = ago(const Duration(days: 29));
      final d = draft('a');
      await timed.upsert(d);
      t = kBase;
      await timed.upsert(d);
      final fast = DraftsRepository(
        db,
        autosaveDelay: const Duration(milliseconds: 5),
        now: () => t,
      );
      fast.autosave(d);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final row = (await timed.read('u1', 'a'))!;
      expect(
        row.updatedAt.isAtSameMomentAs(ago(const Duration(days: 29))),
        isTrue,
      );
      // 2 days later it is past 30 days from the one real edit.
      t = kBase.add(const Duration(days: 2));
      expect(await timed.read('u1', 'a'), isNull);
    });

    test('an edit extends the life', () async {
      t = ago(const Duration(days: 29));
      await timed.upsert(draft('a'));
      t = kBase;
      await timed.upsert(draft('a', text: 'hello, edited'));
      t = kBase.add(const Duration(days: 29));
      expect(await ids('u1'), ['a']);
      // A poll, audience or label change counts as an edit too.
      t = kBase;
      await timed.upsert(
        draft(
          'a',
          text: 'hello, edited',
          poll: const DraftPoll(choices: ['x', 'y'], durationMinutes: 60),
        ),
      );
      final row = (await timed.read('u1', 'a'))!;
      expect(row.updatedAt.isAtSameMomentAs(kBase), isTrue);
    });

    test('purges only the given uid', () async {
      t = ago(const Duration(days: 40));
      await timed.upsert(draft('mine'));
      await timed.upsert(draft('theirs', uid: 'u2'));
      t = kBase;
      expect(await timed.purgeExpired('u1'), 1);
      expect(await db.select(db.composerDraftEntries).get(), hasLength(1));
      // u2's row is still stored (only hidden by the read filter).
      expect((await db.select(db.composerDraftEntries).get()).single.uid, 'u2');
    });

    test('there is no flag in the store: the purge always runs', () async {
      // `drafts` off hides the UI and autosave but keeps rows usable (W6-31);
      // the expiry is a retention rule and applies regardless.
      t = ago(const Duration(days: 45));
      await timed.upsert(draft('a'));
      t = kBase;
      expect(await timed.purgeExpired('u1'), 1);
    });
  });

  test('newId is 16 hex characters and varies', () {
    final a = DraftsRepository.newId();
    expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(DraftsRepository.newId(), isNot(a));
  });

  test('DraftPoll round-trips and rejects malformed json', () {
    const p = DraftPoll(choices: ['a', 'b'], durationMinutes: 5);
    expect(DraftPoll.fromJson(p.toJson()), p);
    expect(
      DraftPoll.fromJson({
        'c': [1],
        'd': 5,
      }),
      isNull,
    );
    expect(DraftPoll.fromJson('x'), isNull);
    expect(
      DraftPoll.fromJson({
        'c': ['a'],
      }),
      isNull,
    );
  });
}
