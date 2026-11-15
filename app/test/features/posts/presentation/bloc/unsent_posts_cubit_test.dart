import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/unsent_posts_store.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/features/posts/presentation/bloc/unsent_posts_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_drafts_repository.dart';

class _BrokenDrafts extends FakeDraftsRepository {
  @override
  Stream<int> watchCount(String uid) =>
      Stream<int>.error(StateError('secret unsent text'));

  @override
  Future<void> deleteAll(String uid) async =>
      throw StateError('secret unsent text');
}

ComposerDraft _draft(String id, String uid) => ComposerDraft(
  id: id,
  uid: uid,
  text: 'unsent $id',
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
);

void main() {
  test('counts this uid only and follows deletes', () async {
    final repo = FakeDraftsRepository(
      drafts: [_draft('a', 'u1'), _draft('b', 'u1'), _draft('c', 'u2')],
    );
    final cubit = UnsentPostsCubit(repository: repo, uid: 'u1');
    addTearDown(cubit.close);
    await pumpEventQueue();
    expect(cubit.state, 2);

    expect(await cubit.deleteAll(), isTrue);
    await pumpEventQueue();
    expect(cubit.state, 0);
    expect(repo.wiped, ['u1']);
    expect(repo.rows.map((d) => d.id), ['c']);
  });

  test(
    'a failing count or delete is 0/false, reported without details',
    () async {
      final reported = <Object>[];
      final cubit = UnsentPostsCubit(
        repository: _BrokenDrafts(),
        uid: 'u1',
        onUnexpectedError: (e, _) => reported.add(e),
      );
      addTearDown(cubit.close);
      await pumpEventQueue();
      expect(cubit.state, 0);
      expect(await cubit.deleteAll(), isFalse);
      expect(reported, hasLength(2));
      for (final e in reported) {
        expect(e.toString(), isNot(contains('secret')));
      }
    },
  );

  test('after close the count no longer changes', () async {
    final repo = FakeDraftsRepository();
    final cubit = UnsentPostsCubit(repository: repo, uid: 'u1');
    await pumpEventQueue();
    await cubit.close();
    await repo.upsert(_draft('a', 'u1'));
    await pumpEventQueue();
    expect(cubit.state, 0);
  });

  test(
    'posts kept for a restart count and are deleted with the drafts',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final store = UnsentPostsStore(db, keepsPhotoBytes: true);
      Future<void> keep(String uid, String id) => store.save(
        UnsentPostRecord(
          uid: uid,
          postId: id,
          text: 't',
          author: common.AuthorSnapshot(userId: uid),
          createdAt: DateTime.now(),
        ),
        epoch: db.sessionEpoch.value,
      );
      await keep('u1', 'a');
      await keep('u1', 'b');
      await keep('u2', 'c');
      var discarded = 0;
      final cubit = UnsentPostsCubit(
        repository: FakeDraftsRepository(),
        uid: 'u1',
        photos: store,
        onDeleted: () => discarded++,
      );
      addTearDown(cubit.close);
      await pumpEventQueue();
      expect(cubit.state, 2);

      expect(await cubit.deleteAll(), isTrue);
      await pumpEventQueue();
      expect(cubit.state, 0);
      expect(discarded, 1);
      expect(await store.load('u1'), isEmpty);
      expect(await store.load('u2'), hasLength(1));
    },
  );
}
