import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_media_strip.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Future<void> _pump(
  WidgetTester tester,
  TimelineState state, {
  bool seeAll = true,
}) => _pumpChild(
  tester,
  ProfileMediaStrip(
    state: state,
    onOpen: (_) {},
    onSeeAll: seeAll ? () {} : null,
  ),
);

Future<void> _pumpChild(WidgetTester tester, Widget child) async {
  useFailingImageCache();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness: Brightness.light),
      home: Scaffold(
        // Natural heights, as in the pane's scroll view.
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 320, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Six images, one per post.
final _six = TimelineState(
  status: TimelineStatus.ready,
  entries: [for (var i = 1; i <= 6; i++) _post('p$i')],
);

/// The tile of image 0 of post [id].
Finder _tile(String id) => find.byKey(ValueKey('profile-media-$id-0'));

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

    testWidgets('the placeholder is exactly as tall as the strip (no jump)', (
      tester,
    ) async {
      await _pump(tester, _six);
      final strip = tester.getSize(find.byType(ProfileMediaStrip)).height;
      expect(strip, lessThan(600), reason: 'its own height, not the body');
      await _pumpChild(tester, const ProfileMediaStripPlaceholder());
      expect(
        tester.getSize(find.byType(ProfileMediaStripPlaceholder)).height,
        strip,
      );
    });

    testWidgets('no See all when it would open the tab already shown', (
      tester,
    ) async {
      await _pump(tester, _six, seeAll: false);
      expect(find.text(kProfileMediaTitle), findsOneWidget);
      expect(find.text('See all'), findsNothing);
      expect(find.byKey(const ValueKey('profile-media-p1-0')), findsOneWidget);
    });

    testWidgets('tiles and placeholder tiles have the 12 dp radius', (
      tester,
    ) async {
      await _pump(tester, _six);
      final clip = tester.widget<ClipRRect>(
        find.descendant(of: _tile('p1'), matching: find.byType(ClipRRect)),
      );
      expect(clip.borderRadius, BorderRadius.circular(AppRadius.md));
      await _pumpChild(tester, const ProfileMediaStripPlaceholder());
      final box = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(ProfileMediaStripPlaceholder),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.color != null && d.border == null)
          .first;
      expect(box.borderRadius, BorderRadius.circular(AppRadius.md));
    });

    testWidgets('a tile is one button, read once, not also an image', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, _six);
      final node = tester.getSemantics(_tile('p1'));
      expect(node.label, 'Open image');
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isImage, isFalse);
      semantics.dispose();
    });

    testWidgets(
      'keyboard focus on a tile paints its highlight over the image',
      (tester) async {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(
          () => FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic,
        );
        await _pump(tester, _six);
        final ink = find.descendant(
          of: _tile('p1'),
          matching: find.byType(InkWell),
        );
        // The ink sits above the image: inside the tile's Stack, after it.
        final stack = tester.widget<Stack>(
          find.descendant(of: _tile('p1'), matching: find.byType(Stack)),
        );
        expect(stack.children.first, isNot(isA<Positioned>()));
        expect(stack.children.last, isA<Positioned>());
        expect(
          find.descendant(
            of: find.descendant(of: _tile('p1'), matching: find.byType(Stack)),
            matching: ink,
          ),
          findsOneWidget,
        );
        // Tab from nothing lands on the first tile.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final element = tester.element(ink);
        final focused = FocusManager.instance.primaryFocus!.context!;
        expect(
          find.descendant(
            of: _tile('p1'),
            matching: find.byWidget(focused.widget),
          ),
          findsOneWidget,
        );
        expect(
          Material.of(element),
          paints..rect(color: Theme.of(element).focusColor),
        );
      },
    );

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
