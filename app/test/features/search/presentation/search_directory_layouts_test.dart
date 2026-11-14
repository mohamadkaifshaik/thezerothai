import 'package:dzeroth/features/communities/presentation/widgets/community_row.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_row.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/search_results_tab.dart';
import 'package:dzeroth/features/search/presentation/widgets/search_directory_tabs.dart';
import 'package:dzeroth/shared/widgets/primitives/app_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/search_directory_rig.dart';

// The Lists and Communities tabs and the "People you follow" filter at the
// three widths of the mocks (phone, tablet, desktop): one set of rows and
// actions, no overflow, in light and dark at text scale 1 and 2.
const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

void main() {
  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final brightness in Brightness.values) {
      for (final scale in const [1.0, 2.0]) {
        final label = '$name ${brightness.name} x$scale';

        testWidgets('Lists tab, $label', (tester) async {
          final rig = SearchDirectoryRig();
          rig.search.listsResult = SearchListsPage(
            lists: [
              searchList('L1'),
              searchList(
                'L2',
                name: 'A list with a rather long name to wrap around',
                following: true,
              ),
            ],
          );
          await rig.pump(
            tester,
            tab: SearchResultsTab.lists,
            size: size,
            brightness: brightness,
            textScale: scale,
          );
          expect(find.byType(ListRow), findsNWidgets(2));
          expect(find.text('Follow'), findsOneWidget);
          expect(find.text('Following'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Communities tab, $label', (tester) async {
          final rig = SearchDirectoryRig();
          rig.search.communitiesResult = SearchCommunitiesPage(
            communities: [
              searchCommunity('c1'),
              searchCommunity(
                'c2',
                name: 'A community with a rather long name to wrap',
              ),
            ],
          );
          await rig.pump(
            tester,
            tab: SearchResultsTab.communities,
            size: size,
            brightness: brightness,
            textScale: scale,
          );
          expect(find.byType(CommunityRow), findsNWidgets(2));
          expect(tester.takeException(), isNull);
        });

        testWidgets('filter row, $label', (tester) async {
          final rig = SearchDirectoryRig();
          rig.search.postsResult = SearchPostsPage(
            posts: [postView(1, text: 'tagged')],
            normalizedTag: 'coffee',
          );
          await rig.pump(
            tester,
            tab: SearchResultsTab.media,
            size: size,
            brightness: brightness,
            textScale: scale,
          );
          expect(find.byType(AppFilterPill), findsNWidgets(2));
          expect(find.text(kSearchFromFollowingLabel), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
