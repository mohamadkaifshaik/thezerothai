import 'package:dzeroth/shared/widgets/browser_context_menu_guard.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeToggle implements BrowserContextMenuToggle {
  final List<String> calls = [];
  bool failing = false;

  @override
  Future<void> disable() async {
    calls.add('disable');
    if (failing) throw StateError('raw-channel');
  }

  @override
  Future<void> enable() async {
    calls.add('enable');
    if (failing) throw StateError('raw-channel');
  }
}

void main() {
  late _FakeToggle toggle;

  setUp(() {
    toggle = _FakeToggle();
    BrowserContextMenuGuard.debugToggle = toggle;
  });
  tearDown(BrowserContextMenuGuard.debugReset);

  const first = ValueKey('first');
  const second = ValueKey('second');
  const field = ValueKey('field');

  Future<void> pumpTwo(WidgetTester tester, {bool showSecond = true}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const BrowserContextMenuGuard(
                child: SizedBox(key: first, width: 200, height: 100),
              ),
              if (showSecond)
                const BrowserContextMenuGuard(
                  child: SizedBox(key: second, width: 200, height: 100),
                ),
              const SizedBox(key: field, width: 200, height: 100),
            ],
          ),
        ),
      ),
    );
  }

  Future<TestGesture> mouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(700, 500));
    addTearDown(gesture.removePointer);
    await tester.pump();
    return gesture;
  }

  testWidgets('the browser menu is off only while the pointer is over a '
      'guarded widget', (tester) async {
    await pumpTwo(tester);
    final gesture = await mouse(tester);
    expect(toggle.calls, isEmpty);

    await gesture.moveTo(tester.getCenter(find.byKey(first)));
    await tester.pump();
    expect(toggle.calls, ['disable']);

    // Outside both (a text field elsewhere keeps the browser menu).
    await gesture.moveTo(tester.getCenter(find.byKey(field)));
    await tester.pump();
    expect(toggle.calls, ['disable', 'enable']);
  });

  testWidgets('moving from one guarded widget to the next leaves it off over '
      'the second', (tester) async {
    await pumpTwo(tester);
    final gesture = await mouse(tester);

    await gesture.moveTo(tester.getCenter(find.byKey(first)));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byKey(second)));
    await tester.pump();

    // Whatever order the exit and the enter arrive in, the last word is
    // "disable" and the net state is off.
    expect(toggle.calls.last, 'disable');
    final off = toggle.calls.where((c) => c == 'disable').length;
    final on = toggle.calls.where((c) => c == 'enable').length;
    expect(off - on, 1);
  });

  testWidgets('a widget removed under the pointer enables the menu again', (
    tester,
  ) async {
    await pumpTwo(tester);
    final gesture = await mouse(tester);
    await gesture.moveTo(tester.getCenter(find.byKey(second)));
    await tester.pump();
    expect(toggle.calls, ['disable']);

    await pumpTwo(tester, showSecond: false);
    await tester.pump();

    expect(toggle.calls, ['disable', 'enable']);
  });

  testWidgets('a failing platform call is swallowed', (tester) async {
    toggle.failing = true;
    await pumpTwo(tester);
    final gesture = await mouse(tester);

    await gesture.moveTo(tester.getCenter(find.byKey(first)));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byKey(field)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(toggle.calls, ['disable', 'enable']);
  });

  testWidgets('off the web there is no layer and no call', (tester) async {
    BrowserContextMenuGuard.debugToggle = null; // kIsWeb is false in tests
    await pumpTwo(tester);

    expect(
      find.descendant(
        of: find.byType(BrowserContextMenuGuard).first,
        matching: find.byType(MouseRegion),
      ),
      findsNothing,
    );
    expect(toggle.calls, isEmpty);
  });
}
