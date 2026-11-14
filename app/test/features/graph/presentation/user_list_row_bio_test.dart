import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

/// The bio line under the @handle of every graph user row. The bio look is
/// not in the design mocks: one or two lines, secondary colour, hidden when
/// empty.
void main() {
  final bioFinder = find.byKey(const ValueKey('user-row-bio'));

  graph.UserListItem item(String bio) {
    final base = suggestedUser(1);
    base.bio = bio;
    return base;
  }

  Future<void> open(
    WidgetTester tester,
    graph.UserListItem it,
    MatrixEnv env,
  ) => pumpThemed(
    tester,
    RepositoryProvider<GraphRepository>.value(
      value: _MockGraph(),
      child: UserListRow(item: it),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
  );

  final long = 'Writes about trains, tea and tiny parks. ' * 8;

  forEachThemeAndWidth('a long bio clamps to two lines and fits', (
    tester,
    env,
  ) async {
    await open(tester, item(long), env);
    expectNoOverflow(tester);
    expect(bioFinder, findsOneWidget);
    final text = tester.widget<Text>(bioFinder);
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    final row = tester.getRect(find.byType(UserListRow));
    expect(tester.getRect(bioFinder).right, lessThanOrEqualTo(row.right));
  });

  forEachThemeAndWidth('a short bio shows in secondary colour', (
    tester,
    env,
  ) async {
    await open(tester, item('Tea.'), env);
    expect(find.text('Tea.'), findsOneWidget);
    final color = tester.widget<Text>(bioFinder).style?.color;
    expect(
      color,
      Theme.of(tester.element(bioFinder)).colorScheme.onSurfaceVariant,
    );
    expectNoOverflow(tester);
  });

  testWidgets('an empty or blank bio draws nothing', (tester) async {
    for (final bio in ['', '   ']) {
      await open(
        tester,
        item(bio),
        MatrixEnv(
          brightness: Brightness.light,
          size: const Size(360, 800),
          textScale: 1,
        ),
      );
      expect(bioFinder, findsNothing);
    }
  });
}
