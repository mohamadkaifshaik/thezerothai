import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/beacons/domain/plans_list_detail.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';

/// Tablet plan section 3, LD families: the Plans master pane shows on
/// `/plans` and `/plans/:id` only; `/plans/mine`, `/plans/new`,
/// `/plans/:id/edit` and `/plans/:id/people` have their own layout.
void main() {
  test('/plans: in the family, nothing selected', () {
    final match = plansMasterMatch(AppRouter.plansPath);
    expect(match, isNotNull);
    expect(match!.selectedId, isNull);
  });

  test('/plans/:id: in the family, that plan selected', () {
    expect(
      plansMasterMatch(AppRouter.planPath(kBeaconIdA))?.selectedId,
      kBeaconIdA,
    );
  });

  test('an encoded id is decoded', () {
    expect(plansMasterMatch(AppRouter.planPath('12 3'))?.selectedId, '12 3');
  });

  test('a trailing slash and a query are ignored', () {
    expect(plansMasterMatch('/plans/')?.selectedId, isNull);
    expect(plansMasterMatch('/plans?x=1'), isNotNull);
    expect(plansMasterMatch('/plans/$kBeaconIdA/')?.selectedId, kBeaconIdA);
  });

  for (final location in [
    AppRouter.planNewPath,
    AppRouter.plansMinePath,
    AppRouter.planEditPath(kBeaconIdA),
    AppRouter.planPeoplePath(kBeaconIdA),
    '/home',
    '/settings',
    '/plansx',
    '/',
    '',
  ]) {
    test('$location: not in the family', () {
      expect(plansMasterMatch(location), isNull);
    });
  }
}
