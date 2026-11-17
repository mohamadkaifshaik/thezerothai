import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';

/// The server never sends a COMMUNITY tab's title: the client labels it.
void main() {
  late SessionEpoch epoch;
  late HomeTabsRepository repo;

  setUp(() {
    epoch = SessionEpoch();
    repo = HomeTabsRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          final r = input as tl.SetHomeTabsRequest;
          // The server echoes the tabs with title "" for a community.
          return tl.SetHomeTabsResponse(
            tabs: [
              for (final t in r.tabs) common.HomeTab(kind: t.kind, id: t.id),
            ],
          );
        }),
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
  });

  HomeTabEntry tab() => repo.tabs.single;

  void adoptCommunityTab() => repo.adoptFromMe([
    common.HomeTab(kind: common.HomeTabKind.HOME_TAB_KIND_COMMUNITY, id: '7'),
  ], epoch: epoch.value);

  test('a pinned community keeps its name after the write settles', () async {
    await repo.pin(HomeTabKind.community, '7', title: 'Chess club');
    expect(repo.labelFor(tab()), 'Chess club');
    expect(repo.needsLabel(tab()), isFalse);
  });

  test('a community from GetMe has no label until its header is seen', () {
    adoptCommunityTab();
    expect(repo.needsLabel(tab()), isTrue);

    final changes = <int>[];
    repo.changes.listen((t) => changes.add(t.length));
    repo.noteCommunityInfo(pb.Community(communityId: '7', name: 'Chess club'));
    expect(repo.labelFor(tab()), 'Chess club');
    expect(repo.needsLabel(tab()), isFalse);
    expect(changes, [1]);

    // A rename shows at once.
    repo.noteCommunityInfo(pb.Community(communityId: '7', name: 'Chess'));
    expect(repo.labelFor(tab()), 'Chess');
  });

  test('sign-out forgets community labels', () {
    repo.noteCommunityInfo(pb.Community(communityId: '7', name: 'Chess club'));
    repo.clearSession();
    adoptCommunityTab();
    expect(repo.needsLabel(tab()), isTrue);
  });
}
