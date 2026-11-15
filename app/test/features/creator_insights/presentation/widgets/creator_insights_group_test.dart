import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/creator_insights/data/creator_insights_repository.dart';
import 'package:dzeroth/features/creator_insights/domain/creator_insights_feature_flag.dart';
import 'package:dzeroth/features/creator_insights/presentation/widgets/insights_metric_tile.dart';
import 'package:dzeroth/features/creator_insights/presentation/widgets/insights_sparkline.dart';
import 'package:dzeroth/features/creator_studio/presentation/widgets/creator_insights_group.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/creator_insights_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _sizes = {
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Future<(MockCreatorInsightsRepository, GoRouter)> _pump(
  WidgetTester tester, {
  bool flag = true,
  Size size = const Size(390, 844),
}) async {
  final repo = MockCreatorInsightsRepository();
  when(() => repo.load(windowDays: any(named: 'windowDays'))).thenAnswer(
    (i) async => insightsResponse(days: i.namedArguments[#windowDays] as int),
  );
  final bloc = _MockOnboardingBloc();
  whenListen(
    bloc,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      enabledFeatures: {if (flag) kFeatureCreatorInsights},
    ),
  );
  final phone = size.width < AppBreakpoints.mobile;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: SingleChildScrollView(
            child: CreatorInsightsGroup(
              style: phone
                  ? SettingsGroupStyle.raised
                  : SettingsGroupStyle.flat,
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/post/:id',
        builder: (context, state) =>
            Scaffold(body: Text('post ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    BlocProvider<OnboardingBloc>.value(
      value: bloc,
      child: RepositoryProvider<CreatorInsightsRepository>.value(
        value: repo,
        child: MaterialApp.router(
          theme: buildAppTheme(brightness: Brightness.light),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (repo, router);
}

void main() {
  testWidgets('flag off keeps the Coming soon rows and makes no call', (
    tester,
  ) async {
    final (repo, _) = await _pump(tester, flag: false);
    expect(find.text('Coming soon'), findsNWidgets(4));
    expect(find.byType(InsightsMetricTile), findsNothing);
    verifyNever(() => repo.load(windowDays: any(named: 'windowDays')));
  });

  for (final e in _sizes.entries) {
    testWidgets('flag on renders three tiles and top posts on ${e.key}', (
      tester,
    ) async {
      final (repo, _) = await _pump(tester, size: e.value);
      expect(find.text('Coming soon'), findsNothing);
      expect(find.byType(InsightsMetricTile), findsNWidgets(3));
      expect(find.byType(InsightsSparkline), findsNWidgets(3));
      expect(find.text('1.2K'), findsOneWidget);
      expect(find.text('+13% vs previous'), findsNWidgets(2));
      expect(find.text('+7'), findsOneWidget);
      expect(find.text('My best post'), findsOneWidget);
      expect(tester.takeException(), isNull);
      verify(() => repo.load(windowDays: 28)).called(1);
    });
  }

  testWidgets('the % change is hidden when absent', (tester) async {
    final (repo, _) = await _pump(tester);
    when(() => repo.load(windowDays: 7))
        .thenAnswer((_) async => insightsResponse(days: 7, pct: null));
    await tester.tap(find.text('7 days'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(InsightsMetricTile), findsNWidgets(3));
    expect(find.byKey(const ValueKey('insight-change')), findsNothing);
  });

  testWidgets('switching to 7 days reloads', (tester) async {
    final (repo, _) = await _pump(tester);
    await tester.tap(find.text('7 days'));
    await tester.pump();
    await tester.pump();
    verify(() => repo.load(windowDays: 7)).called(1);
  });

  testWidgets('empty shows Not enough data yet', (tester) async {
    final (repo, _) = await _pump(tester);
    when(() => repo.load(windowDays: 7))
        .thenAnswer((_) async => emptyInsights());
    await tester.tap(find.text('7 days'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Not enough data yet'), findsOneWidget);
    expect(find.byType(InsightsMetricTile), findsNothing);
  });

  testWidgets('error shows a retry that reloads', (tester) async {
    final (repo, _) = await _pump(tester);
    when(() => repo.load(windowDays: 7))
        .thenThrow(const NetworkException('offline'));
    await tester.tap(find.text('7 days'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('No connection'), findsOneWidget);
    when(() => repo.load(windowDays: 7))
        .thenAnswer((_) async => insightsResponse(days: 7));
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(InsightsMetricTile), findsNWidgets(3));
  });

  testWidgets('tapping a top post opens it', (tester) async {
    await _pump(tester);
    await tester.ensureVisible(find.text('My best post'));
    await tester.tap(find.text('My best post'));
    await tester.pumpAndSettle();
    expect(find.text('post 1234567890123456789'), findsOneWidget);
  });

  test('formatChangePct', () {
    expect(formatChangePct(12.5), '+13%');
    expect(formatChangePct(3.25), '+3.3%');
    expect(formatChangePct(-3), '-3%');
    expect(formatChangePct(0), '0%');
  });
}
