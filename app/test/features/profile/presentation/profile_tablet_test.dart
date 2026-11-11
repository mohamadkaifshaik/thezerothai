import 'dart:async';

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/features/graph/presentation/graph_list_screen.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_media_strip.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/context_pane_rig.dart'
    show expectTabletPanes, findContextPane, inContextPane;
import '../../../support/profile_tablet_rig.dart';
import '../../../support/theme_harness.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];

bool _tabletFlags(Set<String> flags) =>
    flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);

bool _bandB(double w) =>
    w >= AppBreakpoints.expanded && w < AppBreakpoints.tablet;

List<ContextSectionKind> _paneKinds(WidgetTester tester) {
  final pane = findContextPane();
  if (pane.evaluate().isEmpty) return const [];
  return [for (final s in tester.widget<ContextPane>(pane).sections) s.kind];
}

const _profilePane = [
  ContextSectionKind.profileMedia,
  ContextSectionKind.whoToFollow,
  ContextSectionKind.links,
];

const _global = [
  ContextSectionKind.search,
  ContextSectionKind.profile,
  ContextSectionKind.trends,
  ContextSectionKind.whoToFollow,
  ContextSectionKind.links,
];

/// The media tiles in the pane (their keys start with `profile-media-`).
Finder _paneTiles() => inContextPane(
  find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('profile-media-'),
  ),
);

/// The labels of the page's tab bar, and the selected one.
(List<String>, String) _tabs(WidgetTester tester) {
  final bar = tester.widget<AppTabBar>(inProfilePage(find.byType(AppTabBar)));
  final labels = [for (final t in bar.tabs) t.label];
  return (labels, labels[bar.selectedIndex]);
}

const _allTabs = ['Posts', 'Reposts', 'Media', 'Articles'];

void main() {
  group('Profile: flag modes x widths', () {
    for (final MapEntry(key: mode, value: flags) in kProfileFlagModes.entries) {
      for (final w in _widths) {
        final pane = _tabletFlags(flags) && _bandB(w);
        testWidgets(
          '$mode at $w: tabs in the page; '
          '${pane ? 'Media strip + You might like in the pane' : 'no pane'}',
          (tester) async {
            final rig = ProfileTabletRig();
            await rig.pump(tester, width: w, flags: flags);
            expect(tester.takeException(), isNull);

            // Band A, phones and desktop: the Media tab is the media (F).
            expect(_tabs(tester).$1, _allTabs);
            if (pane) {
              expect(_paneKinds(tester), _profilePane);
              expect(
                inContextPane(find.text(kProfileMediaTitle)),
                findsOneWidget,
              );
              expect(_paneTiles(), findsNWidgets(4));
              expect(
                inContextPane(find.text('You might like')),
                findsOneWidget,
              );
              // One Media feed call: the page's own Media tab feed.
              expect(rig.count('feed:$kRigOwnId:media'), 1);
            } else {
              expect(findContextPane(), findsNothing);
              expect(find.byType(ProfileMediaStrip), findsNothing);
              // Nobody opened Media: no call for it.
              expect(rig.count('feed:$kRigOwnId:media'), 0);
            }
            expect(rig.count('feed:$kRigOwnId:posts'), 1);
            expect(rig.count('profile:'), 1);
            expect(
              find.byType(AppSideColumn),
              w >= AppBreakpoints.tablet ? findsOneWidget : findsNothing,
            );
          },
        );
      }
    }
  });

  group('Profile: pushed, held and hidden', () {
    testWidgets('pushed over Home at 1024: the placeholder after one pump, '
        'then the strip; the global set after pop', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, location: AppRouter.homePath);
      expect(_paneKinds(tester), _global);

      unawaited(rig.router.push(AppRouter.profileByIdPath(kRigOtherId)));
      await tester.pump();
      expect(_paneKinds(tester), _profilePane);
      // Never the footer alone: the Media card is there at once.
      expect(inContextPane(find.text(kProfileMediaTitle)), findsOneWidget);

      await tester.pumpAndSettle();
      expect(_paneTiles(), findsNWidgets(4));
      expect(rig.count('feed:$kRigOtherId:media'), 1);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(_paneKinds(tester), _global);
      expect(find.byType(ProfileMediaStrip), findsNothing);
    });

    testWidgets('a held GetProfile: the placeholder, then the strip', (
      tester,
    ) async {
      final rig = ProfileTabletRig()..holdProfile = Completer<void>();
      await rig.pump(
        tester,
        location: AppRouter.profilePath(kRigOtherHandle),
        settle: false,
      );
      expect(find.byType(ProfileMediaStripPlaceholder), findsOneWidget);
      expect(find.bySemanticsLabel('Loading media'), findsOneWidget);
      expect(rig.count('feed:'), 0);

      rig.holdProfile!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileMediaStripPlaceholder), findsNothing);
      expect(_paneTiles(), findsNWidgets(4));
    });

    testWidgets('a held Media feed: the placeholder, then the strip', (
      tester,
    ) async {
      final rig = ProfileTabletRig()..holdMedia = Completer<void>();
      await rig.pump(tester, settle: false);
      await tester.pump();
      expect(find.byType(ProfileMediaStripPlaceholder), findsOneWidget);
      rig.holdMedia!.complete();
      await tester.pumpAndSettle();
      expect(_paneTiles(), findsNWidgets(4));
    });

    final hidden = <String, void Function(ProfileTabletRig rig)>{
      'the profile failed': (rig) =>
          rig.profileError = const UnknownApiException('down'),
      'the profile is not found': (rig) =>
          rig.profileError = const NotFoundException('gone'),
      'the posts are protected': (rig) => rig.otherProtected = true,
      'the viewer blocks them': (rig) => rig.blocking = true,
      'no images': (rig) => rig.mediaPosts = 0,
      'the Media feed failed': (rig) =>
          rig.mediaError = const UnknownApiException('down'),
    };
    for (final MapEntry(key: name, value: arrange) in hidden.entries) {
      testWidgets('$name: no Media card in the pane, You might like stays', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        arrange(rig);
        await rig.pump(
          tester,
          location: AppRouter.profilePath(kRigOtherHandle),
        );
        expect(tester.takeException(), isNull);
        expect(_paneKinds(tester), _profilePane);
        expect(inContextPane(find.text(kProfileMediaTitle)), findsNothing);
        expect(find.byType(ProfileMediaStripPlaceholder), findsNothing);
        expect(inContextPane(find.text('You might like')), findsOneWidget);
        // Nothing asks for images that cannot be shown.
        if (name != 'no images' && name != 'the Media feed failed') {
          expect(rig.count('feed:$kRigOtherId:media'), 0);
        }
      });
    }

    testWidgets('blocked, then "Show posts": the strip appears', (
      tester,
    ) async {
      final rig = ProfileTabletRig()..blocking = true;
      await rig.pump(tester, location: AppRouter.profilePath(kRigOtherHandle));
      expect(inContextPane(find.text(kProfileMediaTitle)), findsNothing);

      await tester.tap(inProfilePage(find.text('Show posts')));
      await tester.pumpAndSettle();
      expect(_paneTiles(), findsNWidgets(4));
      expect(rig.count('feed:$kRigOtherId:media'), 1);
    });

    testWidgets('a FEATURE_DISABLED profile_tabs answer for the strip drops '
        'Reposts and Media from the page and the strip', (tester) async {
      final rig = ProfileTabletRig()
        ..mediaError = const FeatureDisabledException(
          'Not available.',
          feature: 'profile_tabs',
        );
      await rig.pump(tester);
      expect(inContextPane(find.text(kProfileMediaTitle)), findsNothing);
      expect(_tabs(tester).$1, ['Posts', 'Articles']);
      expect(_tabs(tester).$2, 'Posts');
    });

    for (final (flag, kinds) in [
      (
        'profile_tabs',
        [ContextSectionKind.whoToFollow, ContextSectionKind.links],
      ),
      ('posts', [ContextSectionKind.whoToFollow, ContextSectionKind.links]),
      (
        'follow_suggestions',
        [ContextSectionKind.profileMedia, ContextSectionKind.links],
      ),
    ]) {
      testWidgets('$flag off: only its own item goes', (tester) async {
        final rig = ProfileTabletRig();
        await rig.pump(tester, flags: {...kProfileTabletFlags}..remove(flag));
        expect(tester.takeException(), isNull);
        expect(_paneKinds(tester), kinds);
        final media = kinds.contains(ContextSectionKind.profileMedia);
        expect(
          inContextPane(find.text(kProfileMediaTitle)),
          media ? findsOneWidget : findsNothing,
        );
        expect(rig.count('feed:$kRigOwnId:media'), media ? 1 : 0);
        expect(
          inContextPane(find.text('You might like')),
          flag == 'follow_suggestions' ? findsNothing : findsOneWidget,
        );
      });
    }
  });

  group('Profile: the strip', () {
    testWidgets('at most 6 images, newest first, thumbnails only', (
      tester,
    ) async {
      final rig = ProfileTabletRig()
        ..mediaPosts = 5
        ..mediaImages = 2;
      await rig.pump(tester);
      expect(_paneTiles(), findsNWidgets(kProfileMediaStripMax));
      expect(
        inContextPane(find.byKey(const ValueKey('profile-media-m5-0'))),
        findsOneWidget,
      );
      expect(
        inContextPane(find.byKey(const ValueKey('profile-media-m3-1'))),
        findsOneWidget,
      );
      expect(
        inContextPane(find.byKey(const ValueKey('profile-media-m2-0'))),
        findsNothing,
      );
      final cache = rig.images;
      final strip = cache.requested.where((u) => u.contains('/p')).toList();
      expect(strip, isNotEmpty);
      expect(strip.every((u) => u.endsWith('-thumb.webp')), isTrue);
      expect(
        cache.requested.any(
          (u) => u.contains('-full.webp') && u.contains('/p'),
        ),
        isFalse,
      );
    });

    testWidgets('a tile opens the photo viewer at that image', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      await tester.tap(
        inContextPane(find.byKey(const ValueKey('profile-media-m3-0'))),
      );
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.postPhotoPath('m3', 1));
    });

    testWidgets('tiles are 48 dp or more and read their alt text', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 840);
      for (final tile in _paneTiles().evaluate()) {
        final size = tester.getSize(find.byWidget(tile.widget));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      expect(find.bySemanticsLabel('Open image, Photo 4'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('See all selects the Media tab, with no second call', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      expect(_tabs(tester).$2, 'Posts');
      final seeAll = inContextPane(find.text('See all'));
      expect(
        tester
            .getSize(
              find.ancestor(of: seeAll, matching: find.byType(TextButton)),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(seeAll);
      await tester.pumpAndSettle();
      expect(_tabs(tester).$2, 'Media');
      expect(rig.count('feed:$kRigOwnId:media'), 1);
      // Media is shown: See all would do nothing, so it goes.
      expect(inContextPane(find.text('See all')), findsNothing);
      expect(_paneTiles(), findsNWidgets(4));
      // The page's own tab bar still works afterwards, and See all is back.
      await tester.tap(inProfilePage(find.text('Posts')));
      await tester.pumpAndSettle();
      expect(_tabs(tester).$2, 'Posts');
      expect(inContextPane(find.text('See all')), findsOneWidget);
    });

    testWidgets('Media selected in the tab bar: no See all in the pane', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      await tester.tap(inProfilePage(find.text('Media')));
      await tester.pumpAndSettle();
      expect(inContextPane(find.text('See all')), findsNothing);
      await tester.tap(inProfilePage(find.text('Articles')));
      await tester.pumpAndSettle();
      expect(inContextPane(find.text('See all')), findsOneWidget);
    });

    testWidgets('the Media tab opened first: the strip reuses its feed', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 744);
      await tester.tap(inProfilePage(find.text('Media')));
      await tester.pumpAndSettle();
      expect(rig.count('feed:$kRigOwnId:media'), 1);
      await rig.resize(tester, 1024);
      expect(_paneTiles(), findsNWidgets(4));
      expect(rig.count('feed:$kRigOwnId:media'), 1);
    });
  });

  group('Profile: state across resizes', () {
    testWidgets('the same page, its tab and one call per feed across '
        '1024/839/840/1199/1200/599/600/1024', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      await tester.tap(inProfilePage(find.text('Reposts')));
      await tester.pumpAndSettle();
      final page = tester.state<NestedScrollViewState>(
        find.byType(NestedScrollView),
      );
      for (final w in <double>[839, 840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(_tabs(tester).$2, 'Reposts', reason: '$w');
        expect(
          find.byType(ProfileMediaStrip),
          _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      expect(
        tester.state<NestedScrollViewState>(find.byType(NestedScrollView)),
        same(page),
      );
      expect(rig.count('profile:'), 1);
      expect(rig.count('feed:$kRigOwnId:posts'), 1);
      expect(rig.count('feed:$kRigOwnId:reposts'), 1);
      expect(rig.count('feed:$kRigOwnId:media'), 1);
    });
  });

  group('Profile: layout', () {
    testWidgets('RTL at 1024: the pane, then the page, then the rail', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, textDirection: TextDirection.rtl);
      final pane = tester.getRect(findContextPane());
      final page = tester.getRect(find.byType(ProfileScreen));
      expect(pane.left, 0);
      expect(page.left, pane.right + 1);
      expect(page.right, 1024 - AppSize.railCompact);
      // The tiles read right to left: the newest image on the right.
      final newest = tester.getRect(
        inContextPane(find.byKey(const ValueKey('profile-media-m4-0'))),
      );
      final next = tester.getRect(
        inContextPane(find.byKey(const ValueKey('profile-media-m3-0'))),
      );
      expect(newest.left, greaterThan(next.left));
    });

    for (final brightness in Brightness.values) {
      for (final size in [const Size(840, 1194), const Size(1024, 768)]) {
        testWidgets('text scale 2.0 in the ${size.width.toInt()} window '
            '(${brightness.name}): no overflow, 48 dp targets', (tester) async {
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            width: size.width,
            height: size.height,
            textScale: 2,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          final see = find.ancestor(
            of: inContextPane(find.text('See all')),
            matching: find.byType(TextButton),
          );
          await tester.ensureVisible(see);
          await tester.pumpAndSettle();
          expect(tester.getSize(see).height, greaterThanOrEqualTo(48));
          for (final tile in _paneTiles().evaluate()) {
            expect(
              tester.getSize(find.byWidget(tile.widget)).shortestSide,
              greaterThanOrEqualTo(48),
            );
          }
          final paneRect = tester.getRect(findContextPane());
          for (final tile in _paneTiles().evaluate()) {
            final r = tester.getRect(find.byWidget(tile.widget));
            expect(r.left, greaterThanOrEqualTo(paneRect.left));
            expect(r.right, lessThanOrEqualTo(paneRect.right));
          }
        });
      }
    }

    forEachThemeAndWidth(
      'tablet matrix (section 5.5): profile',
      (tester, env) async {
        final width = env.size.width;
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: env.size.height,
          textScale: env.textScale,
          brightness: env.brightness,
        );
        expect(tester.takeException(), isNull);
        expectTabletPanes(tester, find.byType(ProfileScreen), width);
        if (_bandB(width)) {
          final pane = tester.getRect(findContextPane());
          final card = tester.getRect(
            find.ancestor(
              of: inContextPane(find.text(kProfileMediaTitle)),
              matching: find.byType(ProfileMediaStrip),
            ),
          );
          expect(card.left, greaterThanOrEqualTo(pane.left));
          expect(card.right, lessThanOrEqualTo(pane.right));
        }
      },
      widths: kTabletMatrixWidths,
      textScales: kTabletTextScales,
      heights: kTabletHeights,
    );

    for (final w in <double>[834, 1024]) {
      testWidgets('the header menu stays anchored at $w (section 4.2)', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: w,
          location: AppRouter.profilePath(kRigOtherHandle),
        );
        final more = inProfilePage(find.byType(PopupMenuButton<String>));
        await tester.tap(more.first);
        await tester.pumpAndSettle();
        expect(find.text('Mute'), findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        final menu = tester.getRect(
          find
              .ancestor(of: find.text('Mute'), matching: find.byType(Material))
              .first,
        );
        final trigger = tester.getRect(more.first);
        // Anchored at its button, inside the primary pane.
        expect((menu.top - trigger.top).abs(), lessThan(trigger.height + 8));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      });
    }
  });

  group('Profile: focus in the pane', () {
    testWidgets('Tab walks the tiles in reading order, then See all, then You '
        'might like', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      FocusNode tileNode(String id) => Focus.of(
        tester.element(
          find
              .descendant(
                of: inContextPane(find.byKey(ValueKey('profile-media-$id'))),
                matching: find.byType(Stack),
              )
              .first,
        ),
      );
      final order = [
        for (final n in [4, 3, 2, 1]) tileNode('m$n-0'),
      ];
      final seeAll = Focus.of(
        tester.element(inContextPane(find.text('See all'))),
      );
      order.first.requestFocus();
      await tester.pump();
      for (final next in [...order.skip(1), seeAll]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, next);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        focused.findAncestorWidgetOfExactType<WhoToFollowCard>(),
        isNotNull,
      );
    });
  });

  group('GraphList (Followers / Following)', () {
    for (final MapEntry(key: mode, value: flags) in kProfileFlagModes.entries) {
      for (final w in _widths) {
        final pane = _tabletFlags(flags) && _bandB(w);
        testWidgets('$mode at $w, pushed from the profile: '
            '${pane ? 'Who to follow in the pane' : 'no pane'}', (
          tester,
        ) async {
          final rig = ProfileTabletRig();
          await rig.pump(tester, width: w, flags: flags);
          await tester.tap(
            inProfilePage(find.bySemanticsLabel('12 Followers')),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(GraphListScreen), findsOneWidget);
          expect(rig.count('followers:$kRigOwnId'), 1);
          if (pane) {
            expect(_paneKinds(tester), [
              ContextSectionKind.whoToFollow,
              ContextSectionKind.links,
            ]);
            expect(inContextPane(find.text('Who to follow')), findsOneWidget);
            expect(inContextPane(find.text('You might like')), findsNothing);
            expect(find.byType(ProfileMediaStrip), findsNothing);
            expectTabletPanes(tester, find.byType(GraphListScreen), w);
          } else {
            expect(findContextPane(), findsNothing);
          }
        });
      }
    }

    testWidgets('band B: back on the profile its pane returns, '
        'with no second Media call', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      await tester.tap(inProfilePage(find.bySemanticsLabel('34 Following')));
      await tester.pumpAndSettle();
      expect(find.byType(WhoToFollowCard), findsOneWidget);
      expect(find.byType(ProfileMediaStrip), findsNothing);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(_paneKinds(tester), _profilePane);
      expect(_paneTiles(), findsNWidgets(4));
      expect(rig.count('feed:$kRigOwnId:media'), 1);
    });

    testWidgets('a typed /profile/:h/followers at 1024: Who to follow', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.followersPath(kRigOtherHandle),
      );
      expect(_paneKinds(tester), [
        ContextSectionKind.whoToFollow,
        ContextSectionKind.links,
      ]);
      expect(find.byType(AppSearchField), findsNothing);
    });

    testWidgets('follow_suggestions off: the pane holds the footer only', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.followersPath(kRigOtherHandle),
        flags: {...kProfileTabletFlags}..remove('follow_suggestions'),
      );
      expect(_paneKinds(tester), [ContextSectionKind.links]);
      expect(find.byType(WhoToFollowCard), findsNothing);
    });
  });
}
