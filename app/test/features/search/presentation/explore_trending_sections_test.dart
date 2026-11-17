import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_chip.dart';
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
    posts: [for (var i = 1; i <= 3; i++) postView(i)],
  )
  ..exploreMediaResult = SearchPostsPage(
    posts: [_photo('a', 30), _photo('b', 20)],
  )
  ..postsHandler = (query, tab, token) => SearchPostsPage(
    posts: tab == SearchTab.SEARCH_TAB_MEDIA
        ? [_photo('t-$query', 5)]
        : [postView(77, text: 'tagged $query')],
  );

const _base = <String>{...kContextPaneFlags};

Future<ContextPaneRig> _open(
  WidgetTester tester, {
  FakeSearchRepository? repo,
  Set<String> extra = const {'trending_posts', 'trending_media'},
  Set<String> remove = const {},
  double width = 390,
  double height = 844,
}) async {
  useFailingImageCache();
  final rig = ContextPaneRig(search: repo ?? _repo());
  await rig.pump(
    tester,
    location: '/explore',
    width: width,
    height: height,
    flags: {..._base, ...extra}.difference(remove),
    page: (path) =>
        path == '/explore' ? const ExploreScreen() : Text('$path body'),
  );
  await tester.pumpAndSettle();
  return rig;
}

Finder _chip(String tag) => find.byKey(ValueKey('trending-chip-$tag'));

bool _selected(WidgetTester tester, String tag) =>
    tester.widget<AppFilterPill>(_chip(tag)).selected;

void main() {
  group('flag matrix', () {
    testWidgets(
      'both sections: chips, the Posts | Media control, Posts shown',
      (tester) async {
        final repo = _repo();
        await _open(tester, repo: repo);
        expect(find.text('Popular'), findsOneWidget);
        expect(_chip('tag1'), findsOneWidget);
        expect(_chip('tag5'), findsOneWidget);
        expect(_chip('tag6'), findsNothing, reason: 'top five only');
        expect(find.text('Latest · #fresh'), findsOneWidget);
        final bars = tester
            .widgetList<AppTabBar>(find.byType(AppTabBar))
            .map((b) => b.semanticLabel)
            .toList();
        expect(bars, contains('Trending sections'));
        expect(find.byType(FeedPostRow), findsNWidgets(3));
        // The hidden section asks nothing.
        expect(repo.exploreMediaTokens, isEmpty);
        expect(repo.explorePostsTokens, [null]);
      },
    );

    testWidgets('Posts only: no control, Posts shown, Media never asked', (
      tester,
    ) async {
      final repo = _repo();
      await _open(tester, repo: repo, extra: const {'trending_posts'});
      expect(
        find.byWidgetPredicate(
          (w) => w is AppTabBar && w.semanticLabel == 'Trending sections',
        ),
        findsNothing,
      );
      expect(find.byType(FeedPostRow), findsNWidgets(3));
      expect(repo.exploreMediaTokens, isEmpty);
    });

    testWidgets('Media only: no control, the grid shows', (tester) async {
      final repo = _repo();
      await _open(tester, repo: repo, extra: const {'trending_media'});
      expect(
        find.byWidgetPredicate(
          (w) => w is AppTabBar && w.semanticLabel == 'Trending sections',
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('trending-media-a')), findsOneWidget);
      expect(repo.explorePostsTokens, isEmpty);
    });

    testWidgets('both off: today\'s tab (Popular rows, no chips, no control)', (
      tester,
    ) async {
      final repo = _repo();
      await _open(tester, repo: repo, extra: const {});
      expect(find.text('Popular'), findsOneWidget);
      expect(_chip('tag1'), findsNothing);
      expect(find.text('#tag1'), findsOneWidget);
      expect(repo.explorePostsTokens, isEmpty);
      expect(repo.exploreMediaTokens, isEmpty);
    });

    testWidgets('search off hides both sections', (tester) async {
      final repo = _repo();
      await _open(tester, repo: repo, remove: const {'search'});
      expect(repo.explorePostsTokens, isEmpty);
      expect(find.byType(FeedPostRow), findsNothing);
    });

    testWidgets('trends off: sections show without chips or note', (
      tester,
    ) async {
      final repo = _repo();
      await _open(tester, repo: repo, remove: const {'trends'});
      expect(_chip('tag1'), findsNothing);
      expect(find.text('Popular'), findsNothing);
      expect(find.byType(FeedPostRow), findsNWidgets(3));
      expect(repo.calls.where((c) => c.startsWith('trends')), isEmpty);
    });
  });

  group('chips', () {
    testWidgets('a chip filters both sections in place; again clears', (
      tester,
    ) async {
      final repo = _repo();
      await _open(tester, repo: repo);
      await tester.tap(_chip('tag2'));
      await tester.pumpAndSettle();
      expect(_selected(tester, 'tag2'), isTrue);
      expect(repo.calls, contains('posts:#tag2:SEARCH_TAB_LATEST'));
      expect(find.byKey(ValueKey('trending-post-${postId(77)}')), findsOneWidget);
      expect(find.byType(FeedPostRow), findsOneWidget);
      // Media is hidden: not asked for the tag until it is shown.
      expect(repo.calls, isNot(contains('posts:#tag2:SEARCH_TAB_MEDIA')));
      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('posts:#tag2:SEARCH_TAB_MEDIA'));
      expect(repo.exploreMediaTokens, isEmpty);
      await tester.tap(_chip('tag2'));
      await tester.pumpAndSettle();
      expect(_selected(tester, 'tag2'), isFalse);
      // Back to the untagged Media list, already loaded: no new call.
      final before = repo.calls.length;
      expect(find.byKey(const ValueKey('trending-media-a')), findsOneWidget);
      expect(repo.calls.length, before);
    });

    testWidgets('the selected chip is announced selected, the Latest chip '
        'says it is the latest', (tester) async {
      final handle = tester.ensureSemantics();
      await _open(tester);
      await tester.tap(_chip('tag1'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(_chip('tag1')),
        matchesSemantics(
          label: '#tag1',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );
      expect(find.bySemanticsLabel('#fresh, latest hashtag'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('chips are 48 dp tall targets and the row scrolls sideways at '
        'large text', (tester) async {
      await _open(tester);
      expect(
        tester
            .getSize(
              find.descendant(
                of: _chip('tag1'),
                matching: find.byType(InkWell),
              ),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('sections', () {
    testWidgets('Media loads when first shown; switching back asks nothing', (
      tester,
    ) async {
      final repo = _repo();
      await _open(tester, repo: repo);
      expect(repo.exploreMediaTokens, isEmpty);
      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(repo.exploreMediaTokens, [null]);
      expect(find.byKey(const ValueKey('trending-media-a')), findsOneWidget);
      expect(find.byType(FeedPostRow), findsNothing);
      await tester.tap(find.text('Posts'));
      await tester.pumpAndSettle();
      expect(find.byType(FeedPostRow), findsNWidgets(3));
      expect(repo.explorePostsTokens, [null]);
      expect(repo.exploreMediaTokens, [null]);
    });

    testWidgets('pull to refresh asks the visible section and the hashtags '
        'only', (tester) async {
      final repo = _repo();
      await _open(tester, repo: repo);
      final trendsBefore = repo.calls
          .where((c) => c.startsWith('trends'))
          .length;
      await tester.fling(
        find.byType(FeedPostRow).first,
        const Offset(0, 500),
        1000,
      );
      await tester.pumpAndSettle();
      expect(repo.explorePostsTokens, [null, null]);
      expect(repo.exploreMediaTokens, isEmpty);
      expect(
        repo.calls.where((c) => c.startsWith('trends')).length,
        trendsBefore + 1,
      );
    });
  });

  group('scroll', () {
    testWidgets('both bars stay pinned and a switch keeps each offset', (
      tester,
    ) async {
      final repo = _repo()
        ..explorePostsResult = SearchPostsPage(
          posts: [for (var i = 1; i <= 30; i++) postView(i)],
        )
        ..exploreMediaResult = SearchPostsPage(
          posts: [for (var i = 0; i < 30; i++) _photo('m$i', i)],
        );
      await _open(tester, repo: repo, extra: const {'trending_posts', 'trending_media'});
      final scroll = find.byType(CustomScrollView).first;
      await tester.drag(scroll, const Offset(0, -900));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<CustomScrollView>(scroll)
          .controller!;
      final postsOffset = controller.offset;
      expect(postsOffset, greaterThan(500));
      // Both pinned bars are on screen, one under the other.
      final explore = tester.getRect(find.text('Trending'));
      final sections = tester.getRect(find.text('Posts'));
      expect(explore.top, lessThan(sections.top));
      expect(sections.top, lessThan(120));
      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trending-media-m29')), findsOneWidget);
      // The header stays collapsed on the other section, whose list starts
      // at its top under the bars.
      final firstTile = tester.getRect(
        find.byKey(const ValueKey('trending-media-m29')),
      );
      expect(firstTile.top, greaterThan(sections.bottom - 1));
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pumpAndSettle();
      final mediaOffset = controller.offset;
      await tester.tap(find.text('Posts'));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(postsOffset, 1));
      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(mediaOffset, 1));
      expect(repo.explorePostsTokens, [null]);
      expect(repo.exploreMediaTokens, [null]);
    });
  });

  group('states', () {
    testWidgets('empty Posts', (tester) async {
      final repo = _repo()..explorePostsResult = const SearchPostsPage();
      await _open(tester, repo: repo);
      expect(find.text('No posts yet'), findsOneWidget);
      expect(find.text('New public posts show up here.'), findsOneWidget);
    });

    testWidgets('empty Posts under a tag offers Clear filter', (tester) async {
      final repo = _repo()..postsHandler = (_, _, _) => const SearchPostsPage();
      await _open(tester, repo: repo);
      await tester.tap(_chip('tag3'));
      await tester.pumpAndSettle();
      expect(find.text('No posts with #tag3 yet'), findsOneWidget);
      await tester.tap(find.text('Clear filter'));
      await tester.pumpAndSettle();
      expect(_selected(tester, 'tag3'), isFalse);
      expect(find.byType(FeedPostRow), findsNWidgets(3));
    });

    testWidgets('a stalled list says so and Load more asks once more', (
      tester,
    ) async {
      var round = 0;
      final repo = _repo()
        ..explorePostsHandler = (_) => ++round <= 3
            ? const SearchPostsPage(nextPageToken: 'n')
            : SearchPostsPage(posts: [postView(9)]);
      await _open(tester, repo: repo);
      expect(find.text('Nothing to show yet'), findsOneWidget);
      expect(repo.explorePostsTokens, hasLength(3));
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(find.byType(FeedPostRow), findsOneWidget);
      expect(repo.explorePostsTokens, hasLength(4));
    });

    testWidgets('a failed first page shows the error with Retry', (
      tester,
    ) async {
      final repo = _repo();
      repo.error = Exception('boom');
      await _open(tester, repo: repo);
      expect(find.text('Retry'), findsWidgets);
    });

    testWidgets('a first-page rate limit says so', (tester) async {
      final repo = _repo()
        ..explorePostsHandler = (_) => throw const SearchRateLimitedException();
      await _open(tester, repo: repo);
      expect(find.text('Too many searches'), findsOneWidget);
    });

    testWidgets('Media empty and tagged-empty copy', (tester) async {
      final repo = _repo()
        ..exploreMediaResult = const SearchPostsPage()
        ..postsHandler = (_, _, _) => const SearchPostsPage();
      await _open(tester, repo: repo);
      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(find.text('No photos yet'), findsOneWidget);
      await tester.tap(_chip('tag1'));
      await tester.pumpAndSettle();
      expect(find.text('No photos with #tag1 yet'), findsOneWidget);
      expect(find.text('Clear filter'), findsOneWidget);
    });
  });
}
