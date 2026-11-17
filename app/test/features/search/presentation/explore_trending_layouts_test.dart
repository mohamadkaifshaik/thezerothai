import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/features/search/presentation/widgets/trending_media_sliver.dart';
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../support/context_pane_rig.dart';
import '../../../support/failing_image_cache.dart';
import '../../../support/fake_search_repository.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/search_field_rig.dart';

/// The three looks of the Trending tab (Posts and Media sections): phone and
/// tablet one list under a `Posts | Media` control (3 and 4 media columns),
/// desktop two panes inside the 600 column. Flag and state rules live in
/// `explore_trending_sections_test.dart`.

pb.PostView _photo(String id, int seconds) => pb.PostView(
  post: pb.Post(
    postId: id,
    kind: PostKind.POST_KIND_POST,
    createdAt: Timestamp(seconds: Int64(seconds)),
    media: [
      common.MediaRef(
        url: 'https://m.test/$id.webp',
        thumbUrl: 'https://m.test/$id-t.webp',
      ),
    ],
  ),
);

FakeSearchRepository _repo() => FakeSearchRepository()
  ..trendsResult = TrendsResult(
    trends: [for (var i = 1; i <= 6; i++) searchTrend('tag$i', 1000 - i, i)],
    latest: searchTrend('fresh', 1, 0),
    computedAt: DateTime.now().subtract(const Duration(hours: 2)),
  )
  ..explorePostsResult = SearchPostsPage(
    posts: [
      for (var i = 1; i <= 12; i++)
        postView(i, text: 'A post with some words in it, number $i'),
    ],
  )
  ..exploreMediaResult = SearchPostsPage(
    posts: [for (var i = 0; i < 24; i++) _photo('m$i', i)],
  );

Future<void> _open(
  WidgetTester tester, {
  required double width,
  double height = 900,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  useFailingImageCache();
  final rig = ContextPaneRig(search: _repo());
  await rig.pump(
    tester,
    location: '/explore',
    width: width,
    height: height,
    brightness: brightness,
    textScale: textScale,
    flags: {...kContextPaneFlags, 'trending_posts', 'trending_media'},
    page: (path) =>
        path == '/explore' ? const ExploreScreen() : Text('$path body'),
  );
  await tester.pumpAndSettle();
}

int _gridColumns(WidgetTester tester) {
  final grid = tester.widget<SliverGrid>(find.byType(SliverGrid).first);
  return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
      .crossAxisCount;
}

Finder get _control => find.byWidgetPredicate(
  (w) => w is AppTabBar && w.semanticLabel == 'Trending sections',
);

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in const [1.0, 2.0]) {
      final env = '${brightness.name} ${scale}x';

      for (final width in const [390.0, 700.0, 1000.0]) {
        testWidgets('one list under the control at $width ($env)', (
          tester,
        ) async {
          await _open(
            tester,
            width: width,
            brightness: brightness,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          expect(_control, findsOneWidget);
          expect(find.byType(FeedPostRow), findsWidgets);
          await tester.tap(find.text('Media'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(FeedPostRow), findsNothing);
          expect(_gridColumns(tester), width < 600 ? 3 : 4);
        });
      }

      testWidgets('two panes at 1280, 3 media columns, no control ($env)', (
        tester,
      ) async {
        await _open(
          tester,
          width: 1280,
          height: 700,
          brightness: brightness,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        expect(_control, findsNothing);
        final headings = find.byType(ExploreSubsectionHeading);
        expect(headings, findsNWidgets(2));
        final posts = tester.getRect(headings.at(0));
        final media = tester.getRect(headings.at(1));
        expect(posts.left, lessThan(media.left));
        expect(posts.top, media.top, reason: 'side by side');
        // Each pane keeps at least one row at the short window.
        expect(find.byType(FeedPostRow), findsWidgets);
        expect(
          find.byKey(const ValueKey('trending-media-m23')),
          findsOneWidget,
        );
        expect(_gridColumns(tester), 3);
        // The pane is the half of the 600 column (about 299 dp); at 2x text the
        // shell hands the page less width and the post card still lays out.
        final row = tester.getRect(find.byType(FeedPostRow).first);
        expect(
          row.width,
          scale == 1 ? inInclusiveRange(280, 310) : greaterThan(150),
        );
      });
    }
  }
}
