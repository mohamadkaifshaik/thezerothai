import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_media_strip.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/failing_image_cache.dart';

TimelineEntry _post(
  String id, {
  int images = 1,
  PostKind kind = PostKind.POST_KIND_POST,
  bool thumbs = true,
}) => TimelineEntry.post(
  id,
  id,
  pb.PostView(
    post: pb.Post(
      postId: id,
      kind: kind,
      media: [
        for (var i = 0; i < images; i++)
          common.MediaRef(
            url: 'https://m.test/$id-$i.webp',
            thumbUrl: thumbs ? 'https://m.test/$id-$i-t.webp' : '',
          ),
      ],
    ),
  ),
);

List<String> _ids(List<ProfileMediaTile> tiles) => [
  for (final t in tiles) '${t.postId}/${t.index}',
];

Future<void> _pump(WidgetTester tester, TimelineState state) async {
  useFailingImageCache();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness: Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: ProfileMediaStrip(
            state: state,
            onOpen: (_) {},
            onSeeAll: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('profileMediaTiles', () {
    test('newest post first, each post in its own order, at most 6', () {
      final tiles = profileMediaTiles([
        _post('a', images: 2),
        _post('b', images: 3),
        _post('c', images: 4),
      ]);
      expect(_ids(tiles), ['a/0', 'a/1', 'b/0', 'b/1', 'b/2', 'c/0']);
    });

    test('gaps, reposts and images with no thumbnail are skipped', () {
      final tiles = profileMediaTiles([
        TimelineEntry.gap('g', 'g', 'token'),
        _post('r', kind: PostKind.POST_KIND_REPOST),
        _post('n', thumbs: false),
        _post('ok', images: 2),
      ]);
      expect(_ids(tiles), ['ok/0', 'ok/1']);
    });

    test('at most four images of one post (the post card limit)', () {
      expect(profileMediaTiles([_post('a', images: 6)], max: 10).length, 4);
    });

    test('no posts: no tiles', () {
      expect(profileMediaTiles(const []), isEmpty);
    });
  });

  group('ProfileMediaStrip', () {
    final ready = TimelineState(
      status: TimelineStatus.ready,
      entries: [_post('a', images: 2)],
    );
    final cases = <String, (TimelineState, Type?)>{
      'loading: the placeholder': (
        const TimelineState(),
        ProfileMediaStripPlaceholder,
      ),
      'ready with images: the card': (ready, Card),
      'ready with none: nothing': (
        const TimelineState(status: TimelineStatus.ready),
        null,
      ),
      'failed: nothing': (
        const TimelineState(
          status: TimelineStatus.error,
          error: UnknownApiException('down'),
        ),
        null,
      ),
      'protected: nothing': (
        const TimelineState(
          status: TimelineStatus.ready,
          authorProtected: true,
        ),
        null,
      ),
      'unavailable: nothing': (
        const TimelineState(status: TimelineStatus.ready, unavailable: true),
        null,
      ),
    };
    for (final MapEntry(key: name, value: (state, shown)) in cases.entries) {
      testWidgets(name, (tester) async {
        await _pump(tester, state);
        final strip = tester.getSize(find.byType(ProfileMediaStrip));
        if (shown == null) {
          expect(strip.height, 0);
          expect(find.text(kProfileMediaTitle), findsNothing);
        } else {
          expect(find.text(kProfileMediaTitle), findsOneWidget);
          if (shown == ProfileMediaStripPlaceholder) {
            expect(find.byType(ProfileMediaStripPlaceholder), findsOneWidget);
            expect(find.text('See all'), findsNothing);
          } else {
            expect(find.text('See all'), findsOneWidget);
          }
        }
      });
    }

    testWidgets('a GIF shows its still with the badge, and says GIF', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        TimelineState(
          status: TimelineStatus.ready,
          entries: [
            TimelineEntry.post(
              'g',
              'g',
              pb.PostView(
                post: pb.Post(
                  postId: 'g',
                  kind: PostKind.POST_KIND_POST,
                  media: [
                    common.MediaRef(
                      url: 'https://m.test/g.gif',
                      thumbUrl: 'https://m.test/g-t.webp',
                      contentType: 'image/gif',
                      altText: 'A cat',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      expect(find.text('GIF'), findsOneWidget);
      expect(find.bySemanticsLabel('Open image, A cat, GIF'), findsOneWidget);
      semantics.dispose();
    });
  });
}
