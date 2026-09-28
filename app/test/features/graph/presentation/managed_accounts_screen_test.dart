import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/managed_accounts_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

graph.UserListItem _item(String id, String handle) {
  return graph.UserListItem(
    user: common.AuthorSnapshot(
      userId: id,
      handle: handle,
      displayName: 'Display $handle',
    ),
  );
}

void main() {
  late MockGraphRepository graphRepository;

  setUp(() {
    graphRepository = MockGraphRepository();
  });

  Widget wrap(Widget child) {
    return RepositoryProvider<GraphRepository>.value(
      value: graphRepository,
      child: MaterialApp(home: child),
    );
  }

  group('BlockedAccountsScreen', () {
    testWidgets('shows an empty state', (tester) async {
      when(
        () => graphRepository.listBlockedUsers(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));

      await tester.pumpWidget(wrap(const BlockedAccountsScreen()));
      await tester.pumpAndSettle();

      expect(find.text("You haven't blocked anyone."), findsOneWidget);
    });

    testWidgets('lists blocked accounts and unblocks with undo', (
      tester,
    ) async {
      when(
        () => graphRepository.listBlockedUsers(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer(
        (_) async => GraphPage(
          items: [_item('u1', 'one'), _item('u2', 'two')],
          nextPageToken: '',
        ),
      );
      when(
        () => graphRepository.unblock(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: 'u1', blocking: false),
      );
      when(
        () => graphRepository.block(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: 'u1', blocking: true),
      );

      await tester.pumpWidget(wrap(const BlockedAccountsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('@one'), findsOneWidget);
      expect(find.text('@two'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Unblock').first);
      await tester.pump();

      expect(find.text('@one'), findsNothing);
      expect(find.text('Unblocked @one'), findsOneWidget);

      // Invoke the SnackBarAction's callback directly rather than tapping a
      // screen coordinate: the SnackBar can render partly below the default
      // test surface once an AppBar and rows are also on screen, which is a
      // test-harness layout detail, not something worth asserting on.
      final undoAction = tester.widget<SnackBarAction>(
        find.byType(SnackBarAction),
      );
      undoAction.onPressed();
      await tester.pumpAndSettle();

      verify(
        () => graphRepository.block(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text('@one'), findsOneWidget);
    });
  });

  group('MutedAccountsScreen', () {
    testWidgets('lists muted accounts with an Unmute action', (tester) async {
      when(
        () => graphRepository.listMutedUsers(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer(
        (_) async =>
            GraphPage(items: [_item('u3', 'three')], nextPageToken: ''),
      );

      await tester.pumpWidget(wrap(const MutedAccountsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('@three'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Unmute'), findsOneWidget);
    });
  });
}
