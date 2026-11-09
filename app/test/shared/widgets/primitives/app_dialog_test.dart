import 'dart:math' as math;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';

import 'dart:ui' show SemanticsRole;

import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

const _triggerKey = Key('trigger');
const _longBody =
    'This is permanent and cannot be undone. We delete your profile, your '
    'posts and media, and your follows, blocks and mutes. What remains: '
    'mentions of you in other people\'s posts, and backups, which expire '
    'within 14 days. '
    'More explanatory text that keeps the body long enough to need scrolling. '
    'More explanatory text that keeps the body long enough to need scrolling. '
    'More explanatory text that keeps the body long enough to need scrolling.';

/// What the last [_Host] dialog resolved to; `#none` until it closes.
Object? _result = #none;

/// A page with a trigger button that opens [dialog] through [showAppDialog].
/// It reads the real view (not an overriding MediaQuery) so that simulated
/// keyboard insets reach the dialog.
Future<void> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  double textScale = 1,
  bool destructive = true,
  bool barrierDismissible = true,
  String body = 'Short body.',
  Widget Function(BuildContext)? builder,
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
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: _triggerKey,
              onPressed: () async {
                _result = await showAppDialog<Object>(
                  context: context,
                  destructive: destructive,
                  barrierDismissible: barrierDismissible,
                  builder:
                      builder ??
                      (_) => AppConfirmDialog(
                        title: 'Delete your account?',
                        message: body,
                        confirmLabel: 'Delete my account',
                        destructive: destructive,
                      ),
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

bool _inDialog(WidgetTester tester) {
  final focus = FocusManager.instance.primaryFocus;
  if (focus?.context == null) return false;
  return find
      .ancestor(
        of: find.byWidget(focus!.context!.widget),
        matching: find.byType(AppDialog),
      )
      .evaluate()
      .isNotEmpty;
}

String _focusedLabel() {
  final focus = FocusManager.instance.primaryFocus;
  final element = focus?.context as Element?;
  String? found;
  element?.visitAncestorElements((e) {
    if (e.widget is Semantics) {
      final label = (e.widget as Semantics).properties.label;
      if (label != null) {
        found = label;
        return false;
      }
    }
    return true;
  });
  return found ?? '';
}

SemanticsNode? _nodeWithRole(WidgetTester tester, SemanticsRole role) {
  SemanticsNode? hit;
  void visit(SemanticsNode n) {
    if (n.getSemanticsData().role == role) hit = n;
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return hit;
}

void main() {
  group('showAppDialog frame', () {
    forEachThemeAndWidth(
      'sizes, scrolls and does not overflow',
      (tester, env) async {
        await _pump(
          tester,
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
          body: _longBody,
        );
        await _open(tester);
        expect(tester.takeException(), isNull);
        final box = tester.getRect(find.byType(AppDialog));
        // The dialog is the frame content; the frame is 24dp from the edges at
        // most and 560dp wide at most.
        final frame = tester.getRect(
          find
              .ancestor(
                of: find.byType(AppDialog),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(frame.width, closeTo(math.min(560, env.size.width - 48), 0.5));
        expect(frame.left, greaterThanOrEqualTo(24));
        expect(frame.top, greaterThanOrEqualTo(24));
        expect(frame.bottom, lessThanOrEqualTo(env.size.height - 24));
        expect(box.size.width, greaterThan(0));
        // Both actions stay reachable inside the viewport.
        for (final label in ['Cancel', 'Delete my account']) {
          final button = find.widgetWithText(AppPillButton, label);
          expect(button, findsOneWidget);
          final r = tester.getRect(button);
          expect(r.bottom, lessThanOrEqualTo(env.size.height));
          expect(r.height, greaterThanOrEqualTo(48));
        }
        if (env.textScale == 2.0) {
          // The body scrolls instead of overflowing.
          expect(
            find.descendant(
              of: find.byType(AppDialog),
              matching: find.byType(SingleChildScrollView),
            ),
            findsOneWidget,
          );
        }
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    testWidgets('shrinks above the keyboard and scrolls', (tester) async {
      await _pump(
        tester,
        size: const Size(360, 800),
        textScale: 2,
        body: _longBody,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      addTearDown(tester.view.resetViewInsets);
      await _open(tester);
      expect(tester.takeException(), isNull);
      final frame = tester.getRect(
        find
            .ancestor(
              of: find.byType(AppDialog),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(frame.bottom, lessThanOrEqualTo(800 - 400));
      expect(frame.top, greaterThanOrEqualTo(24));
    });

    testWidgets('paints AppShadows.brand on a card-radius surface', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      final deco = tester
          .widgetList<DecoratedBox>(
            find.ancestor(
              of: find.byType(AppDialog),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.boxShadow != null);
      expect(deco.boxShadow, AppShadows.brand);
      expect(deco.borderRadius, BorderRadius.circular(AppRadius.card));
    });

    testWidgets('lives on the root navigator, above a nested one', (
      tester,
    ) async {
      final rootKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootKey,
          theme: buildAppTheme(brightness: Brightness.light),
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: _triggerKey,
                    onPressed: () => showAppDialog<void>(
                      context: context,
                      builder: (_) =>
                          const AppDialog(title: 'Hello', body: Text('Body')),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_triggerKey));
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Overlay).first,
          matching: find.byType(AppDialog),
        ),
        findsOneWidget,
      );
      rootKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsNothing);
    });
  });

  group('focus', () {
    testWidgets('moves into the dialog on open', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(_triggerKey));
      await tester.pumpAndSettle();
      expect(_inDialog(tester), isTrue);
    });

    testWidgets('destructive confirm focuses Cancel, plain focuses confirm', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      expect(_focusedLabel(), 'Cancel');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await _pump(tester, destructive: false);
      await _open(tester);
      expect(_focusedLabel(), 'Delete my account');
    });

    testWidgets('Tab and Shift+Tab cycle inside the dialog only', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester);
      final seen = <String>{};
      for (var i = 0; i < 8; i++) {
        expect(_inDialog(tester), isTrue, reason: 'forward step $i');
        seen.add(_focusedLabel());
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(seen, {'Cancel', 'Delete my account'});
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab, character: null);
        await tester.pump();
        expect(_inDialog(tester), isTrue, reason: 'second lap step $i');
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(_inDialog(tester), isTrue, reason: 'backward step $i');
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    });

    testWidgets('Escape closes and resolves null', (tester) async {
      await _pump(tester);
      await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsNothing);
      expect(_result, isNull);
    });

    testWidgets('Escape does nothing when not barrierDismissible', (
      tester,
    ) async {
      await _pump(tester, barrierDismissible: false);
      await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsOneWidget);
    });

    testWidgets('the system back button closes it', (tester) async {
      await _pump(tester);
      await _open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsNothing);
      expect(_result, isNull);
    });

    testWidgets('tapping the scrim closes it', (tester) async {
      await _pump(tester);
      await _open(tester);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsNothing);
    });

    for (final how in ['Escape', 'Cancel', 'confirm']) {
      testWidgets('returns to the invoking button after $how', (tester) async {
        await _pump(tester);
        // Focus the trigger as a keyboard user would, then activate it.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final invoker = FocusManager.instance.primaryFocus;
        expect(invoker, isNotNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AppDialog), findsOneWidget);
        expect(FocusManager.instance.primaryFocus, isNot(invoker));

        switch (how) {
          case 'Escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          case 'Cancel':
            await tester.tap(find.text('Cancel'));
          default:
            await tester.tap(find.text('Delete my account'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(AppDialog), findsNothing);
        expect(FocusManager.instance.primaryFocus, invoker);
      });
    }
  });

  group('semantics', () {
    testWidgets('a plain dialog is a dialog with a heading and a name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, destructive: false);
      await _open(tester);
      expect(_nodeWithRole(tester, SemanticsRole.dialog), isNotNull);
      expect(_nodeWithRole(tester, SemanticsRole.alertDialog), isNull);
      final title = tester.getSemantics(find.text('Delete your account?'));
      expect(title.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });

    testWidgets('a destructive confirm is an alert dialog naming its route', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      await _open(tester);
      final alert = _nodeWithRole(tester, SemanticsRole.alertDialog);
      expect(alert, isNotNull);
      final named = tester.getSemantics(
        find.descendant(
          of: find.byType(AppDialog),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.namesRoute == true,
          ),
        ),
      );
      expect(named.label, 'Delete your account?');
      expect(named.flagsCollection.scopesRoute, isTrue);
      expect(
        tester.getSemantics(find.widgetWithText(AppPillButton, 'Cancel')),
        matchesSemantics(
          label: 'Cancel',
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('the content behind a modal dialog is not reachable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      await _open(tester);
      var reachable = false;
      void visit(SemanticsNode n) {
        if (n.label == 'Open') reachable = true;
        n.visitChildren((c) {
          visit(c);
          return true;
        });
      }

      visit(
        tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!,
      );
      expect(reachable, isFalse);
      handle.dispose();
    });

    testWidgets('actions meet the 48dp guideline', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      await _open(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  group('contrast', () {
    for (final brightness in Brightness.values) {
      testWidgets('destructive pairs reach 4.5:1 [${brightness.name}]', (
        tester,
      ) async {
        await _pump(tester, brightness: brightness);
        await _open(tester);
        final theme = Theme.of(tester.element(find.byType(AppDialog)));
        final colors = tester.element(find.byType(AppDialog)).appColors;
        final surface = theme.colorScheme.surface;
        // The danger button's fill and label (white on #B42318).
        expect(
          contrast(colors.dangerFill, colors.onDangerFill),
          greaterThanOrEqualTo(4.5),
        );
        // Title, body and the danger-coloured eyebrow on the dialog surface.
        expect(
          contrast(theme.colorScheme.onSurface, surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.colorScheme.onSurfaceVariant, surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.colorScheme.error, surface),
          greaterThanOrEqualTo(4.5),
        );
        // The cancel button's outline against the surface (>= 3:1).
        expect(contrast(colors.uiBorder, surface), greaterThanOrEqualTo(3));
      });
    }

    testWidgets('the danger fill is #B42318 in both themes', (tester) async {
      for (final b in Brightness.values) {
        expect(
          buildAppTheme(brightness: b).extension<AppColors>()!.dangerFill,
          const Color(0xFFB42318),
        );
      }
    });
  });

  group('AppConfirmDialog.show', () {
    testWidgets('resolves true on confirm, false on cancel and on Escape', (
      tester,
    ) async {
      Future<bool?> run(Future<void> Function() act) async {
        bool? out;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness: Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  key: _triggerKey,
                  onPressed: () async => out = await AppConfirmDialog.show(
                    context,
                    title: 'Remove?',
                    message: 'Gone for good.',
                    confirmLabel: 'Remove',
                    destructive: true,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(_triggerKey));
        await tester.pumpAndSettle();
        await act();
        await tester.pumpAndSettle();
        return out;
      }

      expect(await run(() => tester.tap(find.text('Remove'))), isTrue);
      expect(await run(() => tester.tap(find.text('Cancel'))), isFalse);
      expect(
        await run(() => tester.sendKeyEvent(LogicalKeyboardKey.escape)),
        isFalse,
      );
    });
  });
}
