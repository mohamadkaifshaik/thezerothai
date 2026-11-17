import 'package:dzeroth/core/session/user_ids.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/user/follow_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

/// A user row for an account that is gone (the tombstone id): not openable, no
/// follow, no managing action; it reads "Deleted account" without a name.
void main() {
  Future<void> open(WidgetTester tester, UserListRow row) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(value: _MockGraph(), child: row),
    size: const Size(360, 400),
  );

  graph.UserListItem gone({String handle = '', String name = ''}) =>
      graph.UserListItem(
        user: common.AuthorSnapshot(
          userId: kUnavailableUserId,
          handle: handle,
          displayName: name,
        ),
        relationship: graph.Relationship(userId: kUnavailableUserId),
      );

  testWidgets('no profile tap, no follow button, no extra action', (
    tester,
  ) async {
    var opened = 0;
    await open(
      tester,
      UserListRow(
        item: gone(),
        onProfileTap: () => opened++,
        extraAction: const Text('Remove'),
      ),
    );

    await tester.tap(find.text(kUnavailableAccountName));
    await tester.pump();

    expect(opened, 0);
    expect(find.byType(FollowButton), findsNothing);
    expect(find.text('Remove'), findsNothing);
    expect(find.text('@'), findsNothing);
  });

  testWidgets('a name it still carries is shown, the row stays inert', (
    tester,
  ) async {
    var opened = 0;
    await open(
      tester,
      UserListRow(
        item: gone(handle: 'ghost', name: 'Ghost'),
        onProfileTap: () => opened++,
      ),
    );

    await tester.tap(find.text('Ghost'));
    await tester.pump();

    expect(opened, 0);
    expect(find.byType(FollowButton), findsNothing);
    expect(find.text('@ghost'), findsOneWidget);
  });

  testWidgets('a real account in the same position is unchanged', (
    tester,
  ) async {
    var opened = 0;
    await open(
      tester,
      UserListRow(
        item: suggestedUser(1, userId: 'u0abcdefghijklmnopqrstuvw2'),
        onProfileTap: () => opened++,
      ),
    );

    await tester.tap(find.text('User 1'));
    await tester.pump();

    expect(opened, 1);
    expect(find.byType(FollowButton), findsOneWidget);
  });
}
