import 'dart:async';

import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_state.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_search_repository.dart';

void main() {
  late FakeSearchRepository repo;
  late DateTime clock;
  late TrendsCubit cubit;

  setUp(() {
    repo = FakeSearchRepository()
      ..trendsResult = TrendsResult(
        trends: [Trend(tag: 'a', rank: 1, postCount: Int64(3))],
        computedAt: DateTime.now(),
      );
    clock = DateTime.now();
    cubit = TrendsCubit(repository: repo, now: () => clock);
  });

  tearDown(() => cubit.close());

  test('asks for the Trending list size once and shows the answer', () async {
    await cubit.ensureLoaded();
    expect(repo.calls, ['trends:']);
    expect(cubit.state.status, TrendsStatus.ready);
    expect(cubit.state.trends.single.tag, 'a');
  });

  test('concurrent callers share one call', () async {
    final gate = repo.trendsGate = Completer<void>();
    final a = cubit.ensureLoaded();
    final b = cubit.ensureLoaded();
    expect(cubit.state.status, TrendsStatus.loading);
    gate.complete();
    await Future.wait([a, b]);
    expect(repo.calls.length, 1);
  });

  test('a warm answer is free for 5 minutes, then one call', () async {
    await cubit.ensureLoaded();
    clock = clock.add(const Duration(minutes: 4, seconds: 59));
    await cubit.ensureLoaded();
    expect(repo.calls.length, 1);
    clock = clock.add(const Duration(seconds: 2));
    await cubit.ensureLoaded();
    expect(repo.calls.length, 2);
  });

  test('a failure is an attempt too; force (Retry) asks again', () async {
    repo.error = const SearchRateLimitedException();
    await cubit.ensureLoaded();
    expect(cubit.state.status, TrendsStatus.failed);
    await cubit.ensureLoaded();
    expect(repo.calls.length, 1);
    repo.error = null;
    await cubit.ensureLoaded(force: true);
    expect(repo.calls.length, 2);
    expect(cubit.state.status, TrendsStatus.ready);
  });

  test('a failed refresh keeps the earlier list', () async {
    await cubit.ensureLoaded();
    clock = clock.add(const Duration(minutes: 6));
    repo.error = StateError('boom');
    await cubit.ensureLoaded();
    expect(cubit.state.status, TrendsStatus.failed);
    expect(cubit.state.trends, isNotEmpty);
  });

  test('FEATURE_DISABLED ends the calls until reset', () async {
    repo.error = const SearchUnavailableException('trends');
    await cubit.ensureLoaded();
    expect(cubit.state.status, TrendsStatus.unavailable);
    clock = clock.add(const Duration(hours: 1));
    repo.error = null;
    await cubit.ensureLoaded();
    await cubit.ensureLoaded(force: true);
    expect(repo.calls.length, 1);
    cubit.reset();
    await cubit.ensureLoaded();
    expect(repo.calls.length, 2);
  });

  test('reset forgets the list and an answer still in flight', () async {
    final gate = repo.trendsGate = Completer<void>();
    final pending = cubit.ensureLoaded();
    cubit.reset();
    gate.complete();
    await pending;
    expect(cubit.state.status, TrendsStatus.initial);
    expect(cubit.state.trends, isEmpty);
  });
}
