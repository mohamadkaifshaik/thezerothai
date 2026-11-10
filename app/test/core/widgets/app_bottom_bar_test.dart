import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_destination.dart';
import 'package:dzeroth/shared/widgets/primitives/app_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contrast.dart';
import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

const _home = AppNavDestination(
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  label: 'Home',
);
const _explore = AppNavDestination(
  icon: Icons.search,
  selectedIcon: Icons.manage_search,
  label: 'Explore',
);
const _plans = AppNavDestination(
  icon: Icons.event_outlined,
  selectedIcon: Icons.event,
  label: 'Plans',
);
const _alerts = AppNavDestination(
  icon: Icons.notifications_none,
  selectedIcon: Icons.notifications,
  label: 'Notifications',
  barLabel: 'Alerts',
);
const _messages = AppNavDestination(
  icon: Icons.mail_outline,
  selectedIcon: Icons.mail,
  label: 'Messages',
);

/// The five primaries of ADR-0034, in order.
const _five = [_home, _explore, _plans, _alerts, _messages];

/// Two cells: wide enough for a label in the test font at 1.0 and 1.3.
const _two = [_home, _alerts];

final _pill = find.descendant(
  of: find.byType(AppFloatingBottomBar),
  matching: find.byType(Material),
);

const _underKey = Key('under');

/// The bar at the bottom of a [width] x 800 screen, over a full-screen
/// tappable page.
Future<void> _pump(
  WidgetTester tester, {
  List<AppNavDestination> destinations = _five,
  int? selected = 0,
  ValueChanged<int>? onSelected,
  VoidCallback? onUnderTap,
  double width = 360,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  EdgeInsets safeArea = EdgeInsets.zero,
}) {
  final size = Size(width, 800);
  return pumpThemed(
    tester,
    MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
        padding: safeArea,
        viewPadding: safeArea,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: _underKey,
              behavior: HitTestBehavior.opaque,
              onTap: onUnderTap,
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: AppFloatingBottomBar(
              destinations: destinations,
              selectedIndex: selected,
              onSelected: onSelected ?? (_) {},
            ),
          ),
        ],
      ),
    ),
    size: size,
    brightness: brightness,
    textScale: textScale,
  );
}

Rect _cell(WidgetTester tester, String label) =>
    tester.getRect(find.bySemanticsLabel(RegExp('^$label')));

void main() {
  group('geometry', () {
    testWidgets('a 66dp pill, inset 20dp and 24dp above the bottom', (
      tester,
    ) async {
      await _pump(tester);

      final pill = tester.getRect(_pill);
      expect(pill.height, AppSize.floatingNavHeight);
      expect(pill.height, 66);
      expect(pill.left, 20);
      expect(pill.right, 360 - 20);
      expect(pill.bottom, 800 - 24);
    });

    testWidgets('the bottom safe area lifts the pill; the side insets stay', (
      tester,
    ) async {
      await _pump(tester, safeArea: const EdgeInsets.only(bottom: 34));

      final pill = tester.getRect(_pill);
      expect(pill.bottom, 800 - 34 - 24);
      expect(pill.left, 20);
      expect(pill.right, 340);
      expectSize(
        tester,
        find.byType(AppFloatingBottomBar),
        height: AppFloatingBottomBar.reservedHeight + 34,
      );
    });

    for (final brightness in Brightness.values) {
      testWidgets('navy with the nav bar shadow in ${brightness.name}', (
        tester,
      ) async {
        await _pump(tester, brightness: brightness);

        final material = tester.widget<Material>(_pill);
        expect(material.color, AppPalette.navy);
        expect(material.shape, const StadiumBorder());
        final shadow = tester.widget<DecoratedBox>(
          find.ancestor(of: _pill, matching: find.byType(DecoratedBox)).first,
        );
        expect(
          (shadow.decoration as ShapeDecoration).shadows,
          AppShadows.navBar,
        );
      });
    }

    for (final width in [320.0, 360.0, 599.0]) {
      testWidgets('five equal cells of at least 48dp at ${width.toInt()}dp', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, width: width);

        final cells = [for (final d in _five) _cell(tester, d.label)];
        for (final cell in cells) {
          expect(cell.width, closeTo(cells.first.width, 0.01));
          expect(cell.width, greaterThanOrEqualTo(48));
          expect(cell.height, greaterThanOrEqualTo(48));
        }
        for (var i = 1; i < cells.length; i++) {
          expect(cells[i].left, closeTo(cells[i - 1].right, 0.01));
        }
        handle.dispose();
      });
    }

    testWidgets('taps report the index of the cell', (tester) async {
      final taps = <int>[];
      await _pump(tester, onSelected: taps.add);

      await tester.tap(find.byIcon(Icons.mail_outline));
      await tester.tap(find.byIcon(Icons.home));
      expect(taps, [4, 0]);
    });
  });

  group('selection', () {
    testWidgets('the selected cell is the filled glyph in navBarSelected on a '
        '12 % teal disc; the others are the outline in navBarUnselected', (
      tester,
    ) async {
      await _pump(tester, selected: 2);

      final selected = tester.widget<Icon>(find.byIcon(Icons.event));
      expect(selected.color, AppColors.light.navBarSelected);
      expect(find.byIcon(Icons.event_outlined), findsNothing);
      final disc = tester.widget<Container>(
        find.ancestor(
          of: find.byIcon(Icons.event),
          matching: find.byType(Container),
        ),
      );
      expect(
        (disc.decoration! as ShapeDecoration).color,
        AppPalette.tealElectric.withValues(alpha: 0.12),
      );
      expectSize(
        tester,
        find.ancestor(
          of: find.byIcon(Icons.event),
          matching: find.byType(Container),
        ),
        width: 48,
        height: 48,
        tolerance: 0,
      );

      final other = tester.widget<Icon>(find.byIcon(Icons.home_outlined));
      expect(other.color, AppColors.light.navBarUnselected);
      final plain = tester.widget<Container>(
        find.ancestor(
          of: find.byIcon(Icons.home_outlined),
          matching: find.byType(Container),
        ),
      );
      expect((plain.decoration! as ShapeDecoration).color, isNull);
    });

    testWidgets('with no selection every glyph is the outline one', (
      tester,
    ) async {
      await _pump(tester, selected: null);

      for (final d in _five) {
        expect(find.byIcon(d.icon), findsOneWidget);
      }
      expect(find.byIcon(Icons.home), findsNothing);
    });

    testWidgets('cells are announced as a selected / unselected group', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, selected: 0);

      expect(
        tester.getSemantics(find.bySemanticsLabel('Home')),
        isSemantics(
          label: 'Home',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Explore')),
        isSemantics(
          label: 'Explore',
          isButton: true,
          isSelected: false,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });
  });

  group('labels (D3)', () {
    for (final scale in [1.0, 1.3]) {
      testWidgets('x$scale: a 12sp label under each icon; Notifications '
          'reads "Alerts" and is still spoken in full', (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, destinations: _two, textScale: scale, selected: 1);

        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Alerts'), findsOneWidget);
        expect(find.text('Notifications'), findsNothing);
        expect(find.byType(Tooltip), findsNothing);

        final label = tester.widget<Text>(find.text('Home'));
        expect(label.style!.fontSize, 12);
        expect(label.style!.color, AppColors.light.navBarUnselected);
        final selected = tester.widget<Text>(find.text('Alerts'));
        expect(selected.style!.color, AppColors.light.navBarSelected);
        expect(selected.style!.fontWeight, FontWeight.w700);

        // The label is under the icon, inside the pill.
        final pill = tester.getRect(_pill);
        final icon = tester.getRect(find.byIcon(Icons.home_outlined));
        final text = tester.getRect(find.text('Home'));
        expect(text.top, greaterThanOrEqualTo(icon.bottom));
        expect(text.bottom, lessThanOrEqualTo(pill.bottom));
        expect(icon.top, greaterThanOrEqualTo(pill.top));

        expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
        expect(find.bySemanticsLabel('Alerts'), findsNothing);
        expectNoOverflow(tester);
        handle.dispose();
      });
    }

    testWidgets('x2.0: icon-only, with a tooltip and the full semantics '
        'label', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, destinations: _two, textScale: 2, selected: 1);

      expect(find.text('Home'), findsNothing);
      expect(find.text('Alerts'), findsNothing);
      expect(find.byTooltip('Home'), findsOneWidget);
      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Notifications')),
        isSemantics(
          label: 'Notifications',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      // The pill keeps its height: nothing scales but the labels.
      expect(tester.getRect(_pill).height, 66);
      expectNoOverflow(tester);
      handle.dispose();
    });

    testWidgets('a label that does not fit its cell makes every cell '
        'icon-only', (tester) async {
      // The test font is 12dp per glyph: "Messages" needs 96dp, a cell of
      // the five has 60.8dp.
      await _pump(tester);

      for (final d in _five) {
        expect(find.text(d.barLabelText), findsNothing);
        expect(find.byTooltip(d.label), findsOneWidget);
      }
      expectNoOverflow(tester);
    });

    testWidgets('a custom tooltip wins over the label', (tester) async {
      await _pump(
        tester,
        textScale: 2,
        destinations: const [
          AppNavDestination(
            icon: Icons.home_outlined,
            selectedIcon: Icons.home,
            label: 'Home',
            tooltip: 'Your timeline',
          ),
        ],
      );

      expect(find.byTooltip('Your timeline'), findsOneWidget);
    });
  });

  group('badges', () {
    const unreadAlerts = AppNavDestination(
      icon: Icons.notifications_none,
      selectedIcon: Icons.notifications,
      label: 'Notifications',
      barLabel: 'Alerts',
      badgeLabel: '7',
      badgeSemanticLabel: '7 unread',
    );
    const unreadMessages = AppNavDestination(
      icon: Icons.mail_outline,
      selectedIcon: Icons.mail,
      label: 'Messages',
      badgeLabel: '3',
      badgeSemanticLabel: '3 unread conversations',
      badgeCount: 3,
    );

    for (final brightness in Brightness.values) {
      testWidgets('activity is the dot, messages the count, both readable on '
          'navy in ${brightness.name}', (tester) async {
        await _pump(
          tester,
          destinations: const [_home, unreadAlerts, unreadMessages],
          brightness: brightness,
        );

        // Activity: the dot, no digits.
        expect(find.byType(AppUnreadDot), findsOneWidget);
        expect(find.text('7'), findsNothing);
        final dot = tester.widget<AppUnreadDot>(find.byType(AppUnreadDot));
        expect(dot.ringColor, AppPalette.navy);
        final core = tester.widget<Container>(
          find
              .descendant(
                of: find.byType(AppUnreadDot),
                matching: find.byType(Container),
              )
              .last,
        );
        final coreColor = (core.decoration! as BoxDecoration).color!;
        expect(coreColor, AppPalette.tealElectric);
        expect(contrast(coreColor, AppPalette.navy), greaterThanOrEqualTo(3));

        // Messages: the count, inverted for the navy pill.
        final count = tester.widget<AppCountBadge>(find.byType(AppCountBadge));
        expect(count.count, 3);
        expect(count.onNavy, isTrue);
        expect(find.text('3'), findsOneWidget);

        // Both stay inside the pill.
        final pill = tester.getRect(_pill);
        for (final badge in [
          find.byType(AppUnreadDot),
          find.byType(AppCountBadge),
        ]) {
          final rect = tester.getRect(badge);
          expect(rect.top, greaterThanOrEqualTo(pill.top));
          expect(rect.bottom, lessThanOrEqualTo(pill.bottom));
        }
      });
    }

    testWidgets('a count above the cap shows as 99+', (tester) async {
      await _pump(
        tester,
        destinations: const [
          _home,
          AppNavDestination(
            icon: Icons.mail_outline,
            selectedIcon: Icons.mail,
            label: 'Messages',
            badgeLabel: '99+',
            badgeSemanticLabel: '99+ unread conversations',
            badgeCount: 100,
          ),
        ],
      );

      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('the badge is spoken with the cell: "Messages, 3 unread '
        'conversations"', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        destinations: const [_home, unreadAlerts, unreadMessages],
      );

      expect(
        find.bySemanticsLabel('Messages, 3 unread conversations'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Notifications, 7 unread'), findsOneWidget);
      // One node per cell: the badge is not announced a second time.
      expect(find.bySemanticsLabel('3 unread conversations'), findsNothing);
      expect(find.bySemanticsLabel('7 unread'), findsNothing);
      handle.dispose();
    });

    testWidgets('no badge without a badge label', (tester) async {
      await _pump(tester);

      expect(find.byType(AppUnreadDot), findsNothing);
      expect(find.byType(AppCountBadge), findsNothing);
    });
  });

  group('contrast on navy', () {
    for (final colors in [AppColors.light, AppColors.dark]) {
      test('glyphs and labels in ${colors == AppColors.dark ? 'dark' : 'light'}'
          ' are AA', () {
        expect(colors.navBarSurface, AppPalette.navy);
        expect(colors.navBarUnselected, AppPalette.mutedOnDark);
        // 7.15: the unselected glyph (>= 3) and its 12sp label (>= 4.5).
        expect(
          contrast(colors.navBarUnselected, colors.navBarSurface),
          closeTo(7.15, 0.05),
        );
        expect(
          contrast(colors.navBarSelected, colors.navBarSurface),
          greaterThanOrEqualTo(4.5),
        );
        // The selected glyph sits on the 12 % disc, not on bare navy.
        final disc = Color.alphaBlend(
          colors.navBarSelected.withValues(
            alpha: AppFloatingBottomBar.selectedDiscOpacity,
          ),
          colors.navBarSurface,
        );
        expect(
          contrast(colors.navBarSelected, disc),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  group('hit testing around the pill', () {
    testWidgets('the page stays tappable beside and below the pill', (
      tester,
    ) async {
      var under = 0;
      final taps = <int>[];
      await _pump(tester, onUnderTap: () => under++, onSelected: taps.add);

      final pill = tester.getRect(_pill);
      // Left and right of the pill, in its row.
      await tester.tapAt(Offset(10, pill.center.dy));
      await tester.tapAt(Offset(350, pill.center.dy));
      // The 24dp strip under it.
      await tester.tapAt(Offset(180, pill.bottom + 12));
      expect(under, 3);
      expect(taps, isEmpty);

      // The pill itself takes the tap.
      await tester.tapAt(pill.center);
      expect(under, 3);
      expect(taps, [2]);
    });

    testWidgets('the padding of the pill does not leak taps to the page', (
      tester,
    ) async {
      var under = 0;
      await _pump(tester, onUnderTap: () => under++);

      final pill = tester.getRect(_pill);
      await tester.tapAt(Offset(pill.left + 2, pill.center.dy));
      expect(under, 0);
    });
  });

  group('matrix', () {
    forEachThemeAndWidth(
      'fits with 48dp cells',
      (tester, env) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          width: env.size.width,
          brightness: env.brightness,
          textScale: env.textScale,
          destinations: const [
            _home,
            _explore,
            _plans,
            AppNavDestination(
              icon: Icons.notifications_none,
              selectedIcon: Icons.notifications,
              label: 'Notifications',
              barLabel: 'Alerts',
              badgeLabel: '7',
              badgeSemanticLabel: '7 unread',
            ),
            AppNavDestination(
              icon: Icons.mail_outline,
              selectedIcon: Icons.mail,
              label: 'Messages',
              badgeLabel: '99+',
              badgeSemanticLabel: '99+ unread conversations',
              badgeCount: 100,
            ),
          ],
        );

        expectNoOverflow(tester);
        for (final label in ['Home', 'Explore', 'Plans']) {
          final cell = _cell(tester, label);
          expect(cell.width, greaterThanOrEqualTo(48));
          expect(cell.height, greaterThanOrEqualTo(48));
        }
        handle.dispose();
      },
      // The bar is phone chrome: the narrowest phone, the matrix phone and
      // the last width below the 600dp boundary.
      widths: const [320, 360, 599],
      textScales: kMatrixTextScalesLarge,
    );
  });

  test('the legacy bar keeps its 56dp token', () {
    expect(AppSize.bottomNav, 56);
    expect(AppSize.floatingNavHeight, 66);
    expect(AppSize.floatingNavInset, 20);
    expect(AppSize.floatingNavBottom, 24);
    expect(AppFloatingBottomBar.reservedHeight, 90);
  });
}
