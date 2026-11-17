import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/bloc/home_tabs_cubit.dart';
import 'package:dzeroth/features/lists/presentation/bloc/home_tabs_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_transport.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockLists extends Mock implements ListsRepository {}

/// A pinned community tab has no server title: the cubit asks GetCommunity
/// once and the header feed names the tab.
void main() {
  test(
    'an unlabelled community tab costs one GetCommunity, then its name',
    () async {
      final epoch = SessionEpoch();
      final tabs = HomeTabsRepository(
        apiClient: ApiClient.withTransport(
          FakeTransport((procedure, input) async => throw UnimplementedError()),
        ),
        gate: ServiceFeatureGate(
          isEnabled: () => true,
          onUnexpectedError: (_, _) {},
        ),
        communitiesGate: ServiceFeatureGate(
          isEnabled: () => true,
          onUnexpectedError: (_, _) {},
        ),
        epoch: epoch,
      );
      final communities = _MockCommunities();
      when(() => communities.getCommunity('7')).thenAnswer((_) async {
        final community = pb.Community(communityId: '7', name: 'Chess club');
        // What the real repository does with every header it receives.
        tabs.noteCommunityInfo(community);
        return pb.GetCommunityResponse(community: community);
      });
      tabs.adoptFromMe([
        common.HomeTab(
          kind: common.HomeTabKind.HOME_TAB_KIND_COMMUNITY,
          id: '7',
        ),
      ], epoch: epoch.value);

      final cubit = HomeTabsCubit(
        tabs: tabs,
        lists: _MockLists(),
        communities: communities,
      );
      addTearDown(cubit.close);

      await pumpEventQueue();
      final key = cubit.state.tabs.single.key;
      expect(cubit.state.labels[key], 'Chess club');
      verify(() => communities.getCommunity('7')).called(1);

      // Another sync does not ask again.
      tabs.adoptFromMe([
        common.HomeTab(
          kind: common.HomeTabKind.HOME_TAB_KIND_COMMUNITY,
          id: '7',
        ),
      ], epoch: epoch.value);
      verifyNever(() => communities.getCommunity('8'));
    },
  );

  test('the neutral label is "Community" until the header arrives', () {
    final epoch = SessionEpoch();
    final tabs = HomeTabsRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async => throw UnimplementedError()),
      ),
      gate: ServiceFeatureGate(
        isEnabled: () => true,
        onUnexpectedError: (_, _) {},
      ),
      communitiesGate: ServiceFeatureGate(
        isEnabled: () => true,
        onUnexpectedError: (_, _) {},
      ),
      epoch: epoch,
    );
    tabs.adoptFromMe([
      common.HomeTab(kind: common.HomeTabKind.HOME_TAB_KIND_COMMUNITY, id: '7'),
    ], epoch: epoch.value);
    final cubit = HomeTabsCubit(tabs: tabs, lists: _MockLists());
    addTearDown(cubit.close);
    expect(
      cubit.state.labels[cubit.state.tabs.single.key],
      kUnnamedCommunityTabLabel,
    );
  });
}
