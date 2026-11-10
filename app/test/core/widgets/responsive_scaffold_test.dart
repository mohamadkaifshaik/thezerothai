import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/shell_bottom_inset_sliver.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  group('floating bar (ui_shell)', () {
    const rowHeight = 60.0;
    const rows = 40;

    final pillFinder = find.descendant(
      of: find.byType(AppFloatingBottomBar),
      matching: find.byType(Material),
    );

    Widget list({ScrollController? controller}) => ListView.builder(
      controller: controller,
      itemCount: rows,
      itemExtent: rowHeight,
      itemBuilder: (context, i) => Text('row $i', key: ValueKey('row-$i')),
    );

    /// The scaffold with the floating bar inside a view with [safeBottom] of
    /// bottom safe area and [keyboard] of bottom view inset.
    Future<void> pumpFloating(
      WidgetTester tester, {
      Widget? body,
      VoidCallback? onCompose,
      ValueChanged<int>? onSelected,
      double safeBottom = 0,
      double keyboard = 0,
      double width = 360,
      double textScale = 1,
      Brightness brightness = Brightness.light,
      bool disableAnimations = false,
      bool floatingBar = true,
    }) {
      final size = Size(width, 800);
      // An open keyboard covers the bottom safe area (padding drops to 0).
      final padding = EdgeInsets.only(bottom: keyboard > 0 ? 0 : safeBottom);
      return pumpThemed(
        tester,
        MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
            padding: padding,
            viewPadding: EdgeInsets.only(bottom: safeBottom),
            viewInsets: EdgeInsets.only(bottom: keyboard),
            disableAnimations: disableAnimations,
          ),
          child: ResponsiveScaffold(
            selectedIndex: 0,
            onDestinationSelected: onSelected ?? (_) {},
            destinations: _destinations,
            onCompose: onCompose,
            floatingBar: floatingBar,
            body: body ?? const SizedBox.expand(key: _bodyKey),
          ),
        ),
        size: size,
        brightness: brightness,
        textScale: textScale,
        useScaffold: false,
      );
    }

    testWidgets('the pill floats over a full-height body', (tester) async {
      await pumpFloating(tester);

      expect(find.byType(AppFloatingBottomBar), findsOneWidget);
      // The body runs to the bottom edge, behind the bar.
      expect(
        tester.getRect(find.byKey(_bodyKey)),
        const Rect.fromLTRB(0, 0, 360, 800),
      );
      expect(
        tester.getRect(pillFinder),
        const Rect.fromLTRB(20, 800 - 24 - 66, 340, 800 - 24),
      );
    });

    testWidgets('off: the docked bar, the body ends above it and gets no '
        'bottom padding', (tester) async {
      late EdgeInsets padding;
      await pumpFloating(
        tester,
        floatingBar: false,
        onCompose: () {},
        body: Builder(
          builder: (context) {
            padding = MediaQuery.paddingOf(context);
            return const SizedBox.expand(key: _bodyKey);
          },
        ),
      );

      expect(find.byType(AppFloatingBottomBar), findsNothing);
      expect(
        tester.getRect(find.byType(AppBottomBar)),
        const Rect.fromLTRB(0, 800 - 56, 360, 800),
      );
      expect(tester.getRect(find.byKey(_bodyKey)).bottom, 800 - 56);
      expect(padding.bottom, 0);
      expectSize(
        tester,
        find.byType(FloatingActionButton),
        width: AppSize.fab,
        height: AppSize.fab,
        tolerance: 0,
      );
    });

    for (final safeBottom in [0.0, 34.0]) {
      testWidgets('the body gets 66 + 24 + $safeBottom of bottom padding and '
          'view padding', (tester) async {
        late MediaQueryData media;
        await pumpFloating(
          tester,
          safeBottom: safeBottom,
          body: Builder(
            builder: (context) {
              media = MediaQuery.of(context);
              return const SizedBox.expand();
            },
          ),
        );

        expect(media.padding.bottom, 66 + 24 + safeBottom);
        expect(media.viewPadding.bottom, 66 + 24 + safeBottom);
        expect(media.padding.bottom, 800 - tester.getRect(pillFinder).top);
      });
    }

    testWidgets('the last list row scrolls into view above the bar', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpFloating(tester, body: list(controller: controller));

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();

      // The bar is still there (a jump is not a user scroll).
      final pill = tester.getRect(pillFinder);
      final last = tester.getRect(
        find.byKey(const ValueKey('row-${rows - 1}')),
      );
      expect(last.bottom, lessThanOrEqualTo(pill.top));
      expect(last.bottom, 800 - 90);
    });

    testWidgets('a SafeArea in the page ends above the bar', (tester) async {
      await pumpFloating(
        tester,
        safeBottom: 34,
        body: const SafeArea(child: SizedBox.expand(key: _bodyKey)),
      );

      expect(
        tester.getRect(find.byKey(_bodyKey)).bottom,
        tester.getRect(pillFinder).top,
      );
    });

    for (final brightness in Brightness.values) {
      testWidgets('the compose button is the 58dp gradient primary, above the '
          'bar, in ${brightness.name}', (tester) async {
        var composed = 0;
        await pumpFloating(
          tester,
          onCompose: () => composed++,
          brightness: brightness,
        );

        final fab = find.byType(FloatingActionButton);
        expectSize(tester, fab, width: 58, height: 58, tolerance: 0);
        final pill = tester.getRect(pillFinder);
        final rect = tester.getRect(fab);
        expect(rect.overlaps(pill), isFalse);
        expect(rect.bottom, pill.top - 16);

        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find
                          .ancestor(
                            of: fab,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as ShapeDecoration;
        expect(decoration.gradient, AppGradients.primaryButton);
        expect(decoration.shadows, AppShadows.primaryGlow);
        expect(decoration.shape, const CircleBorder());
        final icon = tester.widget<Icon>(find.byIcon(Icons.edit_outlined));
        final iconColor = IconTheme.of(tester.element(find.byWidget(icon)))
            .color;
        expect(iconColor, AppPalette.navy);

        await tester.tap(find.byTooltip('New post'));
        expect(composed, 1);
      });
    }

    testWidgets('the compose button of a page scaffold also clears the bar', (
      tester,
    ) async {
      await pumpFloating(
        tester,
        body: Scaffold(
          body: const SizedBox.expand(),
          floatingActionButton: FloatingActionButton(
            key: const Key('page-fab'),
            onPressed: () {},
            child: const Icon(Icons.mail_outline),
          ),
        ),
      );

      final fab = tester.getRect(find.byKey(const Key('page-fab')));
      final pill = tester.getRect(pillFinder);
      expect(fab.overlaps(pill), isFalse);
      expect(fab.bottom, lessThanOrEqualTo(pill.top));
    });

    testWidgets('the page stays tappable around the pill', (tester) async {
      var taps = 0;
      final picked = <int>[];
      await pumpFloating(
        tester,
        onSelected: picked.add,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: const SizedBox.expand(),
        ),
      );

      final pill = tester.getRect(pillFinder);
      await tester.tapAt(Offset(8, pill.center.dy));
      await tester.tapAt(Offset(352, pill.center.dy));
      await tester.tapAt(Offset(180, pill.bottom + 12));
      expect(taps, 3);
      expect(picked, isEmpty);

      await tester.tap(find.byIcon(Icons.person_outline));
      expect(taps, 3);
      expect(picked, [2]);
    });

    testWidgets('scrolling down slides and fades the bar away, scrolling up '
        'brings it back; the padding does not move', (tester) async {
      final picked = <int>[];
      late EdgeInsets padding;
      await pumpFloating(
        tester,
        onSelected: picked.add,
        body: Builder(
          builder: (context) {
            padding = MediaQuery.paddingOf(context);
            return list();
          },
        ),
      );
      final shown = tester.getRect(pillFinder);

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      final slide = tester.widget<AnimatedSlide>(find.byType(AnimatedSlide));
      expect(slide.offset, const Offset(0, 1));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      // Off the bottom edge, and not a tap target while hidden.
      expect(tester.getRect(pillFinder).top, greaterThanOrEqualTo(800));
      await tester.tapAt(shown.center);
      expect(picked, isEmpty);
      expect(padding.bottom, 90);

      await tester.drag(find.byType(ListView), const Offset(0, 100));
      await tester.pumpAndSettle();

      expect(tester.getRect(pillFinder), shown);
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await tester.tapAt(shown.center);
      expect(picked, [1]);
    });

    testWidgets('a hidden bar leaves the semantics tree', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpFloating(tester, body: list());
      bool excluded() => tester
          .widget<ExcludeSemantics>(
            find
                .ancestor(
                  of: find.byType(AppBottomBar),
                  matching: find.byType(ExcludeSemantics),
                )
                .first,
          )
          .excluding;
      expect(excluded(), isFalse);
      expect(tester.getSemantics(find.byIcon(Icons.home)).label, 'Home');

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(excluded(), isTrue);
      handle.dispose();
    });

    testWidgets('reduced motion: the bar fades without moving', (tester) async {
      await pumpFloating(tester, body: list(), disableAnimations: true);
      final shown = tester.getRect(pillFinder);

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(
        tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset,
        Offset.zero,
      );
      expect(tester.getRect(pillFinder), shown);
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
    });

    group('ShellBottomInsetSliver', () {
      /// A page (its own `Scaffold`, as every shell screen) with two tabs,
      /// each a `CustomScrollView` of [rows] 60 dp rows, ending with the
      /// helper when [inset] is set. The tabs scroll below the depth of the
      /// shell's scroll-hide listener, so the bar never hides here.
      Widget tabbedPage({required bool inset, int rows = 12}) =>
          DefaultTabController(
            length: 2,
            child: Scaffold(
              body: TabBarView(
                children: [
                  for (final tab in ['a', 'b'])
                    CustomScrollView(
                      key: PageStorageKey(tab),
                      slivers: [
                        SliverFixedExtentList.builder(
                          itemExtent: rowHeight,
                          itemCount: rows,
                          itemBuilder: (context, i) =>
                              Text('$tab $i', key: ValueKey('$tab-$i')),
                        ),
                        if (inset) const ShellBottomInsetSliver(),
                      ],
                    ),
                ],
              ),
            ),
          );

      // A zero-tall sliver counts as offstage, so the finders include it.
      double insetHeight(WidgetTester tester) => tester
          .widget<SizedBox>(
            find.descendant(
              of: find.byType(ShellBottomInsetSliver, skipOffstage: false),
              matching: find.byType(SizedBox, skipOffstage: false),
            ),
          )
          .height!;

      testWidgets('a TabBarView tab: without the helper its last row stays '
          'under the pill; with it, the row scrolls above the pill while the '
          'bar stays up', (tester) async {
        // 12 rows end at 720, inside the 90 dp of the bar (its top: 710).
        await pumpFloating(tester, body: tabbedPage(inset: false));
        await tester.drag(find.text('a 3'), const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(const ValueKey('a-11'))).bottom, 720);
        expect(tester.getRect(pillFinder).top, 710);

        await pumpFloating(tester, body: tabbedPage(inset: true));
        await tester.drag(find.text('a 3'), const Offset(0, -300));
        await tester.pumpAndSettle();

        expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
          1,
        );
        final pill = tester.getRect(pillFinder);
        final last = tester.getRect(find.byKey(const ValueKey('a-11')));
        expect(last.bottom, lessThanOrEqualTo(pill.top));
        expect(insetHeight(tester), 90);
      });

      testWidgets('ui_shell off: zero tall, the tab is unchanged', (
        tester,
      ) async {
        await pumpFloating(
          tester,
          floatingBar: false,
          body: tabbedPage(inset: true),
        );
        await tester.drag(find.text('a 3'), const Offset(0, -300));
        await tester.pumpAndSettle();

        expect(insetHeight(tester), 0);
        // The rows fit above the docked bar: nothing scrolled.
        expect(tester.getRect(find.byKey(const ValueKey('a-11'))).bottom, 720);
        expect(tester.getRect(find.byType(AppBottomBar)).top, 744);
      });

      for (final safeBottom in [0.0, 34.0]) {
        testWidgets('as tall as the bar and the $safeBottom dp safe area', (
          tester,
        ) async {
          await pumpFloating(
            tester,
            safeBottom: safeBottom,
            body: tabbedPage(inset: true),
          );

          expect(insetHeight(tester), 90 + safeBottom);
        });
      }

      testWidgets('zero tall under a SafeArea, which already takes the '
          'padding', (tester) async {
        await pumpFloating(
          tester,
          safeBottom: 34,
          body: SafeArea(child: tabbedPage(inset: true)),
        );

        expect(insetHeight(tester), 0);
      });

      for (final width in [600.0, 1200.0]) {
        testWidgets('zero tall on the ${width.toInt()} dp rail layout', (
          tester,
        ) async {
          await pumpFloating(
            tester,
            width: width,
            safeBottom: 34,
            body: tabbedPage(inset: true),
          );

          expect(insetHeight(tester), 0);
        });
      }
    });

    testWidgets('an open keyboard takes the bar and its padding away', (
      tester,
    ) async {
      late MediaQueryData media;
      await pumpFloating(
        tester,
        safeBottom: 34,
        keyboard: 300,
        onCompose: () {},
        body: Builder(
          builder: (context) {
            media = MediaQuery.of(context);
            return const SizedBox.expand(key: _bodyKey);
          },
        ),
      );

      expect(find.byType(AppBottomBar), findsNothing);
      expect(find.byType(AppFloatingBottomBar), findsNothing);
      expect(media.padding.bottom, 0);
      // The page ends at the keyboard.
      expect(tester.getRect(find.byKey(_bodyKey)).bottom, 800 - 300);
    });

    testWidgets('opening the keyboard keeps the page state and the field '
        'focus', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final field = TextField(key: const Key('field'), focusNode: focus);
      await pumpFloating(tester, body: field);
      focus.requestFocus();
      await tester.pump();
      final state = tester.state(find.byKey(const Key('field')));
      expect(find.byType(AppFloatingBottomBar), findsOneWidget);

      await pumpFloating(tester, body: field, keyboard: 300);

      expect(find.byType(AppFloatingBottomBar), findsNothing);
      expect(tester.state(find.byKey(const Key('field'))), same(state));
      expect(focus.hasFocus, isTrue);
    });

    forEachThemeAndWidth(
      'no overflow; the bar only below 600dp',
      (tester, env) async {
        await pumpFloating(
          tester,
          onCompose: () {},
          width: env.size.width,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expectNoOverflow(tester);
        final phone = env.size.width < AppBreakpoints.mobile;
        expect(
          find.byType(AppFloatingBottomBar),
          phone ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationRail),
          phone ? findsNothing : findsOneWidget,
        );
        if (phone) {
          expectMinTarget(tester, find.byType(FloatingActionButton));
          expect(
            tester
                .getRect(find.byType(FloatingActionButton))
                .overlaps(tester.getRect(pillFinder)),
            isFalse,
          );
        }
      },
      // The shared widths plus the last phone width below 600 dp.
      widths: {...kRedesignWidths, ...kMatrixWidths, 599.0}.toList(),
      textScales: kMatrixTextScalesLarge,
    );
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
          'divider on the NavigationRail (ui_tablet off)', (tester) async {
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
        // the items, so the group divider is `AppNavRail`'s (the tablet
        // layout, asserted in the 'tablet layout' group below). This rail
        // stays as it was.
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

  group('tablet layout (ui_shell + ui_tablet, T1)', () {
    // The new shell's rail: five primaries, four secondaries and More.
    List<AppNavDestination> shell() => [
      const AppNavDestination(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Home',
      ),
      const AppNavDestination(
        icon: Icons.search,
        selectedIcon: Icons.manage_search,
        label: 'Explore',
      ),
      const AppNavDestination(
        icon: Icons.track_changes,
        selectedIcon: Icons.adjust,
        label: 'Plans',
      ),
      const AppNavDestination(
        icon: Icons.notifications_none,
        selectedIcon: Icons.notifications,
        label: 'Notifications',
      ),
      const AppNavDestination(
        icon: Icons.mail_outline,
        selectedIcon: Icons.mail,
        label: 'Messages',
      ),
      const AppNavDestination(
        icon: Icons.list_alt_outlined,
        selectedIcon: Icons.list_alt,
        label: 'Lists',
        group: AppNavGroup.secondary,
      ),
      const AppNavDestination(
        icon: Icons.groups_outlined,
        selectedIcon: Icons.groups,
        label: 'Communities',
        group: AppNavGroup.secondary,
      ),
      const AppNavDestination(
        icon: Icons.bookmark_border,
        selectedIcon: Icons.bookmark,
        label: 'History',
        group: AppNavGroup.secondary,
      ),
      const AppNavDestination(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: 'Profile',
        group: AppNavGroup.secondary,
      ),
      AppNavDestination(
        icon: Icons.more_horiz,
        selectedIcon: Icons.more_horiz,
        label: 'More',
        semanticsLabel: 'More, menu',
        group: AppNavGroup.secondary,
        onActivate: (_) {},
      ),
    ];

    Widget tablet({
      Widget? body,
      ShellLayout layout = ShellLayout.tablet,
      int? selected = 0,
      ValueChanged<int>? onSelected,
      void Function(BuildContext anchor, List<int> folded)? onMoreFolded,
    }) => ResponsiveScaffold(
      selectedIndex: selected,
      onDestinationSelected: onSelected ?? (_) {},
      destinations: shell(),
      onCompose: () {},
      redesignedRail: true,
      floatingBar: true,
      layout: layout,
      onMoreFolded: onMoreFolded,
      drawer: const Drawer(),
      sideColumn: const SizedBox(key: _sideKey, height: 10),
      accountChipBuilder: (extended) => SizedBox(
        key: const Key('chip'),
        width: extended ? 200 : 40,
        height: 40,
      ),
      body: body ?? const SizedBox.expand(key: _bodyKey),
    );

    /// Pumps with safe-area [padding] (and the matching view padding).
    Future<void> pumpTablet(
      WidgetTester tester,
      Widget child, {
      double width = 834,
      double height = 1194,
      EdgeInsets padding = EdgeInsets.zero,
      double textScale = 1,
      Brightness brightness = Brightness.light,
    }) => pumpThemed(
      tester,
      MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          padding: padding,
          viewPadding: padding,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child,
      ),
      size: Size(width, height),
      textScale: textScale,
      brightness: brightness,
      useScaffold: false,
    );

    Finder inRail(Finder f) =>
        find.descendant(of: find.byType(AppNavRail), matching: f);

    for (final width in kTabletMatrixWidths) {
      testWidgets('${width.toInt()} dp: the rail is pinned at x = 0 and the '
          'body fills the rest: no dead strip', (tester) async {
        await pumpTablet(tester, tablet(), width: width);

        expect(find.byType(NavigationRail), findsNothing);
        expect(find.byType(AppBottomBar), findsNothing);
        expect(
          tester.getRect(find.byType(AppNavRail)),
          Rect.fromLTWH(0, 0, AppSize.railCompact, 1194),
        );
        expect(
          tester.getRect(find.byKey(_bodyKey)),
          Rect.fromLTWH(80, 0, width - 80, 1194),
        );
        // No side column, drawer scope or phone compose button.
        expect(find.byKey(_sideKey), findsNothing);
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.byKey(const Key('chip')), findsOneWidget);
        expectSize(tester, find.byKey(const Key('chip')), width: 40);
        final geometry = ShellGeometry.maybeOf(
          tester.element(find.byKey(_bodyKey)),
        )!;
        expect(geometry.tablet, isTrue);
        expect(geometry.content, tester.getRect(find.byKey(_bodyKey)));
      });
    }

    testWidgets('the group divider sits between the primaries and the '
        'secondaries (the phase 3.5 tripwire, tablet side)', (tester) async {
      await pumpTablet(tester, tablet());

      final divider = inRail(find.byType(Divider));
      expect(divider, findsOneWidget);
      final y = tester.getCenter(divider).dy;
      expect(
        y,
        greaterThan(
          tester.getCenter(inRail(find.byIcon(Icons.mail_outline))).dy,
        ),
      );
      expect(
        y,
        lessThan(
          tester.getCenter(inRail(find.byIcon(Icons.list_alt_outlined))).dy,
        ),
      );
    });

    testWidgets('the compose button is the 52 dp gradient circle "New '
        'post"', (tester) async {
      await pumpTablet(tester, tablet());

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
      expect(
        (fill.decoration as ShapeDecoration).gradient,
        AppColors.light.primaryFillGradient,
      );
      expectSize(
        tester,
        find.byWidget(fill),
        width: AppSize.railPostHeight,
        height: AppSize.railPostHeight,
      );
      expect(inRail(find.byTooltip('New post')), findsOneWidget);
    });

    testWidgets('per-pane safe areas: no outer SafeArea; the rail takes the '
        'leading inset, the pane stops at the trailing one and gets the top '
        'and bottom ones', (tester) async {
      const padding = EdgeInsets.fromLTRB(44, 24, 30, 20);
      late EdgeInsets bodyPadding;
      await pumpTablet(
        tester,
        tablet(
          body: Builder(
            builder: (context) {
              bodyPadding = MediaQuery.paddingOf(context);
              return const SizedBox.expand(key: _bodyKey);
            },
          ),
        ),
        width: 932,
        height: 430,
        padding: padding,
      );

      expect(
        find.ancestor(
          of: find.byKey(_bodyKey),
          matching: find.byType(SafeArea),
        ),
        findsNothing,
      );
      expect(
        tester.getRect(find.byType(AppNavRail)),
        const Rect.fromLTWH(0, 0, 124, 430),
      );
      // The pane runs under the status bar and ends at the trailing inset:
      // its rect is the geometry's content. Its header and scrollables pad
      // themselves by the top and bottom insets.
      final geometry = ShellGeometry.maybeOf(
        tester.element(find.byKey(_bodyKey)),
      )!;
      expect(
        geometry.content,
        const Rect.fromLTWH(124, 0, 932 - 124 - 30, 430),
      );
      expect(tester.getRect(find.byKey(_bodyKey)), geometry.content);
      expect(bodyPadding, const EdgeInsets.fromLTRB(0, 24, 0, 20));
      // The trailing strip is the page colour.
      final strip = find.byWidgetPredicate(
        (w) =>
            w is ColoredBox &&
            w.color == appLightTheme.scaffoldBackgroundColor &&
            w.key == const ValueKey('tablet-trailing-inset'),
      );
      expect(tester.getRect(strip), const Rect.fromLTRB(902, 0, 932, 430));
    });

    testWidgets('right to left (932 x 430): the rail and its inset on the '
        'right, the trailing strip on the left, the pane between them', (
      tester,
    ) async {
      // Leading is the right edge: 44 there, 30 on the left.
      const padding = EdgeInsets.fromLTRB(30, 24, 44, 20);
      late EdgeInsets bodyPadding;
      await pumpTablet(
        tester,
        Directionality(
          textDirection: TextDirection.rtl,
          child: tablet(
            body: Builder(
              builder: (context) {
                bodyPadding = MediaQuery.paddingOf(context);
                return const SizedBox.expand(key: _bodyKey);
              },
            ),
          ),
        ),
        width: 932,
        height: 430,
        padding: padding,
      );

      expect(
        tester.getRect(find.byType(AppNavRail)),
        const Rect.fromLTRB(932 - 124, 0, 932, 430),
      );
      final strip = find.byKey(const ValueKey('tablet-trailing-inset'));
      expect(tester.getRect(strip), const Rect.fromLTRB(0, 0, 30, 430));
      expect(
        tester.widget<ColoredBox>(strip).color,
        appLightTheme.scaffoldBackgroundColor,
      );
      final geometry = ShellGeometry.maybeOf(
        tester.element(find.byKey(_bodyKey)),
      )!;
      expect(geometry.content, const Rect.fromLTRB(30, 0, 808, 430));
      expect(tester.getRect(find.byKey(_bodyKey)), geometry.content);
      expect(bodyPadding, const EdgeInsets.fromLTRB(0, 24, 0, 20));
      // The items sit inside the rail's 80 dp, clear of the right inset.
      final home = tester.getRect(
        find.descendant(
          of: find.byType(AppNavRail),
          matching: find.byIcon(Icons.home),
        ),
      );
      expect(home.center.dx, closeTo(808 + AppSize.railCompact / 2, 0.5));
      expectNoOverflow(tester);
    });

    testWidgets('a landscape notch on both sides: the rail clears the '
        'leading one, list rows end before the trailing one', (tester) async {
      const padding = EdgeInsets.fromLTRB(44, 0, 47, 21);
      await pumpTablet(
        tester,
        tablet(
          body: ListView.builder(
            itemCount: 20,
            itemExtent: 48,
            itemBuilder: (context, i) =>
                ColoredBox(color: Colors.transparent, key: ValueKey('row-$i')),
          ),
        ),
        width: 932,
        height: 430,
        padding: padding,
      );

      final row = tester.getRect(find.byKey(const ValueKey('row-0')));
      expect(row.right, lessThanOrEqualTo(932 - 47));
      expect(row.left, greaterThanOrEqualTo(44 + AppSize.railCompact));
      final home = tester.getRect(
        find.descendant(
          of: find.byType(AppNavRail),
          matching: find.byIcon(Icons.home),
        ),
      );
      expect(home.left, greaterThanOrEqualTo(44));
      expect(home.center.dx, closeTo(44 + AppSize.railCompact / 2, 0.5));
      expectNoOverflow(tester);
    });

    testWidgets('a ShellBottomInsetSliver is as tall as the bottom inset '
        '(the rail layouts of ui_tablet off keep it zero)', (tester) async {
      await pumpTablet(
        tester,
        tablet(
          body: const CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: 10)),
              ShellBottomInsetSliver(),
            ],
          ),
        ),
        padding: const EdgeInsets.only(bottom: 20),
      );

      expect(
        tester
            .widget<SizedBox>(
              find.descendant(
                of: find.byType(ShellBottomInsetSliver),
                matching: find.byType(SizedBox),
              ),
            )
            .height,
        20,
      );
    });

    testWidgets('phones and desktop ignore the layout; ShellLayout.legacy '
        'keeps the centred NavigationRail', (tester) async {
      await pumpTablet(tester, tablet(), width: 599);
      expect(find.byType(AppFloatingBottomBar), findsOneWidget);
      expect(find.byType(AppNavRail), findsNothing);

      for (final width in [1200.0, 1440.0]) {
        await pumpTablet(tester, tablet(), width: width, height: 900);
        expect(find.byType(AppNavRail), findsNothing);
        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        expect(rail.extended, isTrue);
        expect(find.byKey(_sideKey), findsOneWidget);
        // (At 1200 the side column squeezes the column, as today.)
        if (width == 1440) {
          expectSize(tester, find.byKey(_bodyKey), width: AppSize.contentMax);
        }
      }

      await pumpTablet(tester, tablet(layout: ShellLayout.legacy));
      expect(find.byType(AppNavRail), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      expectSize(tester, find.byKey(_bodyKey), width: AppSize.contentMax);
      expect(
        ShellGeometry.maybeOf(tester.element(find.byKey(_bodyKey))),
        isNull,
      );
    });

    testWidgets('boundaries: the chrome at each side of 600, 840 and 1200', (
      tester,
    ) async {
      for (final width in kBoundaryWidths) {
        await pumpTablet(tester, tablet(), width: width, height: 900);
        final band = ShellBand.of(width);
        expect(
          find.byType(AppNavRail),
          band.isTablet ? findsOneWidget : findsNothing,
          reason: '$width',
        );
        expect(
          find.byType(NavigationRail),
          band == ShellBand.desktop ? findsOneWidget : findsNothing,
          reason: '$width',
        );
        expect(
          find.byType(AppFloatingBottomBar),
          band == ShellBand.phone ? findsOneWidget : findsNothing,
          reason: '$width',
        );
        expectNoOverflow(tester);
      }
    });

    testWidgets('focus order: the rail (its one Tab stop), then the pane', (
      tester,
    ) async {
      await pumpTablet(
        tester,
        tablet(
          selected: 3,
          body: Center(
            child: TextButton(onPressed: () {}, child: const Text('in pane')),
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        Focus.of(tester.element(inRail(find.byIcon(Icons.notifications))))
            .hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        Focus.of(tester.element(find.text('in pane'))).hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('R2 (1024 x 640): More is handed the folded secondaries', (
      tester,
    ) async {
      final folded = <List<int>>[];
      await pumpTablet(
        tester,
        tablet(onMoreFolded: (anchor, rows) => folded.add(rows)),
        width: 1024,
        height: 640,
      );

      expect(inRail(find.byIcon(Icons.list_alt_outlined)), findsNothing);
      await tester.tap(inRail(find.byIcon(Icons.more_horiz)));
      expect(folded, [
        [5, 6, 7, 8],
      ]);
    });

    // Tablet plan section 5.5: 5 widths x 2 scales x 2 themes, portrait,
    // then the landscape heights (R2 and R3 included).
    forEachThemeAndWidth(
      'no overflow; regions sum to W; 48 dp compose target',
      (tester, env) async {
        for (final height in {env.size.height, ...kTabletLandscapeHeights}) {
          await pumpTablet(
            tester,
            tablet(),
            width: env.size.width,
            height: height,
            brightness: env.brightness,
            textScale: env.textScale,
          );

          expectNoOverflow(tester);
          final rail = tester.getRect(find.byType(AppNavRail));
          final body = tester.getRect(find.byKey(_bodyKey));
          expect(rail.left, 0);
          expect(rail.width, AppSize.railCompact);
          expect(body.left, rail.right);
          expect(rail.width + body.width, env.size.width);
          expectMinTarget(tester, inRail(find.byTooltip('New post')));
        }
      },
      widths: kTabletMatrixWidths,
      textScales: kTabletTextScales,
      heights: kTabletHeights,
    );
  });

  group('context pane (band B, tablet layout, T3)', () {
    const paneKey = Key('pane-section');
    const sections = [
      ContextSection(
        ContextSectionKind.trends,
        SizedBox(key: paneKey, height: 120),
      ),
      ContextSection(ContextSectionKind.links, Text('footer')),
    ];

    Widget shell({
      ShellLayout layout = ShellLayout.tablet,
      List<ContextSection>? contextSections = sections,
      Widget? body,
    }) => ResponsiveScaffold(
      selectedIndex: 0,
      onDestinationSelected: (_) {},
      destinations: _destinations,
      onCompose: () {},
      redesignedRail: true,
      floatingBar: true,
      layout: layout,
      sideColumn: const SizedBox(key: _sideKey, height: 10),
      contextSections: contextSections,
      body: body ?? const SizedBox.expand(key: _bodyKey),
    );

    Future<void> pumpAt(
      WidgetTester tester,
      Widget child, {
      double width = 1024,
      double height = 768,
      EdgeInsets padding = EdgeInsets.zero,
    }) => pumpThemed(
      tester,
      MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          padding: padding,
          viewPadding: padding,
        ),
        child: child,
      ),
      size: Size(width, height),
      useScaffold: false,
    );

    final table = <double, (double, double)>{
      840: (439, 320),
      1024: (623, 320),
      1133: (680, 372),
      1199: (680, 438),
    };
    for (final MapEntry(key: width, value: (primary, pane)) in table.entries) {
      testWidgets('${width.toInt()} dp: body ${primary.toInt()}, hairline, '
          'pane ${pane.toInt()}', (tester) async {
        await pumpAt(tester, shell(), width: width);

        expect(
          tester.getRect(find.byKey(_bodyKey)),
          Rect.fromLTWH(80, 0, primary, 768),
        );
        expect(
          tester.getRect(find.byType(ContextPane)),
          Rect.fromLTWH(80 + primary + 1, 0, pane, 768),
        );
        expect(find.byKey(paneKey), findsOneWidget);
        expect(find.text('footer'), findsOneWidget);
        expect(find.byKey(_sideKey), findsNothing);
        expect(
          tester.widget<ContextPaneScope>(find.byType(ContextPaneScope)).shown,
          {ContextSectionKind.trends, ContextSectionKind.links},
        );
      });
    }

    for (final width in [600.0, 834.0, 839.0]) {
      testWidgets('band A (${width.toInt()} dp): no pane, the body keeps the '
          'content, the page is told nothing is in a pane', (tester) async {
        await pumpAt(tester, shell(), width: width);

        expect(find.byType(ContextPane), findsNothing);
        expect(find.byKey(paneKey), findsNothing);
        expect(
          tester.getRect(find.byKey(_bodyKey)),
          Rect.fromLTWH(80, 0, width - 80, 768),
        );
        expect(
          tester.widget<ContextPaneScope>(find.byType(ContextPaneScope)).shown,
          isEmpty,
        );
      });
    }

    for (final empty in [null, <ContextSection>[]]) {
      testWidgets('band B with ${empty == null ? 'no' : 'empty'} sections: '
          'one pane, as in T1', (tester) async {
        await pumpAt(tester, shell(contextSections: empty));

        expect(find.byType(ContextPane), findsNothing);
        expect(
          tester.getRect(find.byKey(_bodyKey)),
          const Rect.fromLTWH(80, 0, 944, 768),
        );
      });
    }

    testWidgets('the legacy layout ignores the sections at 1024 dp', (
      tester,
    ) async {
      await pumpAt(tester, shell(layout: ShellLayout.legacy));

      expect(find.byType(ContextPane), findsNothing);
      expect(find.byType(ContextPaneScope), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(tester.getSize(find.byKey(_bodyKey)).width, AppSize.contentMax);
    });

    testWidgets('desktop ignores them and keeps the side column', (
      tester,
    ) async {
      await pumpAt(tester, shell(), width: 1280, height: 900);

      expect(find.byType(ContextPane), findsNothing);
      expect(find.byType(ContextPaneScope), findsNothing);
      expect(find.byKey(_sideKey), findsOneWidget);
    });

    testWidgets('phones ignore them', (tester) async {
      await pumpAt(tester, shell(), width: 599, height: 900);

      expect(find.byType(ContextPane), findsNothing);
      expect(find.byType(ContextPaneScope), findsNothing);
    });

    testWidgets('insets: the pane pads its content by the top and bottom '
        'ones and stops at the trailing one', (tester) async {
      await pumpAt(
        tester,
        shell(),
        padding: const EdgeInsets.fromLTRB(44, 24, 30, 20),
      );

      // Rail 124; C = 1024 - 124 - 30 = 870; pane 320; body 549.
      expect(
        tester.getRect(find.byType(ContextPane)),
        const Rect.fromLTWH(124 + 549 + 1, 0, 320, 768),
      );
      expect(tester.getTopLeft(find.byKey(paneKey)).dy, 24 + AppSpacing.md);
      final scroll = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: find.byType(ContextPane),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(
        scroll.padding,
        const EdgeInsets.fromLTRB(16, 24 + 16, 16, 20 + 16),
      );
    });

    testWidgets('focus: the rail, the body, then the pane', (tester) async {
      await pumpAt(
        tester,
        shell(
          contextSections: [
            ContextSection(
              ContextSectionKind.links,
              TextButton(onPressed: () {}, child: const Text('in pane')),
            ),
          ],
          body: Center(
            child: TextButton(onPressed: () {}, child: const Text('in body')),
          ),
        ),
      );

      bool focused(String text) =>
          Focus.of(tester.element(find.text(text))).hasPrimaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        Focus.of(
          tester.element(
            find.descendant(
              of: find.byType(AppNavRail),
              matching: find.byIcon(Icons.home),
            ),
          ),
        ).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused('in body'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused('in pane'), isTrue);
    });
  });
}
