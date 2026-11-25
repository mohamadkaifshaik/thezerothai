import 'package:dzeroth/core/widgets/app_tap_area.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _button(String label, List<String> taps, {double width = 44}) =>
    AppTapArea(
      child: Semantics(
        button: true,
        label: label,
        onTap: () => taps.add(label),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps.add(label),
          child: SizedBox(width: width, height: 44, key: Key(label)),
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: child),
  ),
);

void main() {
  testWidgets('keeps the drawn 44 dp box and takes taps 2 dp around it', (
    tester,
  ) async {
    final taps = <String>[];
    await _pump(tester, _button('a', taps));
    final box = tester.getRect(find.byKey(const Key('a')));
    expect(box.size, const Size.square(44));
    expect(tester.getSize(find.byType(AppTapArea)), const Size.square(44));
    final area = tester
        .renderObject<RenderAppTapArea>(find.byType(AppTapArea))
        .hitRect;
    expect(area.size, const Size.square(48));

    for (final at in [
      box.topLeft - const Offset(1.5, 1.5),
      box.bottomRight + const Offset(1.5, 1.5),
      box.centerLeft - const Offset(1.9, 0),
      box.topCenter - const Offset(0, 1.9),
    ]) {
      await tester.tapAt(at);
    }
    expect(taps, ['a', 'a', 'a', 'a']);
    taps.clear();
    await tester.tapAt(box.centerLeft - const Offset(2.5, 0));
    await tester.tapAt(box.bottomCenter + const Offset(0, 2.5));
    expect(taps, isEmpty);
  });

  testWidgets('the accessibility node is the 48 dp tap area', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _button('a', []));
    final node = tester.getSemantics(find.bySemanticsLabel('a'));
    expect(node.rect.size, const Size.square(48));
    handle.dispose();
  });

  testWidgets('a bleed row: laid out 10 dp wider on each side, its items '
      'reachable 2 dp above and below, a neighbour never takes a tap on an '
      'item', (tester) async {
    final taps = <String>[];
    await _pump(
      tester,
      AppTapAreaHost(
        // The host's own bounds hold the bleed and the rings (a card with
        // its gutter).
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _bleedRow(taps),
        ),
      ),
    );
    final row = tester.getRect(find.byType(AppTapArea).first);
    expect(row.width, 200);
    expect(row.height, 44);
    final a = tester.getRect(find.byKey(const Key('a')));
    final b = tester.getRect(find.byKey(const Key('b')));
    final c = tester.getRect(find.byKey(const Key('c')));
    expect(a.left, row.left - 10);
    expect(c.right, row.right + 10);
    expect(b.left, a.right);

    // Above and below the row, on an item.
    await tester.tapAt(Offset(a.center.dx, row.top - 1.5));
    await tester.tapAt(Offset(c.center.dx, row.bottom + 1.5));
    // Inside a, 1 dp from b: a, not b's ring.
    await tester.tapAt(Offset(a.right - 1, a.center.dy));
    await tester.tapAt(Offset(b.left + 1, b.center.dy));
    // In the bleed, past the row's own edge.
    await tester.tapAt(Offset(row.left - 8, a.center.dy));
    // Left of the bleed, inside a's 48 dp ring.
    await tester.tapAt(Offset(a.left - 1.5, a.center.dy));
    expect(taps, ['a', 'c', 'a', 'b', 'a', 'a']);

    taps.clear();
    await tester.tapAt(Offset(a.center.dx, row.top - 3));
    // The free space between b and c is no target.
    await tester.tapAt(Offset((b.right + c.left) / 2, row.center.dy));
    expect(taps, isEmpty);
  });

  testWidgets('without a host the row still takes taps on its own box', (
    tester,
  ) async {
    final taps = <String>[];
    await _pump(tester, _bleedRow(taps));
    final a = tester.getRect(find.byKey(const Key('a')));
    final row = tester.getRect(find.byType(AppTapArea).first);
    await tester.tapAt(Offset(row.left + 1, a.center.dy));
    await tester.tapAt(Offset(a.right - 1, a.center.dy));
    expect(taps, ['a', 'a']);
  });

  testWidgets('the host leaves a tap that something under it takes', (
    tester,
  ) async {
    final taps = <String>[];
    await _pump(
      tester,
      AppTapAreaHost(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps.add('text'),
              child: const SizedBox(width: 200, height: 40),
            ),
            _bleedRow(taps),
          ],
        ),
      ),
    );
    final a = tester.getRect(find.byKey(const Key('a')));
    // 1.5 dp above the row: inside a's ring but on the text block.
    await tester.tapAt(Offset(a.center.dx, a.top - 1.5));
    expect(taps, ['text']);
  });
}

Widget _bleedRow(List<String> taps) => SizedBox(
  width: 200,
  child: AppTapArea.bleed(
    bleed: 10,
    child: Row(
      children: [
        _button('a', taps, width: 39),
        _button('b', taps, width: 39),
        const Spacer(),
        _button('c', taps),
      ],
    ),
  ),
);
