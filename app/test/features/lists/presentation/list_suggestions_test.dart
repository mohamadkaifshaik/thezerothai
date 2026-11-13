import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/lists_feature_flag.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_suggestions_cubit.dart';
import 'package:dzeroth/features/lists/presentation/list_members_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/lists_flags_support.dart';
import '../../../support/theme_harness.dart';

class _MockLists extends Mock implements ListsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

graph.UserListItem _u(int i) => graph.UserListItem(
  user: common.AuthorSnapshot(
    userId: 's$i',
    handle: 'suggest$i',
    displayName: 'Suggested $i',
  ),
);

pb.ListInfo _header(String owner) => pb.ListInfo(
  listId: '77',
  name: 'Friends',
  memberCount: 2,
  owner: common.AuthorSnapshot(userId: owner, handle: 'o'),
);

const _widths = <double>[390, 800, 1280];
const _scales = <double>[1.0, 2.0];
const _on = {kFeatureLists, 'graph', kFeatureListSuggestions};
const _off = {kFeatureLists, 'graph'};

void main() {
  late _MockLists lists;
  late _MockGraph graphRepo;

  setUp(() {
    lists = _MockLists();
    graphRepo = _MockGraph();
    when(() => lists.headerChanges).thenAnswer((_) => const Stream.empty());
    when(
      () => lists.listMembers(
        listId: any(named: 'listId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
        maxEmptyPages: any(named: 'maxEmptyPages'),
      ),
    ).thenAnswer(
      (_) async => ListMembersPage(
        users: [
          graph.UserListItem(
            user: common.AuthorSnapshot(
              userId: 'm1',
              handle: 'member1',
              displayName: 'Member 1',
            ),
          ),
        ],
      ),
    );
  });

  void stubSuggestions(List<graph.UserListItem> users) => when(
    () => lists.listSuggestedMembers(
      listId: any(named: 'listId'),
      maxResults: any(named: 'maxResults'),
    ),
  ).thenAnswer((_) async => users);

  void verifyNoSuggestionCall() => verifyNever(
    () => lists.listSuggestedMembers(
      listId: any(named: 'listId'),
      maxResults: any(named: 'maxResults'),
    ),
  );

  // ----------------------------------------------------------------- cubit

  group('ListSuggestionsCubit', () {
    test('load asks for 10 and keeps at most 10', () async {
      stubSuggestions([for (var i = 0; i < 12; i++) _u(i)]);
      final c = ListSuggestionsCubit(repository: lists, listId: '77');
      await c.load();
      expect(c.state.status, ListSuggestionsStatus.ready);
      expect(c.state.items, hasLength(10));
      verify(() => lists.listSuggestedMembers(listId: '77', maxResults: 10))
          .called(1);
      await c.close();
    });

    test('a failed load hides the card state (failed)', () async {
      when(
        () => lists.listSuggestedMembers(
          listId: any(named: 'listId'),
          maxResults: any(named: 'maxResults'),
        ),
      ).thenThrow(const NetworkException('off'));
      final c = ListSuggestionsCubit(repository: lists, listId: '77');
      await c.load();
      expect(c.state.status, ListSuggestionsStatus.failed);
      await c.close();
    });

    test('add removes that person and uses a fresh valid key', () async {
      stubSuggestions([_u(1), _u(2)]);
      String? key;
      when(
        () => lists.addMember(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: '77',
          userId: 's1',
        ),
      ).thenAnswer((i) async {
        key = i.namedArguments[#idempotencyKey] as String;
        return _header('viewer');
      });
      final c = ListSuggestionsCubit(repository: lists, listId: '77');
      await c.load();

      final r = await c.add('s1');

      expect(r.added, isTrue);
      expect(r.item?.user.userId, 's1');
      expect(c.state.items.map((i) => i.user.userId), ['s2']);
      expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
      await c.close();
    });

    test(
      'a retry after a failure reuses the same key; the row stays',
      () async {
        stubSuggestions([_u(1)]);
        final keys = <String>[];
        var fail = true;
        when(
          () => lists.addMember(
            idempotencyKey: any(named: 'idempotencyKey'),
            listId: '77',
            userId: 's1',
          ),
        ).thenAnswer((i) async {
          keys.add(i.namedArguments[#idempotencyKey] as String);
          if (fail) throw const NetworkException('off');
          return _header('viewer');
        });
        final c = ListSuggestionsCubit(repository: lists, listId: '77');
        await c.load();

        final first = await c.add('s1');
        expect(first.error, isA<NetworkException>());
        expect(c.state.items, hasLength(1));
        expect(c.state.busyIds, isEmpty);

        fail = false;
        expect((await c.add('s1')).added, isTrue);
        expect(keys.toSet(), hasLength(1));
        await c.close();
      },
    );

    test(
      'a full List keeps the row; NOT_FOUND and protected drop it',
      () async {
        stubSuggestions([_u(1), _u(2), _u(3)]);
        when(
          () => lists.addMember(
            idempotencyKey: any(named: 'idempotencyKey'),
            listId: '77',
            userId: 's1',
          ),
        ).thenThrow(const LimitReachedException('x', quota: kListMembersLimit));
        when(
          () => lists.addMember(
            idempotencyKey: any(named: 'idempotencyKey'),
            listId: '77',
            userId: 's2',
          ),
        ).thenThrow(const NotFoundException('gone'));
        when(
          () => lists.addMember(
            idempotencyKey: any(named: 'idempotencyKey'),
            listId: '77',
            userId: 's3',
          ),
        ).thenThrow(const ProtectedAccountException());
        final c = ListSuggestionsCubit(repository: lists, listId: '77');
        await c.load();

        await c.add('s1');
        await c.add('s2');
        await c.add('s3');

        expect(c.state.items.map((i) => i.user.userId), ['s1']);
        await c.close();
      },
    );
  });

  // ---------------------------------------------------------------- screen

  Future<void> open(
    WidgetTester tester,
    Set<String> flags, {
    String owner = kListsViewerId,
    MatrixEnv? env,
  }) {
    when(() => lists.header('77')).thenReturn(_header(owner));
    return pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: listsFlags(flags),
          child: const ListMembersScreen(listId: '77'),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(390, 800),
      textScale: env?.textScale ?? 1.0,
      useScaffold: false,
    );
  }

  forEachThemeAndWidth(
    'flag on, owner: the card shows up to 3 people with Add and Show more',
    (tester, env) async {
      stubSuggestions([for (var i = 1; i <= 10; i++) _u(i)]);
      await open(tester, _on, env: env);

      expectNoOverflow(tester);
      expect(find.text('Suggested members'), findsOneWidget);
      expect(find.text('Add'), findsNWidgets(3));
      expect(find.text('Show more'), findsOneWidget);

      await tester.ensureVisible(find.text('Show more'));
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.text('Show more'), findsNothing);
      expect(find.text('Suggested members'), findsOneWidget);
    },
    widths: _widths,
    textScales: _scales,
  );

  forEachThemeAndWidth(
    'flag off: no card and no ListSuggestedMembers call',
    (tester, env) async {
      stubSuggestions([_u(1)]);
      await open(tester, _off, env: env);

      expectNoOverflow(tester);
      expect(find.text('Suggested members'), findsNothing);
      verifyNoSuggestionCall();
    },
    widths: _widths,
    textScales: _scales,
  );

  testWidgets('flag on but not the owner: no card, no call', (tester) async {
    stubSuggestions([_u(1)]);
    await open(tester, _on, owner: 'someone-else');

    expect(find.text('Suggested members'), findsNothing);
    verifyNoSuggestionCall();
  });

  testWidgets('flag on, owner, no suggestions: no card', (tester) async {
    stubSuggestions([]);
    await open(tester, _on);

    expect(find.text('Suggested members'), findsNothing);
    verify(() => lists.listSuggestedMembers(listId: '77', maxResults: 10))
        .called(1);
  });

  testWidgets('Add calls AddListMember, removes the row and adds the person '
      'to Members', (tester) async {
    stubSuggestions([_u(1), _u(2)]);
    when(
      () => lists.addMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
        userId: 's1',
      ),
    ).thenAnswer((_) async => _header(kListsViewerId));
    await open(tester, _on);
    expect(find.text('Suggested 1'), findsOneWidget);

    await tester.tap(find.text('Add').first);
    await tester.pumpAndSettle();

    verify(
      () => lists.addMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
        userId: 's1',
      ),
    ).called(1);
    // Gone from the card, present once (in Members).
    expect(find.text('Suggested 1'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Suggested 2'), findsOneWidget);
  });

  testWidgets('a full List says so and keeps the row', (tester) async {
    stubSuggestions([_u(1)]);
    when(
      () => lists.addMember(
        idempotencyKey: any(named: 'idempotencyKey'),
        listId: '77',
        userId: 's1',
      ),
    ).thenThrow(const LimitReachedException('x', quota: kListMembersLimit));
    await open(tester, _on);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.textContaining('This List is full'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
  });
}
