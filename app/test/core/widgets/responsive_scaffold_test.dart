import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contrast.dart';
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
  bool redesignedRail = false,
  List<AppNavDestination> destinations = _destinations,
}) => ResponsiveScaffold(
  selectedIndex: selected,
  onDestinationSelected: onSelected ?? (_) {},
  destinations: destinations,
  onCompose: onCompose,
  showFab: showFab,
  redesignedRail: redesignedRail,
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
      expect(material.color, AppPalette.tealText);
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

    // PR 1.5: rail labels are labelMedium (14 sp) until the phase 3 rail
    // restyle; weight, not colour alone, marks the selected one.
    testWidgets('selected rail destinations are bold 14dp labels', (
      tester,
    ) async {
      await _pump(tester, _scaffold(selected: 1), width: 1400);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 1);
      final theme = appLightTheme.navigationRailTheme;
      expect(theme.selectedLabelTextStyle!.fontWeight, FontWeight.w700);
      expect(theme.selectedLabelTextStyle!.fontSize, 14);
      expect(theme.unselectedLabelTextStyle!.fontWeight, FontWeight.w600);
    });
  });

  group('destination groups (ADR-0034)', () {
    test('railOnly follows the group; the tooltip defaults to the label', () {
      const primary = AppNavDestination(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Home',
      );
      const secondary = AppNavDestination(
        icon: Icons.groups_outlined,
        selectedIcon: Icons.groups,
        label: 'Communities',
        group: AppNavGroup.secondary,
        tooltip: 'Your communities',
      );
      expect(primary.group, AppNavGroup.primary);
      expect(primary.railOnly, isFalse);
      expect(primary.tooltipText, 'Home');
      expect(secondary.railOnly, isTrue);
      expect(secondary.tooltipText, 'Your communities');
    });

    testWidgets('the bar keeps the primaries in list order and maps taps '
        'back to the full list', (tester) async {
      const destinations = [
        AppNavDestination(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          label: 'Home',
        ),
        AppNavDestination(
          icon: Icons.event_outlined,
          selectedIcon: Icons.event,
          label: 'Plans',
        ),
        AppNavDestination(
          icon: Icons.list_alt_outlined,
          selectedIcon: Icons.list_alt,
          label: 'Lists',
          group: AppNavGroup.secondary,
        ),
        AppNavDestination(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: 'Profile',
          group: AppNavGroup.secondary,
        ),
      ];
      final taps = <int>[];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ResponsiveScaffold(
            selectedIndex: 3,
            onDestinationSelected: taps.add,
            destinations: destinations,
            body: const SizedBox.expand(),
          ),
        ),
      );

      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
      expect(find.byIcon(Icons.event_outlined), findsOneWidget);
      expect(find.byIcon(Icons.list_alt_outlined), findsNothing);
      expect(find.byIcon(Icons.person_outline), findsNothing);
      // A secondary destination is selected: no bar cell is.
      expect(find.byIcon(Icons.event), findsNothing);

      await tester.tap(find.byIcon(Icons.event_outlined));
      expect(taps, [1]);
    });
  });

  group('destination groups (ADR-0034)', () {
    test('railOnly follows the group; the tooltip defaults to the label', () {
      const primary = AppNavDestination(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Home',
      );
      const secondary = AppNavDestination(
        icon: Icons.groups_outlined,
        selectedIcon: Icons.groups,
        label: 'Communities',
        group: AppNavGroup.secondary,
        tooltip: 'Your communities',
      );
      expect(primary.group, AppNavGroup.primary);
      expect(primary.railOnly, isFalse);
      expect(primary.tooltipText, 'Home');
      expect(secondary.railOnly, isTrue);
      expect(secondary.tooltipText, 'Your communities');
    });

    testWidgets('the bar keeps the primaries in list order and maps taps '
        'back to the full list', (tester) async {
      const destinations = [
        AppNavDestination(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          label: 'Home',
        ),
        AppNavDestination(
          icon: Icons.event_outlined,
          selectedIcon: Icons.event,
          label: 'Plans',
        ),
        AppNavDestination(
          icon: Icons.list_alt_outlined,
          selectedIcon: Icons.list_alt,
          label: 'Lists',
          group: AppNavGroup.secondary,
        ),
        AppNavDestination(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: 'Profile',
          group: AppNavGroup.secondary,
        ),
      ];
      final taps = <int>[];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ResponsiveScaffold(
            selectedIndex: 3,
            onDestinationSelected: taps.add,
            destinations: destinations,
            body: const SizedBox.expand(),
          ),
        ),
      );

      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
      expect(find.byIcon(Icons.event_outlined), findsOneWidget);
      expect(find.byIcon(Icons.list_alt_outlined), findsNothing);
      expect(find.byIcon(Icons.person_outline), findsNothing);
      // A secondary destination is selected: no bar cell is.
      expect(find.byIcon(Icons.event), findsNothing);

      await tester.tap(find.byIcon(Icons.event_outlined));
      expect(taps, [1]);
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
        group: AppNavGroup.secondary,
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

  group('rail style (PR 3.5, 600dp and up)', () {
    // The new shell's full rail: the five primaries, then the secondaries.
    const shell = [
      AppNavDestination(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Home',
      ),
      AppNavDestination(
        icon: Icons.search,
        selectedIcon: Icons.manage_search,
        label: 'Explore',
      ),
      AppNavDestination(
        icon: Icons.event_outlined,
        selectedIcon: Icons.event,
        label: 'Plans',
      ),
      AppNavDestination(
        icon: Icons.notifications_none,
        selectedIcon: Icons.notifications,
        label: 'Notifications',
      ),
      AppNavDestination(
        icon: Icons.mail_outline,
        selectedIcon: Icons.mail,
        label: 'Messages',
      ),
      AppNavDestination(
        icon: Icons.list_alt_outlined,
        selectedIcon: Icons.list_alt,
        label: 'Lists',
        group: AppNavGroup.secondary,
      ),
      AppNavDestination(
        icon: Icons.groups_outlined,
        selectedIcon: Icons.groups,
        label: 'Communities',
        group: AppNavGroup.secondary,
      ),
      AppNavDestination(
        icon: Icons.bookmark_border,
        selectedIcon: Icons.bookmark,
        label: 'History',
        group: AppNavGroup.secondary,
      ),
      AppNavDestination(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: 'Profile',
        group: AppNavGroup.secondary,
      ),
      AppNavDestination(
        icon: Icons.more_horiz,
        selectedIcon: Icons.more_horiz,
        label: 'More',
        group: AppNavGroup.secondary,
      ),
    ];

    NavigationRail rail(WidgetTester tester) =>
        tester.widget<NavigationRail>(find.byType(NavigationRail));
    Finder inRail(Finder f) =>
        find.descendant(of: find.byType(NavigationRail), matching: f);
    // The colour and style a text or glyph is painted with.
    TextStyle painted(WidgetTester tester, Finder f) => tester
        .widget<RichText>(
          find.descendant(of: f, matching: find.byType(RichText)).first,
        )
        .text
        .style!;
    AppColors colorsOf(Brightness b) =>
        b == Brightness.dark ? AppColors.dark : AppColors.light;
    ThemeData themeOf(Brightness b) => buildAppTheme(brightness: b);

    for (final width in [834.0, 1440.0]) {
      final desktop = width >= AppBreakpoints.tablet;
      final w = '${width.toInt()}dp';

      for (final brightness in Brightness.values) {
        final b = brightness.name;

        testWidgets('$w $b: the indicator is a selectedIndicator pill behind '
            'the filled glyph; labels w800 / w600 text2', (tester) async {
          await _pump(
            tester,
            _scaffold(selected: 3, destinations: shell, redesignedRail: true),
            width: width,
            height: 1000,
            brightness: brightness,
          );
          final colors = colorsOf(brightness);
          final scheme = themeOf(brightness).colorScheme;
          final r = rail(tester);

          expect(r.indicatorShape, const StadiumBorder());
          expect(r.indicatorColor, colors.selectedIndicator);
          expect(r.selectedIconTheme!.color, scheme.onPrimary);
          expect(r.unselectedIconTheme!.color, colors.text2);
          expect(r.selectedLabelTextStyle!.fontWeight, FontWeight.w800);
          expect(r.selectedLabelTextStyle!.color, scheme.onSurface);
          expect(r.unselectedLabelTextStyle!.fontWeight, FontWeight.w600);
          expect(r.unselectedLabelTextStyle!.color, colors.text2);
          // Weight, never `fontVariations` (the engine maps the axis).
          expect(r.selectedLabelTextStyle!.fontVariations, isNull);

          // The selected glyph is the filled one, painted in the pill's ink.
          expect(inRail(find.byIcon(Icons.notifications)), findsOneWidget);
          expect(inRail(find.byIcon(Icons.notifications_none)), findsNothing);
          expect(
            painted(tester, inRail(find.byIcon(Icons.notifications))).color,
            scheme.onPrimary,
          );
          expect(
            painted(tester, inRail(find.byIcon(Icons.home_outlined))).color,
            colors.text2,
          );
          // Contrast pairs: glyph on the pill, labels and glyphs on the page.
          expect(
            contrast(scheme.onPrimary, colors.selectedIndicator),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(colors.text2, scheme.surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(scheme.onSurface, scheme.surface),
            greaterThanOrEqualTo(4.5),
          );

          if (desktop) {
            // The labels as painted on the extended rail.
            final selected = painted(
              tester,
              inRail(find.text('Notifications')),
            );
            expect(selected.fontWeight, FontWeight.w800);
            expect(selected.color, scheme.onSurface);
            final other = painted(tester, inRail(find.text('Home')));
            expect(other.fontWeight, FontWeight.w600);
            expect(other.color, colors.text2);
          }
        });

        testWidgets('$w $b: the compose control is the gradient primary with '
            'a navy label that reads on both gradient stops', (tester) async {
          var composed = 0;
          await _pump(
            tester,
            _scaffold(
              onCompose: () => composed++,
              destinations: shell,
              redesignedRail: true,
            ),
            width: width,
            height: 1000,
            brightness: brightness,
          );
          final colors = colorsOf(brightness);

          final Color label;
          if (desktop) {
            final pill = find.widgetWithText(AppPillButton, 'Post');
            expect(pill, findsOneWidget);
            expectSize(
              tester,
              pill,
              width: AppSize.railPostWidth,
              height: AppSize.railPostHeight,
            );
            final ink = tester.widget<Ink>(
              find.descendant(of: pill, matching: find.byType(Ink)),
            );
            final box = ink.decoration! as BoxDecoration;
            expect(box.gradient, colors.primaryFillGradient);
            expect(box.gradient, AppGradients.primaryButton);
            expect(box.boxShadow, AppShadows.primaryGlow);
            label = painted(tester, find.text('Post')).color!;
            // The legacy strong pill is gone.
            expect(find.widgetWithText(FilledButton, 'Post'), findsNothing);
          } else {
            final glyph = inRail(find.byIcon(Icons.edit_outlined));
            final fill = tester.widget<DecoratedBox>(
              find.ancestor(
                of: glyph,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is DecoratedBox &&
                      w.decoration is ShapeDecoration &&
                      (w.decoration as ShapeDecoration).gradient != null,
                ),
              ),
            );
            final shape = fill.decoration as ShapeDecoration;
            expect(shape.shape, const CircleBorder());
            expect(shape.gradient, colors.primaryFillGradient);
            expect(shape.shadows, AppShadows.primaryGlow);
            expectSize(
              tester,
              find.byWidget(fill),
              width: AppSize.railPostHeight,
              height: AppSize.railPostHeight,
            );
            label = painted(tester, glyph).color!;
          }
          expect(label, colors.primaryFillLabel);
          for (final stop in colors.primaryFillGradient.colors) {
            expect(
              contrast(label, stop),
              greaterThanOrEqualTo(4.5),
              reason: 'label on $stop',
            );
          }

          await tester.tap(find.byTooltip('New post'));
          expect(composed, 1);
        });
      }

      testWidgets('$w: the primaries, then the secondaries, in list order; no '
          'divider until T1', (tester) async {
        // No selection: every glyph is the outline one.
        await _pump(
          tester,
          _scaffold(selected: null, destinations: shell, redesignedRail: true),
          width: width,
          height: 1000,
        );

        final r = rail(tester);
        expect(r.destinations, hasLength(shell.length));
        // Every primary sits before every secondary.
        final groups = [for (final d in shell) d.group];
        expect(groups.take(5), everyElement(AppNavGroup.primary));
        expect(groups.skip(5), everyElement(AppNavGroup.secondary));
        final ys = [
          for (final d in shell)
            tester.getCenter(inRail(find.byIcon(d.icon))).dy,
        ];
        for (var i = 1; i < ys.length; i++) {
          expect(ys[i], greaterThan(ys[i - 1]), reason: shell[i].label);
        }
        // Ruling: `NavigationRail.leading`/`trailing` sit above or below all
        // the items, so the group divider waits for T1's `AppNavRail`.
        expect(inRail(find.byType(Divider)), findsNothing);
      });

      testWidgets('$w: the selected destination is announced as selected', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          _scaffold(selected: 3, destinations: shell, redesignedRail: true),
          width: width,
          height: 1000,
        );

        expect(
          tester.getSemantics(inRail(find.byIcon(Icons.notifications))),
          isSemantics(isSelected: true, hasSelectedState: true),
        );
        expect(
          tester.getSemantics(inRail(find.byIcon(Icons.home_outlined))),
          isSemantics(isSelected: false, hasSelectedState: true),
        );
        handle.dispose();
      });

      testWidgets('$w: legacy rail (ui_shell off) keeps the theme and the '
          'strong pill', (tester) async {
        await _pump(
          tester,
          _scaffold(onCompose: () {}, destinations: shell),
          width: width,
          height: 1000,
        );

        final r = rail(tester);
        expect(r.indicatorShape, isNull);
        expect(r.indicatorColor, isNull);
        expect(r.selectedIconTheme, isNull);
        expect(r.unselectedIconTheme, isNull);
        expect(r.selectedLabelTextStyle, isNull);
        expect(r.unselectedLabelTextStyle, isNull);
        expect(find.byType(AppPillButton), findsNothing);
        final button = inRail(find.byType(FilledButton));
        expect(button, findsOneWidget);
        final material = tester.widget<Material>(
          find.descendant(of: button, matching: find.byType(Material)).first,
        );
        expect(material.color, AppColors.light.strongPillFill);
      });
    }

    for (final redesigned in [true, false]) {
      final mode = redesigned ? 'ui_shell on' : 'ui_shell off';
      void matrix(
        List<double> widths,
        List<double> scales, {
        Map<double, double>? heights,
        required String set,
      }) => forEachThemeAndWidth(
        '$mode ($set): no overflow and 48dp compose targets',
        (tester, env) async {
          await _pump(
            tester,
            _scaffold(
              onCompose: () {},
              destinations: shell,
              redesignedRail: redesigned,
              side: const SizedBox(height: 100),
              chip: (extended) => const SizedBox(width: 56, height: 56),
              drawer: const Drawer(),
            ),
            width: env.size.width,
            height: env.size.height,
            brightness: env.brightness,
            textScale: env.textScale,
          );

          expectNoOverflow(tester);
          if (env.size.width >= AppBreakpoints.mobile) {
            final target = tester.getSize(inRail(find.byTooltip('New post')));
            expect(target.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
            expect(
              target.height,
              greaterThanOrEqualTo(AppSpacing.minTapTarget),
            );
          }
        },
        widths: widths,
        textScales: scales,
        heights: heights,
      );

      matrix(
        kRedesignWidths,
        kRedesignTextScales,
        heights: kRedesignHeights,
        set: 'redesign widths',
      );
      matrix(kMatrixWidths, kRedesignTextScales, set: 'boundaries');
    }
  });
}
