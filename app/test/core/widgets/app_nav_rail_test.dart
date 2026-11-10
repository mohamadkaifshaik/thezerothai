import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';
import '../../support/contrast.dart';
import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

// The new shell's destinations: the primary five, then the secondaries and
// More (the item with `onActivate`).
List<AppNavDestination> _shell({
  void Function(BuildContext anchor)? onMore,
  String notificationsBadge = '',
}) => [
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
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
    badgeLabel: notificationsBadge,
    badgeSemanticLabel: notificationsBadge.isEmpty
        ? null
        : '$notificationsBadge unread',
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
    onActivate: onMore ?? (_) {},
  ),
];

const _labels = [
  'Home',
  'Explore',
  'Plans',
  'Notifications',
  'Messages',
  'Lists',
  'Communities',
  'History',
  'Profile',
  'More',
];

// Primaries with short labels (test-only names), so labels fit at 1.3.
const _shortLabels = ['Home', 'Feed', 'Plans', 'Inbox', 'Chat'];

List<AppNavDestination> _short() => [
  for (final (i, d) in _shell().indexed)
    i < 5
        ? AppNavDestination(
            icon: d.icon,
            selectedIcon: d.selectedIcon,
            label: _shortLabels[i],
          )
        : d,
];

const _composeKey = Key('compose');
const _accountKey = Key('account');
const _bodyKey = Key('body-button');

Finder _inRail(Finder f) =>
    find.descendant(of: find.byType(AppNavRail), matching: f);

Future<void> _pump(
  WidgetTester tester, {
  double width = 1024,
  double height = 768,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  int? selected = 0,
  List<AppNavDestination>? destinations,
  ValueChanged<int>? onSelected,
  bool moreHasOwnRows = true,
  void Function(BuildContext anchor, List<int> folded)? onMoreFolded,
  EdgeInsets padding = EdgeInsets.zero,
  bool compose = true,
  bool account = true,
  bool before = false,
  bool accountMenu = false,
}) => pumpThemed(
  tester,
  Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(padding: padding),
      child: _withBefore(
        before,
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: AppSize.railCompact + padding.left,
              child: FocusTraversalGroup(
                child: AppNavRail(
                  destinations: destinations ?? _shell(),
                  selectedIndex: selected,
                  onDestinationSelected: onSelected ?? (_) {},
                  moreHasOwnRows: moreHasOwnRows,
                  onMoreFolded: onMoreFolded,
                  compose: compose
                      ? IconButton(
                          key: _composeKey,
                          tooltip: 'New post',
                          onPressed: () {},
                          icon: const Icon(Icons.edit_outlined),
                        )
                      : null,
                  account: !account
                      ? null
                      : accountMenu
                      // Like `AppAccountChip`: a button that opens a menu.
                      ? PopupMenuButton<int>(
                          key: _accountKey,
                          tooltip: 'Account menu',
                          icon: const Icon(Icons.account_circle),
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 1, child: Text('menu row')),
                          ],
                        )
                      : IconButton(
                          key: _accountKey,
                          tooltip: 'Account menu',
                          onPressed: () {},
                          icon: const Icon(Icons.account_circle),
                        ),
                ),
              ),
            ),
            Expanded(
              child: FocusTraversalGroup(
                child: Center(
                  child: TextButton(
                    key: _bodyKey,
                    onPressed: () {},
                    child: const Text('body'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
  size: Size(width, height),
  textScale: textScale,
  brightness: brightness,
  useScaffold: true,
);

const _beforeKey = Key('before-button');

/// [child], under a focusable control that comes before the rail in the
/// traversal order when [before] is set.
Widget _withBefore(bool before, Widget child) => before
    ? Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: _beforeKey,
              onPressed: () {},
              child: const Text('before'),
            ),
          ),
          Expanded(child: child),
        ],
      )
    : child;

/// The rail items that are drawn, top to bottom, by their glyph.
List<String> _visible(WidgetTester tester, List<AppNavDestination> all) {
  final shown = <(double, String)>[];
  for (final d in all) {
    for (final icon in {d.icon, d.selectedIcon}) {
      final f = _inRail(find.byIcon(icon));
      if (f.evaluate().isNotEmpty) {
        shown.add((tester.getCenter(f.first).dy, d.label));
        break;
      }
    }
  }
  shown.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final s in shown) s.$2];
}

void main() {
  // Label visibility depends on measured widths: use the bundled DM Sans
  // (the default test font draws every glyph 1 em wide).
  setUpAll(loadAppFonts);

  test('density thresholds: R1 from 700, R2 from 500, R3 below', () {
    expect(AppNavRailDensity.of(1366), AppNavRailDensity.full);
    expect(AppNavRailDensity.of(700), AppNavRailDensity.full);
    expect(AppNavRailDensity.of(699), AppNavRailDensity.folded);
    expect(AppNavRailDensity.of(500), AppNavRailDensity.folded);
    expect(AppNavRailDensity.of(499), AppNavRailDensity.compact);
    expect(AppNavRailDensity.of(390), AppNavRailDensity.compact);
    // The stacks the thresholds were derived from (plan section 2.1).
    const full = 8 + 5 * 56 + 17 + 5 * 48 + 68 + 64;
    const folded = 8 + 5 * 56 + 17 + 48 + 68 + 64;
    expect(full, 677);
    expect(folded, 485);
  });

  group('R1 (1024 x 768)', () {
    testWidgets('every item in order: labelled primaries, a divider, then '
        'icon-only secondaries with tooltips', (tester) async {
      await _pump(tester, selected: null);

      expect(_visible(tester, _shell()), _labels);
      for (final label in _labels.take(5)) {
        expect(_inRail(find.text(label)), findsOneWidget, reason: label);
      }
      for (final label in _labels.skip(5)) {
        expect(_inRail(find.text(label)), findsNothing, reason: label);
        expect(_inRail(find.byTooltip(label)), findsOneWidget, reason: label);
      }
      // The group divider sits between Messages and Lists.
      final divider = tester.getCenter(_inRail(find.byType(Divider))).dy;
      expect(
        divider,
        greaterThan(
          tester.getCenter(_inRail(find.byIcon(Icons.mail_outline))).dy,
        ),
      );
      expect(
        divider,
        lessThan(
          tester.getCenter(_inRail(find.byIcon(Icons.list_alt_outlined))).dy,
        ),
      );
      expect(
        tester.widget<Divider>(_inRail(find.byType(Divider))).color,
        AppColors.light.hairline,
      );
      expectNoOverflow(tester);
      _expectUnclipped(tester);
    });

    testWidgets('pinned at x = 0, 80 dp wide, on the rail surface with a '
        'trailing hairline; compose after the items, account at the '
        'bottom', (tester) async {
      await _pump(tester);

      expect(
        tester.getRect(find.byType(AppNavRail)),
        const Rect.fromLTWH(0, 0, 80, 768),
      );
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppNavRail),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final decoration = box.decoration as BoxDecoration;
      // The surface is a Material (the items' ink paints on it).
      final surface = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppNavRail),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(surface.color, appLightTheme.navigationRailTheme.backgroundColor);
      expect(decoration.color, isNull);
      expect(
        (decoration.border! as BorderDirectional).end.color,
        AppColors.light.hairline,
      );
      final more = tester.getRect(_inRail(find.byIcon(Icons.more_horiz)));
      final compose = tester.getRect(find.byKey(_composeKey));
      final account = tester.getRect(find.byKey(_accountKey));
      expect(compose.top, greaterThan(more.bottom));
      expect(account.top, greaterThan(compose.bottom + 100));
      expect(account.bottom, lessThanOrEqualTo(768));
      expect(768 - account.bottom, lessThan(AppNavRail.accountSlot));
    });

    testWidgets('More is left out when it has no rows and nothing is '
        'folded', (tester) async {
      await _pump(tester, moreHasOwnRows: false);

      expect(_inRail(find.byIcon(Icons.more_horiz)), findsNothing);
      expect(_visible(tester, _shell()), _labels.take(9));
    });

    testWidgets('a tap selects; More activates with no folded rows', (
      tester,
    ) async {
      final picked = <int>[];
      final activated = <BuildContext>[];
      final folded = <List<int>>[];
      await _pump(
        tester,
        destinations: _shell(onMore: activated.add),
        onSelected: picked.add,
        onMoreFolded: (anchor, rows) => folded.add(rows),
      );

      await tester.tap(_inRail(find.byIcon(Icons.groups_outlined)));
      await tester.tap(_inRail(find.byIcon(Icons.notifications_none)));
      expect(picked, [6, 3]);
      await tester.tap(_inRail(find.byIcon(Icons.more_horiz)));
      expect(activated, hasLength(1));
      expect(folded, isEmpty);
      expect(picked, [6, 3]);
    });
  });

  group('R2 (1024 x 640)', () {
    testWidgets('the secondaries fold into More, which lists them first', (
      tester,
    ) async {
      final folded = <List<int>>[];
      final activated = <BuildContext>[];
      await _pump(
        tester,
        height: 640,
        destinations: _shell(onMore: activated.add),
        onMoreFolded: (anchor, rows) {
          folded.add(rows);
          expect(anchor.mounted, isTrue);
        },
      );

      expect(_visible(tester, _shell()), [..._labels.take(5), 'More']);
      expect(_inRail(find.byType(Divider)), findsOneWidget);
      await tester.tap(_inRail(find.byIcon(Icons.more_horiz)));
      expect(folded, [
        [5, 6, 7, 8],
      ]);
      expect(activated, isEmpty);
      expectNoOverflow(tester);
      _expectUnclipped(tester);
    });

    testWidgets('without a More destination nothing folds: the secondaries '
        'stay on the rail', (tester) async {
      final noMore = _shell().where((d) => d.onActivate == null).toList();
      await _pump(tester, height: 640, destinations: noMore);

      expect(_visible(tester, noMore), _labels.take(9));
      expectNoOverflow(tester);
      _expectUnclipped(tester);
    });

    testWidgets('More shows even without rows of its own', (tester) async {
      await _pump(tester, height: 640, moreHasOwnRows: false);

      expect(_inRail(find.byIcon(Icons.more_horiz)), findsOneWidget);
    });

    testWidgets('a folded selection selects More', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, height: 640, selected: 6);

      expect(
        tester.getSemantics(_inRail(find.byIcon(Icons.more_horiz))),
        isSemantics(label: 'More, menu', isSelected: true, isButton: true),
      );
      expect(
        tester.getSemantics(_inRail(find.byIcon(Icons.home_outlined))),
        isSemantics(isSelected: false, hasSelectedState: true),
      );
      handle.dispose();
    });
  });

  group('R3 (844 x 390, a phone in landscape)', () {
    testWidgets('icon-only items in a scrolling region; compose and account '
        'pinned', (tester) async {
      await _pump(tester, width: 844, height: 390);

      for (final label in _labels) {
        expect(_inRail(find.text(label)), findsNothing, reason: label);
      }
      expect(_inRail(find.byTooltip('Home')), findsOneWidget);
      final scrollable = tester.state<ScrollableState>(
        _inRail(find.byType(Scrollable)),
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      final compose = tester.getRect(find.byKey(_composeKey));
      final account = tester.getRect(find.byKey(_accountKey));
      expect(account.bottom, lessThanOrEqualTo(390));
      expect(compose.bottom, lessThanOrEqualTo(account.top));
      // The region ends above the pinned compose button.
      final region = tester.getRect(_inRail(find.byType(Scrollable)));
      expect(region.bottom, lessThanOrEqualTo(compose.top));
      expectNoOverflow(tester);
      _expectUnclipped(tester);

      // Scrolling the region leaves the pinned controls where they are.
      await tester.drag(
        _inRail(find.byType(Scrollable)),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(tester.getRect(find.byKey(_composeKey)), compose);
      expect(tester.getRect(find.byKey(_accountKey)), account);
    });

    testWidgets('the arrow keys scroll the focused item into view', (
      tester,
    ) async {
      await _pump(tester, width: 844, height: 390);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      final more = _inRail(find.byIcon(Icons.more_horiz));
      expect(Focus.of(tester.element(more)).hasPrimaryFocus, isTrue);
      final region = tester.getRect(_inRail(find.byType(Scrollable)));
      final item = tester.getRect(more);
      expect(item.top, greaterThanOrEqualTo(region.top - 0.5));
      expect(item.bottom, lessThanOrEqualTo(region.bottom + 0.5));
    });
  });

  group('labels and text scale', () {
    testWidgets('at 1.0 the labels show at their own size, never through a '
        'FittedBox', (tester) async {
      await _pump(tester, selected: 3);

      for (final label in _labels.take(5)) {
        final text = _inRail(find.text(label));
        expect(text, findsOneWidget, reason: label);
        expect(
          find.ancestor(of: text, matching: find.byType(FittedBox)),
          findsNothing,
          reason: label,
        );
        expect(tester.getSize(text).height, 16, reason: label);
      }
    });

    // Owner decision 2026-11-10: rail labels may wrap to two lines.
    for (final scale in [1.1, 1.3]) {
      testWidgets('at $scale "Notifications" wraps to two balanced lines and '
          'the labels show; semantics and tooltips are unchanged', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, textScale: scale, selected: 3);

        final text = _inRail(find.text('Notifications'));
        expect(text, findsOneWidget);
        // Two lines of 12 sp x scale x 1.33, never shrunk.
        final line = (12 * scale * 1.33).roundToDouble();
        final size = tester.getSize(text);
        expect(size.height, greaterThanOrEqualTo(2 * line - 1));
        expect(size.height, lessThan(3 * line - 1));
        // Balanced halves: well inside the 78 dp item, not "Notification / s".
        expect(size.width, lessThanOrEqualTo(60));
        expect(
          find.ancestor(of: text, matching: find.byType(FittedBox)),
          findsNothing,
        );
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.textAlign, TextAlign.center);
        expect(paragraph.maxLines, 2);
        // The other labels are one line, at the same scale.
        for (final label in ['Home', 'Explore', 'Plans', 'Messages']) {
          expect(
            tester.getSize(_inRail(find.text(label))).height,
            line,
            reason: label,
          );
        }
        // Spoken as one word; the secondaries keep their tooltips.
        expect(
          tester.getSemantics(_inRail(find.byIcon(Icons.notifications))),
          isSemantics(label: 'Notifications', isSelected: true),
        );
        for (final label in _labels.skip(5)) {
          expect(_inRail(find.byTooltip(label)), findsOneWidget);
        }
        expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
        expectNoOverflow(tester);
        _expectUnclipped(tester);
        handle.dispose();
      });
    }

    testWidgets('the Notifications item grows with its two lines; the item '
        'height does not change with the selection', (tester) async {
      await _pump(tester, textScale: 1.3, selected: 3);
      Rect item(IconData icon) => tester.getRect(
        find
            .ancestor(
              of: _inRail(find.byIcon(icon)),
              matching: find.byType(InkWell),
            )
            .first,
      );
      final tall = item(Icons.notifications).height;
      final one = item(Icons.home_outlined).height;
      expect(tall, greaterThan(one + 15));

      await _pump(tester, textScale: 1.3, selected: 0);
      expect(item(Icons.notifications_none).height, tall);
      expect(item(Icons.home).height, one);
    });

    testWidgets('at 1.3 labels that fit are drawn at the full scale', (
      tester,
    ) async {
      await _pump(tester, textScale: 1.3, destinations: _short());

      for (final label in _shortLabels) {
        final text = _inRail(find.text(label));
        expect(text, findsOneWidget, reason: label);
        // 12 sp x 1.3 x 1.33 line height: the user's scale, unshrunk.
        expect(tester.getSize(text).height, 21, reason: label);
        expect(
          find.ancestor(of: text, matching: find.byType(FittedBox)),
          findsNothing,
          reason: label,
        );
      }
      expectNoOverflow(tester);
      _expectUnclipped(tester);
    });

    // R2's floor is 500, but with labels at 1.3 the folded stack is
    // 531 dp (Notifications on two lines) or 510 dp (short labels): the rail
    // steps down to R3 instead of overlapping or scrolling away.
    for (final short in [false, true]) {
      final set = short ? 'short labels' : 'with Notifications';
      testWidgets('1024 x 500 at 1.3 ($set): the measured stack does not fit '
          'R2, so R3: icon-only, compose pinned, nothing overlaps', (
        tester,
      ) async {
        await _pump(
          tester,
          height: 500,
          textScale: 1.3,
          destinations: short ? _short() : null,
        );

        for (final label in short ? _shortLabels : _labels.take(5)) {
          expect(_inRail(find.text(label)), findsNothing, reason: label);
          expect(_inRail(find.byTooltip(label)), findsOneWidget);
        }
        final compose = tester.getRect(find.byKey(_composeKey));
        final account = tester.getRect(find.byKey(_accountKey));
        final region = tester.getRect(_inRail(find.byType(Scrollable)));
        final more = tester.getRect(_inRail(find.byIcon(Icons.more_horiz)));
        expect(compose.top, greaterThanOrEqualTo(region.bottom));
        expect(compose.bottom, lessThanOrEqualTo(account.top));
        expect(account.bottom, lessThanOrEqualTo(500));
        // Every item is in view: nothing scrolled away.
        expect(more.bottom, lessThanOrEqualTo(region.bottom));
        expectNoOverflow(tester);
        _expectUnclipped(tester);
      });
    }

    testWidgets('1024 x 520 at 1.3 with short labels: the folded stack '
        '(510 dp) fits, so R2 with labels and compose after the items', (
      tester,
    ) async {
      await _pump(tester, height: 520, textScale: 1.3, destinations: _short());

      expect(_inRail(find.text('Inbox')), findsOneWidget);
      expect(_inRail(find.byIcon(Icons.list_alt_outlined)), findsNothing);
      final more = tester.getRect(
        find
            .ancestor(
              of: _inRail(find.byIcon(Icons.more_horiz)),
              matching: find.byType(InkWell),
            )
            .first,
      );
      final compose = tester.getRect(find.byKey(_composeKey));
      final account = tester.getRect(find.byKey(_accountKey));
      expect(compose.top - more.bottom, closeTo(AppNavRail.composeGap, 0.5));
      expect(compose.bottom, lessThanOrEqualTo(account.top));
      expect(
        tester
            .state<ScrollableState>(_inRail(find.byType(Scrollable)))
            .position
            .maxScrollExtent,
        0,
      );
      expectNoOverflow(tester);
      _expectUnclipped(tester);
    });

    testWidgets('1024 x 700 at 1.3: the full stack with two-line '
        'Notifications (723 dp) does not fit R1, so R2; 768 is R1', (
      tester,
    ) async {
      await _pump(tester, height: 700, textScale: 1.3);

      expect(_inRail(find.text('Notifications')), findsOneWidget);
      expect(_inRail(find.byIcon(Icons.list_alt_outlined)), findsNothing);
      await _pump(tester, height: 768, textScale: 1.3);
      expect(_inRail(find.byIcon(Icons.list_alt_outlined)), findsOneWidget);
      expectNoOverflow(tester);
      _expectUnclipped(tester);
    });

    testWidgets('R1 where everything fits: compose follows the items', (
      tester,
    ) async {
      await _pump(tester, height: 768, destinations: _short());

      final more = tester.getRect(
        find
            .ancestor(
              of: _inRail(find.byIcon(Icons.more_horiz)),
              matching: find.byType(InkWell),
            )
            .first,
      );
      final compose = tester.getRect(find.byKey(_composeKey));
      expect(compose.top - more.bottom, closeTo(AppNavRail.composeGap, 0.5));
      // Inside the destination region, right after the items.
      expect(
        compose.bottom,
        lessThanOrEqualTo(
          tester.getRect(_inRail(find.byType(Scrollable))).bottom,
        ),
      );
    });

    for (final scale in [1.31, 2.0]) {
      testWidgets('above 1.3 ($scale) every item is icon-only with a tooltip '
          'and keeps its spoken label', (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, textScale: scale, selected: 3);

        for (final label in _labels) {
          expect(_inRail(find.text(label)), findsNothing, reason: label);
          expect(_inRail(find.byTooltip(label)), findsOneWidget, reason: label);
        }
        expect(
          tester.getSemantics(_inRail(find.byIcon(Icons.notifications))),
          isSemantics(label: 'Notifications', isSelected: true),
        );
        expectNoOverflow(tester);
        _expectUnclipped(tester);
        handle.dispose();
      });
    }

    testWidgets('the label is spoken once: tooltips stay out of the '
        'semantics tree', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);

      expect(find.bySemanticsLabel('Lists'), findsOneWidget);
      expect(find.bySemanticsLabel('Home'), findsOneWidget);
      handle.dispose();
    });
  });

  group('selection and badges', () {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: the selected item has the pill, the '
          'filled glyph in onPrimary and a w800 label', (tester) async {
        await _pump(tester, selected: 3, brightness: brightness);
        final colors = brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light;
        final scheme = buildAppTheme(brightness: brightness).colorScheme;

        expect(_inRail(find.byIcon(Icons.notifications)), findsOneWidget);
        expect(_inRail(find.byIcon(Icons.notifications_none)), findsNothing);
        final pill = tester.widget<Container>(
          find
              .ancestor(
                of: _inRail(find.byIcon(Icons.notifications)),
                matching: find.byType(Container),
              )
              .first,
        );
        final shape = pill.decoration! as ShapeDecoration;
        expect(shape.color, colors.selectedIndicator);
        expect(shape.shape, const StadiumBorder());
        TextStyle painted(Finder f) => tester
            .widget<RichText>(
              find.descendant(of: f, matching: find.byType(RichText)).first,
            )
            .text
            .style!;
        expect(
          painted(_inRail(find.byIcon(Icons.notifications))).color,
          scheme.onPrimary,
        );
        expect(
          painted(_inRail(find.byIcon(Icons.home_outlined))).color,
          colors.text2,
        );
        final selected = painted(_inRail(find.text('Notifications')));
        expect(selected.fontWeight, FontWeight.w800);
        expect(selected.fontVariations, isNull);
        expect(selected.fontSize, 12);
        expect(selected.color, scheme.onSurface);
        final other = painted(_inRail(find.text('Home')));
        expect(other.fontWeight, FontWeight.w600);
        expect(other.color, colors.text2);
        expect(
          contrast(scheme.onPrimary, colors.selectedIndicator),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(colors.text2, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
    }

    testWidgets('a badge is drawn and spoken with the label', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, destinations: _shell(notificationsBadge: '7'));

      expect(_inRail(find.text('7')), findsOneWidget);
      expect(find.bySemanticsLabel('Notifications, 7 unread'), findsOneWidget);
      handle.dispose();
    });
  });

  testWidgets('the brand mark only from 900 dp, outside the semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, height: 1366);
    expect(_inRail(find.byType(Image)), findsOneWidget);
    expect(
      find.ancestor(
        of: _inRail(find.byType(Image)),
        matching: find.byType(ExcludeSemantics),
      ),
      findsWidgets,
    );

    await _pump(tester, height: 899);
    expect(_inRail(find.byType(Image)), findsNothing);
    handle.dispose();
  });

  testWidgets('safe areas: the surface fills the insets, the items are '
      'padded by them', (tester) async {
    const padding = EdgeInsets.fromLTRB(44, 24, 0, 20);
    await _pump(tester, width: 932, height: 430, padding: padding);

    expect(
      tester.getRect(find.byType(AppNavRail)),
      const Rect.fromLTWH(0, 0, 124, 430),
    );
    final home = tester.getRect(_inRail(find.byIcon(Icons.home)));
    expect(home.left, greaterThanOrEqualTo(44));
    expect(home.center.dx, closeTo(44 + 40, 0.5));
    expect(home.top, greaterThanOrEqualTo(24 + AppNavRail.topGap));
    expect(
      tester.getRect(find.byKey(_accountKey)).bottom,
      lessThanOrEqualTo(430 - 20),
    );
    expectNoOverflow(tester);
    _expectUnclipped(tester);
  });

  group('keyboard: roving focus', () {
    bool focused(WidgetTester tester, Finder f) =>
        Focus.of(tester.element(f)).hasPrimaryFocus;

    testWidgets('one Tab stop (the selected item); Tab moves on to the '
        'pane, Shift+Tab comes back to it', (tester) async {
      await _pump(tester, selected: 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(tester, _inRail(find.byIcon(Icons.adjust))), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        Focus.of(tester.element(find.text('body'))).hasPrimaryFocus,
        isTrue,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(focused(tester, _inRail(find.byIcon(Icons.adjust))), isTrue);
    });

    testWidgets('no selection: the first item is the Tab stop', (tester) async {
      await _pump(tester, selected: null);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        focused(tester, _inRail(find.byIcon(Icons.home_outlined))),
        isTrue,
      );
    });

    Future<void> shiftTab(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }

    // Arrowed-to stops: a non-selected item, compose, the account chip.
    final stops = <String, (int, Finder Function())>{
      'an item (Explore)': (1, () => _inRail(find.byIcon(Icons.search))),
      'compose': (10, () => find.byIcon(Icons.edit_outlined)),
      'the account': (11, () => find.byIcon(Icons.account_circle)),
    };
    for (final MapEntry(key: name, value: (downs, finder)) in stops.entries) {
      Future<void> arrowTo(WidgetTester tester) async {
        await _pump(tester, selected: 0, before: true);
        // Into the rail from the control before it.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          Focus.of(tester.element(find.text('before'))).hasPrimaryFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focused(tester, _inRail(find.byIcon(Icons.home))), isTrue);
        for (var i = 0; i < downs; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        expect(focused(tester, finder()), isTrue, reason: name);
      }

      testWidgets('from $name reached by the arrows, Tab leaves the rail for '
          'the pane', (tester) async {
        await arrowTo(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          Focus.of(tester.element(find.text('body'))).hasPrimaryFocus,
          isTrue,
        );
      });

      testWidgets('from $name reached by the arrows, Shift+Tab leaves the '
          'rail for what comes before it', (tester) async {
        await arrowTo(tester);
        await shiftTab(tester);
        expect(
          Focus.of(tester.element(find.text('before'))).hasPrimaryFocus,
          isTrue,
        );
        // Coming back in lands on the selected item again.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focused(tester, _inRail(find.byIcon(Icons.home))), isTrue);
      });
    }

    // A menu opened from the rail takes the focus out of it; when the menu
    // closes the focus comes back to the stop that opened it, which must be
    // the Tab stop again.
    final menuStops = <String, int>{'the account chip': 11, 'More': 9};
    for (final MapEntry(key: name, value: downs) in menuStops.entries) {
      testWidgets('$name: Enter opens its menu, Escape returns the focus, and '
          'Shift+Tab then leaves the rail', (tester) async {
        await _pump(
          tester,
          selected: 0,
          before: true,
          accountMenu: true,
          destinations: _shell(
            onMore: (anchor) => showMenu<int>(
              context: anchor,
              position: const RelativeRect.fromLTRB(80, 0, 0, 0),
              items: const [PopupMenuItem(value: 1, child: Text('menu row'))],
            ),
          ),
        );
        final stop = name == 'More'
            ? _inRail(find.byIcon(Icons.more_horiz))
            : find.byIcon(Icons.account_circle);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        for (var i = 0; i < downs; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        expect(focused(tester, stop), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('menu row'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('menu row'), findsNothing);
        expect(focused(tester, stop), isTrue);

        await shiftTab(tester);
        expect(
          Focus.of(tester.element(find.text('before'))).hasPrimaryFocus,
          isTrue,
        );
      });
    }

    testWidgets('the arrows walk the items, then compose and the account; '
        'Enter activates', (tester) async {
      final picked = <int>[];
      await _pump(tester, selected: 0, onSelected: picked.add);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final order = [
        for (final d in _shell().skip(1)) _inRail(find.byIcon(d.icon)),
        find.byIcon(Icons.edit_outlined),
        find.byIcon(Icons.account_circle),
      ];
      for (final f in order) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(focused(tester, f), isTrue, reason: '$f');
      }
      // The ring ends at the account.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focused(tester, find.byIcon(Icons.account_circle)), isTrue);

      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      // Account -> compose -> More -> Profile -> History.
      expect(
        focused(tester, _inRail(find.byIcon(Icons.bookmark_border))),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(picked, [7]);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(picked, [7, 7]);
    });
  });

  // Two-line labels (owner decision 2026-11-10): no overflow at the band
  // edges, at 1.0 and 1.3, on tall and short windows.
  forEachThemeAndWidth(
    'two-line labels: no overflow, nothing past the rail',
    (tester, env) async {
      for (final height in [1194.0, 768.0, 640.0, 500.0, 390.0]) {
        await _pump(
          tester,
          width: env.size.width,
          height: height,
          brightness: env.brightness,
          textScale: env.textScale,
          selected: 3,
        );
        expectNoOverflow(tester);
        _expectUnclipped(tester);
        final compose = tester.getRect(find.byKey(_composeKey));
        final account = tester.getRect(find.byKey(_accountKey));
        expect(
          compose.bottom,
          lessThanOrEqualTo(account.top),
          reason: '$height',
        );
        expect(account.bottom, lessThanOrEqualTo(height), reason: '$height');
        final text = _inRail(find.text('Notifications'));
        if (text.evaluate().isNotEmpty) {
          final r = tester.getRect(text);
          expect(r.left, greaterThanOrEqualTo(0), reason: '$height');
          expect(r.right, lessThanOrEqualTo(80), reason: '$height');
        }
      }
    },
    widths: const [600, 834, 1199],
    textScales: kMatrixTextScales,
  );

  // Tablet plan section 5.5: no overflow and 48 dp targets in every cell.
  forEachThemeAndWidth(
    'no overflow, pinned 80 dp, 48 dp targets',
    (tester, env) async {
      for (final height in {env.size.height, ...kTabletLandscapeHeights}) {
        await _pump(
          tester,
          width: env.size.width,
          height: height,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expectNoOverflow(tester);
        _expectUnclipped(tester);
        expect(
          tester.getRect(find.byType(AppNavRail)),
          Rect.fromLTWH(0, 0, 80, height),
        );
        final rail = tester.getRect(find.byType(AppNavRail));
        for (final d in _shell()) {
          final f = _inRail(find.byIcon(d.icon));
          if (f.evaluate().isEmpty) continue;
          final target = find
              .ancestor(of: f, matching: find.byType(InkWell))
              .first;
          final r = tester.getRect(target);
          // Scrolled-off items (R3) are clipped, not drawn outside.
          if (r.bottom > rail.bottom || r.top < rail.top) continue;
          expectMinTarget(tester, target, reason: '${d.label} at $height');
        }
      }
    },
    widths: kTabletMatrixWidths,
    textScales: kTabletTextScales,
    heights: kTabletHeights,
  );
}

/// Every text the rail draws is drawn in full: no label needs more lines
/// than it may show (a clipped label would pass the size and overflow
/// checks).
void _expectUnclipped(WidgetTester tester) {
  final paragraphs = find.descendant(
    of: find.byType(AppNavRail),
    matching: find.byType(RichText),
  );
  for (final element in paragraphs.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
  }
}
