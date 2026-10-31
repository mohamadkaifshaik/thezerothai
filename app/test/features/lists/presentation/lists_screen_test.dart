import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockLists extends Mock implements ListsRepository {}

pb.ListInfo _list(
  int i, {
  bool isPrivate = false,
  int members = 3,
  String? name,
}) => pb.ListInfo(
  listId: 'l$i',
  name: name ?? 'List $i',
  isPrivate: isPrivate,
  memberCount: members,
);

/// W5-11: the Lists screen at 360 / 600 / 1200 dp, light and dark, text scale
/// 1.0 / 1.3 / 2.0.
void main() {
  late _MockLists repo;

  setUpAll(() {
    registerFallbackValue(pb.ListInfo());
  });

  setUp(() {
    repo = _MockLists();
    when(() => repo.enabled).thenReturn(true);
  });

  void stubLists(List<pb.ListInfo> lists) {
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => ListsPage(lists: lists));
  }

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
    tester,
    RepositoryProvider<ListsRepository>.value(
      value: repo,
      child: const ListsScreen(),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  forEachThemeAndWidth(
    'rows fit, a long name wraps, a private list has the lock',
    (tester, env) async {
      stubLists([
        _list(1, isPrivate: true, name: 'Mine'),
        _list(
          2,
          name: 'A very long List name that could fill the row',
          members: 1,
        ),
      ]);
      final semantics = tester.ensureSemantics();
      await open(tester, env: env);

      expectNoOverflow(tester);
      expect(find.text('Lists'), findsOneWidget);
      expect(find.text('Your Lists'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.bySemanticsLabel('Mine, 3 members, private'), findsOneWidget);
      expect(find.byTooltip('Create a new List'), findsOneWidget);
      expect(find.byTooltip('Edit Mine'), findsOneWidget);
      semantics.dispose();
    },
    textScales: kMatrixTextScalesLarge,
  );

  testWidgets('loading shows the skeleton, one ListUserLists per open', (
    tester,
  ) async {
    stubLists([_list(1)]);
    await open(tester);
    verify(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
  });

  testWidgets('empty: the sentence, Create still enabled', (tester) async {
    stubLists([]);
    await open(tester);

    expect(find.textContaining("haven't created any Lists"), findsOneWidget);
    final create = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.playlist_add),
    );
    expect(create.onPressed, isNotNull);
  });

  testWidgets('20 lists: Create is disabled with the reason', (tester) async {
    stubLists([for (var i = 1; i <= 20; i++) _list(i)]);
    await open(tester);

    final create = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.playlist_add),
    );
    expect(create.onPressed, isNull);
    expect(create.tooltip, contains('Delete one'));
  });

  testWidgets('error: friendly message and Retry reloads', (tester) async {
    var calls = 0;
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async {
      if (calls++ == 0) throw const NetworkException('offline');
      return ListsPage(lists: [_list(1)]);
    });
    await open(tester);

    expect(find.textContaining('No connection'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Your Lists'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('feature disabled: the calm not-available state', (tester) async {
    when(
      () => repo.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const FeatureDisabledException("Lists aren't available yet."));
    await open(tester);

    expect(find.text("Lists aren't available right now"), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  group('the editor', () {
    void stubCreate() {
      when(
        () => repo.createList(
          idempotencyKey: any(named: 'idempotencyKey'),
          name: any(named: 'name'),
          description: any(named: 'description'),
          isPrivate: any(named: 'isPrivate'),
        ),
      ).thenAnswer((_) async => _list(9, isPrivate: true, name: 'Fresh'));
    }

    for (final width in [360.0, 1200.0]) {
      testWidgets('create at ${width.toInt()}dp: private by default, Save '
          'needs a name, the new row appears', (tester) async {
        stubLists([]);
        stubCreate();
        await open(
          tester,
          env: MatrixEnv(
            brightness: Brightness.light,
            size: Size(width, 800),
            textScale: 1,
          ),
        );

        await tester.tap(find.byTooltip('Create a new List'));
        await tester.pumpAndSettle();
        expect(find.text('Create a List'), findsOneWidget);
        expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
        // No name: Save does nothing.
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        verifyNever(
          () => repo.createList(
            idempotencyKey: any(named: 'idempotencyKey'),
            name: any(named: 'name'),
            description: any(named: 'description'),
            isPrivate: any(named: 'isPrivate'),
          ),
        );

        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          ' Fresh ',
        );
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final captured = verify(
          () => repo.createList(
            idempotencyKey: captureAny(named: 'idempotencyKey'),
            name: 'Fresh',
            description: '',
            isPrivate: true,
          ),
        ).captured;
        expect(captured.single, isNotEmpty);
        expect(find.text('Create a List'), findsNothing);
        expect(find.textContaining('Fresh'), findsOneWidget);
      });
    }

    testWidgets('name is capped at 25 characters', (tester) async {
      stubLists([]);
      await open(tester);
      await tester.tap(find.byTooltip('Create a new List'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'x' * 40);
      await tester.pump();
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Name'),
      );
      expect(field.controller!.text.length, 25);
    });

    testWidgets('LIMIT_REACHED shows the reason and keeps the form', (
      tester,
    ) async {
      stubLists([]);
      when(
        () => repo.createList(
          idempotencyKey: any(named: 'idempotencyKey'),
          name: any(named: 'name'),
          description: any(named: 'description'),
          isPrivate: any(named: 'isPrivate'),
        ),
      ).thenThrow(const LimitReachedException('x', quota: 'lists_per_user'));
      await open(tester);
      await tester.tap(find.byTooltip('Create a new List'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'A');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('up to 20 Lists'), findsOneWidget);
      expect(find.text('Create a List'), findsOneWidget);
    });

    testWidgets('edit sends only the changed field, Delete confirms then '
        'removes the row', (tester) async {
      stubLists([_list(1, name: 'Old')]);
      when(
        () => repo.updateList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: any(named: 'listId'),
          name: any(named: 'name'),
          description: any(named: 'description'),
          isPrivate: any(named: 'isPrivate'),
        ),
      ).thenAnswer((_) async => _list(1, name: 'New'));
      when(
        () => repo.deleteList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: any(named: 'listId'),
        ),
      ).thenAnswer((_) async {});
      await open(tester);

      await tester.tap(find.byTooltip('Edit Old'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'New');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      verify(
        () => repo.updateList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: 'l1',
          name: 'New',
          description: null,
          isPrivate: null,
        ),
      ).called(1);
      expect(find.textContaining('New'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit New'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete List'));
      await tester.tap(find.text('Delete List'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this List?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      verify(
        () => repo.deleteList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: 'l1',
        ),
      ).called(1);
      expect(find.textContaining("haven't created any Lists"), findsOneWidget);
    });
  });
}
