import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/domain/engagement_entry.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class _MockRepo extends Mock implements EngagementRepository {}

void main() {
  late _MockRepo repo;
  late EngagementCubit cubit;
  final target = postId(1);
  const row = EngagementEntry(
    liked: false,
    reposted: false,
    likeCount: 4,
    repostCount: 2,
    shareCount: 3,
  );

  setUpAll(() => registerFallbackValue(ShareChannel.SHARE_CHANNEL_COPY_LINK));

  setUp(() {
    repo = _MockRepo();
    cubit = EngagementCubit(repository: repo);
  });
  tearDown(() => cubit.close());

  When<Future<eng.PostEngagement?>> record() => when(
    () => repo.recordPostShare(
      postId: any(named: 'postId'),
      channel: any(named: 'channel'),
    ),
  );

  eng.PostEngagement answer(int shares) =>
      eng.PostEngagement(postId: target, shareCount: Int64(shares));

  group('EngagementEntry.shareCount', () {
    pb.PostView view({PostKind kind = PostKind.POST_KIND_POST}) => pb.PostView(
      post: pb.Post(
        postId: target,
        kind: kind,
        shareCount: Int64(7),
        author: common.AuthorSnapshot(userId: 'u1', handle: 'a'),
      ),
    );

    test('comes from the row', () {
      expect(EngagementEntry.fromView(view()).shareCount, 7);
    });

    test('is unknown on a REPOST row, like the other counts', () {
      expect(
        EngagementEntry.fromView(view(kind: PostKind.POST_KIND_REPOST))
            .shareCount,
        isNull,
      );
    });

    test('a refreshed row with another count wins over an older entry', () {
      final entry = EngagementEntry.fromView(view()).copyWith(shareCount: 8);
      // The entry's base is the row it was made from.
      final withBase = EngagementEntry(
        liked: false,
        reposted: false,
        shareCount: 8,
        base: EngagementEntry.fromView(view()),
      );
      expect(entry.shareCount, 8);
      expect(withBase.matches(view()), isTrue);
      final newer = view()..post.shareCount = Int64(9);
      expect(withBase.matches(newer), isFalse);
    });
  });

  group('recordShare', () {
    test('shows the server count on the target and reports it once', () async {
      record().thenAnswer((_) async => answer(4));

      await cubit.recordShare(
        target,
        ShareChannel.SHARE_CHANNEL_COPY_LINK,
        shown: row,
      );

      verify(
        () => repo.recordPostShare(
          postId: target,
          channel: ShareChannel.SHARE_CHANNEL_COPY_LINK,
        ),
      ).called(1);
      final entry = cubit.state.entries[target]!;
      expect(entry.shareCount, 4);
      // The other counts stay what the row said.
      expect(entry.likeCount, 4);
      expect(entry.repostCount, 2);
      expect(cubit.state.failure, isNull);
    });

    test(
      'nothing learned (flag off, repeat, failure): no entry, no error',
      () async {
        record().thenAnswer((_) async => null);
        await cubit.recordShare(
          target,
          ShareChannel.SHARE_CHANNEL_SHARE_SHEET,
          shown: row,
        );
        expect(cubit.state.entries, isEmpty);
        expect(cubit.state.failure, isNull);
      },
    );

    test('an answer after sign-out is dropped', () async {
      record().thenAnswer((_) async {
        cubit.reset();
        return answer(5);
      });
      await cubit.recordShare(
        target,
        ShareChannel.SHARE_CHANNEL_COPY_LINK,
        shown: row,
      );
      expect(cubit.state.entries, isEmpty);
    });

    test('a REPOST row learns its original\'s count from the answer', () async {
      record().thenAnswer((_) async => answer(12));
      const unknown = EngagementEntry(liked: false, reposted: false);
      await cubit.recordShare(
        target,
        ShareChannel.SHARE_CHANNEL_COPY_LINK,
        shown: unknown,
      );
      expect(cubit.state.entries[target]!.shareCount, 12);
    });
  });
}
