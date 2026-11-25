import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/post/post_action_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/dz_finders.dart';
import '../../../support/theme_harness.dart';

PostActions _actions() => PostActions(
  onReply: () {},
  onRepost: () {},
  onLike: () {},
  onBookmark: () {},
  onShare: () {},
);

Widget _bar({
  bool liked = false,
  bool reposted = false,
  bool bookmarked = false,
  PostActionBarLayout layout = PostActionBarLayout.compact,
  PostActionBarStyle style = PostActionBarStyle.feed,
  bool showCounts = true,
  PostActions? actions,
  int likes = 12,
}) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16),
  child: PostActionBar(
    actions: actions ?? _actions(),
    replyCount: 3,
    repostCount: 1,
    likeCount: likes,
    liked: liked,
    reposted: reposted,
    bookmarked: bookmarked,
    layout: layout,
    style: style,
    showCounts: showCounts,
  ),
);

Rect _icon(WidgetTester tester, Finder finder) => tester.getRect(finder);

/// The tap box around an icon: the nearest InkResponse.
Rect _target(WidgetTester tester, Finder icon) => tester.getRect(
  find.ancestor(of: icon, matching: find.byType(InkResponse)).first,
);

void main() {
  group('compact layout (DzHome, DzThread)', () {
    testWidgets('reply, repost, like lead; save and share trail, 44 dp boxes', (
      tester,
    ) async {
      await pumpThemed(tester, _bar(), size: const Size(390, 400));
      final bar = tester.getRect(find.byType(PostActionBar));
      final reply = _target(tester, findDz(DzIcons.reply));
      final repost = _target(tester, findDz(DzIcons.repost));
      final like = _target(tester, findDz(DzIcons.like));
      final save = _target(tester, findDz(DzIcons.save));
      final share = _target(tester, findDz(DzIcons.share));

      expect(reply.left, closeTo(bar.left, 0.5));
      expect(repost.left, closeTo(reply.right, 0.5));
      expect(like.left, closeTo(repost.right, 0.5));
      expect(share.right, closeTo(bar.right, 0.5));
      expect(save.right, closeTo(share.left, 0.5));
      expect(save.left, greaterThan(like.right));
      for (final box in [reply, repost, like, save, share]) {
        expect(box.height, 48);
        expect(box.width, greaterThanOrEqualTo(48));
      }
      // Save and share are bare 48 dp squares (the design's 44, raised to the
      // app's minimum tap target).
      expect(save.width, 48);
      expect(share.width, 48);
    });

    testWidgets('icons are 19 dp and counts are 13/600 with tabular figures', (
      tester,
    ) async {
      await pumpThemed(tester, _bar(), size: const Size(390, 400));
      for (final icon in dzActionIcons) {
        expect(tester.getSize(findDz(icon)), const Size.square(19));
      }
      final count = tester.widget<Text>(find.text('12'));
      expect(count.style?.fontSize, 13);
      expect(count.style?.fontWeight, FontWeight.w600);
      expect(count.style?.fontFeatures, isNotEmpty);
      // The count sits 5 dp from its glyph.
      final like = tester.getRect(findDz(DzIcons.like));
      final text = tester.getRect(find.text('12'));
      expect(text.left - like.right, closeTo(5, 0.5));
    });

    testWidgets('idle is text2, liked is the like colour, saved is filled', (
      tester,
    ) async {
      await pumpThemed(tester, _bar(), size: const Size(390, 400));
      final colors = AppColors.light;
      expect(dzIconOf(tester, DzIcons.like).color, colors.text2);
      expect(dzIconOf(tester, DzIcons.like).fill, 0);
      await pumpThemed(
        tester,
        _bar(liked: true, reposted: true, bookmarked: true),
        size: const Size(390, 400),
      );
      expect(dzIconOf(tester, DzIcons.like).color, colors.like);
      expect(dzIconOf(tester, DzIcons.like).fill, 1);
      expect(dzIconOf(tester, DzIcons.repost).color, colors.repost);
      expect(
        dzIconOf(tester, DzIcons.repost).fill,
        0,
        reason: 'only recolours',
      );
      expect(dzIconOf(tester, DzIcons.repost).strokeWidth, 2.2);
      expect(dzIconOf(tester, DzIcons.save).fill, 1);
    });

    testWidgets('showCounts false draws no counts', (tester) async {
      await pumpThemed(
        tester,
        _bar(showCounts: false),
        size: const Size(390, 400),
      );
      expect(find.text('12'), findsNothing);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('semantics: label with count, selected, tap', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _bar(liked: true), size: const Size(390, 400));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Unlike, 12')),
        matchesSemantics(
          label: 'Unlike, 12',
          isButton: true,
          isSelected: true,
          isEnabled: true,
          hasEnabledState: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });
  });

  group('spread layout (DzPost, ZPhotoViewer)', () {
    testWidgets('five 48 dp boxes spread evenly', (tester) async {
      await pumpThemed(
        tester,
        _bar(layout: PostActionBarLayout.spread, showCounts: false),
        size: const Size(390, 400),
      );
      final boxes = [for (final i in dzActionIcons) _target(tester, findDz(i))];
      for (final box in boxes) {
        expect(box.height, closeTo(48, 0.001));
        expect(box.width, closeTo(48, 0.001));
      }
      final gaps = [
        for (var i = 1; i < boxes.length; i++)
          boxes[i].left - boxes[i - 1].right,
      ];
      for (final g in gaps) {
        expect(g, closeTo(gaps.first, 0.5));
      }
      // space-around: half a gap on each side.
      final bar = tester.getRect(find.byType(PostActionBar));
      expect(boxes.first.left - bar.left, closeTo(gaps.first / 2, 0.5));
    });

    testWidgets('photo viewer style keeps the panel greys', (tester) async {
      await pumpThemed(
        tester,
        _bar(
          layout: PostActionBarLayout.spread,
          style: PostActionBarStyle.photoViewer,
        ),
        size: const Size(390, 400),
      );
      expect(dzIconOf(tester, DzIcons.reply).color, AppPhotoPanel.muted);
    });
  });

  group('toggle animation', () {
    testWidgets('like fills over ~180 ms and pops, then settles', (
      tester,
    ) async {
      await pumpThemed(tester, _bar(), size: const Size(390, 400));
      expect(paintedFill(tester, DzIcons.like), 0);
      expect(_icon(tester, findDz(DzIcons.like)).width, closeTo(19, 0.01));

      await pumpThemedUpdate(tester, _bar(liked: true));
      expect(dzIconOf(tester, DzIcons.like).fill, 1, reason: 'the target');
      await tester.pump(const Duration(milliseconds: 60));
      expect(paintedFill(tester, DzIcons.like), inExclusiveRange(0, 1));
      // Mid-pop the glyph is bigger than its resting size.
      expect(_icon(tester, findDz(DzIcons.like)).width, greaterThan(19.5));

      await tester.pump(const Duration(milliseconds: 200));
      expect(paintedFill(tester, DzIcons.like), 1);
      expect(_icon(tester, findDz(DzIcons.like)).width, closeTo(19, 0.01));
    });

    testWidgets('unliking fades the fill out without a pop', (tester) async {
      await pumpThemed(tester, _bar(liked: true), size: const Size(390, 400));
      expect(paintedFill(tester, DzIcons.like), 1);
      await pumpThemedUpdate(tester, _bar());
      await tester.pump(const Duration(milliseconds: 60));
      expect(paintedFill(tester, DzIcons.like), inExclusiveRange(0, 1));
      expect(_icon(tester, findDz(DzIcons.like)).width, closeTo(19, 0.01));
      await tester.pump(const Duration(milliseconds: 200));
      expect(paintedFill(tester, DzIcons.like), 0);
    });

    testWidgets('reduce motion: the end state at once, no pop', (tester) async {
      await pumpThemed(
        tester,
        _bar(),
        size: const Size(390, 400),
        disableAnimations: true,
      );
      await pumpThemedUpdate(
        tester,
        _bar(liked: true),
        disableAnimations: true,
      );
      await tester.pump();
      expect(paintedFill(tester, DzIcons.like), 1);
      expect(_icon(tester, findDz(DzIcons.like)).width, closeTo(19, 0.01));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('the first build shows its state without animating', (
      tester,
    ) async {
      await pumpThemed(tester, _bar(liked: true, bookmarked: true));
      expect(paintedFill(tester, DzIcons.like), 1);
      expect(paintedFill(tester, DzIcons.save), 1);
    });

    testWidgets('pressing shrinks the glyph, releasing restores it', (
      tester,
    ) async {
      await pumpThemed(tester, _bar(), size: const Size(390, 400));
      final gesture = await tester.startGesture(
        tester.getCenter(findDz(DzIcons.like)),
      );
      await tester.pump(const Duration(milliseconds: 120));
      double scale() => tester
          .widget<AnimatedScale>(
            find
                .ancestor(
                  of: findDz(DzIcons.like),
                  matching: find.byType(AnimatedScale),
                )
                .first,
          )
          .scale;
      expect(scale(), lessThan(0.95));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(scale(), 1);
    });

    testWidgets('the like count keeps its slot when it grows a digit', (
      tester,
    ) async {
      await pumpThemed(tester, _bar(likes: 9), size: const Size(390, 400));
      final saveBefore = tester.getRect(findDz(DzIcons.save));
      await pumpThemedUpdate(tester, _bar(likes: 10));
      await tester.pumpAndSettle();
      // Save and share are pinned to the trailing edge, so they never move.
      expect(tester.getRect(findDz(DzIcons.save)), saveBefore);
    });
  });

  group('callbacks and missing actions', () {
    testWidgets('each button fires its callback once', (tester) async {
      final fired = <String>[];
      await pumpThemed(
        tester,
        _bar(
          actions: PostActions(
            onReply: () => fired.add('reply'),
            onRepost: () => fired.add('repost'),
            onLike: () => fired.add('like'),
            onBookmark: () => fired.add('save'),
            onShare: () => fired.add('share'),
          ),
        ),
        size: const Size(390, 400),
      );
      for (final icon in dzActionIcons) {
        await tester.tap(findDz(icon));
      }
      expect(fired, ['reply', 'repost', 'like', 'save', 'share']);
    });

    testWidgets('no bookmark callback, no save', (tester) async {
      await pumpThemed(
        tester,
        _bar(
          actions: PostActions(onLike: () {}, onShare: () {}),
        ),
        size: const Size(390, 400),
      );
      expect(findDz(DzIcons.save), findsNothing);
      expect(findDz(DzIcons.like), findsOneWidget);
    });
  });
}

/// Replaces the pumped widget in place (keeps the theme and media), so a
/// state change animates instead of rebuilding from scratch.
Future<void> pumpThemedUpdate(
  WidgetTester tester,
  Widget child, {
  bool disableAnimations = false,
}) async {
  final media = MediaQueryData(
    size: tester.view.physicalSize,
    textScaler: TextScaler.noScaling,
    disableAnimations: disableAnimations,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness: Brightness.light),
      home: MediaQuery(
        data: media,
        child: Scaffold(body: child),
      ),
    ),
  );
}
