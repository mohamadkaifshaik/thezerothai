import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/creator_insights/presentation/bloc/creator_insights_cubit.dart';
import 'package:dzeroth/features/creator_insights/presentation/bloc/creator_insights_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/creator_insights_fixtures.dart';

void main() {
  late MockCreatorInsightsRepository repo;
  setUp(() => repo = MockCreatorInsightsRepository());

  CreatorInsightsCubit build() => CreatorInsightsCubit(repository: repo);

  blocTest<CreatorInsightsCubit, CreatorInsightsState>(
    'loads the default 28 day window',
    setUp: () =>
        when(() => repo.load(windowDays: 28))
            .thenAnswer((_) async => insightsResponse()),
    build: build,
    act: (c) => c.load(),
    expect: () => [
      const CreatorInsightsState.loading(windowDays: 28),
      isA<CreatorInsightsReady>().having((s) => s.windowDays, 'days', 28),
    ],
  );

  blocTest<CreatorInsightsCubit, CreatorInsightsState>(
    'nothing recorded is the empty state',
    setUp: () =>
        when(() => repo.load(windowDays: 28))
            .thenAnswer((_) async => emptyInsights()),
    build: build,
    act: (c) => c.load(),
    expect: () => [
      const CreatorInsightsState.loading(windowDays: 28),
      const CreatorInsightsState.empty(windowDays: 28),
    ],
  );

  blocTest<CreatorInsightsCubit, CreatorInsightsState>(
    'a failure is the error state, and load retries',
    setUp: () {
      var calls = 0;
      when(() => repo.load(windowDays: 28)).thenAnswer((_) async {
        if (calls++ == 0) throw const NetworkException('offline');
        return insightsResponse();
      });
    },
    build: build,
    act: (c) async {
      await c.load();
      await c.load();
    },
    expect: () => [
      const CreatorInsightsState.loading(windowDays: 28),
      isA<CreatorInsightsError>().having(
        (s) => s.error,
        'error',
        isA<NetworkException>(),
      ),
      const CreatorInsightsState.loading(windowDays: 28),
      isA<CreatorInsightsReady>(),
    ],
  );

  blocTest<CreatorInsightsCubit, CreatorInsightsState>(
    'switching the window reloads with it; the same window is a no-op',
    setUp: () {
      when(() => repo.load(windowDays: 28))
          .thenAnswer((_) async => insightsResponse());
      when(() => repo.load(windowDays: 7))
          .thenAnswer((_) async => insightsResponse(days: 7));
    },
    build: build,
    act: (c) async {
      await c.load();
      await c.selectWindow(7);
      await c.selectWindow(7);
    },
    expect: () => [
      const CreatorInsightsState.loading(windowDays: 28),
      isA<CreatorInsightsReady>(),
      const CreatorInsightsState.loading(windowDays: 7),
      isA<CreatorInsightsReady>().having((s) => s.windowDays, 'days', 7),
    ],
    verify: (_) {
      verify(() => repo.load(windowDays: 7)).called(1);
    },
  );
}
