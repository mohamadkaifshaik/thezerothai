import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/bloc/community_moderation_cubit.dart';
import 'package:dzeroth/features/communities/presentation/bloc/community_moderation_log_cubit.dart';
import 'package:dzeroth/features/communities/presentation/community_moderation_log_screen.dart';
import 'package:dzeroth/features/communities/presentation/widgets/moderation_log_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

final _now = DateTime.now();

pb.ModerationLogEntry _entry(
  int seq,
  ModerationLogAction action, {
  String actor = 'mo',
  String? target,
  String postId = '',
  bool actorDeleted = false,
  bool targetDeleted = false,
}) {
  final e = pb.ModerationLogEntry(
    seq: Int64(seq),
    action: action,
    postId: postId,
    actorDeleted: actorDeleted,
    targetDeleted: targetDeleted,
  );
  e.at = _ts(_now.subtract(Duration(hours: seq)));
  if (!actorDeleted) {
    e.actor = common.AuthorSnapshot(userId: 'a', handle: actor);
  }
  if (target != null) {
    e.target = common.AuthorSnapshot(userId: 't', handle: target);
  }
  return e;
}

ts.Timestamp _ts(DateTime t) => ts.Timestamp.fromDateTime(t.toUtc());

void main() {
  late _MockCommunities communities;

  setUp(() {
    communities = _MockCommunities();
  });

  void stubLog(
    List<pb.ModerationLogEntry> entries, {
    String next = '',
    Object? error,
  }) {
    when(
      () => communities.listModerationLog(
        communityId: any(named: 'communityId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async {
      if (error != null) throw error;
      return ModerationLogPage(entries: entries, nextPageToken: next);
    });
  }

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
    tester,
    RepositoryProvider<CommunitiesRepository>.value(
      value: communities,
      child: CommunityModerationLogScreen(communityId: '77', now: _now),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  group('sentences', () {
    test('every known action, deleted accounts, unknown values', () {
      String s(pb.ModerationLogEntry e) => moderationLogSentence(e);
      expect(
        s(_entry(1, ModerationLogAction.MODERATION_LOG_ACTION_HIDE)),
        '@mo removed a post',
      );
      expect(
        s(
          _entry(
            2,
            ModerationLogAction.MODERATION_LOG_ACTION_BAN,
            target: 'raider',
          ),
        ),
        '@mo banned @raider',
      );
      expect(
        s(
          _entry(
            3,
            ModerationLogAction.MODERATION_LOG_ACTION_BAN,
            targetDeleted: true,
          ),
        ),
        '@mo banned Deleted account',
      );
      expect(
        s(
          _entry(
            4,
            ModerationLogAction.MODERATION_LOG_ACTION_HIDE,
            actorDeleted: true,
          ),
        ),
        'Deleted account removed a post',
      );
      expect(
        s(_entry(5, ModerationLogAction.MODERATION_LOG_ACTION_UNSPECIFIED)),
        'Moderation action',
      );
      expect(
        s(_entry(6, ModerationLogAction.MODERATION_LOG_ACTION_OWNER_HANDOVER)),
        'The Community was archived',
      );
    });
  });

  forEachThemeAndWidth('entries with times and Restore fit', (
    tester,
    env,
  ) async {
    stubLog([
      _entry(
        3,
        ModerationLogAction.MODERATION_LOG_ACTION_HIDE,
        postId: postId(1),
      ),
      _entry(
        2,
        ModerationLogAction.MODERATION_LOG_ACTION_BAN,
        target: 'raider',
      ),
      _entry(1, ModerationLogAction.MODERATION_LOG_ACTION_UNSPECIFIED),
    ]);
    await open(tester, env: env);
    expectNoOverflow(tester);
    expect(find.text('Moderation log'), findsOneWidget);
    expect(find.text('@mo removed a post'), findsOneWidget);
    expect(find.text('@mo banned @raider'), findsOneWidget);
    expect(find.text('3h'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
    // R10: the rows are taller (the action tile), so at 360 x2.0 the third
    // entry is below the fold of the lazy list.
    await tester.scrollUntilVisible(find.text('Moderation action'), 100);
    expectNoOverflow(tester);
    expect(find.text('Moderation action'), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('empty log: a sentence', (tester) async {
    stubLog([]);
    await open(tester);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('FORBIDDEN not_moderator: a sentence, no retry', (tester) async {
    stubLog(
      [],
      error: CommunityForbiddenException(CommunityForbiddenReason.notModerator),
    );
    await open(tester);
    expect(find.text('Only moderators can do that.'), findsOneWidget);
  });

  testWidgets('NOT_FOUND: the unavailable view', (tester) async {
    stubLog([], error: const NotFoundException('gone'));
    await open(tester);
    expect(find.text('This Community is unavailable'), findsOneWidget);
  });

  testWidgets('a network failure offers Retry', (tester) async {
    stubLog([], error: const NetworkException('offline'));
    await open(tester);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('Restore calls the server once and shows Restored', (
    tester,
  ) async {
    stubLog([
      _entry(
        3,
        ModerationLogAction.MODERATION_LOG_ACTION_HIDE,
        postId: postId(1),
      ),
    ]);
    when(
      () => communities.restorePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        postId: postId(1),
      ),
    ).thenAnswer((_) async {});
    await open(tester);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('Restored'), findsOneWidget);
    expect(find.text('Restore'), findsNothing);
    verify(
      () => communities.restorePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        postId: postId(1),
      ),
    ).called(1);
  });

  testWidgets('a HIDE already undone by a later RESTORE has no button', (
    tester,
  ) async {
    stubLog([
      _entry(
        4,
        ModerationLogAction.MODERATION_LOG_ACTION_RESTORE,
        postId: postId(1),
      ),
      _entry(
        3,
        ModerationLogAction.MODERATION_LOG_ACTION_HIDE,
        postId: postId(1),
      ),
    ]);
    await open(tester);
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets('a failed Restore keeps the button and says why', (tester) async {
    stubLog([
      _entry(
        3,
        ModerationLogAction.MODERATION_LOG_ACTION_HIDE,
        postId: postId(1),
      ),
    ]);
    when(
      () => communities.restorePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: any(named: 'communityId'),
        postId: any(named: 'postId'),
      ),
    ).thenThrow(
      CommunityForbiddenException(CommunityForbiddenReason.notModerator),
    );
    await open(tester);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('Only moderators can do that.'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
  });

  test('the platform acted: no actor and not deleted reads as the platform', () {
    final hide = pb.ModerationLogEntry(
      seq: Int64(1),
      action: ModerationLogAction.MODERATION_LOG_ACTION_RESTORE,
    );
    expect(moderationLogSentence(hide), 'The platform restored a post');
    // An actor row with an empty handle is still a person.
    final person = _entry(
      2,
      ModerationLogAction.MODERATION_LOG_ACTION_HIDE,
      actor: '',
    );
    expect(moderationLogSentence(person), 'A moderator removed a post');
  });

  testWidgets(
    "a reply's HIDE row restores by the reply's id; the platform's bulk "
    'RESTORE row has no button',
    (tester) async {
      final replyId = postId(9);
      stubLog([
        pb.ModerationLogEntry(
          seq: Int64(4),
          action: ModerationLogAction.MODERATION_LOG_ACTION_RESTORE,
        )..at = _ts(_now.subtract(const Duration(hours: 1))),
        _entry(
          3,
          ModerationLogAction.MODERATION_LOG_ACTION_HIDE,
          postId: replyId,
        ),
      ]);
      when(
        () => communities.restorePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: '77',
          postId: replyId,
        ),
      ).thenAnswer((_) async {});
      await open(tester);
      expect(find.text('The platform restored a post'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Restored'), findsOneWidget);
      verify(
        () => communities.restorePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: '77',
          postId: replyId,
        ),
      ).called(1);
    },
  );

  group('CommunityModerationLogCubit', () {
    CommunityModerationLogCubit make() => CommunityModerationLogCubit(
      communityId: '77',
      communities: communities,
      moderation: CommunityModerationCubit(
        communityId: '77',
        communities: communities,
      ),
      pageSize: 2,
    );

    blocTest<CommunityModerationLogCubit, ModerationLogState>(
      'load then loadMore appends with the cursor',
      build: make,
      setUp: () {
        when(
          () => communities.listModerationLog(
            communityId: '77',
            pageSize: 2,
            pageToken: '',
          ),
        ).thenAnswer(
          (_) async => ModerationLogPage(
            entries: [
              _entry(3, ModerationLogAction.MODERATION_LOG_ACTION_HIDE),
              _entry(2, ModerationLogAction.MODERATION_LOG_ACTION_HIDE),
            ],
            nextPageToken: 'c1',
          ),
        );
        when(
          () => communities.listModerationLog(
            communityId: '77',
            pageSize: 2,
            pageToken: 'c1',
          ),
        ).thenAnswer(
          (_) async => ModerationLogPage(
            entries: [_entry(1, ModerationLogAction.MODERATION_LOG_ACTION_BAN)],
          ),
        );
      },
      act: (c) async {
        await c.load();
        await c.loadMore();
        await c.loadMore();
      },
      verify: (c) {
        expect(c.state.entries.map((e) => e.seq.toInt()), [3, 2, 1]);
        expect(c.state.hasMore, isFalse);
        verify(
          () => communities.listModerationLog(
            communityId: '77',
            pageSize: 2,
            pageToken: any(named: 'pageToken'),
          ),
        ).called(2);
      },
    );

    blocTest<CommunityModerationLogCubit, ModerationLogState>(
      'a failed later page keeps the entries and flags the footer',
      build: make,
      setUp: () {
        when(
          () => communities.listModerationLog(
            communityId: '77',
            pageSize: 2,
            pageToken: '',
          ),
        ).thenAnswer(
          (_) async => ModerationLogPage(
            entries: [
              _entry(3, ModerationLogAction.MODERATION_LOG_ACTION_HIDE),
            ],
            nextPageToken: 'c1',
          ),
        );
        when(
          () => communities.listModerationLog(
            communityId: '77',
            pageSize: 2,
            pageToken: 'c1',
          ),
        ).thenThrow(const NetworkException('offline'));
      },
      act: (c) async {
        await c.load();
        await c.loadMore();
      },
      verify: (c) {
        expect(c.state.entries, hasLength(1));
        expect(c.state.loadMoreFailed, isTrue);
        expect(c.state.status, ModerationLogStatus.ready);
      },
    );
  });
}
