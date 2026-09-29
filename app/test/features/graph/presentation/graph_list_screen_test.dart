import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/graph_list_screen.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

void main() {
  late MockIdentityRepository identityRepository;
  late MockGraphRepository graphRepository;

  setUp(() {
    identityRepository = MockIdentityRepository();
    graphRepository = MockGraphRepository();
  });

  Widget wrap(Widget child) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<IdentityRepository>.value(value: identityRepository),
        RepositoryProvider<GraphRepository>.value(value: graphRepository),
      ],
      child: MaterialApp(home: child),
    );
  }

  testWidgets('uses the uid passed via extra, without calling GetProfile', (
    tester,
  ) async {
    when(
      () => graphRepository.listFollowers(
        userId: 'target-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));
    when(
      () => graphRepository.listFollowing(
        userId: 'target-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));

    await tester.pumpWidget(
      wrap(const GraphListScreen(handle: 'kaif', userId: 'target-uid')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Followers'), findsOneWidget);
    expect(find.text('Following'), findsOneWidget);
    verifyNever(
      () => identityRepository.getProfile(handle: any(named: 'handle')),
    );
  });

  testWidgets('resolves the uid via GetProfile when extra is not provided', (
    tester,
  ) async {
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(userId: 'resolved-uid', handle: 'kaif'),
    );
    when(
      () => graphRepository.listFollowers(
        userId: 'resolved-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => GraphPage(
        items: [
          graph.UserListItem(
            user: common.AuthorSnapshot(
              userId: 'f1',
              handle: 'follower1',
              displayName: 'Follower One',
            ),
            relationship: graph.Relationship(
              followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
            ),
          ),
        ],
        nextPageToken: '',
      ),
    );
    when(
      () => graphRepository.listFollowing(
        userId: 'resolved-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));

    await tester.pumpWidget(wrap(const GraphListScreen(handle: 'kaif')));
    await tester.pumpAndSettle();

    expect(find.text('@follower1'), findsOneWidget);
    // The row's FollowButton must come from the list item, not a separate
    // GetRelationships round trip (ADR-0008 D4). Scoped to the OutlinedButton
    // because the "Following" tab label shares the text.
    expect(find.widgetWithText(OutlinedButton, 'Following'), findsOneWidget);
    verifyNever(() => graphRepository.relationshipFor(any()));
  });

  testWidgets('shows a retry view when resolving the uid fails', (
    tester,
  ) async {
    when(() => identityRepository.getProfile(handle: 'ghost'))
        .thenThrow(const NotFoundException("doesn't exist"));

    await tester.pumpWidget(wrap(const GraphListScreen(handle: 'ghost')));
    await tester.pumpAndSettle();

    expect(find.text("This account doesn't exist."), findsOneWidget);
  });

  graph.UserListItem item(int i) => graph.UserListItem(
    user: common.AuthorSnapshot(
      userId: 'u$i',
      handle: 'user$i',
      displayName: 'User $i',
    ),
    relationship: graph.Relationship(
      followState: graph.FollowState.FOLLOW_STATE_NONE,
    ),
  );

  void stubFollowing(GraphPage page) {
    when(
      () => graphRepository.listFollowing(
        userId: 'target-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => page);
  }

  testWidgets('45 followers load as 3 pages with no duplicates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stubFollowing(const GraphPage(items: [], nextPageToken: ''));
    final tokens = <String>[];
    when(
      () => graphRepository.listFollowers(
        userId: 'target-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((invocation) async {
      final token = invocation.namedArguments[#pageToken] as String;
      tokens.add(token);
      return switch (token) {
        '' => GraphPage(
          items: [for (var i = 0; i < 20; i++) item(i)],
          nextPageToken: 'p2',
        ),
        'p2' => GraphPage(
          items: [for (var i = 20; i < 40; i++) item(i)],
          nextPageToken: 'p3',
        ),
        _ => GraphPage(
          items: [for (var i = 40; i < 45; i++) item(i)],
          nextPageToken: '',
        ),
      };
    });

    await tester.pumpWidget(
      wrap(const GraphListScreen(handle: 'kaif', userId: 'target-uid')),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
      await tester.pumpAndSettle();
    }

    expect(tokens, ['', 'p2', 'p3']);
    expect(find.text('@user44', skipOffstage: false), findsOneWidget);
    expect(find.text('@user0', skipOffstage: false), findsNothing);
  });

  testWidgets('empty followers shows an empty state', (tester) async {
    stubFollowing(const GraphPage(items: [], nextPageToken: ''));
    when(
      () => graphRepository.listFollowers(
        userId: 'target-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));

    await tester.pumpWidget(
      wrap(const GraphListScreen(handle: 'kaif', userId: 'target-uid')),
    );
    await tester.pumpAndSettle();

    expect(find.text('No followers yet.'), findsOneWidget);
  });

  testWidgets('rate-limited shows a friendly view with no auto-retry', (
    tester,
  ) async {
    stubFollowing(const GraphPage(items: [], nextPageToken: ''));
    when(
      () => graphRepository.listFollowers(
        userId: 'target-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const RateLimitedException('slow down'));

    await tester.pumpWidget(
      wrap(const GraphListScreen(handle: 'kaif', userId: 'target-uid')),
    );
    await tester.pumpAndSettle(const Duration(seconds: 30));

    verify(
      () => graphRepository.listFollowers(
        userId: 'target-uid',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
    expect(find.textContaining('a bit too fast'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('the Following tab loads lazily and honors initialTab', (
    tester,
  ) async {
    stubFollowing(GraphPage(items: [item(1)], nextPageToken: ''));

    await tester.pumpWidget(
      wrap(
        const GraphListScreen(
          handle: 'kaif',
          userId: 'target-uid',
          initialTab: GraphListTab.following,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('@user1'), findsOneWidget);
    verifyNever(
      () => graphRepository.listFollowers(
        userId: any(named: 'userId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    );
  });
}
