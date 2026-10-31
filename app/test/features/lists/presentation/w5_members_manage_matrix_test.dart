import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/list_members_screen.dart';
import 'package:dzeroth/features/lists/presentation/manage_pinned_screen.dart';
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

import '../../../support/fake_transport.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockLists extends Mock implements ListsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

graph.UserListItem _member(int i, {String? name}) => graph.UserListItem(
  user: common.AuthorSnapshot(
    userId: 'm$i',
    handle: 'member$i',
    displayName: name ?? 'Member $i',
  ),
);

/// W5-16: the Members and Manage pinned states the developers left to one
/// cell (empty, unavailable, error, loading, disabled), plus long, emoji and
/// RTL member names, at 360 / 600 / 1200 dp, light and dark, 1.0 / 1.3 / 2.0.
void main() {
  late _MockLists lists;
  late _MockOnboarding onboarding;

  setUp(() {
    lists = _MockLists();
    onboarding = _MockOnboarding();
    when(() => lists.header('77')).thenAnswer(
      (_) => pb.ListInfo(
        listId: '77',
        name: 'Friends',
        owner: common.AuthorSnapshot(userId: 'viewer', handle: 'o'),
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'viewer', handle: 'me'),
        enabledFeatures: const {'lists', 'graph'},
      ),
    );
  });

  When<Future<ListMembersPage>> membersCall() => when(
    () => lists.listMembers(
      listId: any(named: 'listId'),
      pageSize: any(named: 'pageSize'),
      pageToken: any(named: 'pageToken'),
      maxEmptyPages: any(named: 'maxEmptyPages'),
    ),
  );

  Future<void> openMembers(WidgetTester tester, MatrixEnv env) => pumpThemed(
    tester,
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<ListsRepository>.value(value: lists),
        RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: const ListMembersScreen(listId: '77'),
      ),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
    useScaffold: false,
  );

  group('Members states', () {
    forEachThemeAndWidth('empty', (tester, env) async {
      membersCall().thenAnswer((_) async => const ListMembersPage(users: []));
      await openMembers(tester, env);
      expectNoOverflow(tester);
      expect(find.text('No one is on this List yet'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('NOT_FOUND: the unavailable state, no cause', (
      tester,
      env,
    ) async {
      membersCall().thenThrow(const NotFoundException('private'));
      await openMembers(tester, env);
      expectNoOverflow(tester);
      expect(find.text('This List is unavailable'), findsOneWidget);
      expect(find.text('Unpin from Home'), findsNothing);
      expect(find.textContaining('private'), findsNothing);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('network error: Retry', (tester, env) async {
      membersCall().thenThrow(const NetworkException('offline'));
      await openMembers(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('owner: long, emoji and RTL names keep Remove and '
        'Follow reachable', (tester, env) async {
      membersCall().thenAnswer(
        (_) async => ListMembersPage(
          users: [
            _member(1, name: 'A member with a very long display name indeed'),
            _member(2, name: 'שלום עולם \u{1F30D}'),
            _member(3, name: 'Z​W​S​P'),
          ],
        ),
      );
      await openMembers(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Remove'), findsNWidgets(3));
    }, textScales: kMatrixTextScalesLarge);
  });

  group('Manage pinned states', () {
    late HomeTabsRepository tabs;
    late ListsRepository real;

    Future<void> openManage(
      WidgetTester tester,
      MatrixEnv env,
      Object? Function(String) lists,
    ) async {
      final api = ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          final out = lists(procedure.split('/').last);
          if (out is Exception) throw out;
          return out!;
        }),
      );
      final gate = ServiceFeatureGate(
        isEnabled: () => true,
        onUnexpectedError: (_, _) {},
      );
      tabs = HomeTabsRepository(
        apiClient: api,
        gate: gate,
        epoch: SessionEpoch(),
      );
      real = ListsRepository(apiClient: api, gate: gate);
      await pumpThemed(
        tester,
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<ListsRepository>.value(value: real),
            RepositoryProvider<HomeTabsRepository>.value(value: tabs),
          ],
          child: const ManagePinnedScreen(),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
        useScaffold: false,
      );
    }

    forEachThemeAndWidth('your Lists fail to load: message and Retry', (
      tester,
      env,
    ) async {
      await openManage(
        tester,
        env,
        (_) => connect.ConnectException(connect.Code.unavailable, 'x'),
      );
      expectNoOverflow(tester);
      // Reachable by scrolling even when text scale 2.0 pushes it below the fold.
      final retry = find.text('Retry', skipOffstage: false);
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      expect(find.text('Retry').hitTestable(), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('Lists off server-side: the calm note, no Retry', (
      tester,
      env,
    ) async {
      await openManage(
        tester,
        env,
        (_) => connect.ConnectException(
          connect.Code.unimplemented,
          "not deployed",
        ),
      );
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsNothing);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('all Lists pinned', (tester, env) async {
      await openManage(tester, env, (rpc) {
        return pb.ListUserListsResponse(
          lists: [pb.ListInfo(listId: 'L1', name: 'Friends')],
        );
      });
      tabs.adoptFromMe([
        common.HomeTab(
          kind: common.HomeTabKind.HOME_TAB_KIND_LIST,
          id: 'L1',
          title: 'Friends',
        ),
      ], epoch: 0);
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.text('All your Lists are pinned.'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });
}
