import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_detail_state.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/user_lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_detail_header.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_unavailable_view.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
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
  String description = '',
}) => pb.ListInfo(
  listId: 'l$i',
  name: name ?? 'List $i',
  description: description,
  isPrivate: isPrivate,
  memberCount: members,
);

// 25 code points of every kind the name field accepts.
const _names = <String>[
  'A very long List name 25 c',
  'Books \u{1F4DA}\u{1F4DA}\u{1F4DA}\u{1F4DA}\u{1F4DA}\u{1F4DA}\u{1F4DA}\u{1F4DA}',
  'רשימה ארוכה מאוד עם',
  'Z​W​S​P​j​o​i​n',
];

final _description100 = 'x' * 40 + ' \u{1F600}שלום ' + 'y' * 40;

/// W5-16: the cells the developers' matrices left open for the Lists screens:
/// every state (empty, error, disabled, capped, editor, edit with Delete,
/// unavailable, header variants) at 360 / 600 / 1200 dp, light and dark, text
/// scale 1.0 / 1.3 / 2.0, with long, emoji, RTL and zero-width names.
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

  Future<void> openLists(WidgetTester tester, MatrixEnv env) => pumpThemed(
    tester,
    RepositoryProvider<ListsRepository>.value(
      value: repo,
      child: const ListsScreen(),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
    useScaffold: false,
  );

  Future<void> openUserLists(WidgetTester tester, MatrixEnv env) => pumpThemed(
    tester,
    RepositoryProvider<ListsRepository>.value(
      value: repo,
      child: const UserListsScreen(userId: 'u9', handle: 'kaif'),
    ),
    brightness: env.brightness,
    size: env.size,
    textScale: env.textScale,
    useScaffold: false,
  );

  group('Lists screen states', () {
    forEachThemeAndWidth('empty: the sentence and an enabled Create', (
      tester,
      env,
    ) async {
      listCall().thenAnswer((_) async => const ListsPage(lists: []));
      await openLists(tester, env);
      expectNoOverflow(tester);
      expect(find.textContaining("haven't created any Lists"), findsOneWidget);
      // 40dp on desktop platforms: the theme uses adaptivePlatformDensity
      // (observation O3, not a Lists defect).
      expect(tester.getSize(find.byTooltip('Create a new List')).width, greaterThanOrEqualTo(40));
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('error: message and Retry fit', (tester, env) async {
      listCall().thenThrow(const NetworkException('offline'));
      await openLists(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsOneWidget);
      expectMinTarget(tester, _button('Retry'));
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('disabled: the calm state has no Retry', (
      tester,
      env,
    ) async {
      listCall().thenThrow(const FeatureDisabledException('off'));
      await openLists(tester, env);
      expectNoOverflow(tester);
      expect(find.text("Lists aren't available right now"), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('20 Lists with long, emoji, RTL and zero-width names: '
        'Create is disabled with the reason', (tester, env) async {
      listCall().thenAnswer(
        (_) async => ListsPage(
          lists: [
            for (var i = 0; i < 20; i++)
              _list(i, name: _names[i % _names.length], isPrivate: i.isEven),
          ],
        ),
      );
      await openLists(tester, env);
      expectNoOverflow(tester);
      final create = find.byTooltip(RegExp('You have 20 Lists'));
      expect(create, findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.playlist_add),
            )
            .onPressed,
        isNull,
      );
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('the create sheet: fields, private switch, Save and '
        'Cancel fit; the keyboard does not hide Save', (tester, env) async {
      listCall().thenAnswer((_) async => const ListsPage(lists: []));
      await openLists(tester, env);
      await tester.tap(find.byTooltip('Create a new List'));
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.text('Create a List'), findsOneWidget);
      expectMinTarget(tester, find.byType(Switch));

      // A software keyboard of 300 dp: the sheet scrolls, nothing overflows.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        _names[1].substring(0, 8),
      );
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Save').hitTestable(), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('the edit sheet: a 100-character mixed-script '
        'description and Delete List fit', (tester, env) async {
      listCall().thenAnswer(
        (_) async => ListsPage(
          lists: [
            _list(
              1,
              name: _names[2],
              description: _description100,
              isPrivate: true,
            ),
          ],
        ),
      );
      await openLists(tester, env);
      await tester.tap(find.byTooltip('Edit ${_names[2]}'));
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      await tester.ensureVisible(find.text('Delete List'));
      await tester.pumpAndSettle();
      expect(find.text('Delete List'), findsOneWidget);
      expectNoOverflow(tester);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('User lists screen states', () {
    forEachThemeAndWidth('empty', (tester, env) async {
      listCall().thenAnswer((_) async => const ListsPage(lists: []));
      await openUserLists(tester, env);
      expectNoOverflow(tester);
      expect(find.text('No public Lists'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('NOT_FOUND', (tester, env) async {
      listCall().thenThrow(const NotFoundException('x'));
      await openUserLists(tester, env);
      expectNoOverflow(tester);
      expect(find.text('These Lists are unavailable'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('error with Retry', (tester, env) async {
      listCall().thenThrow(const NetworkException('offline'));
      await openUserLists(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('disabled', (tester, env) async {
      listCall().thenThrow(const FeatureDisabledException('off'));
      await openUserLists(tester, env);
      expectNoOverflow(tester);
      expect(find.text("Lists aren't available right now"), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('long, emoji, RTL and zero-width names', (
      tester,
      env,
    ) async {
      listCall().thenAnswer(
        (_) async => ListsPage(
          lists: [for (var i = 0; i < 4; i++) _list(i, name: _names[i])],
        ),
      );
      await openUserLists(tester, env);
      expectNoOverflow(tester);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('ListUnavailableView', () {
    for (final (label, unpin, busy) in [
      ('without Unpin', false, false),
      ('with Unpin', true, false),
      ('Unpin busy', true, true),
    ]) {
      forEachThemeAndWidth('$label fits; the button is 48dp', (
        tester,
        env,
      ) async {
        var taps = 0;
        await pumpThemed(
          tester,
          ListUnavailableView(onUnpin: unpin ? () => taps++ : null, busy: busy),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expectNoOverflow(tester);
        expect(find.text('This List is unavailable'), findsOneWidget);
        // One text for private, deleted, hidden and blocked.
        expect(find.textContaining('private'), findsNothing);
        expect(find.textContaining('deleted'), findsNothing);
        if (unpin) {
          expectMinTarget(tester, _button('Unpin from Home'));
          await tester.tap(find.text('Unpin from Home'));
          expect(taps, busy ? 0 : 1);
        } else {
          expect(find.text('Unpin from Home'), findsNothing);
        }
      }, textScales: kMatrixTextScalesLarge);
    }
  });

  group('ListDetailHeader variants', () {
    pb.ListInfo header({
      String name = 'Friends',
      String description = '',
      bool isPrivate = false,
      int members = 3,
    }) => pb.ListInfo(
      listId: '77',
      name: name,
      description: description,
      isPrivate: isPrivate,
      memberCount: members,
      owner: common.AuthorSnapshot(
        userId: 'owner',
        handle: 'olivia',
        displayName: 'אוליביה \u{1F338}',
      ),
    );

    final variants = <String, (ListDetailState, bool)>{
      'private, long mixed description, owner': (
        ListDetailState(
          status: ListDetailStatus.ready,
          header: header(
            name: _names[0],
            description: _description100,
            isPrivate: true,
          ),
        ),
        true,
      ),
      'emoji name, 0 members, pinned': (
        ListDetailState(
          status: ListDetailStatus.ready,
          header: header(name: _names[1], members: 0),
          pinned: true,
        ),
        false,
      ),
      'RTL name, five pinned (Pin disabled with the hint)': (
        ListDetailState(
          status: ListDetailStatus.ready,
          header: header(name: _names[2]),
          pinFull: true,
        ),
        false,
      ),
      'pinning not available yet': (
        ListDetailState(
          status: ListDetailStatus.ready,
          header: header(name: _names[3]),
          pinWriteUnavailable: true,
        ),
        false,
      ),
      'no header and the fallback GetList failed': (
        ListDetailState(headerFailed: true),
        false,
      ),
    };
    for (final entry in variants.entries) {
      forEachThemeAndWidth(entry.key, (tester, env) async {
        await pumpThemed(
          tester,
          SingleChildScrollView(
            child: ListDetailHeader(
              state: entry.value.$1,
              isOwner: entry.value.$2,
              onMembers: () {},
              onOwner: () {},
              onTogglePin: () {},
              onEdit: () {},
              onRetry: () {},
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expectNoOverflow(tester);
      }, textScales: kMatrixTextScalesLarge);
    }
  });
}

/// The button (not its label) that carries [label].
Finder _button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
);
