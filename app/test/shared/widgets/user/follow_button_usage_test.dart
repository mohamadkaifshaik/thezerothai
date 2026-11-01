import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/telemetry/analytics_event.dart';
import 'package:dzeroth/core/telemetry/usage_reporter.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/relationship_cubit.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/user/follow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/recording_usage_analytics.dart';

class _MockGraphRepository extends Mock implements GraphRepository {}

/// TEL-6: `follow` is reported once the server confirmed it, with the source.
void main() {
  late _MockGraphRepository repo;
  late RecordingUsageAnalytics analytics;

  setUp(() {
    repo = _MockGraphRepository();
    analytics = RecordingUsageAnalytics();
  });

  Widget button(Widget child) => BlocProvider(
    create: (_) => RelationshipCubit(
      graphRepository: repo,
      userId: 'u2',
      initial: graph.Relationship(userId: 'u2'),
    ),
    child: child,
  );

  Widget wrap(Widget child, {bool scoped = true}) => MaterialApp(
    home: Scaffold(
      body: scoped
          ? UsageScope(
              reporter: UsageReporter.analytics(analytics),
              child: button(child),
            )
          : button(child),
    ),
  );

  void stubFollow(Future<graph.Relationship> Function() answer) => when(
    () => repo.follow(
      userId: any(named: 'userId'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  ).thenAnswer((_) => answer());

  Future<graph.Relationship> following() async => graph.Relationship(
    userId: 'u2',
    followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
  );

  testWidgets('a confirmed follow logs one follow with its source', (
    tester,
  ) async {
    stubFollow(following);
    await tester.pumpWidget(
      wrap(const FollowButton(source: FollowSource.profile)),
    );
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(analytics.wire, ['follow{source=profile}']);
  });

  testWidgets('the default source is other', (tester) async {
    stubFollow(following);
    await tester.pumpWidget(wrap(const FollowButton()));
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(analytics.wire, ['follow{source=other}']);
  });

  testWidgets('a refused follow rolls back and logs nothing', (tester) async {
    stubFollow(() async => throw const NetworkException('offline'));
    await tester.pumpWidget(
      wrap(const FollowButton(source: FollowSource.list)),
    );
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(find.text('Follow'), findsOneWidget);
    expect(analytics.events, isEmpty);
  });

  testWidgets('a follow refused after the row left the screen logs nothing', (
    tester,
  ) async {
    final answer = Completer<graph.Relationship>();
    stubFollow(() => answer.future);
    await tester.pumpWidget(wrap(const FollowButton()));
    await tester.tap(find.text('Follow'));
    await tester.pump();
    // The row scrolls away: the cubit closes while the request is in flight.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    answer.completeError(const NetworkException('offline'));
    await tester.pumpAndSettle();

    expect(analytics.events, isEmpty);
  });

  testWidgets('without a UsageScope the button works and reports nothing', (
    tester,
  ) async {
    stubFollow(following);
    await tester.pumpWidget(wrap(const FollowButton(), scoped: false));
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();

    expect(find.text('Following'), findsOneWidget);
    expect(analytics.events, isEmpty);
  });
}
