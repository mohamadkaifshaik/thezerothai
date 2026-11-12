import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_form_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_main_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 680 dp readable column (tablet plan sections 2.2, 3 and 6.3; T8e):
/// on the tablet layout `AppMainColumn` caps the reading content at
/// [AppSize.readableMax], centred in its pane, while the header's divider
/// and the tab bar's hairline span the whole pane. Panes narrower than 680
/// are unaffected; phones and desktop keep today's 600 dp column between
/// two hairlines.

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _tabletFlags = {kFeatureUiShell, kFeatureUiTablet};

const _bodyKey = ValueKey('readable-body');

/// Where the page sits.
enum _Pane {
  /// The primary pane, alone (band A), or band B with no pane beside it.
  primary,

  /// Band B: the detail beside a list pane (code LD).
  detail,

  /// A full-screen root route (no shell, no rail).
  root,
}

int _backTaps = 0;

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}

int _cancelTaps = 0;
int _actionTaps = 0;

Widget _header({
  bool form = false,
  String? title,
  String actionLabel = 'Save',
}) => form
    ? AppFormHeader(
        title: title ?? 'Edit',
        onCancel: () => _cancelTaps++,
        actionLabel: actionLabel,
        onAction: () => _actionTaps++,
      )
    : AppBackHeader(
        title: title ?? 'Title',
        onBack: () => _backTaps++,
        actions: [
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onPressed: () => _actionTaps++,
          ),
        ],
      );

Widget _page({
  bool form = false,
  String? title,
  String actionLabel = 'Save',
  Widget Function(Widget header)? wrapHeader,
}) {
  final header = _header(form: form, title: title, actionLabel: actionLabel);
  return Scaffold(
    body: SafeArea(
      child: AppMainColumn(
        child: Column(
          children: [
            if (wrapHeader == null) header else wrapHeader(header),
            AppTabBar(
              tabs: const [
                AppTab(label: 'One'),
                AppTab(label: 'Two'),
              ],
              selectedIndex: 0,
              onChanged: (_) {},
            ),
            Expanded(
              child: ListView(
                key: _bodyKey,
                children: const [
                  _Counter(),
                  ListTile(title: Text('A row of reading content')),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double height = 900,
  _Pane pane = _Pane.primary,
  Set<String> flags = _tabletFlags,
  TextDirection textDirection = TextDirection.ltr,
  double textScale = 1,
  bool form = false,
  String? title,
  String actionLabel = 'Save',
  Widget Function(Widget header)? wrapHeader,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final onboarding = _MockOnboardingBloc();
  whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      enabledFeatures: flags,
      profile: identity.Profile(userId: 'u1', handle: 'alice'),
    ),
  );
  final tablet =
      flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);
  final page = _page(
    form: form,
    title: title,
    actionLabel: actionLabel,
    wrapHeader: wrapHeader,
  );
  final home = pane == _Pane.root
      ? page
      : ResponsiveScaffold(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          layout: tablet ? ShellLayout.tablet : ShellLayout.legacy,
          redesignedRail: true,
          floatingBar: true,
          destinations: const [
            AppNavDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home,
              label: 'Home',
            ),
            AppNavDestination(
              icon: Icons.search,
              selectedIcon: Icons.search,
              label: 'Explore',
            ),
          ],
          masterPane: pane == _Pane.detail
              ? const ColoredBox(color: Colors.transparent)
              : null,
          body: page,
        );
  await tester.pumpWidget(
    BlocProvider<OnboardingBloc>.value(
      value: onboarding,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: Brightness.light),
        builder: (context, child) =>
            Directionality(textDirection: textDirection, child: child!),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The pane the page is in, in window coordinates (tablet plan section 3).
Rect _paneRect(
  double width, {
  double height = 900,
  _Pane pane = _Pane.primary,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (pane == _Pane.root) return Rect.fromLTWH(0, 0, width, height);
  final c = width - AppSize.railCompact;
  final bandB = width >= AppBreakpoints.expanded;
  final double paneWidth = switch (pane) {
    _Pane.detail when bandB => c - 1 - ShellGeometry.listPaneWidthFor(c),
    _ => c,
  };
  // The rail (and in LD the list) lead.
  final double leading = pane == _Pane.detail && bandB
      ? AppSize.railCompact + ShellGeometry.listPaneWidthFor(c) + 1
      : AppSize.railCompact;
  final ltr = textDirection == TextDirection.ltr;
  final left = ltr ? leading : width - leading - paneWidth;
  return Rect.fromLTWH(left, 0, paneWidth, height);
}

Rect _body(WidgetTester tester) => tester.getRect(find.byKey(_bodyKey));

Rect _headerDivider(WidgetTester tester, {bool form = false}) => tester.getRect(
  find.descendant(
    of: find.byType(form ? AppFormHeader : AppBackHeader),
    matching: find.byType(Divider),
  ),
);

BoxDecoration _columnDecoration(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find
                  .descendant(
                    of: find.byType(AppMainColumn),
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
            )
            .decoration
        as BoxDecoration;

void main() {
  setUp(() {
    _backTaps = 0;
    _cancelTaps = 0;
    _actionTaps = 0;
  });

  group('the tablet layout: reading content at most 680, centred', () {
    // The widths of the brief: band A's edges, band B's edges and 1024.
    const cases = <(double, _Pane)>[
      (600, _Pane.primary),
      (839, _Pane.primary),
      (840, _Pane.primary),
      (1024, _Pane.primary),
      (1199, _Pane.primary),
      (840, _Pane.detail),
      (1024, _Pane.detail),
      (1199, _Pane.detail),
    ];
    for (final (width, pane) in cases) {
      testWidgets('${width.toInt()} in the ${pane.name} pane', (tester) async {
        await _pump(tester, width: width, pane: pane);
        final paneRect = _paneRect(width, pane: pane);
        final column = paneRect.width < AppSize.readableMax
            ? paneRect.width
            : AppSize.readableMax;

        final body = _body(tester);
        expect(body.width, closeTo(column, 0.5), reason: 'the column width');
        expect(body.center.dx, closeTo(paneRect.center.dx, 0.5));

        // The header's divider and the tab bar span the pane, whatever the
        // column.
        final divider = _headerDivider(tester);
        expect(divider.left, closeTo(paneRect.left, 0.5));
        expect(divider.right, closeTo(paneRect.right, 0.5));
        final bleed = (paneRect.width - column) / 2;
        final bar = tester.getRect(find.byType(AppTabBar));
        expect(bar.width, closeTo(column, 0.5));
        expect(
          tester.renderObject(find.byKey(AppTabBar.hairlineKey)),
          bleed == 0
              ? isNot(paints..rect())
              : (paints
                  ..rect(
                    rect: Rect.fromLTRB(-bleed, bar.height - 1, 0, bar.height),
                  )
                  ..rect(
                    rect: Rect.fromLTRB(
                      bar.width,
                      bar.height - 1,
                      bar.width + bleed,
                      bar.height,
                    ),
                  )),
        );

        // No hairlines at the column's edges: the pane's own hairlines
        // bound it, and the background is continuous.
        expect(_columnDecoration(tester).border, isNull);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a narrower pane is unaffected: the column is the pane', (
      tester,
    ) async {
      // 840 beside the list pane: the detail is 439.
      await _pump(tester, width: 840, pane: _Pane.detail);
      final paneRect = _paneRect(840, pane: _Pane.detail);
      expect(paneRect.width, 439);
      expect(_body(tester).left, paneRect.left);
      expect(_body(tester).width, 439);
      expect(_headerDivider(tester).left, paneRect.left);
      expect(_headerDivider(tester).width, 439);
    });

    testWidgets('the header controls keep a real hit area', (tester) async {
      await _pump(tester, width: 839);
      await tester.tap(find.byTooltip('Back'));
      expect(_backTaps, 1);
      // T8f: the back button leads the pane, outside the 680 column.
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.left, _paneRect(839).left + AppSpacing.xs);
      expect(back.left, lessThan(_body(tester).left));
    });

    testWidgets('a form header bleeds too', (tester) async {
      await _pump(tester, width: 1199, pane: _Pane.detail, form: true);
      final paneRect = _paneRect(1199, pane: _Pane.detail);
      final divider = _headerDivider(tester, form: true);
      expect(divider.left, closeTo(paneRect.left, 0.5));
      expect(divider.right, closeTo(paneRect.right, 0.5));
      expect(_body(tester).width, AppSize.readableMax);
    });

    for (final width in [839.0, 1024.0]) {
      testWidgets('RTL at ${width.toInt()}: centred, the divider spans the '
          'pane, Back at the start of the pane', (tester) async {
        await _pump(
          tester,
          width: width,
          pane: width >= 840 ? _Pane.detail : _Pane.primary,
          textDirection: TextDirection.rtl,
        );
        final paneRect = _paneRect(
          width,
          pane: width >= 840 ? _Pane.detail : _Pane.primary,
          textDirection: TextDirection.rtl,
        );
        final body = _body(tester);
        expect(body.center.dx, closeTo(paneRect.center.dx, 0.5));
        final divider = _headerDivider(tester);
        expect(divider.left, closeTo(paneRect.left, 0.5));
        expect(divider.right, closeTo(paneRect.right, 0.5));
        final back = tester.getRect(find.byTooltip('Back'));
        expect(back.right, closeTo(paneRect.right - AppSpacing.xs, 0.5));
        expect(back.right, greaterThan(body.center.dx));
      });
    }

    for (final width in [600.0, 839.0, 1024.0]) {
      testWidgets('text scale 2.0 at ${width.toInt()}: nothing overflows', (
        tester,
      ) async {
        await _pump(
          tester,
          width: width,
          pane: width >= 840 ? _Pane.detail : _Pane.primary,
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(_body(tester).width, lessThanOrEqualTo(AppSize.readableMax));
      });
    }

    testWidgets('a full-screen root page on the tablet layout: 680 centred '
        'on the window (Drafts, Scheduled, a band A thread)', (tester) async {
      await _pump(tester, width: 839, pane: _Pane.root);
      final body = _body(tester);
      expect(body.width, AppSize.readableMax);
      expect(body.center.dx, closeTo(839 / 2, 0.5));
      final divider = _headerDivider(tester);
      expect(divider.left, 0);
      expect(divider.right, 839);
    });
  });

  group('T8f, one header rule: Back or Cancel leads the pane, the title '
      'follows it, the actions end the pane', () {
    // The brief's widths in the primary pane, band B's context and detail
    // panes, and a full-screen root page (Drafts, Scheduled, a cold-start
    // composer).
    const cases = <(double, _Pane)>[
      (600, _Pane.primary),
      (839, _Pane.primary),
      (840, _Pane.primary),
      (1024, _Pane.primary),
      (1199, _Pane.primary),
      (840, _Pane.detail),
      (1024, _Pane.detail),
      (1199, _Pane.detail),
      (600, _Pane.root),
      (839, _Pane.root),
      (840, _Pane.root),
      (1024, _Pane.root),
      (1199, _Pane.root),
    ];
    for (final (width, pane) in cases) {
      for (final rtl in [false, true]) {
        final dir = rtl ? TextDirection.rtl : TextDirection.ltr;
        final label = '${width.toInt()} ${pane.name}${rtl ? ' RTL' : ''}';

        testWidgets('$label: a back header', (tester) async {
          await _pump(tester, width: width, pane: pane, textDirection: dir);
          final area = _paneRect(width, pane: pane, textDirection: dir);
          final back = tester.getRect(find.byTooltip('Back'));
          final more = tester.getRect(find.byTooltip('More'));
          final title = tester.getRect(find.text('Title'));
          if (rtl) {
            expect(back.right, closeTo(area.right - AppSpacing.xs, 0.5));
            expect(more.left, closeTo(area.left + AppSpacing.xs, 0.5));
            expect(title.right, closeTo(back.left - AppSpacing.xs, 0.5));
          } else {
            expect(back.left, closeTo(area.left + AppSpacing.xs, 0.5));
            expect(more.right, closeTo(area.right - AppSpacing.xs, 0.5));
            expect(title.left, closeTo(back.right + AppSpacing.xs, 0.5));
          }
          // The content stays in the column.
          final column = area.width < AppSize.readableMax
              ? area.width
              : AppSize.readableMax;
          expect(_body(tester).width, closeTo(column, 0.5));
          expect(_body(tester).center.dx, closeTo(area.center.dx, 0.5));
          // Real hit areas, also where they sit outside the column.
          await tester.tapAt(back.center);
          await tester.tapAt(more.center);
          await tester.pumpAndSettle();
          expect(_backTaps, 1);
          expect(_actionTaps, 1);
          expect(tester.takeException(), isNull);
        });

        testWidgets('$label: a form header', (tester) async {
          await _pump(
            tester,
            width: width,
            pane: pane,
            textDirection: dir,
            form: true,
          );
          final area = _paneRect(width, pane: pane, textDirection: dir);
          final cancel = tester.getRect(
            find.widgetWithText(TextButton, 'Cancel'),
          );
          final save = tester.getRect(find.byType(AppPillButton));
          if (rtl) {
            expect(cancel.right, closeTo(area.right - AppSpacing.xs, 0.5));
            expect(save.left, closeTo(area.left + AppSpacing.xs, 0.5));
          } else {
            expect(cancel.left, closeTo(area.left + AppSpacing.xs, 0.5));
            expect(save.right, closeTo(area.right - AppSpacing.xs, 0.5));
          }
          await tester.tapAt(cancel.center);
          await tester.tapAt(save.center);
          await tester.pumpAndSettle();
          expect(_cancelTaps, 1);
          expect(_actionTaps, 1);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('1024 full screen: Back in the gutter shows its tooltip on a '
        'long press and announces at the pane edge', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, width: 1024, pane: _Pane.root);
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.left, AppSpacing.xs);
      expect(back.right, lessThan(_body(tester).left));
      expect(
        tester.getSemantics(find.byTooltip('Back')).rect.width,
        closeTo(back.width, 0.5),
      );
      await tester.longPressAt(back.center);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Back'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      semantics.dispose();
    });

    testWidgets('a dialog over the page takes the tap, not the header below', (
      tester,
    ) async {
      await _pump(tester, width: 1024, pane: _Pane.root);
      final back = tester.getRect(find.byTooltip('Back'));
      showDialog<void>(
        context: tester.element(find.byType(AppBackHeader)),
        builder: (_) => const AlertDialog(content: Text('Over')),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(back.center);
      await tester.pumpAndSettle();
      expect(_backTaps, 0);
      // The barrier took it: the dialog closed.
      expect(find.text('Over'), findsNothing);
    });

    testWidgets('a header under IgnorePointer takes no tap in the gutter', (
      tester,
    ) async {
      await _pump(
        tester,
        width: 1024,
        pane: _Pane.root,
        wrapHeader: (header) => IgnorePointer(child: header),
      );
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.left, AppSpacing.xs);
      await tester.tapAt(back.center);
      await tester.pumpAndSettle();
      expect(_backTaps, 0);
    });

    testWidgets('a header inside a clip keeps its controls in the column '
        '(nothing is drawn where it cannot be tapped)', (tester) async {
      await _pump(
        tester,
        width: 1024,
        pane: _Pane.root,
        wrapHeader: (header) => ClipRect(child: header),
      );
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.left, _body(tester).left + AppSpacing.xs);
      await tester.tapAt(back.center);
      expect(_backTaps, 1);
    });

    for (final (width, pane) in <(double, _Pane)>[
      (600, _Pane.primary),
      (600, _Pane.root),
      (839, _Pane.primary),
      (840, _Pane.detail),
      (1024, _Pane.detail),
    ]) {
      for (final rtl in [false, true]) {
        testWidgets('text scale 2.0, ${width.toInt()} ${pane.name}'
            '${rtl ? ' RTL' : ''}: a long title yields; the actions stay in '
            'the pane and the primary action is whole', (tester) async {
          const long =
              'A very long page title that cannot fit on one line at twice '
              'the size';
          final dir = rtl ? TextDirection.rtl : TextDirection.ltr;
          final area = _paneRect(width, pane: pane, textDirection: dir);
          for (final form in [false, true]) {
            await _pump(
              tester,
              width: width,
              pane: pane,
              textScale: 2,
              textDirection: dir,
              form: form,
              title: long,
              actionLabel: 'Schedule',
            );
            expect(tester.takeException(), isNull);
            final controls = form
                ? [
                    find.widgetWithText(TextButton, 'Cancel'),
                    find.byType(AppPillButton),
                  ]
                : [find.byTooltip('Back'), find.byTooltip('More')];
            for (final control in controls) {
              final rect = tester.getRect(control);
              expect(rect.left, greaterThanOrEqualTo(area.left - 0.5));
              expect(rect.right, lessThanOrEqualTo(area.right + 0.5));
            }
            if (form) {
              final action = tester.renderObject<RenderParagraph>(
                find.descendant(
                  of: find.byType(AppPillButton),
                  matching: find.text('Schedule'),
                ),
              );
              expect(action.didExceedMaxLines, isFalse);
            }
            final title = tester.renderObject<RenderParagraph>(find.text(long));
            expect(title.didExceedMaxLines, isTrue, reason: 'it yields');
          }
        });
      }
    }

    for (final (name, wrap, widened)
        in <(String, Widget Function(Widget), bool)>[
          ('AbsorbPointer', (h) => AbsorbPointer(child: h), true),
          ('Offstage', (h) => Offstage(child: h), false),
          (
            'a hidden IndexedStack child',
            (h) => IndexedStack(
              index: 1,
              children: [h, const SizedBox(height: 8)],
            ),
            false,
          ),
        ]) {
      testWidgets('$name over a header: a tap in the gutter does nothing', (
        tester,
      ) async {
        await _pump(tester, width: 1024, pane: _Pane.root, wrapHeader: wrap);
        final back = tester.getRect(
          find.byTooltip('Back', skipOffstage: false),
        );
        if (widened) expect(back.left, AppSpacing.xs);
        await tester.tapAt(back.center);
        await tester.pumpAndSettle();
        expect(_backTaps, 0);
      });
    }

    testWidgets('439 dp at text scale 2.0: the title is still announced, as '
        'a header, after Cancel and before the action', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        width: 840,
        pane: _Pane.detail,
        textScale: 2,
        form: true,
        title: 'Edit plan',
        actionLabel: 'Schedule',
      );
      expect(tester.takeException(), isNull);
      final finder = find.bySemanticsLabel('Edit plan');
      expect(finder, findsOneWidget);
      final node = tester.getSemantics(finder);
      expect(node, isSemantics(isHeader: true, label: 'Edit plan'));
      var matrix = Matrix4.identity();
      for (SemanticsNode? n = node; n != null; n = n.parent) {
        if (n.transform != null) matrix = n.transform!.multiplied(matrix);
      }
      final rect = MatrixUtils.transformRect(matrix, node.rect);
      expect(rect.width, greaterThan(0));
      final cancel = tester.getRect(find.widgetWithText(TextButton, 'Cancel'));
      final action = tester.getRect(find.byType(AppPillButton));
      expect(rect.left, greaterThanOrEqualTo(cancel.right - 0.5));
      expect(rect.right, lessThanOrEqualTo(action.left + 0.5));
      semantics.dispose();
    });

    for (final form in [false, true]) {
      testWidgets('text scale 2.0 at 600: ${form ? 'form' : 'back'} header '
          'meets the tap target guideline', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pump(
          tester,
          width: 600,
          pane: _Pane.primary,
          textScale: 2,
          form: form,
          title: 'Edit plan',
          actionLabel: 'Schedule',
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        semantics.dispose();
      });
    }

    testWidgets('Back follows the pane edge across 599, 600, 1199, 1200 and '
        'back (same widgets: the page keeps its state)', (tester) async {
      await _pump(tester, width: 599, pane: _Pane.root);
      final state = tester.state(find.byType(_Counter));
      for (final width in [599.0, 600.0, 1024.0, 1199.0, 1200.0, 599.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        final back = tester.getRect(find.byTooltip('Back'));
        final tablet = width >= 600 && width < 1200;
        expect(
          back.left,
          tablet ? AppSpacing.xs : _body(tester).left + AppSpacing.xs,
          reason: '$width',
        );
        expect(tester.state(find.byType(_Counter)), same(state));
      }
    });
  });

  group('outside the tablet layout: today\'s 600 column between hairlines', () {
    for (final width in [360.0, 599.0, 1200.0, 1440.0]) {
      testWidgets('${width.toInt()} with both flags on', (tester) async {
        await _pump(tester, width: width);
        final body = _body(tester);
        if (width < 600) {
          expect(body.width, width);
        } else {
          expect(body.width, lessThanOrEqualTo(AppLayout.mainColumnMaxWidth));
        }
        // The divider stops with the column: no bleed.
        expect(_headerDivider(tester).left, body.left);
        // T8f: the controls stay where they were (pixel-equal).
        expect(
          tester.getRect(find.byTooltip('Back')).left,
          body.left + AppSpacing.xs,
        );
        expect(
          tester.getRect(find.byTooltip('More')).right,
          body.right - AppSpacing.xs,
        );
        expect(_headerDivider(tester).width, body.width);
        expect(
          tester.renderObject(find.byKey(AppTabBar.hairlineKey)),
          isNot(paints..rect()),
        );
        expect(_columnDecoration(tester).border, isNotNull);
      });
    }

    for (final (width, flags) in <(double, Set<String>)>[
      (839, {kFeatureUiShell}),
      (1024, {kFeatureUiTablet}),
      (1024, <String>{}),
    ]) {
      testWidgets('${width.toInt()} with $flags: the legacy 600 column', (
        tester,
      ) async {
        await _pump(tester, width: width, flags: flags);
        expect(_body(tester).width, AppLayout.mainColumnMaxWidth);
        expect(_columnDecoration(tester).border, isNotNull);
      });
    }

    for (final (width, pane, flags) in <(double, _Pane, Set<String>)>[
      (360, _Pane.root, _tabletFlags),
      (599, _Pane.primary, _tabletFlags),
      (1200, _Pane.primary, _tabletFlags),
      (1440, _Pane.root, _tabletFlags),
      (1024, _Pane.primary, {kFeatureUiShell}),
      (839, _Pane.root, {kFeatureUiTablet}),
    ]) {
      testWidgets('${width.toInt()} ${pane.name} with $flags: the form '
          'header: Cancel and the action where they were', (tester) async {
        await _pump(tester, width: width, pane: pane, flags: flags, form: true);
        final body = _body(tester);
        expect(
          tester.getRect(find.widgetWithText(TextButton, 'Cancel')).left,
          body.left + AppSpacing.sm,
        );
        expect(
          tester.getRect(find.byType(AppPillButton)).right,
          body.right - AppSpacing.sm,
        );
      });
    }

    testWidgets('a full-screen root page with the flags off at 839: 600', (
      tester,
    ) async {
      await _pump(tester, width: 839, pane: _Pane.root, flags: const {});
      expect(_body(tester).width, AppLayout.mainColumnMaxWidth);
    });
  });

  testWidgets('the column keeps its state across 599, 600, 839, 840, 1199 '
      'and 1200 (same widgets, new values only)', (tester) async {
    await _pump(tester, width: 599, pane: _Pane.root);
    final state = tester.state(find.byType(_Counter));
    for (final width in [600.0, 839.0, 840.0, 1199.0, 1200.0, 599.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(_Counter)),
        same(state),
        reason: '$width',
      );
    }
  });

  group('scrollsAcrossPane: the child (a scroll view) spans the pane', () {
    const key = ValueKey('across');
    Future<void> pumpAcross(WidgetTester tester, double width) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      final onboarding = _MockOnboardingBloc();
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          status: OnboardingStatus.ready,
          enabledFeatures: _tabletFlags,
          profile: identity.Profile(userId: 'u1', handle: 'alice'),
        ),
      );
      await tester.pumpWidget(
        BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp(
            theme: buildAppTheme(brightness: Brightness.light),
            home: Scaffold(
              body: AppMainColumn(
                scrollsAcrossPane: true,
                child: Builder(
                  builder: (context) => Padding(
                    key: key,
                    padding: EdgeInsets.symmetric(
                      horizontal: AppMainColumnBleed.of(context),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('839 (a full-screen page on the tablet layout): the child is '
        'the window, its bleed centres a 680 column', (tester) async {
      await pumpAcross(tester, 839);
      expect(
        tester.getRect(find.byKey(key)),
        const Rect.fromLTWH(0, 0, 839, 900),
      );
      expect(tester.getRect(find.byType(SizedBox).last).width, 680);
      expect(_columnDecoration(tester).border, isNull);
    });

    for (final width in [360.0, 1440.0]) {
      testWidgets('${width.toInt()}: the same column as without it', (
        tester,
      ) async {
        await pumpAcross(tester, width);
        final rect = tester.getRect(find.byKey(key));
        expect(rect.width, width < 600 ? width : 600);
        expect(rect.center.dx, width / 2);
        expect(_columnDecoration(tester).border, isNotNull);
      });
    }
  });
  group('T8f: a header inside a scroll view', () {
    const rows = ValueKey('rows');

    /// A full-screen page whose header is the first sliver of a scroll view,
    /// as in a List or a Community feed: across the pane
    /// ([AppMainColumn.scrollsAcrossPane]), or inside the column.
    Future<void> pumpScrolling(
      WidgetTester tester, {
      required bool across,
      double width = 1024,
      List<Widget> Function(double inset)? before,
      Widget Function(Widget headerSliver)? wrapSliver,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 600);
      addTearDown(tester.view.reset);
      final onboarding = _MockOnboardingBloc();
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          status: OnboardingStatus.ready,
          enabledFeatures: _tabletFlags,
          profile: identity.Profile(userId: 'u1', handle: 'alice'),
        ),
      );
      Widget slivers(double inset) => CustomScrollView(
        key: rows,
        slivers: [
          ...?before?.call(inset),
          () {
            final header = SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              sliver: AppMainColumnBleed(
                bleed: inset,
                child: SliverToBoxAdapter(child: _header()),
              ),
            );
            return wrapSliver == null ? header : wrapSliver(header);
          }(),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            sliver: SliverList.builder(
              itemCount: 60,
              itemBuilder: (context, i) => ListTile(title: Text('Row $i')),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp(
            theme: buildAppTheme(brightness: Brightness.light),
            home: Scaffold(
              body: AppMainColumn(
                scrollsAcrossPane: across,
                child: Builder(
                  builder: (context) =>
                      slivers(across ? AppMainColumnBleed.of(context) : 0),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('across the pane: Back leads the window and takes taps', (
      tester,
    ) async {
      await pumpScrolling(tester, across: true);
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.left, AppSpacing.xs);
      expect(
        tester.getRect(find.byTooltip('More')).right,
        1024 - AppSpacing.xs,
      );
      await tester.tapAt(back.center);
      await tester.pumpAndSettle();
      expect(_backTaps, 1);
      // A drag that starts on the header in the gutter still scrolls.
      await tester.dragFrom(back.center, const Offset(0, -200));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(rows),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.pixels, greaterThan(0));
      expect(_backTaps, 1);
    });

    testWidgets('across the pane, scrolled away: a tap where Back was goes '
        'to the rows, not to Back', (tester) async {
      await pumpScrolling(tester, across: true);
      final back = tester.getRect(find.byTooltip('Back'));
      await tester.drag(find.byKey(rows), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tapAt(back.center);
      await tester.pumpAndSettle();
      expect(_backTaps, 0);
    });

    testWidgets('a pane-wide pinned bar over a scrolled header takes the tap '
        'where it covers it; the visible part still goes back', (tester) async {
      await pumpScrolling(
        tester,
        across: true,
        before: (inset) => [
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedBar(height: 56),
          ),
        ],
      );
      await tester.drag(find.byKey(rows), const Offset(0, -30));
      await tester.pumpAndSettle();
      final moved = tester.getRect(find.byTooltip('Back'));
      expect(moved.top, lessThan(56), reason: 'partly under the bar');
      expect(moved.bottom, greaterThan(60), reason: 'partly below it');
      // Under the pane-wide bar, in the gutter: the bar takes it.
      await tester.tapAt(Offset(moved.center.dx, 40));
      await tester.pumpAndSettle();
      expect(_backTaps, 0);
      // Below the bar: what is visible works.
      await tester.tapAt(Offset(moved.center.dx, 59));
      await tester.pumpAndSettle();
      expect(_backTaps, 1);
    });

    testWidgets('a column-capped pinned bar over a scrolled header: the '
        'gutter part under the overlap is neither painted nor tapped; '
        'below it both work', (tester) async {
      await pumpScrolling(
        tester,
        across: true,
        before: (inset) => [
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            sliver: SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedBar(height: 56),
            ),
          ),
        ],
      );
      Object row() => tester.renderObject(
        find
            .byWidgetPredicate((w) => w.runtimeType.toString() == '_Bleed')
            .first,
      );
      expect(row(), isNot(paints..clipPath()), reason: 'nothing overlaps yet');
      await tester.drag(find.byKey(rows), const Offset(0, -30));
      await tester.pumpAndSettle();
      expect(row(), paints..clipPath(), reason: 'the overlap is clipped');
      final moved = tester.getRect(find.byTooltip('Back'));
      await tester.tapAt(Offset(moved.center.dx, 40));
      await tester.pumpAndSettle();
      expect(_backTaps, 0);
      await tester.tapAt(Offset(moved.center.dx, 59));
      await tester.pumpAndSettle();
      expect(_backTaps, 1);
    });

    testWidgets('a sliver that ignores pointers takes no gutter tap', (
      tester,
    ) async {
      await pumpScrolling(
        tester,
        across: true,
        wrapSliver: (sliver) => SliverIgnorePointer(sliver: sliver),
      );
      await tester.tapAt(tester.getRect(find.byTooltip('Back')).center);
      expect(_backTaps, 0);
    });

    testWidgets('an offstage sliver takes no gutter tap', (tester) async {
      await pumpScrolling(
        tester,
        across: true,
        wrapSliver: (sliver) => SliverOffstage(sliver: sliver),
      );
      await tester.tapAt(
        tester.getRect(find.byTooltip('Back', skipOffstage: false)).center,
      );
      expect(_backTaps, 0);
    });

    testWidgets('a scroll view inside the column clips there: the controls '
        'stay in the column', (tester) async {
      await pumpScrolling(tester, across: false);
      final column = tester.getRect(find.byKey(rows));
      expect(column.width, AppSize.readableMax);
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.left, column.left + AppSpacing.xs);
      await tester.tapAt(back.center);
      expect(_backTaps, 1);
    });
  });
}

/// A pinned bar of a fixed height (the pinned-sliver tests).
class _PinnedBar extends SliverPersistentHeaderDelegate {
  _PinnedBar({required this.height});

  final double height;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      ColoredBox(
        color: Colors.blueGrey,
        child: SizedBox(height: height),
      );

  @override
  bool shouldRebuild(covariant _PinnedBar oldDelegate) =>
      oldDelegate.height != height;
}
