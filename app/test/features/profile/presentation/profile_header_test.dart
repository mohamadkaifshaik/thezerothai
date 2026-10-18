import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class MockModerationRepository extends Mock implements ModerationRepository {}

void main() {
  late MockGraphRepository graphRepository;

  setUp(() {
    graphRepository = MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  final profile = identity.Profile(
    userId: 'u-alice',
    handle: 'alice',
    displayName: 'Alice',
  );

  Widget wrap({
    required bool isOwnProfile,
    required bool graphEnabled,
    required bool reportsEnabled,
  }) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<GraphRepository>.value(value: graphRepository),
        RepositoryProvider<ModerationRepository>.value(
          value: MockModerationRepository(),
        ),
        RepositoryProvider<UnexpectedErrorReporter>.value(value: (e, s) {}),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ProfileHeader(
            profile: profile,
            isOwnProfile: isOwnProfile,
            graphEnabled: graphEnabled,
            reportsEnabled: reportsEnabled,
            relationship: graphEnabled && !isOwnProfile
                ? graph.Relationship(userId: 'u-alice')
                : null,
          ),
        ),
      ),
    );
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
  }

  testWidgets('reports on + graph on: the menu offers Report @handle next to '
      'Mute and Block', (tester) async {
    await tester.pumpWidget(
      wrap(isOwnProfile: false, graphEnabled: true, reportsEnabled: true),
    );

    await openMenu(tester);

    expect(find.text('Report @alice'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
  });

  testWidgets('reports off + graph on: no Report entry (AC7)', (tester) async {
    await tester.pumpWidget(
      wrap(isOwnProfile: false, graphEnabled: true, reportsEnabled: false),
    );

    await openMenu(tester);

    expect(find.textContaining('Report'), findsNothing);
    expect(find.text('Mute'), findsOneWidget);
  });

  testWidgets('reports on + graph off: a menu with Report alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(isOwnProfile: false, graphEnabled: false, reportsEnabled: true),
    );

    await openMenu(tester);

    expect(find.text('Report @alice'), findsOneWidget);
    expect(find.text('Block'), findsNothing);
  });

  testWidgets('reports off + graph off: no menu at all (AC7)', (tester) async {
    await tester.pumpWidget(
      wrap(isOwnProfile: false, graphEnabled: false, reportsEnabled: false),
    );

    expect(find.byIcon(Icons.more_horiz), findsNothing);
  });

  testWidgets('own profile never offers Report', (tester) async {
    await tester.pumpWidget(
      wrap(isOwnProfile: true, graphEnabled: true, reportsEnabled: true),
    );

    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(find.textContaining('Report'), findsNothing);
  });

  testWidgets('choosing Report opens the report sheet for the account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(isOwnProfile: false, graphEnabled: false, reportsEnabled: true),
    );

    await openMenu(tester);
    await tester.tap(find.text('Report @alice'));
    await tester.pumpAndSettle();

    expect(find.text('Report @alice'), findsOneWidget);
    expect(find.text("It's spam"), findsOneWidget);
  });
}
