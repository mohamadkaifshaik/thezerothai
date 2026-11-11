import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_form_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_main_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
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

  /// Band B: the primary beside a context pane (code P).
  context,

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

Widget _page({bool form = false}) => Scaffold(
  body: SafeArea(
    child: AppMainColumn(
      child: Column(
        children: [
          if (form)
            AppFormHeader(title: 'Edit', onCancel: () {}, actionLabel: 'Save')
          else
            AppBackHeader(title: 'Title', onBack: () => _backTaps++),
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

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double height = 900,
  _Pane pane = _Pane.primary,
  Set<String> flags = _tabletFlags,
  TextDirection textDirection = TextDirection.ltr,
  double textScale = 1,
  bool form = false,
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
  final page = _page(form: form);
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
          contextSections: pane == _Pane.context
              ? const [
                  ContextSection(
                    ContextSectionKind.search,
                    SizedBox(height: 1),
                  ),
                ]
              : null,
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
    _Pane.context when bandB => c - 1 - ShellGeometry.contextPaneWidthFor(c),
    _Pane.detail when bandB => c - 1 - ShellGeometry.listPaneWidthFor(c),
    _ => c,
  };
  // The rail (and in LD the list) lead; the context pane trails.
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
  setUp(() => _backTaps = 0);

  group('the tablet layout: reading content at most 680, centred', () {
    // The widths of the brief: band A's edges, band B's edges and 1024.
    const cases = <(double, _Pane)>[
      (600, _Pane.primary),
      (839, _Pane.primary),
      (840, _Pane.primary),
      (1024, _Pane.primary),
      (1199, _Pane.primary),
      (840, _Pane.context),
      (1024, _Pane.context),
      (1199, _Pane.context),
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
      // 840 with a context pane: the primary is 439.
      await _pump(tester, width: 840, pane: _Pane.context);
      final paneRect = _paneRect(840, pane: _Pane.context);
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
      // The back button leads the column, inside the pane.
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.left, greaterThanOrEqualTo(_body(tester).left));
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
          'pane, Back at the start of the column', (tester) async {
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
        expect(back.right, lessThanOrEqualTo(body.right + 0.5));
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
          pane: width >= 840 ? _Pane.context : _Pane.primary,
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
}
