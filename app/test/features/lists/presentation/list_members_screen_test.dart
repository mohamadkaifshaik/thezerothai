import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/list_members_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockLists extends Mock implements ListsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

graph.UserListItem _member(int i) => graph.UserListItem(
  user: common.AuthorSnapshot(
    userId: 'm$i',
    handle: 'member$i',
    displayName: 'Member $i',
  ),
);

/// W5-12: `/lists/:id/members` at 360 / 600 / 1200 dp, light and dark, text
/// scale 1.0 / 1.3 / 2.0.
void main() {
  late _MockLists lists;
  late _MockGraph graphRepo;
  late _MockOnboarding onboarding;
  var ownerId = 'owner';

  setUp(() {
    ownerId = 'owner';
    lists = _MockLists();
    graphRepo = _MockGraph();
    onboarding = _MockOnboarding();
    when(() => lists.header('77')).thenAnswer(
      (_) => pb.ListInfo(
        listId: '77',
        name: 'Friends',
        owner: common.AuthorSnapshot(userId: ownerId, handle: 'o'),
      ),
    );
  });

  void stubMembers(List<graph.UserListItem> users, {String next = ''}) {
    when(
      () => lists.listMembers(
        listId: any(named: 'listId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
        maxEmptyPages: any(named: 'maxEmptyPages'),
      ),
    ).thenAnswer(
      (_) async => ListMembersPage(users: users, nextPageToken: next),
    );
  }

  Future<void> open(WidgetTester tester, {MatrixEnv? env, String? viewer}) {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: viewer ?? 'viewer', handle: 'me'),
        enabledFeatures: const {'lists', 'graph'},
      ),
    );
    return pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: const ListMembersScreen(listId: '77'),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(360, 800),
      textScale: env?.textScale ?? 1.0,
      useScaffold: false,
    );
  }

  forEachThemeAndWidth('a non-owner sees members with Follow and no Remove', (
    tester,
    env,
  ) async {
    stubMembers([_member(1), _member(2)]);
    await open(tester, env: env);

    expectNoOverflow(tester);
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Member 1'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);
    expect(find.text('Follow'), findsNWidgets(2));
  }, textScales: kMatrixTextScalesLarge);

  forEachThemeAndWidth('the owner also gets Remove, beside Follow', (
    tester,
    env,
  ) async {
    ownerId = 'viewer';
    stubMembers([_member(1), _member(2)]);
    await open(tester, env: env);

    expectNoOverflow(tester);
    expect(find.text('Remove'), findsNWidgets(2));
    expect(find.text('Follow'), findsNWidgets(2));
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('the repository is asked to follow empty pages', (tester) async {
    stubMembers([_member(1)]);
    await open(tester);

    verify(
      () => lists.listMembers(
        listId: '77',
        pageSize: any(named: 'pageSize'),
        pageToken: '',
        maxEmptyPages: 5,
      ),
    ).called(1);
  });

  testWidgets('empty list: the sentence', (tester) async {
    stubMembers([]);
    await open(tester);

    expect(find.text('No one is on this List yet'), findsOneWidget);
  });

  testWidgets('Remove confirms, then removes with one RPC', (tester) async {
    ownerId = 'viewer';
    stubMembers([_member(1), _member(2)]);
    when(
      () => lists.removeMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
        userId: any(named: 'userId'),
      ),
    ).thenAnswer((_) async => pb.ListInfo(listId: '77'));
    await open(tester);

    await tester.tap(find.text('Remove').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove @member1?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    verify(
      () => lists.removeMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
        userId: 'm1',
      ),
    ).called(1);
    expect(find.text('Member 1'), findsNothing);
    expect(find.text('Member 2'), findsOneWidget);
  });

  testWidgets('a failed Remove puts the row back with the reason', (
    tester,
  ) async {
    ownerId = 'viewer';
    stubMembers([_member(1)]);
    when(
      () => lists.removeMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
        userId: any(named: 'userId'),
      ),
    ).thenThrow(const NetworkException('off'));
    await open(tester);

    await tester.tap(find.text('Remove').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('Member 1'), findsOneWidget);
    expect(find.textContaining('No connection'), findsOneWidget);
  });

  testWidgets('Cancel on the confirm sends nothing', (tester) async {
    ownerId = 'viewer';
    stubMembers([_member(1)]);
    await open(tester);

    await tester.tap(find.text('Remove').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    verifyNever(
      () => lists.removeMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
        userId: any(named: 'userId'),
      ),
    );
    expect(find.text('Member 1'), findsOneWidget);
  });

  testWidgets('NOT_FOUND: the unavailable state', (tester) async {
    when(
      () => lists.listMembers(
        listId: any(named: 'listId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
        maxEmptyPages: any(named: 'maxEmptyPages'),
      ),
    ).thenThrow(const NotFoundException('gone'));
    await open(tester);

    expect(find.text('This List is unavailable'), findsOneWidget);
  });

  testWidgets('UNIMPLEMENTED (FEATURE_DISABLED): the not-available state', (
    tester,
  ) async {
    when(
      () => lists.listMembers(
        listId: any(named: 'listId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
        maxEmptyPages: any(named: 'maxEmptyPages'),
      ),
    ).thenThrow(const FeatureDisabledException('x', feature: 'lists'));
    await open(tester);

    expect(find.text("Lists aren't available right now"), findsOneWidget);
  });
}
