import 'dart:math' as math;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_sheet.dart';
import 'package:dzeroth/shared/widgets/primitives/sheet_option_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

const _triggerKey = Key('trigger');
const _longLabel =
    'Everyone who follows you and everyone they follow, including accounts '
    'you have not met yet';

/// What the last sheet resolved to; `#none` until it closes.
Object? _result = #none;

Widget _content(BuildContext context, {int rows = 3, String? long}) => ListView(
  shrinkWrap: true,
  children: [
    for (var i = 0; i < rows; i++)
      SheetOptionRow(
        icon: Icons.public,
        label: i == 0 && long != null ? long : 'Option ${i + 1}',
        selected: i == 0,
        onTap: () => Navigator.of(context).pop('option${i + 1}'),
      ),
  ],
);

/// A page with a trigger that opens a sheet through [showAppSheet]. It reads
/// the real view so simulated insets and sizes reach the sheet.
Future<void> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  double textScale = 1,
  bool isDismissible = true,
  double menuFromWidth = double.infinity,
  Alignment align = Alignment.center,
  String? long,
  int rows = 3,
}) async {
  _result = #none;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: brightness),
      home: Scaffold(
        body: Align(
          alignment: align,
          child: Builder(
            builder: (context) => ElevatedButton(
              key: _triggerKey,
              onPressed: () async {
                _result = await showAppSheet<Object>(
                  context: context,
                  semanticLabel: 'Who can reply?',
                  isDismissible: isDismissible,
                  anchor: context,
                  menuFromWidth: menuFromWidth,
                  builder: (c) => _content(c, long: long, rows: rows),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_triggerKey));
  await tester.pumpAndSettle();
}

/// The label of the option row that holds focus ('' when none does).
String _focusedLabel() {
  final focus = FocusManager.instance.primaryFocus;
  final element = focus?.context as Element?;
  String? found;
  element?.visitAncestorElements((e) {
    final w = e.widget;
    if (w is SheetOptionRow) {
      found = w.label;
      return false;
    }
    return true;
  });
  return found ?? '';
}

bool _focusIn<W extends Widget>() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  var hit = false;
  ctx.visitAncestorElements((e) {
    if (e.widget is W) {
      hit = true;
      return false;
    }
    return true;
  });
  return hit;
}

bool _insideContent() => _focusIn<SheetOptionRow>();

Finder get _sheetMaterial => find
    .ancestor(of: find.byType(AppSheetHandle), matching: find.byType(Material))
    .first;

void main() {
  group('appSheetPresentationFor', () {
    test('sheet by default, menu from the chosen width with an anchor', () {
      expect(appSheetPresentationFor(1600), AppSheetPresentation.sheet);
      expect(
        appSheetPresentationFor(1199, menuFromWidth: AppBreakpoints.tablet),
        AppSheetPresentation.sheet,
      );
      expect(
        appSheetPresentationFor(1200, menuFromWidth: AppBreakpoints.tablet),
        AppSheetPresentation.menu,
      );
      expect(
        appSheetPresentationFor(
          1440,
          menuFromWidth: AppBreakpoints.tablet,
          hasAnchor: false,
        ),
        AppSheetPresentation.sheet,
      );
    });
  });

  group('sheet', () {
    forEachThemeAndWidth(
      'frames, sizes and reflows',
      (tester, env) async {
        await _pump(
          tester,
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
          long: _longLabel,
        );
        await _open(tester);
        expect(tester.takeException(), isNull);
        final sheet = tester.getRect(_sheetMaterial);
        expect(sheet.width, closeTo(math.min(640, env.size.width), 0.5));
        expect(sheet.bottom, closeTo(env.size.height, 0.5));
        // Top radius 32 (the theme's sheet shape).
        final material = tester.widget<Material>(_sheetMaterial);
        expect(
          (material.shape! as RoundedRectangleBorder).borderRadius,
          const BorderRadius.vertical(top: Radius.circular(AppRadius.sheetTop)),
        );
        // The handle is a 48 dp target around a 36 x 4 pill, 3:1 on the sheet.
        final handle = tester.getRect(find.byType(AppSheetHandle));
        expect(handle.height, greaterThanOrEqualTo(48));
        expect(handle.width, greaterThanOrEqualTo(48));
        final element = tester.element(find.byType(AppSheetHandle));
        expect(
          contrast(
            element.appColors.uiBorder,
            Theme.of(element).bottomSheetTheme.backgroundColor!,
          ),
          greaterThanOrEqualTo(3),
        );
        // Rows are 48 dp or taller and stay inside the sheet.
        for (final row in tester.widgetList(find.byType(SheetOptionRow))) {
          final r = tester.getRect(find.byWidget(row));
          expect(r.height, greaterThanOrEqualTo(48));
          expect(r.left, greaterThanOrEqualTo(sheet.left));
          expect(r.right, lessThanOrEqualTo(sheet.right));
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    testWidgets('tall content scrolls inside the safe area', (tester) async {
      await _pump(tester, size: const Size(360, 400), rows: 12);
      await _open(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a selected row is not colour alone: it shows a check', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('semantics: a named route with a close handle', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      await _open(tester);
      expect(find.bySemanticsLabel('Who can reply?'), findsOneWidget);
      expect(find.bySemanticsLabel('Close'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('moves focus into the sheet on open', (tester) async {
      await _pump(tester);
      await _open(tester);
      expect(_insideContent(), isTrue);
    });

    testWidgets('Tab and Shift+Tab cycle inside the sheet only', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      final seen = <String>{};
      for (var i = 0; i < 8; i++) {
        expect(_insideContent() || _focusIn<AppSheetHandle>(), isTrue);
        seen.add(_focusedLabel());
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(seen.where((l) => l.startsWith('Option')).length, 3);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          _insideContent() || _focusIn<AppSheetHandle>(),
          isTrue,
          reason: 'back $i',
        );
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    });

    testWidgets('Escape closes and resolves null', (tester) async {
      await _pump(tester);
      await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SheetOptionRow), findsNothing);
      expect(_result, isNull);
    });

    testWidgets('Escape does nothing when not dismissible', (tester) async {
      await _pump(tester, isDismissible: false);
      await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SheetOptionRow), findsWidgets);
    });

    testWidgets('the system back button closes it', (tester) async {
      await _pump(tester);
      await _open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SheetOptionRow), findsNothing);
      expect(_result, isNull);
    });

    testWidgets('tapping the scrim or the handle closes it', (tester) async {
      await _pump(tester);
      await _open(tester);
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.byType(SheetOptionRow), findsNothing);
      await _open(tester);
      await tester.tap(find.byType(AppSheetHandle));
      await tester.pumpAndSettle();
      expect(find.byType(SheetOptionRow), findsNothing);
    });

    testWidgets('choosing a row resolves its value', (tester) async {
      await _pump(tester);
      await _open(tester);
      await tester.tap(find.text('Option 2'));
      await tester.pumpAndSettle();
      expect(_result, 'option2');
    });

    for (final how in ['Escape', 'choice', 'scrim']) {
      testWidgets('returns to the invoking button after $how', (tester) async {
        await _pump(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final invoker = FocusManager.instance.primaryFocus;
        expect(invoker, isNotNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(SheetOptionRow), findsWidgets);
        expect(FocusManager.instance.primaryFocus, isNot(invoker));
        switch (how) {
          case 'Escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          case 'choice':
            await tester.tap(find.text('Option 3'));
          default:
            await tester.tapAt(const Offset(200, 20));
        }
        await tester.pumpAndSettle();
        expect(find.byType(SheetOptionRow), findsNothing);
        expect(FocusManager.instance.primaryFocus, invoker);
      });
    }

    testWidgets('lives on the root navigator, above a nested one', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.light),
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  key: _triggerKey,
                  onPressed: () => showAppSheet<void>(
                    context: context,
                    builder: (c) => _content(c),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_triggerKey));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Overlay).first,
          matching: find.byType(SheetOptionRow),
        ),
        findsWidgets,
      );
    });
  });

  group('anchored menu', () {
    bool menuOpen() => find.byType(SheetOptionRow).evaluate().isNotEmpty;

    Rect menuRect(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.byType(SheetOptionRow).first,
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    );

    forEachThemeAndWidth(
      'hangs below the anchor, at most 320 wide, no overflow',
      (tester, env) async {
        await _pump(
          tester,
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
          menuFromWidth: 0,
          align: Alignment.topLeft,
          long: _longLabel,
        );
        await _open(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(AppSheetHandle), findsNothing);
        final anchor = tester.getRect(find.byKey(_triggerKey));
        final menu = menuRect(tester);
        expect(menu.width, lessThanOrEqualTo(320));
        expect(menu.top, greaterThanOrEqualTo(anchor.bottom - 1));
        expect(menu.left, greaterThanOrEqualTo(0));
        expect(menu.right, lessThanOrEqualTo(env.size.width));
        expect(menu.bottom, lessThanOrEqualTo(env.size.height));
        for (final row in tester.widgetList(find.byType(SheetOptionRow))) {
          expect(
            tester.getRect(find.byWidget(row)).height,
            greaterThanOrEqualTo(48),
          );
        }
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    testWidgets('flips above when there is no room below', (tester) async {
      await _pump(
        tester,
        size: const Size(800, 400),
        menuFromWidth: 0,
        align: Alignment.bottomCenter,
      );
      await _open(tester);
      final anchor = tester.getRect(find.byKey(_triggerKey));
      expect(menuRect(tester).bottom, lessThanOrEqualTo(anchor.top + 1));
    });

    testWidgets('clamps to the window at the right edge', (tester) async {
      await _pump(
        tester,
        size: const Size(800, 600),
        menuFromWidth: 0,
        align: Alignment.topRight,
      );
      await _open(tester);
      expect(menuRect(tester).right, lessThanOrEqualTo(800));
    });

    testWidgets('only from the chosen width: a narrower window gets a sheet', (
      tester,
    ) async {
      await _pump(
        tester,
        size: const Size(600, 800),
        menuFromWidth: AppBreakpoints.tablet,
      );
      await _open(tester);
      expect(find.byType(AppSheetHandle), findsOneWidget);
    });

    testWidgets('a long menu scrolls within the room', (tester) async {
      await _pump(
        tester,
        size: const Size(800, 300),
        menuFromWidth: 0,
        rows: 12,
      );
      await _open(tester);
      expect(tester.takeException(), isNull);
      expect(menuRect(tester).height, lessThanOrEqualTo(300));
    });

    testWidgets('moves focus in, arrows move between items, Escape closes '
        'and focus returns', (tester) async {
      await _pump(tester, menuFromWidth: 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final invoker = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(menuOpen(), isTrue);
      expect(_insideContent(), isTrue);
      final first = _focusedLabel();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_insideContent(), isTrue);
      expect(_focusedLabel(), isNot(first));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_focusedLabel(), first);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(menuOpen(), isFalse);
      expect(_result, isNull);
      expect(FocusManager.instance.primaryFocus, invoker);
    });

    testWidgets('Tab stays inside the menu', (tester) async {
      await _pump(tester, menuFromWidth: 0);
      await _open(tester);
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(_insideContent(), isTrue, reason: 'step $i');
      }
    });

    testWidgets('back, an outside tap and a choice close it', (tester) async {
      await _pump(tester, menuFromWidth: 0, align: Alignment.topLeft);
      await _open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(menuOpen(), isFalse);
      await _open(tester);
      await tester.tapAt(const Offset(390, 700));
      await tester.pumpAndSettle();
      expect(menuOpen(), isFalse);
      await _open(tester);
      await tester.tap(find.text('Option 2'));
      await tester.pumpAndSettle();
      expect(_result, 'option2');
    });

    testWidgets('semantics: a named menu', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, menuFromWidth: 0);
      await _open(tester);
      expect(find.bySemanticsLabel('Who can reply?'), findsOneWidget);
      handle.dispose();
    });
  });
}
