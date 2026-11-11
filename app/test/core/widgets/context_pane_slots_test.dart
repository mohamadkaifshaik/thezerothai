import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/context_pane_slots.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page that lends the pane a section while it is mounted.
class _Lender extends StatefulWidget {
  const _Lender({
    required this.location,
    required this.label,
    this.kind = ContextSectionKind.communityAbout,
  });

  final String location;
  final String label;
  final ContextSectionKind kind;

  @override
  State<_Lender> createState() => _LenderState();
}

class _LenderState extends State<_Lender> {
  final _lease = ContextPaneLease();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lease.attach(context, widget.location, {
      widget.kind: (context) => Text('lent ${widget.label}'),
    });
  }

  @override
  void dispose() {
    _lease.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('page ${widget.label}');
}

Widget _app({
  required List<Widget> pages,
  String slotLocation = '/communities/77',
  ContextSectionKind kind = ContextSectionKind.communityAbout,
  bool host = true,
}) {
  final body = Column(
    children: [
      ...pages,
      ContextPaneSlot(kind: kind, location: slotLocation),
    ],
  );
  return MaterialApp(
    home: Scaffold(body: host ? ContextPaneSlotsHost(child: body) : body),
  );
}

void main() {
  group('ContextPaneSlots (page to pane, T8a)', () {
    testWidgets('a mounted page fills the slot of its location and kind', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          pages: const [_Lender(location: '/communities/77', label: 'A')],
        ),
      );
      await tester.pump();
      expect(find.text('lent A'), findsOneWidget);
    });

    testWidgets('another location or kind leaves the slot empty (0 height)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          pages: const [_Lender(location: '/communities/78', label: 'A')],
        ),
      );
      await tester.pump();
      expect(find.text('lent A'), findsNothing);
      expect(tester.getSize(find.byType(ContextPaneSlot)).height, 0);

      await tester.pumpWidget(
        _app(
          pages: const [
            _Lender(location: '/communities/77', label: 'B'),
            _Lender(
              location: '/communities/77',
              label: 'C',
              kind: ContextSectionKind.exploreCommunities,
            ),
          ],
          kind: ContextSectionKind.exploreCommunities,
        ),
      );
      await tester.pump();
      expect(find.text('lent B'), findsNothing);
      expect(find.text('lent C'), findsOneWidget);
    });

    testWidgets('a query or a trailing slash does not change the location', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          pages: const [_Lender(location: '/communities/77/', label: 'A')],
          slotLocation: '/communities/77?tab=about',
        ),
      );
      await tester.pump();
      expect(find.text('lent A'), findsOneWidget);
    });

    testWidgets('the page mounted last wins; its removal reveals the one '
        'below', (tester) async {
      await tester.pumpWidget(
        _app(
          pages: const [
            _Lender(location: '/communities/77', label: 'lower'),
            _Lender(location: '/communities/77', label: 'upper'),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('lent upper'), findsOneWidget);
      expect(find.text('lent lower'), findsNothing);

      await tester.pumpWidget(
        _app(
          pages: const [_Lender(location: '/communities/77', label: 'lower')],
        ),
      );
      // The removal is announced after the frame (the tree is locked while
      // the page is disposed); the next frame shows the page below.
      await tester.pump();
      expect(find.text('lent lower'), findsOneWidget);
      expect(find.text('lent upper'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a disposed page empties the slot without an error', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          pages: const [_Lender(location: '/communities/77', label: 'A')],
        ),
      );
      await tester.pump();
      expect(find.text('lent A'), findsOneWidget);

      await tester.pumpWidget(_app(pages: const []));
      await tester.pump();
      expect(find.text('lent A'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a placeholder fills the slot until a page lends, and comes '
        'back when it leaves', (tester) async {
      Widget app(List<Widget> pages) => MaterialApp(
        home: Scaffold(
          body: ContextPaneSlotsHost(
            child: Column(
              children: [
                ...pages,
                const ContextPaneSlot(
                  kind: ContextSectionKind.communityAbout,
                  location: '/communities/77',
                  placeholder: Text('placeholder'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(const []));
      expect(find.text('placeholder'), findsOneWidget);

      await tester.pumpWidget(
        app(const [_Lender(location: '/communities/77', label: 'A')]),
      );
      await tester.pump();
      expect(find.text('lent A'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);

      await tester.pumpWidget(app(const []));
      await tester.pump();
      expect(find.text('placeholder'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a host a page lends nothing and the slot is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          pages: const [_Lender(location: '/communities/77', label: 'A')],
          host: false,
        ),
      );
      await tester.pump();
      expect(find.text('page A'), findsOneWidget);
      expect(find.text('lent A'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('lookups read the latest lease of a location and kind', () {
      final slots = ContextPaneSlots();
      addTearDown(slots.dispose);
      final a = Object();
      final b = Object();
      Widget one(BuildContext _) => const Text('1');
      Widget two(BuildContext _) => const Text('2');
      slots.put(a, '/communities', {
        ContextSectionKind.exploreCommunities: one,
      });
      slots.put(b, '/communities', {
        ContextSectionKind.exploreCommunities: two,
      });
      expect(
        slots.builderFor('/communities', ContextSectionKind.exploreCommunities),
        same(two),
      );
      slots.remove(b);
      expect(
        slots.builderFor('/communities', ContextSectionKind.exploreCommunities),
        same(one),
      );
      expect(
        slots.builderFor('/communities', ContextSectionKind.communityAbout),
        isNull,
      );
      slots.remove(a);
      expect(
        slots.builderFor('/communities', ContextSectionKind.exploreCommunities),
        isNull,
      );
    });
  });
}
