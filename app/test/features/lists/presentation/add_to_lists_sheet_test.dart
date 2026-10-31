import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/widgets/add_to_lists_sheet.dart';
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockLists extends Mock implements ListsRepository {}

pb.ListInfo _list(int i, {bool isPrivate = false, String? name}) => pb.ListInfo(
  listId: 'l$i',
  name: name ?? 'List $i',
  isPrivate: isPrivate,
  memberCount: 3,
);

/// W5-13: the Add-to-Lists sheet at 360 / 600 / 1200 dp, light and dark, text
/// scale 1.0 / 1.3 / 2.0.
void main() {
  late _MockLists repo;

  setUp(() {
    repo = _MockLists();
    when(() => repo.enabled).thenReturn(true);
  });

  void stubLists(List<pb.ListInfo> lists, {Set<String> containing = const {}}) {
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => ListsPage(lists: lists, containingListIds: containing),
    );
  }

  // Opens the real sheet from a button, so the modal route and width cap apply.
  Future<void> open(WidgetTester tester, {MatrixEnv? env}) async {
    await pumpThemed(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showAddToListsSheet(
            context,
            repository: repo,
            userId: 'u9',
            handle: 'kaif',
          ),
          child: const Text('open'),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(360, 800),
      textScale: env?.textScale ?? 1.0,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  forEachThemeAndWidth('rows fit; a list that holds the person is checked', (
    tester,
    env,
  ) async {
    stubLists(
      [
        _list(1, isPrivate: true, name: 'Mine'),
        _list(2, name: 'A very long List name that could fill the row'),
      ],
      containing: {'l1'},
    );
    final semantics = tester.ensureSemantics();
    await open(tester, env: env);

    expectNoOverflow(tester);
    expect(find.text('Add or remove @kaif'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(boxes.map((c) => c.value), [true, false]);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Mine, 3 members, private')),
      matchesSemantics(
        label: 'Mine, 3 members, private',
        hasCheckedState: true,
        isChecked: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('one ListUserLists with contains_user_id per open', (
    tester,
  ) async {
    stubLists([_list(1)]);
    await open(tester);
    verify(
      () => repo.listUserLists(
        containsUserId: 'u9',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
  });

  testWidgets('tapping a row adds, and the row stays checked', (tester) async {
    stubLists([_list(1)]);
    when(
      () => repo.addMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: 'l1',
        userId: 'u9',
      ),
    ).thenAnswer((_) async => _list(1));
    await open(tester);

    await tester.tap(find.textContaining('List 1', findRichText: true));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    verify(
      () => repo.addMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: 'l1',
        userId: 'u9',
      ),
    ).called(1);
  });

  testWidgets('LIMIT_REACHED unchecks the row and shows the reason', (
    tester,
  ) async {
    stubLists([_list(1)]);
    when(
      () => repo.addMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: any(named: 'listId'),
        userId: any(named: 'userId'),
      ),
    ).thenThrow(const LimitReachedException('full', quota: 'list_members'));
    await open(tester);

    await tester.tap(find.textContaining('List 1', findRichText: true));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(find.textContaining('This List is full'), findsOneWidget);
  });

  testWidgets('no lists: the empty state offers Create a List', (tester) async {
    stubLists([]);
    await open(tester);
    expect(find.text('No Lists yet'), findsOneWidget);
    expect(find.text('Create a List'), findsOneWidget);
  });

  testWidgets('load failure: friendly error with Retry', (tester) async {
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const NetworkException('offline'));
    await open(tester);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('FEATURE_DISABLED: the calm unavailable state', (tester) async {
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const FeatureDisabledException('off', feature: 'lists'));
    await open(tester);
    expect(find.text("Lists aren't available right now"), findsOneWidget);
  });

  testWidgets('Done closes the sheet', (tester) async {
    stubLists([_list(1)]);
    await open(tester);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(AddToListsSheet), findsNothing);
  });
}
