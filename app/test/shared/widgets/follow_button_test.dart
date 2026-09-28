import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/presentation/bloc/relationship_cubit.dart';
import 'package:dzeroth/features/graph/presentation/bloc/relationship_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/follow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockRelationshipCubit extends MockCubit<RelationshipState>
    implements RelationshipCubit {}

void main() {
  late MockRelationshipCubit cubit;

  setUp(() {
    cubit = MockRelationshipCubit();
  });

  Widget wrap() {
    return MaterialApp(
      home: Scaffold(
        body: BlocProvider<RelationshipCubit>.value(
          value: cubit,
          child: const FollowButton(),
        ),
      ),
    );
  }

  testWidgets('shows "Follow" when there is no relationship', (tester) async {
    whenListen(
      cubit,
      const Stream<RelationshipState>.empty(),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_NONE,
        ),
      ),
    );

    await tester.pumpWidget(wrap());

    expect(find.text('Follow'), findsOneWidget);
    // FilledButton has a 48dp minimum height from the app theme.
    final size = tester.getSize(find.byType(FilledButton));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('tapping Follow calls cubit.follow()', (tester) async {
    whenListen(
      cubit,
      const Stream<RelationshipState>.empty(),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_NONE,
        ),
      ),
    );
    when(() => cubit.follow()).thenAnswer((_) async {});

    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Follow'));

    verify(() => cubit.follow()).called(1);
  });

  testWidgets('shows "Following" and unfollows on tap', (tester) async {
    whenListen(
      cubit,
      const Stream<RelationshipState>.empty(),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      ),
    );
    when(() => cubit.unfollow()).thenAnswer((_) async {});

    await tester.pumpWidget(wrap());
    expect(find.text('Following'), findsOneWidget);

    await tester.tap(find.text('Following'));
    verify(() => cubit.unfollow()).called(1);
  });

  testWidgets('shows "Unblock" (never "Follow") while the caller blocks the '
      'target', (tester) async {
    whenListen(
      cubit,
      const Stream<RelationshipState>.empty(),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_NONE,
          blocking: true,
        ),
      ),
    );
    when(() => cubit.unblock()).thenAnswer((_) async {});

    await tester.pumpWidget(wrap());

    expect(find.text('Unblock'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);

    await tester.tap(find.text('Unblock'));
    verify(() => cubit.unblock()).called(1);
  });

  testWidgets('shows a disabled "Requested" state (hidden variant)', (
    tester,
  ) async {
    whenListen(
      cubit,
      const Stream<RelationshipState>.empty(),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
        ),
      ),
    );

    await tester.pumpWidget(wrap());

    expect(find.text('Requested'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'shows a loading indicator and disables the button while updating',
    (tester) async {
      whenListen(
        cubit,
        const Stream<RelationshipState>.empty(),
        initialState: RelationshipState(
          relationship: graph.Relationship(
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          ),
          isUpdating: true,
        ),
      );

      await tester.pumpWidget(wrap());

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('shows a friendly snackbar (never the raw message) on error', (
    tester,
  ) async {
    whenListen(
      cubit,
      Stream<RelationshipState>.fromIterable([
        RelationshipState(
          relationship: graph.Relationship(
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          ),
          error: const QuotaExceededException('raw server text'),
        ),
      ]),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_NONE,
        ),
      ),
    );

    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.text('raw server text'), findsNothing);
    expect(
      find.text(
        "You've hit today's limit for this action. It resets tomorrow.",
      ),
      findsOneWidget,
    );
  });
}
