import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/shell_bottom_inset_sliver.dart';
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
}
