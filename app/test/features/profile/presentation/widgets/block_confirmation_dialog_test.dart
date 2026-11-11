import 'package:dzeroth/features/profile/presentation/widgets/block_confirmation_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/theme_harness.dart';

/// The destructive confirm shared by Delete, Block and Remove from community
/// (`AppConfirmDialog`): Cancel takes initial focus so Enter never confirms,
/// the dialog is an alert dialog, and the buttons stack on a phone.
void main() {
  Future<Future<bool>> open(
    WidgetTester tester, {
    Size size = const Size(360, 800),
    double textScale = 1,
    TextDirection direction = TextDirection.ltr,
  }) async {
    late BuildContext context;
    await pumpThemed(
      tester,
      Directionality(
        textDirection: direction,
        child: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
      size: size,
      textScale: textScale,
    );
    final result = showBlockConfirmationDialog(context);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Cancel has the initial focus; Enter cancels, never blocks', (
    tester,
  ) async {
    final result = await open(tester);

    final cancel = tester.widget<AppPillButton>(
      find.widgetWithText(AppPillButton, 'Cancel'),
    );
    expect(cancel.autofocus, isTrue);
    final block = tester.widget<AppPillButton>(
      find.widgetWithText(AppPillButton, 'Block'),
    );
    expect(block.autofocus, isFalse);
    expect(block.variant, AppButtonVariant.danger);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('it is announced as an alert dialog', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    SemanticsNode? alert;
    void visit(SemanticsNode n) {
      if (n.getSemanticsData().role == SemanticsRole.alertDialog) alert = n;
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
    expect(alert, isNotNull);
    handle.dispose();
  });

  testWidgets('at 360 the buttons are stacked, the primary on top', (
    tester,
  ) async {
    await open(tester);
    final block = tester.getRect(find.widgetWithText(AppPillButton, 'Block'));
    final cancel = tester.getRect(find.widgetWithText(AppPillButton, 'Cancel'));
    expect(block.bottom, lessThanOrEqualTo(cancel.top));
    expect(block.width, cancel.width);
  });

  testWidgets('Block confirms', (tester) async {
    final result = await open(tester);
    await tester.tap(find.widgetWithText(AppPillButton, 'Block'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('RTL at text scale 2.0: no overflow, no ellipsized actions', (
    tester,
  ) async {
    await open(tester, textScale: 2, direction: TextDirection.rtl);
    expect(tester.takeException(), isNull);
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  for (final width in const [600.0, 1200.0, 1440.0]) {
    testWidgets('at ${width.toInt()} it keeps the 400 dp alert width and is '
        'centred', (tester) async {
      await open(tester, size: Size(width, 900));
      final box = tester.getRect(find.byType(AppConfirmDialog));
      expect(box.width, lessThanOrEqualTo(400.5));
      expect(box.center.dx, closeTo(width / 2, 1));
      expect(tester.takeException(), isNull);
    });
  }
}
