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

  Widget wrap({bool followedBy = false}) {
    return MaterialApp(
      home: Scaffold(
        body: BlocProvider<RelationshipCubit>.value(
          value: cubit,
          child: FollowButton(followedBy: followedBy),
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

  group('Requested (ADR-0025 D6, D7)', () {
    void showRequested({bool isUpdating = false}) => whenListen(
      cubit,
      const Stream<RelationshipState>.empty(),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
        ),
        isUpdating: isUpdating,
      ),
    );

    testWidgets('shows an outlined, tappable "Requested" 48dp target', (
      tester,
    ) async {
      showRequested();

      await tester.pumpWidget(wrap());

      expect(find.text('Requested'), findsOneWidget);
      final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(button.onPressed, isNotNull);
      expect(tester.getSize(find.byType(OutlinedButton)).height, 48);
      expect(
        tester.getSize(find.byType(OutlinedButton)).width,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('a tap asks first, and Cancel request sends one unfollow', (
      tester,
    ) async {
      showRequested();
      when(() => cubit.unfollow()).thenAnswer((_) async {});
      await tester.pumpWidget(wrap());

      await tester.tap(find.text('Requested'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel your follow request?'), findsOneWidget);
      verifyNever(() => cubit.unfollow());

      await tester.tap(find.text('Cancel request'));
      await tester.pumpAndSettle();

      verify(() => cubit.unfollow()).called(1);
    });

    testWidgets('Keep request closes the dialog and sends nothing', (
      tester,
    ) async {
      showRequested();
      await tester.pumpWidget(wrap());

      await tester.tap(find.text('Requested'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep request'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel your follow request?'), findsNothing);
      verifyNever(() => cubit.unfollow());
    });

    testWidgets('is disabled while the withdraw is in flight', (tester) async {
      showRequested(isUpdating: true);

      await tester.pumpWidget(wrap());

      final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(button.onPressed, isNull);
    });
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

  group('onGone (NOT_FOUND: blocked-by, suspended or deleted)', () {
    Widget wrapGone(VoidCallback onGone) => MaterialApp(
      home: Scaffold(
        body: BlocProvider<RelationshipCubit>.value(
          value: cubit,
          child: FollowButton(onGone: onGone),
        ),
      ),
    );

    void failWith(AppException error) => whenListen(
      cubit,
      Stream<RelationshipState>.fromIterable([
        RelationshipState(
          relationship: graph.Relationship(
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          ),
          error: error,
        ),
      ]),
      initialState: RelationshipState(
        relationship: graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_NONE,
        ),
      ),
    );

    testWidgets('NOT_FOUND calls it once and shows no snackbar', (
      tester,
    ) async {
      failWith(const NotFoundException('not found'));
      var gone = 0;

      await tester.pumpWidget(wrapGone(() => gone++));
      await tester.pump();

      expect(gone, 1);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('without it NOT_FOUND still says so in a snackbar', (
      tester,
    ) async {
      failWith(const NotFoundException('not found'));

      await tester.pumpWidget(wrap());
      await tester.pump();

      expect(find.text("This account doesn't exist anymore."), findsOneWidget);
    });

    testWidgets('any other error keeps the snackbar and does not call it', (
      tester,
    ) async {
      failWith(const QuotaExceededException('limit'));
      var gone = 0;

      await tester.pumpWidget(wrapGone(() => gone++));
      await tester.pump();

      expect(gone, 0);
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('followedBy (the profile header, "Follows you")', () {
    void arrange(graph.Relationship relationship) {
      whenListen(
        cubit,
        const Stream<RelationshipState>.empty(),
        initialState: RelationshipState(relationship: relationship),
      );
    }

    testWidgets('not following yet: "Follow back", and it follows on tap', (
      tester,
    ) async {
      arrange(
        graph.Relationship(followState: graph.FollowState.FOLLOW_STATE_NONE),
      );
      when(() => cubit.follow()).thenAnswer((_) async {});

      await tester.pumpWidget(wrap(followedBy: true));

      expect(find.text('Follow back'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      expect(find.bySemanticsLabel('Follow back'), findsWidgets);
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.text('Follow back'));
      verify(() => cubit.follow()).called(1);
    });

    testWidgets('without followedBy it stays "Follow"', (tester) async {
      arrange(
        graph.Relationship(followState: graph.FollowState.FOLLOW_STATE_NONE),
      );

      await tester.pumpWidget(wrap());

      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Follow back'), findsNothing);
    });

    testWidgets('following: "Following", never "Follow back"', (tester) async {
      arrange(
        graph.Relationship(
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );

      await tester.pumpWidget(wrap(followedBy: true));

      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Follow back'), findsNothing);
    });

    testWidgets('blocking: "Unblock", never "Follow back"', (tester) async {
      arrange(graph.Relationship(blocking: true));

      await tester.pumpWidget(wrap(followedBy: true));

      expect(find.text('Unblock'), findsOneWidget);
      expect(find.text('Follow back'), findsNothing);
    });
  });
}
