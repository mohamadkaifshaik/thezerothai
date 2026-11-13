import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/thread_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as cpb;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pbenum.dart'
    show CommunityRole;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _owner = CommunityRole.COMMUNITY_ROLE_OWNER;
const _moderator = CommunityRole.COMMUNITY_ROLE_MODERATOR;
const _member = CommunityRole.COMMUNITY_ROLE_MEMBER;
const _banned = CommunityRole.COMMUNITY_ROLE_BANNED;

/// "Remove from Community" on the replies of a
/// community conversation. The root's `community` label plus the server's
/// `viewer_role` (ListMyCommunities, session cache) decide; the server refuses
/// what a role may not do.
void main() {
  const cid = '77';
  late MockPostsRepository posts;
  late _MockGraph graph;
  late _MockCommunities communities;
  late _MockOnboarding onboarding;
  late StreamController<String> removed;

  setUp(() {
    removed = StreamController<String>.broadcast();
    addTearDown(removed.close);
    posts = MockPostsRepository();
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    graph = _MockGraph();
    when(() => graph.cached(any())).thenReturn(null);
    communities = _MockCommunities();
    onboarding = _MockOnboarding();
  });

  pb.PostView root({bool community = true}) {
    final v = postView(1, text: 'root post');
    if (community) {
      v.post.community = pb.CommunityRef(id: cid, name: 'Chess club');
    }
    return v;
  }

  pb.PostView reply(int n, {String author = 'u2'}) => pb.PostView(
    post: pb.Post(
      postId: postId(n),
      kind: PostKind.POST_KIND_REPLY,
      text: 'reply $n',
      replyToPostId: postId(1),
      replyToHandle: 'h1',
      conversationId: postId(1),
      author: common.AuthorSnapshot(userId: author, handle: 'h$author'),
    ),
  );

  void stubThread({bool community = true}) {
    when(
      () => posts.getThread(
        postId(1),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer(
      (_) async => pb.GetThreadResponse(
        focal: root(community: community),
        replies: [
          reply(2),
          reply(3, author: 'me'),
        ],
      ),
    );
  }

  void stubRole(CommunityRole role) {
    when(() => communities.myCommunities()).thenAnswer(
      (_) async => MyCommunities(
        communities: [
          cpb.Community(communityId: cid, name: 'Chess club', viewerRole: role),
        ],
        canCreate: true,
      ),
    );
  }

  void stubHide({Object? error}) {
    when(
      () => communities.hidePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: cid,
        postId: any(named: 'postId'),
      ),
    ).thenAnswer((_) async {
      if (error != null) throw error;
    });
    when(
      () => communities.restorePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: cid,
        postId: any(named: 'postId'),
      ),
    ).thenAnswer((_) async {});
  }

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'posts', 'replies', 'communities'},
    MatrixEnv? env,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    await pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<CommunitiesRepository>.value(value: communities),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: ThreadScreen(
            postId: postId(1),
            fallbackBuilder: (_) => const Text('fallback'),
          ),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(390, 900),
      textScale: env?.textScale ?? 1.0,
      useScaffold: false,
    );
  }

  Finder menuOf(int n) => find.descendant(
    of: find.byKey(ValueKey('reply-${postId(n)}')),
    matching: find.byTooltip('More options'),
  );

  Future<void> openMenuOf(WidgetTester tester, int n) async {
    await tester.tap(menuOf(n));
    await tester.pumpAndSettle();
  }

  Future<void> hideReply(WidgetTester tester, int n) async {
    await openMenuOf(tester, n);
    await tester.tap(find.text('Remove from community'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
  }

  group('menu entry by role', () {
    for (final role in [_owner, _moderator]) {
      testWidgets('${role.name}: on another member reply', (tester) async {
        stubThread();
        stubRole(role);
        await open(tester);
        await openMenuOf(tester, 2);
        expect(find.text('Remove from community'), findsOneWidget);
      });
    }

    testWidgets('a member: no entry on any reply', (tester) async {
      stubThread();
      stubRole(_member);
      await open(tester);
      // Another member's reply has no menu at all (reports are off); the
      // viewer's own reply keeps Delete only.
      expect(menuOf(2), findsNothing);
      await openMenuOf(tester, 3);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Remove from community'), findsNothing);
    });

    testWidgets('banned or not in the community: no entry', (tester) async {
      stubThread();
      stubRole(_banned);
      await open(tester);
      expect(menuOf(2), findsNothing);
    });

    testWidgets('a conversation with no community: no entry, no lookup', (
      tester,
    ) async {
      stubThread(community: false);
      stubRole(_owner);
      await open(tester);
      expect(menuOf(2), findsNothing);
      verifyNever(() => communities.myCommunities());
    });

    testWidgets('communities off: no entry, no lookup', (tester) async {
      stubThread();
      stubRole(_owner);
      await open(tester, features: const {'posts', 'replies'});
      expect(menuOf(2), findsNothing);
      verifyNever(() => communities.myCommunities());
    });

    testWidgets('a failed role lookup fails closed', (tester) async {
      stubThread();
      when(() => communities.myCommunities())
          .thenThrow(const NetworkException('offline'));
      await open(tester);
      expect(menuOf(2), findsNothing);
    });

    testWidgets('the focal post gets no entry', (tester) async {
      stubThread();
      stubRole(_owner);
      await open(tester);
      expect(find.text('root post'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('focal-${postId(1)}')),
          matching: find.byTooltip('More options'),
        ),
        findsNothing,
      );
    });
  });

  group('hide', () {
    testWidgets('confirm, the reply leaves the thread, one call', (
      tester,
    ) async {
      stubThread();
      stubRole(_moderator);
      stubHide();
      await open(tester);
      await openMenuOf(tester, 2);
      await tester.tap(find.text('Remove from community'));
      await tester.pumpAndSettle();
      expect(find.text('Remove this reply from Chess club?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('reply 2'), findsNothing);
      expect(find.text('reply 3'), findsOneWidget);
      expect(find.text('Removed from Chess club.'), findsOneWidget);
      verify(
        () => communities.hidePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: cid,
          postId: postId(2),
        ),
      ).called(1);
      verify(() => communities.myCommunities()).called(1);
    });

    testWidgets('cancel does nothing', (tester) async {
      stubThread();
      stubRole(_owner);
      stubHide();
      await open(tester);
      await openMenuOf(tester, 2);
      await tester.tap(find.text('Remove from community'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('reply 2'), findsOneWidget);
      verifyNever(
        () => communities.hidePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: any(named: 'communityId'),
          postId: any(named: 'postId'),
        ),
      );
    });

    testWidgets('Undo restores the reply by its id', (tester) async {
      stubThread();
      stubRole(_moderator);
      stubHide();
      await open(tester);
      await hideReply(tester, 2);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('reply 2'), findsOneWidget);
      verify(
        () => communities.restorePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: cid,
          postId: postId(2),
        ),
      ).called(1);
    });

    testWidgets('not_owner: friendly text, the reply stays', (tester) async {
      stubThread();
      stubRole(_moderator);
      stubHide(
        error: CommunityForbiddenException(CommunityForbiddenReason.notOwner),
      );
      await open(tester);
      await hideReply(tester, 2);
      expect(find.text('reply 2'), findsOneWidget);
      expect(
        find.text(
          'Only the Community owner can remove a reply by the owner or '
          'another moderator.',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('NOT_FOUND: the reply text, not the community one', (
      tester,
    ) async {
      stubThread();
      stubRole(_owner);
      stubHide(error: const NotFoundException('post not found'));
      await open(tester);
      await hideReply(tester, 2);
      expect(find.text('reply 2'), findsOneWidget);
      expect(find.text("This reply isn't available any more."), findsOneWidget);
      expect(find.text('This community is unavailable.'), findsNothing);
    });

    testWidgets('a network failure offers Retry and the reply stays', (
      tester,
    ) async {
      stubThread();
      stubRole(_owner);
      stubHide(error: const NetworkException('offline'));
      await open(tester);
      await hideReply(tester, 2);
      expect(find.text('reply 2'), findsOneWidget);
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  forEachThemeAndWidth('thread with the entry fits, the dialog too', (
    tester,
    env,
  ) async {
    stubThread();
    stubRole(_owner);
    stubHide();
    await open(tester, env: env);
    expectNoOverflow(tester);
    await openMenuOf(tester, 2);
    expect(find.text('Remove from community'), findsOneWidget);
    await tester.tap(find.text('Remove from community'));
    await tester.pumpAndSettle();
    expectNoOverflow(tester);
    expect(find.text('Remove this reply from Chess club?'), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);
}
