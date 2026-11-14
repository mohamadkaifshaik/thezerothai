import 'package:dzeroth/features/engagement/domain/impression_tracker.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/impression_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<List<String>> sent;
  late ImpressionTracker tracker;
  late ScrollController controller;
  var enabled = true;

  setUp(() {
    sent = [];
    enabled = true;
    controller = ScrollController();
    tracker = ImpressionTracker(
      send: (ids) async => sent.add(ids),
      isEnabled: () => enabled,
    );
  });

  tearDown(() {
    tracker.dispose();
    controller.dispose();
  });

  // Ten 300 px cards in an 800 px viewport (the test view is 800 x 600).
  Future<void> pumpList(WidgetTester tester, {bool noTracker = false}) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget list = MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          controller: controller,
          itemCount: 10,
          itemBuilder: (_, i) => ImpressionDetector(
            postId: 'p$i',
            child: SizedBox(height: 300, child: Text('card $i')),
          ),
        ),
      ),
    );
    if (!noTracker) {
      list = RepositoryProvider<ImpressionTracker>.value(
        value: tracker,
        child: list,
      );
    }
    await tester.pumpWidget(list);
  }

  Set<String> pending() {
    // Flush synchronously observable through the sender.
    tracker.flush();
    return sent.expand((b) => b).toSet();
  }

  testWidgets('counts cards at least half visible after 1 s', (tester) async {
    await pumpList(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(tracker.pendingCount, 0, reason: 'not yet 1 s');
    await tester.pump(const Duration(milliseconds: 200));

    // Cards 0 and 1 fill 600 px; card 2 is off screen.
    expect(pending(), {'p0', 'p1'});
  });

  testWidgets('a card scrolled away before 1 s is not counted', (tester) async {
    await pumpList(tester);
    await tester.pump(const Duration(milliseconds: 500));
    // Jump 1800 px: cards 6 and 7 are on screen now, 0 to 1 are gone.
    controller.jumpTo(1800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(pending(), isEmpty, reason: 'cards 0/1 left; 6/7 are only 0.6 s');

    await tester.pump(const Duration(milliseconds: 600));
    expect(pending(), {'p6', 'p7'});
  });

  testWidgets('a card only 40% visible is not counted', (tester) async {
    await pumpList(tester);
    controller.jumpTo(180); // card 0: 120 of 300 left; card 2: 180 of 300 in
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    // 0: 120/300 = 40% no; 1: full; 2: 600-... shown 180/300 = 60% yes.
    expect(pending(), {'p1', 'p2'});
  });

  testWidgets('flag off: nothing is measured or counted', (tester) async {
    enabled = false;
    await pumpList(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(pending(), isEmpty);
    expect(sent, isEmpty);
  });

  testWidgets('without a tracker above it is a plain pass-through', (
    tester,
  ) async {
    await pumpList(tester, noTracker: true);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('card 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('immediate counts at the first frame (opened post)', (
    tester,
  ) async {
    await tester.pumpWidget(
      RepositoryProvider<ImpressionTracker>.value(
        value: tracker,
        child: const MaterialApp(
          home: ImpressionDetector(
            postId: 'open',
            immediate: true,
            child: SizedBox(height: 50),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(pending(), {'open'});
  });
}
