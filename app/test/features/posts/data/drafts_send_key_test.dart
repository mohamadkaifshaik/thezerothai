import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:flutter_test/flutter_test.dart';

// Relative to the real clock, whole seconds (the columns store seconds).
final kBase = DateTime.fromMillisecondsSinceEpoch(
  DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
  isUtc: true,
);

/// W6-39: the send key on the draft row (ADR-0029 Amendment 1 A4).
Matcher sameMoment(DateTime t) =>
    predicate<DateTime>((d) => d.isAtSameMomentAs(t), "is $t");

void main() {
  late AppDatabase db;
  late DraftsRepository repo;
  late DateTime clock;
  var minted = 0;

  String newKey() => 'key-${++minted}';

  ComposerDraft draft(String id, {String text = 'hello'}) => ComposerDraft(
    id: id,
    uid: 'u1',
    text: text,
    createdAt: kBase,
    updatedAt: kBase,
  );

  Future<ComposerDraftRow> row(String id) => (db.select(
    db.composerDraftEntries,
  )..where((t) => t.draftId.equals(id))).getSingle();

  Future<SendClaim> claim(
    String id, {
    SendKind kind = SendKind.post,
    DateTime? publishAt,
    bool forceNew = false,
  }) => repo.claimSend(
    draft: draft(id),
    kind: kind,
    newKey: newKey,
    publishAt: publishAt,
    forceNew: forceNew,
  );

  setUp(() {
    clock = kBase;
    minted = 0;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = DraftsRepository(
      db,
      autosaveDelay: const Duration(milliseconds: 10),
      now: () => clock,
    );
  });
  tearDown(() async {
    repo.cancelPending();
    await db.close();
  });

  test(
    'the first claim mints a key and stores it; the next reuses it',
    () async {
      await repo.upsert(draft('a'));

      final first = await claim('a');
      final second = await claim('a');

      expect(first.key, 'key-1');
      expect(first.reused, isFalse);
      expect(second.key, 'key-1');
      expect(second.reused, isTrue);
      final r = await row('a');
      expect(r.sendKey, 'key-1');
      expect(r.sendKind, 'post');
      expect(r.sendStartedAt, sameMoment(kBase));
    },
  );

  test('claiming does not bump updatedAt (W6-45)', () async {
    await repo.upsert(draft('a'));
    final before = (await row('a')).updatedAt;
    clock = clock.add(const Duration(hours: 5));

    await claim('a');
    await claim('a');

    expect((await row('a')).updatedAt, before);
  });

  test('a reuse does not refresh the start of the window', () async {
    await repo.upsert(draft('a'));
    await claim('a');
    clock = clock.add(const Duration(hours: 10));
    await claim('a');

    expect((await row('a')).sendStartedAt, sameMoment(kBase));
  });

  test('an autosave of an edit keeps the pending key (G3)', () async {
    await repo.upsert(draft('a'));
    await claim('a');

    repo.autosave(draft('a', text: 'edited'));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final r = await row('a');
    expect(r.draftText, 'edited');
    expect(r.sendKey, 'key-1');
    expect(r.sendKind, 'post');
  });

  test('a draft nobody stored yet is stored by the claim', () async {
    final c = await claim('fresh');

    expect(c.key, 'key-1');
    final r = await row('fresh');
    expect(r.draftText, 'hello');
    expect(r.sendKey, 'key-1');
  });

  group('G5: a row that is gone', () {
    test('is refused when this instance had seen it', () async {
      await repo.upsert(draft('a'));
      await repo.delete('u1', ['a']);

      final c = await claim('a');

      expect(c.isBlocked, isTrue);
      expect(c.block, SendBlock.rowGone);
      expect(c.key, isNull);
      expect(await repo.read('u1', 'a'), isNull, reason: 'no row is created');
    });

    test('is refused for a row another instance sent and removed', () async {
      await repo.upsert(draft('a'));
      final stale = DraftsRepository(db, now: () => clock);
      await stale.read('u1', 'a');
      await repo.delete('u1', ['a']);

      final c = await stale.claimSend(
        draft: draft('a'),
        kind: SendKind.post,
        newKey: newKey,
      );

      expect(c.block, SendBlock.rowGone);
    });

    test('is not refused once the user emptied the draft themselves', () async {
      await repo.upsert(draft('a'));
      await repo.upsert(draft('a', text: ''));

      final c = await claim('a');

      expect(c.key, isNotNull, reason: 'their own delete is not "sent"');
    });
  });

  group('G6: the other kind', () {
    test('a post key blocks a schedule, and the reverse', () async {
      await repo.upsert(draft('a'));
      await claim('a');
      final s = await claim('a', kind: SendKind.schedule, publishAt: kBase);
      expect(s.block, SendBlock.otherKind);
      expect(s.pendingKind, SendKind.post);

      await repo.upsert(draft('b'));
      await claim('b', kind: SendKind.schedule, publishAt: kBase);
      final p = await claim('b');
      expect(p.block, SendBlock.otherKind);
      expect(p.pendingKind, SendKind.schedule);
    });

    test('forceNew mints a new key of the new kind', () async {
      await repo.upsert(draft('a'));
      await claim('a');

      final c = await claim('a', kind: SendKind.schedule, forceNew: true);

      expect(c.key, 'key-2');
      expect((await row('a')).sendKind, 'schedule');
    });
  });

  group('the key window', () {
    test(
      'a post key is reused for 23 h, then refused as unconfirmed',
      () async {
        await repo.upsert(draft('a'));
        await claim('a');

        clock = kBase.add(const Duration(hours: 22, minutes: 59));
        expect((await claim('a')).reused, isTrue);

        clock = kBase.add(const Duration(hours: 23));
        final late = await claim('a');
        expect(late.block, SendBlock.unconfirmed);
        expect((await row('a')).sendKey, 'key-1', reason: 'kept until chosen');
      },
    );

    test('forceNew after the window mints a fresh window', () async {
      await repo.upsert(draft('a'));
      await claim('a');
      clock = kBase.add(const Duration(hours: 24));

      final c = await claim('a', forceNew: true);

      expect(c.key, 'key-2');
      expect((await row('a')).sendStartedAt, sameMoment(clock));
      expect((await claim('a')).reused, isTrue);
    });

    test('a schedule key lives until 7 days after the publish time', () async {
      await repo.upsert(draft('a'));
      final publishAt = kBase.add(const Duration(days: 2));
      await claim('a', kind: SendKind.schedule, publishAt: publishAt);

      clock = kBase.add(const Duration(days: 8));
      expect((await claim('a', kind: SendKind.schedule)).reused, isTrue);

      clock = publishAt.add(const Duration(days: 7, minutes: 1));
      expect(
        (await claim('a', kind: SendKind.schedule)).block,
        SendBlock.unconfirmed,
      );
    });
  });

  group('clearSend', () {
    test('clears the four columns of the matching key only', () async {
      await repo.upsert(draft('a'));
      await claim('a');
      final updated = (await row('a')).updatedAt;

      await repo.clearSend('u1', 'a', 'someone-elses');
      expect((await row('a')).sendKey, 'key-1');

      await repo.clearSend('u1', 'a', 'key-1');
      final r = await row('a');
      expect(r.sendKey, isNull);
      expect(r.sendKind, isNull);
      expect(r.sendPublishAt, isNull);
      expect(r.sendStartedAt, isNull);
      expect(r.updatedAt, updated);
      expect((await claim('a')).reused, isFalse, reason: 'a fresh key now');
    });

    test('is safe for a row that is gone', () async {
      await repo.clearSend('u1', 'nope', 'key-1');
    });
  });

  test('another account never touches the key', () async {
    await repo.upsert(draft('a'));
    await claim('a');

    await repo.clearSend('u2', 'a', 'key-1');

    expect((await row('a')).sendKey, 'key-1');
  });
}
