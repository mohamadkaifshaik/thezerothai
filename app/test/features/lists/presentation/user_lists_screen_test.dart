import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/user_lists_screen.dart';
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockLists extends Mock implements ListsRepository {}

pb.ListInfo _list(int i, {String? name}) =>
    pb.ListInfo(listId: 'l$i', name: name ?? 'List $i', memberCount: 3);

/// W5-13: another person's public Lists at 360 / 600 / 1200 dp, light and
/// dark, text scale 1.0 / 1.3 / 2.0.
void main() {
  late _MockLists repo;

  setUp(() {
    repo = _MockLists();
    when(() => repo.enabled).thenReturn(true);
  });

  When<Future<ListsPage>> listCall() => when(
    () => repo.listUserLists(
      ownerId: any(named: 'ownerId'),
      containsUserId: any(named: 'containsUserId'),
      pageSize: any(named: 'pageSize'),
      pageToken: any(named: 'pageToken'),
    ),
  );

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
    tester,
    RepositoryProvider<ListsRepository>.value(
      value: repo,
      child: const UserListsScreen(userId: 'u9', handle: 'kaif'),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  forEachThemeAndWidth('rows fit and read as buttons', (tester, env) async {
    listCall().thenAnswer(
      (_) async => ListsPage(
        lists: [
          _list(1, name: 'Mine'),
          _list(2, name: 'A very long List name that could fill the row'),
        ],
      ),
    );
    final semantics = tester.ensureSemantics();
    await open(tester, env: env);

    expectNoOverflow(tester);
    expect(find.text("@kaif's Lists"), findsOneWidget);
    expect(find.bySemanticsLabel('Mine, 3 members'), findsOneWidget);
    // Someone else's lists: no Create, no Edit.
    expect(find.byTooltip('Create a new List'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    semantics.dispose();
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('asks for the owner\'s lists, once', (tester) async {
    listCall().thenAnswer((_) async => ListsPage(lists: [_list(1)]));
    await open(tester);
    verify(
      () => repo.listUserLists(
        ownerId: 'u9',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
  });

  testWidgets('empty: public-lists sentence', (tester) async {
    listCall().thenAnswer((_) async => const ListsPage(lists: []));
    await open(tester);
    expect(find.text('No public Lists'), findsOneWidget);
  });

  testWidgets('NOT_FOUND: one fixed text, no cause', (tester) async {
    listCall().thenThrow(const NotFoundException('profile not found'));
    await open(tester);
    expect(find.text('These Lists are unavailable'), findsOneWidget);
    expect(find.textContaining('profile not found'), findsNothing);
  });

  testWidgets('network error: Retry reloads', (tester) async {
    listCall().thenThrow(const NetworkException('offline'));
    await open(tester);
    expect(find.text('Retry'), findsOneWidget);

    listCall().thenAnswer((_) async => ListsPage(lists: [_list(1)]));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('List 1', findRichText: true), findsOneWidget);
  });

  testWidgets('FEATURE_DISABLED: the calm unavailable state', (tester) async {
    listCall().thenThrow(const FeatureDisabledException('off'));
    await open(tester);
    expect(find.text("Lists aren't available right now"), findsOneWidget);
  });
}
