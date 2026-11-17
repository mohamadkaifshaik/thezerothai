import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/widgets/trend_row.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pump(WidgetTester tester, Widget row) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: row)));

void main() {
  testWidgets('the Latest row shows its label and tag, no rank and no count', (
    tester,
  ) async {
    var taps = 0;
    await _pump(
      tester,
      TrendRow(
        trend: Trend(tag: 'fresh', rank: 0),
        ranked: true,
        last: true,
        kicker: 'Latest',
        onTap: () => taps++,
      ),
    );
    expect(find.text('Latest'), findsOneWidget);
    expect(find.text('#fresh'), findsOneWidget);
    expect(find.textContaining('post'), findsNothing);
    expect(find.text('0'), findsNothing);
    await tester.tap(find.text('#fresh'));
    expect(taps, 1);
  });

  testWidgets('a "Just posted" row is labelled for screen readers', (
    tester,
  ) async {
    await _pump(
      tester,
      TrendRow(
        trend: Trend(tag: 'new'),
        ranked: true,
        last: true,
        kicker: 'Just posted',
        onTap: () {},
      ),
    );
    expect(find.text('Just posted'), findsOneWidget);
    expect(find.bySemanticsLabel('Just posted, #new'), findsOneWidget);
  });

  testWidgets('a ranked Popular row keeps its rank and post count', (
    tester,
  ) async {
    await _pump(
      tester,
      TrendRow(
        trend: Trend(tag: 'go', rank: 2, postCount: Int64(5)),
        ranked: true,
        onTap: () {},
      ),
    );
    expect(find.text('2'), findsOneWidget);
    expect(find.text('#go'), findsOneWidget);
    expect(find.text('5 posts'), findsOneWidget);
    expect(find.text('Latest'), findsNothing);
  });
}
