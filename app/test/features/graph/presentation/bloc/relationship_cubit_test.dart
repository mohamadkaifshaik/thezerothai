import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/relationship_cubit.dart';
import 'package:dzeroth/features/graph/presentation/bloc/relationship_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

void main() {
  late MockGraphRepository graphRepository;
  const userId = 'target-uid';
  final initialNone = graph.Relationship(
    userId: userId,
    followState: graph.FollowState.FOLLOW_STATE_NONE,
  );

  setUp(() {
    graphRepository = MockGraphRepository();
  });

  group('follow', () {
    blocTest<RelationshipCubit, RelationshipState>(
      'shows Following optimistically, then confirms with the server response',
      build: () {
        when(
          () => graphRepository.follow(
            userId: userId,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer(
          (_) async => graph.Relationship(
            userId: userId,
            followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
          ),
        );
        return RelationshipCubit(
          graphRepository: graphRepository,
          userId: userId,
          initial: initialNone,
        );
      },
      act: (cubit) => cubit.follow(),
      expect: () => [
        isA<RelationshipState>()
            .having(
              (s) => s.relationship.followState,
              'optimistic followState',
              graph.FollowState.FOLLOW_STATE_FOLLOWING,
            )
            .having((s) => s.isUpdating, 'isUpdating', true),
        isA<RelationshipState>()
            .having(
              (s) => s.relationship.followState,
              'confirmed followState',
              graph.FollowState.FOLLOW_STATE_FOLLOWING,
            )
            .having((s) => s.isUpdating, 'isUpdating', false),
      ],
    );

    blocTest<RelationshipCubit, RelationshipState>(
      'rolls back to the previous relationship and surfaces the error on failure',
      build: () {
        when(
          () => graphRepository.follow(
            userId: userId,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenThrow(
          const QuotaExceededException('daily limit', quota: 'follows'),
        );
        return RelationshipCubit(
          graphRepository: graphRepository,
          userId: userId,
          initial: initialNone,
        );
      },
      act: (cubit) => cubit.follow(),
      expect: () => [
        isA<RelationshipState>().having(
          (s) => s.relationship.followState,
          'optimistic followState',
          graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
        isA<RelationshipState>()
            .having(
              (s) => s.relationship.followState,
              'rolled back followState',
              graph.FollowState.FOLLOW_STATE_NONE,
            )
            .having((s) => s.isUpdating, 'isUpdating', false)
            .having((s) => s.error, 'error', isA<QuotaExceededException>()),
      ],
    );

    test('reuses the same idempotency key on a retry after failure', () async {
      final keys = <String>[];
      when(
        () => graphRepository.follow(
          userId: userId,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        throw const NetworkException('no connection');
      });
      final cubit = RelationshipCubit(
        graphRepository: graphRepository,
        userId: userId,
        initial: initialNone,
      );

      await cubit.follow();
      await cubit.follow();

      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      await cubit.close();
    });

    test(
      'generates a fresh idempotency key after a successful follow',
      () async {
        final keys = <String>[];
        when(
          () => graphRepository.follow(
            userId: userId,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer((invocation) async {
          keys.add(invocation.namedArguments[#idempotencyKey] as String);
          return graph.Relationship(
            userId: userId,
            followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
          );
        });
        when(
          () => graphRepository.unfollow(
            userId: userId,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer((invocation) async {
          keys.add(invocation.namedArguments[#idempotencyKey] as String);
          return graph.Relationship(
            userId: userId,
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          );
        });
        final cubit = RelationshipCubit(
          graphRepository: graphRepository,
          userId: userId,
          initial: initialNone,
        );

        await cubit.follow();
        await cubit.unfollow();
        await cubit.follow();

        expect(keys.toSet(), hasLength(3));
        await cubit.close();
      },
    );
  });

  group('block', () {
    blocTest<RelationshipCubit, RelationshipState>(
      'unfollows optimistically and marks blocking',
      build: () {
        when(
          () => graphRepository.block(
            userId: userId,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer(
          (_) async => graph.Relationship(userId: userId, blocking: true),
        );
        return RelationshipCubit(
          graphRepository: graphRepository,
          userId: userId,
          initial: graph.Relationship(
            userId: userId,
            followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
          ),
        );
      },
      act: (cubit) => cubit.block(),
      expect: () => [
        isA<RelationshipState>()
            .having((s) => s.relationship.blocking, 'optimistic blocking', true)
            .having(
              (s) => s.relationship.followState,
              'optimistic followState',
              graph.FollowState.FOLLOW_STATE_NONE,
            ),
        isA<RelationshipState>().having(
          (s) => s.relationship.blocking,
          'confirmed blocking',
          true,
        ),
      ],
    );
  });

  blocTest<RelationshipCubit, RelationshipState>(
    'a non-AppException failure rolls back and clears isUpdating',
    build: () {
      when(
        () => graphRepository.follow(
          userId: userId,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(StateError('drift write failed'));
      return RelationshipCubit(
        graphRepository: graphRepository,
        userId: userId,
        initial: initialNone,
      );
    },
    act: (cubit) => cubit.follow(),
    verify: (cubit) {
      expect(cubit.state.isUpdating, isFalse);
      expect(cubit.state.error, isA<UnknownApiException>());
      expect(
        cubit.state.relationship.followState,
        graph.FollowState.FOLLOW_STATE_NONE,
      );
    },
  );

  blocTest<RelationshipCubit, RelationshipState>(
    'a second tap while updating is ignored',
    build: () {
      when(
        () => graphRepository.follow(
          userId: userId,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return graph.Relationship(
          userId: userId,
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        );
      });
      return RelationshipCubit(
        graphRepository: graphRepository,
        userId: userId,
        initial: initialNone,
      );
    },
    act: (cubit) async {
      final first = cubit.follow();
      await cubit.follow();
      await first;
    },
    verify: (_) {
      verify(
        () => graphRepository.follow(
          userId: userId,
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    },
  );
}
