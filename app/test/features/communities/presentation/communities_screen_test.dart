import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/communities_screen.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

pb.Community _community(
  int i, {
  pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_NONE,
  int members = 3,
  String? name,
}) => pb.Community(
  communityId: 'c$i',
  name: name ?? 'Community $i',
  memberCount: Int64(members),
  viewerRole: role,
);

/// The Communities screen at 360 / 600 / 1200 dp, light and dark, text
/// scale 1.0 / 1.3 / 2.0.
void main() {
  late _MockCommunities repo;

  setUp(() {
    repo = _MockCommunities();
    when(() => repo.enabled).thenReturn(true);
  });

  void stubMine(List<pb.Community> mine, {bool canCreate = false}) {
    when(
      () => repo.listMyCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => MyCommunities(communities: mine, canCreate: canCreate),
    );
  }

  void stubDirectory(List<pb.Community> all) {
    when(
      () => repo.listCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => CommunitiesPage(communities: all));
  }

  /// R10 (F23): Explore is the second tab on phones.
  Future<void> showExplore(WidgetTester tester) async {
    // R10 review item 3: the tab bar may scroll; bring the tab into view.
    await tester.ensureVisible(find.text('Explore'));
    await tester.pump();
    await tester.tap(find.text('Explore'));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
    tester,
    RepositoryProvider<CommunitiesRepository>.value(
      value: repo,
      child: const CommunitiesScreen(),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  forEachThemeAndWidth(
    'both sections fit: role badge, long names wrap, Join pills',
    (tester, env) async {
      stubMine([
        _community(
          1,
          role: pb.CommunityRole.COMMUNITY_ROLE_OWNER,
          name: 'Mine',
          members: 1,
        ),
      ]);
      stubDirectory([
        _community(
          2,
          name: 'A very long Community name that could fill the whole row',
        ),
        _community(3, role: pb.CommunityRole.COMMUNITY_ROLE_BANNED),
      ]);
      final semantics = tester.ensureSemantics();
      await open(tester, env: env);

      expectNoOverflow(tester);
      expect(find.text('Communities'), findsOneWidget);
      expect(find.text('My communities'), findsOneWidget);
      expect(find.text('Explore'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('1 member'), findsOneWidget);
      // The inert "Joined" pill is part of the row's one spoken label.
      expect(
        find.bySemanticsLabel(RegExp(r'^Mine, 1 member, Owner\nJoined Mine$')),
        findsOneWidget,
      );
      await showExplore(tester);
      expectNoOverflow(tester);
      expect(find.text('Join'), findsOneWidget);
      expect(find.text('Banned'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Join A very long Community name that could fill the whole row',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    },
    textScales: kMatrixTextScalesLarge,
  );

  testWidgets('one ListMyCommunities and one ListCommunities per open', (
    tester,
  ) async {
    stubMine([_community(1)]);
    stubDirectory([_community(2)]);
    await open(tester);
    verify(
      () => repo.listMyCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
    verify(
      () => repo.listCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
  });

  testWidgets('can_create false: no Create entry', (tester) async {
    stubMine([]);
    stubDirectory([]);
    await open(tester);
    expect(find.byTooltip('Create a community'), findsNothing);
  });

  testWidgets('can_create true: the Create entry shows', (tester) async {
    stubMine([], canCreate: true);
    stubDirectory([]);
    await open(tester);
    expect(find.byTooltip('Create a community'), findsOneWidget);
  });

  testWidgets('empty sections show a sentence each', (tester) async {
    stubMine([]);
    stubDirectory([]);
    await open(tester);
    expect(
      find.textContaining("haven't joined any Communities"),
      findsOneWidget,
    );
    await showExplore(tester);
    expect(find.text('No Communities to explore yet.'), findsOneWidget);
  });

  testWidgets('loading shows skeletons before the answers', (tester) async {
    final mine = Completer<MyCommunities>();
    final dir = Completer<CommunitiesPage>();
    when(
      () => repo.listMyCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) => mine.future);
    when(
      () => repo.listCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) => dir.future);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: RepositoryProvider<CommunitiesRepository>.value(
          value: repo,
          child: const CommunitiesScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Loading your Communities'), findsOneWidget);
    // R10 review item 3: the tab bar may scroll; bring the tab into view.
    await tester.ensureVisible(find.text('Explore'));
    await tester.pump();
    await tester.tap(find.text('Explore'));
    await tester.pump();
    expect(
      find.bySemanticsLabel('Loading Communities to explore'),
      findsOneWidget,
    );
    mine.complete(const MyCommunities(communities: [], canCreate: false));
    dir.complete(const CommunitiesPage(communities: []));
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('directory error: Retry reloads, My Communities stays', (
    tester,
  ) async {
    stubMine([_community(1, name: 'Mine')]);
    var calls = 0;
    when(
      () => repo.listCommunities(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async {
      if (calls++ == 0) throw const NetworkException('offline');
      return CommunitiesPage(communities: [_community(2, name: 'Found')]);
    });
    await open(tester);

    expect(find.text('Mine'), findsOneWidget);
    await showExplore(tester);
    expect(find.text('Found'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Found'), findsOneWidget);
  });

  testWidgets('Join is optimistic and rolls back with a message', (
    tester,
  ) async {
    stubMine([]);
    stubDirectory([_community(2, name: 'Chess')]);
    final answer = Completer<pb.Community>();
    when(
      () => repo.joinCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: 'c2',
      ),
    ).thenAnswer((_) => answer.future);
    await open(tester);
    await showExplore(tester);

    await tester.tap(find.text('Join'));
    await tester.pump();
    expect(find.text('Joined'), findsOneWidget);
    expect(find.text('Join'), findsNothing);

    answer.completeError(const NetworkException('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Join'), findsOneWidget);
    expect(find.text('Joined'), findsNothing);
    expect(find.textContaining('No connection'), findsOneWidget);
  });

  testWidgets('Join succeeds: the row stays Joined', (tester) async {
    stubMine([]);
    stubDirectory([_community(2, name: 'Chess')]);
    when(
      () => repo.joinCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: 'c2',
      ),
    ).thenAnswer(
      (_) async => _community(2, role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER),
    );
    await open(tester);
    await showExplore(tester);

    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text('Joined'), findsOneWidget);
  });

  testWidgets('a Join refused as banned says so', (tester) async {
    stubMine([]);
    stubDirectory([_community(2, name: 'Chess')]);
    when(
      () => repo.joinCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: 'c2',
      ),
    ).thenThrow(CommunityForbiddenException(CommunityForbiddenReason.banned));
    await open(tester);
    await showExplore(tester);

    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text('Banned'), findsOneWidget);
  });
}
