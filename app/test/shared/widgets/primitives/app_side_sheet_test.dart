import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `showAppSideSheet` (tablet plan section 4.2, code SS). The chat info
/// sheet's own tests cover its geometry, scrim and focus; this covers what
/// T7 added: Escape closes a sheet whose content has a `Scaffold` (the
/// photo viewer's post sheet), which used to swallow the key.
void main() {
  Future<void> open(WidgetTester tester, Widget content) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(744, 1133);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAppSideSheet<void>(
                  context: context,
                  semanticLabel: 'Sheet',
                  builder: (_) => content,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Inside'), findsOneWidget);
  }

  for (final (name, content) in [
    ('plain content', const Center(child: Text('Inside'))),
    (
      'content with a Scaffold',
      Scaffold(
        appBar: AppBar(title: const Text('Header')),
        body: const Center(child: Text('Inside')),
      ),
    ),
  ]) {
    testWidgets('Escape closes the sheet: $name', (tester) async {
      await open(tester, content);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Inside'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    });
  }
}
