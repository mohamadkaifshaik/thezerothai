import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/explore_media.dart';
import 'package:dzeroth/features/search/presentation/bloc/explore_media_cubit.dart';
import 'package:dzeroth/features/search/presentation/bloc/explore_media_state.dart';
import 'package:dzeroth/features/search/presentation/explore_media_screen.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/features/search/presentation/explore_trending_screen.dart';
import 'package:dzeroth/features/search/presentation/widgets/explore_media_tile.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../support/app_fonts.dart';
import '../../../support/context_pane_rig.dart';
import '../../../support/failing_image_cache.dart';
import '../../../support/fake_search_repository.dart';
import '../../../support/search_field_rig.dart';

// Explore under the header: "Trending" (top 3 rows, See all to the full
// page) and "Media" (photos of the top trends, See all to a grid), then Who
// to follow. Three widths, light and dark.

const _screenshots = bool.fromEnvironment('EXPLORE_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  // Let the (real) image loads finish, then paint them.
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/explore/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

pb.PostView _photo(
  String id,
  int seconds, {
  int images = 1,
  PostKind kind = PostKind.POST_KIND_POST,
  bool thumbs = true,
}) => pb.PostView(
  post: pb.Post(
    postId: id,
    kind: kind,
    createdAt: Timestamp(seconds: Int64(seconds)),
    media: [
      for (var i = 0; i < images; i++)
        common.MediaRef(
          url: 'https://m.test/$id-$i.webp',
          thumbUrl: thumbs ? 'https://m.test/$id-$i-t.webp' : '',
        ),
    ],
  ),
);

SearchPostsPage _byTag(String query, String? token) {
  switch (query) {
    case '#tag1':
      return SearchPostsPage(posts: [_photo('10', 10), _photo('dup', 30)]);
    case '#tag2':
      return SearchPostsPage(posts: [_photo('20', 20), _photo('dup', 30)]);
    case '#tag3':
      return SearchPostsPage(posts: [_photo('5', 5)]);
  }
  return const SearchPostsPage();
}

FakeSearchRepository _repo({int trends = 6}) {
  final repo = FakeSearchRepository()
    ..trendsResult = TrendsResult(
      trends: [
        for (var i = 1; i <= trends; i++)
          searchTrend('tag$i', 1000 * (trends - i + 1), i),
      ],
      computedAt: DateTime.now().subtract(const Duration(hours: 2)),
    )
    ..postsHandler = (q, tab, token) => _byTag(q, token);
  return repo;
}

int _postCalls(FakeSearchRepository r) =>
    r.calls.where((c) => c.startsWith('posts:')).length;

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

const _flags = {...kContextPaneFlags, 'media'};

Future<ContextPaneRig> _open(
  WidgetTester tester,
  Size size, {
  FakeSearchRepository? repo,
  Set<String> flags = _flags,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  String location = '/explore',
}) async {
  useFailingImageCache();
  late ContextPaneRig rig;
  rig = ContextPaneRig(search: repo ?? _repo());
  await rig.pump(
    tester,
    location: location,
    width: size.width,
    height: size.height,
    flags: flags,
    textScale: textScale,
    brightness: brightness,
    page: (path) => switch (path) {
      '/explore' => const ExploreScreen(),
      '/explore/trending' => const ExploreTrendingScreen(),
      '/explore/media' => ExploreMediaScreen(
        cubit: rig.router.state.extra is ExploreMediaCubit
            ? rig.router.state.extra as ExploreMediaCubit
            : null,
      ),
      _ => Text('$path body'),
    },
  );
  return rig;
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  group('mergeMediaTiles', () {
    test('newest first, one tile per post id, first image with a thumb', () {
      final tiles = mergeMediaTiles([
        [_photo('10', 10), _photo('dup', 30)],
        [_photo('20', 20), _photo('dup', 30)],
        [_photo('5', 5, images: 2)],
      ]);
      expect([for (final t in tiles) t.postId], ['dup', '20', '10', '5']);
    });

    test('skips reposts, posts without a thumbnail and without media', () {
      final tiles = mergeMediaTiles([
        [
          _photo('1', 1, kind: PostKind.POST_KIND_REPOST),
          _photo('2', 2, thumbs: false),
          _photo('3', 3, images: 0),
          pb.PostView(),
          _photo('4', 4),
        ],
      ]);
      expect([for (final t in tiles) t.postId], ['4']);
      expect(tiles.single.index, 0);
      expect(tiles.single.kind, ExploreMediaKind.photo);
    });

    test('equal times: the larger post id first', () {
      final tiles = mergeMediaTiles([
        [_photo('1', 5), _photo('2', 5)],
      ]);
      expect([for (final t in tiles) t.postId], ['2', '1']);
    });
  });

  group('ExploreMediaCubit', () {
    blocTest<ExploreMediaCubit, ExploreMediaState>(
      'start asks each of the top 3 tags once, MEDIA tab, and never again',
      build: () => ExploreMediaCubit(repository: _repo()),
      act: (c) async {
        await c.start(['tag1', 'tag2', 'tag3', 'tag4']);
        await c.start(['tag1', 'tag2', 'tag3']);
      },
      verify: (c) {
        expect(
          [for (final t in c.state.tiles) t.postId],
          ['dup', '20', '10', '5'],
        );
      },
      expect: () => [
        const ExploreMediaState(status: ExploreMediaStatus.loading),
        isA<ExploreMediaState>().having(
          (s) => s.status,
          'status',
          ExploreMediaStatus.ready,
        ),
      ],
    );

    test('asks exactly #tag1..3 on the media tab', () async {
      final repo = _repo();
      final cubit = ExploreMediaCubit(repository: repo);
      await cubit.start(['tag1', 'tag2', 'tag3', 'tag4']);
      expect(repo.calls, [
        'posts:#tag1:SEARCH_TAB_MEDIA',
        'posts:#tag2:SEARCH_TAB_MEDIA',
        'posts:#tag3:SEARCH_TAB_MEDIA',
      ]);
      await cubit.close();
    });

    test('empty tags: nothing asked, and a later start still works', () async {
      final repo = _repo();
      final cubit = ExploreMediaCubit(repository: repo);
      await cubit.start([]);
      expect(repo.calls, isEmpty);
      await cubit.start(['tag1']);
      expect(_postCalls(repo), 1);
      await cubit.close();
    });

    test('every first page failing: failed, nothing kept', () async {
      final repo = _repo()..error = const SearchRateLimitedException();
      final cubit = ExploreMediaCubit(repository: repo);
      await cubit.start(['tag1', 'tag2']);
      expect(cubit.state.status, ExploreMediaStatus.failed);
      expect(cubit.state.tiles, isEmpty);
      await cubit.close();
    });

    test('FEATURE_DISABLED: unavailable', () async {
      final repo = _repo()..error = const SearchUnavailableException('media');
      final cubit = ExploreMediaCubit(repository: repo);
      await cubit.start(['tag1']);
      expect(cubit.state.status, ExploreMediaStatus.unavailable);
      await cubit.close();
    });

    test(
      'loadMore follows tokens past empty pages, within the bound',
      () async {
        final repo = FakeSearchRepository();
        var served = 0;
        repo.postsHandler = (q, tab, token) {
          if (token == null) {
            return SearchPostsPage(
              posts: [_photo('first-$q', 100)],
              nextPageToken: 't0',
            );
          }
          served++;
          // Empty pages with a token, forever.
          return SearchPostsPage(nextPageToken: 't$served');
        };
        final cubit = ExploreMediaCubit(repository: repo);
        await cubit.start(['a', 'b', 'c']);
        expect(repo.calls, hasLength(3));
        await cubit.loadMore();
        // One loadMore: at most two rounds over the three tags.
        expect(repo.calls.length - 3, kExploreMediaMaxCallsPerMore);
        expect(cubit.state.hasMore, isTrue);
        expect(cubit.state.loadingMore, isFalse);
        expect(cubit.state.tiles, hasLength(3));
        await cubit.close();
      },
    );

    test(
      'loadMore merges new pages, drops duplicates and ends on no token',
      () async {
        final repo = FakeSearchRepository();
        repo.postsHandler = (q, tab, token) => token == null
            ? SearchPostsPage(
                posts: [_photo('a', 50)],
                nextPageToken: q == '#x' ? 'more' : null,
              )
            : SearchPostsPage(posts: [_photo('a', 50), _photo('b', 60)]);
        final cubit = ExploreMediaCubit(repository: repo);
        await cubit.start(['x', 'y']);
        expect(cubit.state.hasMore, isTrue);
        await cubit.loadMore();
        expect([for (final t in cubit.state.tiles) t.postId], ['b', 'a']);
        expect(cubit.state.hasMore, isFalse);
        final before = repo.calls.length;
        await cubit.loadMore();
        expect(repo.calls.length, before);
        await cubit.close();
      },
    );

    test(
      'a failed page keeps the tiles and halts paging until retryMore',
      () async {
        final repo = FakeSearchRepository();
        var fail = false;
        repo.postsHandler = (q, tab, token) {
          if (token != null && fail) throw const SearchRateLimitedException();
          return token == null
              ? SearchPostsPage(posts: [_photo('a', 1)], nextPageToken: 'n')
              : SearchPostsPage(posts: [_photo('b', 2)]);
        };
        final cubit = ExploreMediaCubit(repository: repo);
        await cubit.start(['x']);
        fail = true;
        await cubit.loadMore();
        expect(cubit.state.pagingFailed, isTrue);
        expect(cubit.state.tiles, hasLength(1));
        final calls = repo.calls.length;
        await cubit.loadMore();
        expect(repo.calls.length, calls, reason: 'halted until retryMore');
        fail = false;
        await cubit.retryMore();
        expect(cubit.state.tiles, hasLength(2));
        await cubit.close();
      },
    );
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final desktop = size.width >= 1200;
    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('top 3 trends, no tab bar, Media row, one fetch', (
        tester,
      ) async {
        final repo = _repo();
        final rig = await _open(tester, size, repo: repo);
        // The header's one-tab "Trending" bar is gone; the section is the
        // only "Trending" title.
        expect(find.text('Trending'), findsOneWidget);
        expect(find.byType(Tab), findsNothing);
        for (final i in [1, 2, 3]) {
          expect(find.text('#tag$i'), findsOneWidget);
        }
        expect(find.text('#tag4'), findsNothing);
        expect(find.text('6K posts'), findsOneWidget);
        expect(find.text('Trending today'), findsNothing);
        expect(find.text('Media'), findsOneWidget);
        expect(find.text('See all'), findsNWidgets(2));
        expect(
          find.byType(ExploreMediaTileView).evaluate().length,
          allOf(greaterThanOrEqualTo(3), lessThanOrEqualTo(4)),
        );
        // Newest first: dup, then 20, then 10.
        final dx = [
          for (final id in ['dup', '20', '10'])
            tester.getTopLeft(find.byKey(ValueKey('explore-media-$id'))).dx,
        ];
        expect(dx, orderedEquals([...dx]..sort()));
        // Once per open: 3 calls, none more after a rebuild or a refreshed
        // trends list.
        expect(_postCalls(repo), 3);
        await rig.trends.ensureLoaded(force: true);
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(Size(size.width + 1, size.height));
        await tester.pumpAndSettle();
        expect(_postCalls(repo), 3);
        expect(rig.trendCalls, 2);
        await tester.binding.setSurfaceSize(null);
      });

      testWidgets('tap targets are at least 48 dp', (tester) async {
        await _open(tester, size);
        for (final f in [
          find.text('#tag1'),
          find.text('See all').first,
          find.text('See all').last,
        ]) {
          final box = tester.getSize(
            find.ancestor(of: f, matching: find.byType(InkWell)).first,
          );
          expect(box.height, greaterThanOrEqualTo(48));
        }
        expect(
          tester.getSize(find.byType(ExploreMediaTileView).first).width,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byType(ExploreMediaTileView).first).height,
          greaterThanOrEqualTo(48),
        );
      });

      testWidgets('a trend opens its results, a photo its viewer', (
        tester,
      ) async {
        final rig = await _open(tester, size);
        await tester.tap(find.text('#tag2'));
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.path, '/search');
        expect(rig.router.state.uri.queryParameters['q'], '#tag2');
        rig.router.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('explore-media-dup')));
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.path, '/post/dup/photo/1');
      });

      testWidgets('side column: no What\'s happening beside Explore', (
        tester,
      ) async {
        await _open(tester, size);
        final side = find.byType(AppSideColumn);
        if (desktop) {
          expect(side, findsOneWidget);
          expect(
            find.descendant(of: side, matching: find.text("What's happening")),
            findsNothing,
          );
          expect(
            find.descendant(of: side, matching: find.text('You might like')),
            findsOneWidget,
          );
        } else {
          expect(find.text('Who to follow'), findsOneWidget);
        }
      });

      for (final brightness in Brightness.values) {
        testWidgets('${brightness.name}: no overflow at 1x and 2x text', (
          tester,
        ) async {
          for (final scale in [1.0, 2.0]) {
            await _open(tester, size, brightness: brightness, textScale: scale);
            expect(tester.takeException(), isNull, reason: 'x$scale');
            await _capture(
              tester,
              'explore-$name-${brightness.name}${scale == 2 ? '-x2' : ''}',
            );
          }
        });
      }

      testWidgets('See all (Trending): the full page, up to 30 rows', (
        tester,
      ) async {
        final repo = _repo(trends: 35);
        final rig = await _open(tester, size, repo: repo);
        await tester.tap(find.text('See all').first);
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.path, '/explore/trending');
        expect(find.text('#tag1'), findsOneWidget);
        expect(find.text('#tag4'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('#tag30'),
          300,
          scrollable: find.descendant(
            of: find.byType(ExploreTrendingScreen),
            matching: find.byType(Scrollable),
          ),
        );
        expect(find.text('#tag30'), findsOneWidget);
        expect(find.text('#tag31'), findsNothing);
        expect(rig.trendCalls, 1, reason: 'the shared list, no second call');
        await _capture(tester, 'trending-$name');
        await tester.tap(find.text('#tag30'));
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.queryParameters['q'], '#tag30');
      });

      testWidgets('See all (Media): the same photos, no new fetch', (
        tester,
      ) async {
        final repo = _repo();
        final rig = await _open(tester, size, repo: repo);
        await tester.tap(find.text('See all').last);
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.path, '/explore/media');
        expect(find.text('Media'), findsOneWidget);
        expect(find.byType(ExploreMediaTileView), findsNWidgets(4));
        expect(_postCalls(repo), 3, reason: 'Explore handed its cubit over');
        await _capture(tester, 'media-$name');
        await tester.tap(find.byKey(const ValueKey('explore-media-20')));
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.path, '/post/20/photo/1');
      });
    });
  }

  group('Trending page states', () {
    testWidgets('loading skeleton, then rows', (tester) async {
      final gate = Completer<void>();
      final repo = _repo()..trendsGate = gate;
      final rig = await _open(
        tester,
        _sizes['phone']!,
        repo: repo,
        location: '/explore/trending',
      );
      expect(find.bySemanticsLabel('Loading trends'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('#tag1'), findsOneWidget);
      expect(rig.trendCalls, 1);
    });

    testWidgets('failed: message and Retry', (tester) async {
      final repo = _repo()..error = Exception('boom');
      await _open(
        tester,
        _sizes['phone']!,
        repo: repo,
        location: '/explore/trending',
      );
      expect(find.text("Trends couldn't be loaded right now."), findsOneWidget);
      repo.error = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('#tag1'), findsOneWidget);
    });

    testWidgets('empty', (tester) async {
      final repo = _repo(trends: 0);
      await _open(
        tester,
        _sizes['phone']!,
        repo: repo,
        location: '/explore/trending',
      );
      expect(find.text('Nothing is trending yet'), findsOneWidget);
    });
  });

  group('Media page', () {
    testWidgets('opened by link: makes its own fetch and pages on scroll', (
      tester,
    ) async {
      final repo = FakeSearchRepository()
        ..trendsResult = TrendsResult(
          trends: [searchTrend('tag1', 10, 1)],
          computedAt: DateTime.now(),
        )
        ..postsHandler = (q, tab, token) => token == null
            ? SearchPostsPage(
                posts: [for (var i = 0; i < 12; i++) _photo('a$i', 100 + i)],
                nextPageToken: 'n1',
              )
            : SearchPostsPage(posts: [_photo('late', 1)]);
      await _open(
        tester,
        _sizes['phone']!,
        repo: repo,
        location: '/explore/media',
      );
      expect(repo.calls, contains('posts:#tag1:SEARCH_TAB_MEDIA'));
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('explore-media-late')),
        find.descendant(
          of: find.byType(ExploreMediaScreen),
          matching: find.byType(Scrollable),
        ),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('explore-media-late')), findsOneWidget);
      expect(repo.postsPageTokens, [null, 'n1']);
    });

    testWidgets('empty and failed', (tester) async {
      final repo = FakeSearchRepository()
        ..trendsResult = TrendsResult(
          trends: [searchTrend('tag1', 10, 1)],
          computedAt: DateTime.now(),
        )
        ..postsResult = const SearchPostsPage();
      await _open(
        tester,
        _sizes['phone']!,
        repo: repo,
        location: '/explore/media',
      );
      expect(find.text('No photos yet'), findsOneWidget);
    });
  });

  group('flags and empty data', () {
    final modes = <String, Set<String>>{
      'media off': {...kContextPaneFlags},
      'trends off': {...kContextPaneFlags, 'media'}..remove('trends'),
      'search off': {...kContextPaneFlags, 'media'}..remove('search'),
    };
    for (final MapEntry(key: mode, value: flags) in modes.entries) {
      testWidgets('$mode: no Media section and no media call', (tester) async {
        final repo = _repo();
        await _open(tester, _sizes['phone']!, repo: repo, flags: flags);
        expect(find.text('Media'), findsNothing);
        expect(_postCalls(repo), 0);
      });
    }

    testWidgets('trends off: no Trending section either', (tester) async {
      await _open(
        tester,
        _sizes['phone']!,
        flags: {...kContextPaneFlags, 'media'}..remove('trends'),
      );
      expect(find.text('Trending'), findsNothing);
      expect(find.text('Who to follow'), findsOneWidget);
    });

    testWidgets('no photos: the section is hidden, Trending stays', (
      tester,
    ) async {
      final repo = _repo()..postsHandler = null;
      await _open(tester, _sizes['phone']!, repo: repo);
      expect(find.text('Media'), findsNothing);
      expect(find.text('Trending'), findsOneWidget);
      expect(_postCalls(repo), 3);
    });

    testWidgets('no trends: no Media section, no media call', (tester) async {
      final repo = _repo(trends: 0);
      await _open(tester, _sizes['phone']!, repo: repo);
      expect(find.text('Media'), findsNothing);
      expect(_postCalls(repo), 0);
    });

    testWidgets('media calls fail: the section is hidden quietly', (
      tester,
    ) async {
      final repo = _repo()
        ..postsHandler = (q, tab, token) =>
            throw const SearchUnavailableException('media');
      await _open(tester, _sizes['phone']!, repo: repo);
      expect(find.text('Media'), findsNothing);
      expect(find.text('#tag1'), findsOneWidget);
    });
  });
}
