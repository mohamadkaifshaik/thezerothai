import 'package:dzeroth/core/telemetry/usage_reporter.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_search_repository.dart';
import '../../../support/recording_usage_analytics.dart';
import '../../../support/search_field_rig.dart';

/// TEL-6: a submitted search reports its kind only, never the text.
void main() {
  late RecordingUsageAnalytics analytics;

  setUp(() => analytics = RecordingUsageAnalytics());

  Future<void> open(WidgetTester tester) => pumpWithSearch(
    tester,
    UsageScope(
      reporter: UsageReporter.analytics(analytics),
      child: AppSearchField(
        onSubmitted: (_, _) {},
        onPersonSelected: (_, _) {},
      ),
    ),
    repository: FakeSearchRepository(),
    store: FakeRecentSearchesStore(),
  );

  Future<void> submit(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
  }

  testWidgets('a #tag logs hashtag; a handle or a word logs people', (
    tester,
  ) async {
    await open(tester);
    await submit(tester, '#launch');
    await submit(tester, '@ann');
    await submit(tester, 'ann');

    expect(analytics.wire, [
      'search_used{type=hashtag}',
      'search_used{type=people}',
      'search_used{type=people}',
    ]);
    expect(analytics.wire.join(), isNot(contains('launch')));
    expect(analytics.wire.join(), isNot(contains('ann')));
  });

  testWidgets('a query that cannot be searched logs nothing', (tester) async {
    await open(tester);
    await submit(tester, '@');
    expect(analytics.events, isEmpty);
  });
}
