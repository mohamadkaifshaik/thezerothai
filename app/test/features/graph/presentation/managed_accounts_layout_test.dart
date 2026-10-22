import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/managed_accounts_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockGraph extends Mock implements GraphRepository {}

graph.UserListItem _item(int i) => graph.UserListItem(
  user: common.AuthorSnapshot(
    userId: 'u$i',
    handle: 'user$i',
    displayName: 'A long display name for user number $i',
  ),
);

/// The blocked/muted screens share `UserListRow` and `PagedUserList` with the
/// followers/following restyle (UI slice graph lists); they must stay
/// working and fit in every size, theme and text scale. Their behaviour is
/// owned by managed_accounts_screen_test.dart.
void main() {
  late _MockGraph repo;

  setUp(() {
    repo = _MockGraph();
    final page = GraphPage(items: [_item(1), _item(2)], nextPageToken: '');
    when(
      () => repo.listBlockedUsers(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => page);
    when(
      () => repo.listMutedUsers(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => page);
  });

  for (final blocked in const [true, false]) {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        testWidgets('${blocked ? 'blocked' : 'muted'} ${size.width.toInt()} '
            '${brightness.name} at text x2: rows, action, no overflow', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final action = blocked ? 'Unblock' : 'Unmute';
          await tester.pumpWidget(
            RepositoryProvider<GraphRepository>.value(
              value: repo,
              child: MaterialApp(
                theme: buildAppTheme(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: blocked
                    ? const BlockedAccountsScreen()
                    : const MutedAccountsScreen(),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.text('@user1'), findsOneWidget);
          expect(find.widgetWithText(TextButton, action), findsNWidgets(2));
          // The row's action keeps a 48dp target.
          expect(
            tester
                .getSize(find.widgetWithText(TextButton, action).first)
                .height,
            greaterThanOrEqualTo(AppSpacing.minTapTarget),
          );
        });
      }
    }
  }
}
