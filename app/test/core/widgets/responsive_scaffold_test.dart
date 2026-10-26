import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

const _destinations = [
  AppNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
  ),
  AppNavDestination(
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    label: 'Profile',
  ),
];

const _bodyKey = Key('body');
const _sideKey = Key('side');

Widget _scaffold({
  int? selected = 0,
  ValueChanged<int>? onSelected,
  VoidCallback? onCompose,
  bool showFab = true,
  Widget? drawer,
  Widget? side,
  Widget Function(bool extended)? chip,
  Widget? body,
}) => ResponsiveScaffold(
  selectedIndex: selected,
  onDestinationSelected: onSelected ?? (_) {},
  destinations: _destinations,
  onCompose: onCompose,
  showFab: showFab,
  drawer: drawer,
  sideColumn: side,
  accountChipBuilder: chip,
  body: body ?? const SizedBox.expand(key: _bodyKey),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  double height = 800,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => pumpThemed(
  tester,
  child,
  size: Size(width, height),
  brightness: brightness,
  textScale: textScale,
  useScaffold: false,
);

void main() {
  group('narrow (< 600dp)', () {
    testWidgets('shows the bottom bar and no rail', (tester) async {
      await _pump(tester, _scaffold());

      expect(find.byType(AppBottomBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expectSize(tester, find.byType(AppBottomBar), height: AppSize.bottomNav);
      // The page body gets the full width.
      expectSize(tester, find.byKey(_bodyKey), width: 360);
    });

    testWidgets('the selected cell shows the filled glyph, the others the '
        'outline; there are no labels', (tester) async {
      await _pump(tester, _scaffold(selected: 1));

      expect(find.byIcon(Icons.notifications), findsOneWidget);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    });

    testWidgets('with no selection every glyph is the outline one', (
      tester,
    ) async {
      await _pump(tester, _scaffold(selected: null));

      expect(find.byIcon(Icons.home), findsNothing);
      expect(find.byIcon(Icons.notifications), findsNothing);
      expect(find.byIcon(Icons.person), findsNothing);
    });

    testWidgets('cells are equal width and report their index', (tester) async {
      int? picked;
      await _pump(tester, _scaffold(onSelected: (i) => picked = i));

      final xs = [
        for (final i in [
          Icons.home,
          Icons.notifications_none,
          Icons.person_outline,
        ])
          tester.getCenter(find.byIcon(i)).dx,
      ];
      expect(xs[1] - xs[0], closeTo(120, 1));
      expect(xs[2] - xs[1], closeTo(120, 1));

      await tester.tap(find.byIcon(Icons.person_outline));
      expect(picked, 2);
    });

    testWidgets('cells are announced as a selected / unselected group', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _scaffold(selected: 0));

      expect(
        tester.getSemantics(find.byIcon(Icons.home)),
        isSemantics(
          label: 'Home',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a notification badge is drawn on its cell', (tester) async {
      await _pump(
        tester,
        ResponsiveScaffold(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          destinations: const [
            AppNavDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home,
              label: 'Home',
              badgeLabel: '3',
              badgeSemanticLabel: '3 unread',
            ),
          ],
          body: const SizedBox.expand(),
        ),
      );

      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('the compose button shows when onCompose is set and showFab '
        'is true', (tester) async {
      var composed = 0;
      await _pump(tester, _scaffold(onCompose: () => composed++));

      expect(find.byType(FloatingActionButton), findsOneWidget);
      await tester.tap(find.byTooltip('New post'));
      expect(composed, 1);
    });

    testWidgets('no compose button when showFab is false or onCompose is '
        'null', (tester) async {
      await _pump(tester, _scaffold(onCompose: () {}, showFab: false));
      expect(find.byType(FloatingActionButton), findsNothing);

      await _pump(tester, _scaffold());
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('the FAB is the accent colour', (tester) async {
      await _pump(tester, _scaffold(onCompose: () {}));

      final fab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(fab.tooltip, 'New post');
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(FloatingActionButton),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, const Color(0xFF1D9BF0));
    });

    testWidgets('a scope opens the drawer; without a drawer there is no '
        'scope', (tester) async {
      await _pump(
        tester,
        _scaffold(
          drawer: const Drawer(child: Text('drawer content')),
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: AppShellScope.maybeOf(context)!.openDrawer,
              child: const Text('open'),
            ),
          ),
        ),
      );
      expect(find.text('drawer content'), findsNothing);

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.text('drawer content'), findsOneWidget);

      await _pump(
        tester,
        _scaffold(
          body: Builder(
            builder: (context) {
              expect(AppShellScope.maybeOf(context), isNull);
              return const SizedBox.expand();
            },
          ),
        ),
      );
    });

    testWidgets('the side column never shows on a phone', (tester) async {
      await _pump(
        tester,
        _scaffold(side: const SizedBox(key: _sideKey, height: 10)),
      );

      expect(find.byKey(_sideKey), findsNothing);
    });
  });

  group('tablet (600-1199dp): icon rail', () {
    testWidgets('shows an icon-only rail, the round compose button and the '
        'avatar chip, and no bottom bar', (tester) async {
      final extendedSeen = <bool>[];
      await _pump(
        tester,
        _scaffold(
          onCompose: () {},
          chip: (extended) {
            extendedSeen.add(extended);
            return const SizedBox(key: Key('chip'), width: 40, height: 40);
          },
        ),
        width: 800,
      );

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isFalse);
      expect(find.byType(AppBottomBar), findsNothing);
      expect(find.byKey(const Key('chip')), findsOneWidget);
      expect(extendedSeen.every((e) => e == false), isTrue);
      expectSize(
        tester,
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byType(FilledButton),
        ),
        width: AppSize.railPostHeight,
        height: AppSize.railPostHeight,
      );
      expect(find.byTooltip('New post'), findsOneWidget);
    });

    testWidgets('the content column is 600dp wide and the cluster is '
        'centred', (tester) async {
      await _pump(tester, _scaffold(), width: 1000);

      expectSize(tester, find.byKey(_bodyKey), width: AppSize.contentMax);
      // Rail on the left of the column; the cluster sits in the middle.
      final rail = tester.getRect(find.byType(NavigationRail));
      final body = tester.getRect(find.byKey(_bodyKey));
      final left = rail.left;
      final right = 1000 - body.right;
      expect((left - right).abs(), lessThan(2));
    });

    testWidgets('the side column stays hidden below 1200dp', (tester) async {
      await _pump(
        tester,
        _scaffold(side: const SizedBox(key: _sideKey, height: 10)),
        width: 1100,
      );

      expect(find.byKey(_sideKey), findsNothing);
    });

    testWidgets('on a 600dp tablet the content takes what the rail leaves', (
      tester,
    ) async {
      await _pump(tester, _scaffold(), width: 600);

      final rail = tester.getRect(find.byType(NavigationRail));
      expectSize(tester, find.byKey(_bodyKey), width: 600 - rail.width);
    });
  });

  group('desktop (>= 1200dp): extended rail', () {
    testWidgets('1200dp is already the extended layout', (tester) async {
      await _pump(tester, _scaffold(onCompose: () {}), width: 1200);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isTrue);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('the Post pill is 233 x 52dp and starts a post', (
      tester,
    ) async {
      var composed = 0;
      await _pump(tester, _scaffold(onCompose: () => composed++), width: 1400);

      final pill = find.widgetWithText(FilledButton, 'Post');
      expectSize(
        tester,
        pill,
        width: AppSize.railPostWidth,
        height: AppSize.railPostHeight,
      );
      await tester.tap(pill);
      expect(composed, 1);
    });

    testWidgets('the Post pill is the strong inverse pill in both themes', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        await _pump(
          tester,
          _scaffold(onCompose: () {}),
          width: 1400,
          brightness: brightness,
        );
        final colors = brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light;
        final style = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
            .style!;
        expect(style.fixedSize!.resolve({}), const Size(233, 52));
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.widgetWithText(FilledButton, 'Post'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, colors.strongPillFill);
      }
    });

    testWidgets('no compose control without onCompose', (tester) async {
      await _pump(tester, _scaffold(), width: 1400);

      expect(find.widgetWithText(FilledButton, 'Post'), findsNothing);
      expect(find.byTooltip('New post'), findsNothing);
    });

    testWidgets('the content column is 600dp between two hairlines', (
      tester,
    ) async {
      await _pump(tester, _scaffold(), width: 1600);

      expectSize(tester, find.byKey(_bodyKey), width: AppSize.contentMax);
      final box = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.byKey(_bodyKey),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final border = (box.decoration as BoxDecoration).border! as Border;
      expect(border.left.color, appLightTheme.colorScheme.outlineVariant);
      expect(border.right.color, appLightTheme.colorScheme.outlineVariant);
    });

    testWidgets('the 350dp side column shows when a screen provides one', (
      tester,
    ) async {
      await _pump(
        tester,
        _scaffold(side: const SizedBox(key: _sideKey, height: 10)),
        width: 1600,
      );

      expectSize(tester, find.byKey(_sideKey), width: AppSize.sideColumn);
      // The column is 24dp to the right of the content.
      expectHorizontalGap(
        tester,
        find.byKey(_bodyKey),
        find.byKey(_sideKey),
        AppSpacing.lg + 1,
      );
    });

    testWidgets('without a side column the content stays capped and centred', (
      tester,
    ) async {
      await _pump(tester, _scaffold(), width: 1600);

      expectSize(tester, find.byKey(_bodyKey), width: AppSize.contentMax);
    });

    testWidgets('the account chip is built extended and sits at the bottom of '
        'the rail', (tester) async {
      final seen = <bool>[];
      await _pump(
        tester,
        _scaffold(
          chip: (extended) {
            seen.add(extended);
            return const SizedBox(key: Key('chip'), width: 200, height: 56);
          },
        ),
        width: 1400,
      );

      expect(seen.last, isTrue);
      final chip = tester.getRect(find.byKey(const Key('chip')));
      final rail = tester.getRect(find.byType(NavigationRail));
      expect(chip.bottom, greaterThan(rail.bottom - 24));
    });

    testWidgets('with no selection no rail destination is selected', (
      tester,
    ) async {
      await _pump(tester, _scaffold(selected: null), width: 1400);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, isNull);
    });

    testWidgets('selected rail destinations are bold 20dp labels', (
      tester,
    ) async {
      await _pump(tester, _scaffold(selected: 1), width: 1400);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 1);
      final theme = appLightTheme.navigationRailTheme;
      expect(theme.selectedLabelTextStyle!.fontWeight, FontWeight.w700);
      expect(theme.selectedLabelTextStyle!.fontSize, 20);
      expect(theme.unselectedLabelTextStyle!.fontWeight, FontWeight.w400);
    });
  });

  group('rail-only destinations (History, W2-7)', () {
    const withBookmarks = [
      AppNavDestination(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Home',
      ),
      AppNavDestination(
        icon: Icons.bookmark_border,
        selectedIcon: Icons.bookmark,
        label: 'History',
        railOnly: true,
      ),
      AppNavDestination(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: 'Profile',
      ),
    ];

    Widget scaffold({int? selected, ValueChanged<int>? onSelected}) =>
        ResponsiveScaffold(
          selectedIndex: selected,
          onDestinationSelected: onSelected ?? (_) {},
          destinations: withBookmarks,
          body: const SizedBox.expand(),
        );

    testWidgets('the phone bar leaves it out; indexes map to the full list', (
      tester,
    ) async {
      int? picked;
      await _pump(tester, scaffold(selected: 2, onSelected: (i) => picked = i));

      expect(find.byIcon(Icons.bookmark_border), findsNothing);
      // Profile (index 2 of 3) is the second cell and shows selected.
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.person));
      expect(picked, 2);
      await tester.tap(find.byIcon(Icons.home_outlined));
      expect(picked, 0);
    });

    testWidgets('selecting it selects no cell of the phone bar', (
      tester,
    ) async {
      await _pump(tester, scaffold(selected: 1));

      expect(find.byIcon(Icons.home), findsNothing);
      expect(find.byIcon(Icons.person), findsNothing);
      expect(find.byIcon(Icons.bookmark), findsNothing);
    });

    for (final width in [600.0, 1200.0]) {
      testWidgets('the ${width.toInt()}dp rail shows it, selected, and reports '
          'its index', (tester) async {
        int? picked;
        await _pump(
          tester,
          scaffold(selected: 1, onSelected: (i) => picked = i),
          width: width,
        );

        expect(find.byType(AppBottomBar), findsNothing);
        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        expect(rail.destinations, hasLength(3));
        expect(rail.selectedIndex, 1);
        expect(find.byIcon(Icons.bookmark), findsOneWidget);

        await tester.tap(find.byIcon(Icons.person_outline));
        expect(picked, 2);
      });
    }
  });

  forEachThemeAndWidth('does not overflow at any theme, width or text scale', (
    tester,
    env,
  ) async {
    await _pump(
      tester,
      _scaffold(
        onCompose: () {},
        side: const SizedBox(height: 100),
        chip: (extended) => const SizedBox(width: 56, height: 56),
        drawer: const Drawer(),
      ),
      width: env.size.width,
      brightness: env.brightness,
      textScale: env.textScale,
    );

    expectNoOverflow(tester);
  });
}
