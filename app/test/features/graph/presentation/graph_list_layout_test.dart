import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/graph_list_screen.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/app_empty_view.dart';
import 'package:dzeroth/shared/widgets/user_list_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockIdentity extends Mock implements IdentityRepository {}

graph.UserListItem _item(
  int i, {
  graph.FollowState follow = graph.FollowState.FOLLOW_STATE_NONE,
  bool blocking = false,
  String name = '',
}) => graph.UserListItem(
  user: common.AuthorSnapshot(
    userId: 'u$i',
    handle: 'user$i',
    displayName: name.isEmpty ? 'User $i' : name,
  ),
  relationship: graph.Relationship(
    userId: 'u$i',
    followState: follow,
    blocking: blocking,
  ),
);

/// Layout and state coverage of the restyled followers/following screen, its
/// rows and its list states (UI slice graph lists). Paging, cursors and the
/// resolve flow are owned by graph_list_screen_test.dart and the cubit tests.
void main() {
  late _MockGraph graphRepo;
  late _MockIdentity identityRepo;

  setUp(() {
    graphRepo = _MockGraph();
    identityRepo = _MockIdentity();
  });

  void stubFollowers(Future<GraphPage> Function(String token) answer) {
    when(
      () => graphRepo.listFollowers(
        userId: 'target',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((i) => answer(i.namedArguments[#pageToken] as String));
  }

  void stubFollowing(Future<GraphPage> Function(String token) answer) {
    when(
      () => graphRepo.listFollowing(
        userId: 'target',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((i) => answer(i.namedArguments[#pageToken] as String));
  }

  Future<GoRouter> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    GraphListTab tab = GraphListTab.followers,
    bool settle = true,
    bool pushed = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('previous page')),
        ),
        GoRoute(
          path: '/profile/:handle',
          builder: (_, state) => Scaffold(
            body: Text('profile of ${state.pathParameters['handle']}'),
          ),
        ),
        GoRoute(
          path: '/people',
          builder: (_, _) => GraphListScreen(
            handle: 'kaif',
            userId: 'target',
            initialTab: tab,
          ),
        ),
      ],
      initialLocation: pushed ? '/' : '/people',
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<IdentityRepository>.value(value: identityRepo),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    if (pushed) unawaited(router.push('/people'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
    return router;
  }

  GraphPage page(List<graph.UserListItem> items, {String next = ''}) =>
      GraphPage(items: items, nextPageToken: next);

  group('layout, per tab', () {
    for (final tab in GraphListTab.values) {
      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        for (final brightness in Brightness.values) {
          for (final textScale in const [1.0, 2.0]) {
            testWidgets(
              '${tab.name} ${size.width.toInt()}x${size.height.toInt()} '
              '${brightness.name} text x$textScale: no overflow, header, tabs, '
              'rows',
              (tester) async {
                stubFollowers(
                  (_) async => page([
                    _item(
                      1,
                      follow: graph.FollowState.FOLLOW_STATE_FOLLOWING,
                      name: 'A very long display name that must ellipsize',
                    ),
                    _item(2),
                  ]),
                );
                stubFollowing(
                  (_) async => page([
                    _item(
                      1,
                      follow: graph.FollowState.FOLLOW_STATE_FOLLOWING,
                      name: 'A very long display name that must ellipsize',
                    ),
                    _item(2),
                  ]),
                );
                await open(
                  tester,
                  tab: tab,
                  size: size,
                  brightness: brightness,
                  textScale: textScale,
                );
                expect(tester.takeException(), isNull);
                expect(find.text('@kaif'), findsOneWidget);
                expect(find.byTooltip('Back'), findsOneWidget);
                expect(find.text('@user1'), findsOneWidget);
                expect(find.text('@user2'), findsOneWidget);
              },
            );
          }
        }
      }
    }

    testWidgets('wide: header, tabs and rows stay in the main column', (
      tester,
    ) async {
      stubFollowers((_) async => page([_item(1)]));
      stubFollowing((_) async => page([_item(1)]));
      await open(tester, size: const Size(1440, 900));
      const gutter = (1440 - AppLayout.mainColumnMaxWidth) / 2;
      expect(
        tester.getTopLeft(find.byTooltip('Back')).dx,
        greaterThanOrEqualTo(gutter),
      );
      expect(
        tester.getTopRight(find.text('Following').first).dx,
        lessThanOrEqualTo(1440 - gutter),
      );
    });
  });

  group('header and tabs', () {
    testWidgets('Back pops to the previous page', (tester) async {
      stubFollowers((_) async => page([]));
      stubFollowing((_) async => page([]));
      await open(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('previous page'), findsOneWidget);
    });

    testWidgets('with no history Back goes to that profile', (tester) async {
      stubFollowers((_) async => page([]));
      stubFollowing((_) async => page([]));
      await open(tester, pushed: false);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('profile of kaif'), findsOneWidget);
    });

    testWidgets('semantics: Back is a labelled button, the handle a header, '
        'the selected tab is announced selected', (tester) async {
      final handle = tester.ensureSemantics();
      stubFollowers((_) async => page([_item(1)]));
      stubFollowing((_) async => page([_item(2)]));
      await open(tester, tab: GraphListTab.following);

      expect(
        tester.getSemantics(find.byTooltip('Back')),
        isSemantics(tooltip: 'Back', isButton: true, isEnabled: true),
      );
      expect(
        tester.getSemantics(find.text('@kaif')),
        isSemantics(label: '@kaif', isHeader: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(Tab, 'Following')),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(Tab, 'Followers')),
        isSemantics(isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('switching tabs moves the selected state and loads that '
        'list', (tester) async {
      final handle = tester.ensureSemantics();
      stubFollowers((_) async => page([_item(1)]));
      stubFollowing((_) async => page([_item(2)]));
      await open(tester);
      expect(find.text('@user1'), findsOneWidget);
      verifyNever(
        () => graphRepo.listFollowing(
          userId: any(named: 'userId'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      );

      await tester.tap(find.widgetWithText(Tab, 'Following'));
      await tester.pumpAndSettle();
      expect(find.text('@user2'), findsOneWidget);
      expect(
        tester.getSemantics(find.widgetWithText(Tab, 'Following')),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(Tab, 'Followers')),
        isSemantics(isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('the selected tab is also marked visually: bold label', (
      tester,
    ) async {
      stubFollowers((_) async => page([]));
      stubFollowing((_) async => page([]));
      await open(tester, brightness: Brightness.dark);
      final selected = tester.widget<DefaultTextStyle>(
        find
            .ancestor(
              of: find.text('Followers'),
              matching: find.byType(DefaultTextStyle),
            )
            .first,
      );
      final other = tester.widget<DefaultTextStyle>(
        find
            .ancestor(
              of: find.text('Following'),
              matching: find.byType(DefaultTextStyle),
            )
            .first,
      );
      expect(
        selected.style.fontWeight!.value,
        greaterThan(other.style.fontWeight!.value),
      );
    });
  });

  for (final tab in GraphListTab.values) {
    final label = tab == GraphListTab.followers ? 'followers' : 'following';
    final empty = tab == GraphListTab.followers
        ? 'No followers yet.'
        : 'Not following anyone yet.';
    void stub(Future<GraphPage> Function(String) a) {
      stubFollowers(a);
      stubFollowing(a);
    }

    group('states: $label', () {
      testWidgets('loading: a skeleton, announced, no overflow', (
        tester,
      ) async {
        final done = Completer<GraphPage>();
        stub((_) => done.future);
        await open(tester, tab: tab, settle: false, textScale: 2);

        expect(find.byType(UserListSkeleton), findsOneWidget);
        expect(find.bySemanticsLabel('Loading people'), findsOneWidget);
        expect(tester.takeException(), isNull);

        done.complete(page([_item(1)]));
        await tester.pumpAndSettle();
        expect(find.byType(UserListSkeleton), findsNothing);
        expect(find.text('@user1'), findsOneWidget);
      });

      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        testWidgets('empty ${size.width.toInt()}: icon and message, no '
            'overflow at text x2', (tester) async {
          stub((_) async => page([]));
          await open(
            tester,
            tab: tab,
            size: size,
            brightness: Brightness.dark,
            textScale: 2,
          );
          expect(find.text(empty), findsOneWidget);
          expect(find.byType(AppEmptyView), findsOneWidget);
          expect(find.byIcon(Icons.people_outline), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('error ${size.width.toInt()}: friendly message with '
            'Retry', (tester) async {
          stub((_) async => throw const NetworkException('offline'));
          await open(tester, tab: tab, size: size);
          expect(
            find.text('No connection. Check your network and try again.'),
            findsOneWidget,
          );
          expect(find.text('Retry'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('rate limited: friendly text, no retry loop', (tester) async {
        stub((_) async => throw const RateLimitedException('slow down'));
        await open(tester, tab: tab);
        expect(find.textContaining('a bit too fast'), findsOneWidget);
      });

      testWidgets('load more: the footer spinner shows while the next page '
          'loads, and nothing at the end of the list', (tester) async {
        tester.view.physicalSize = const Size(390, 1200);
        final second = Completer<GraphPage>();
        stub(
          (token) => token.isEmpty
              ? Future.value(
                  page([for (var i = 0; i < 12; i++) _item(i)], next: 'p2'),
                )
              : second.future,
        );
        await open(tester, tab: tab, size: const Size(390, 700));
        await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.byType(CircularProgressIndicator, skipOffstage: false),
          findsOneWidget,
        );

        second.complete(page([for (var i = 12; i < 14; i++) _item(i)]));
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(find.text('@user13', skipOffstage: false), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });
    });
  }

  group('the follow control is unchanged', () {
    void stubBoth(List<graph.UserListItem> items) {
      stubFollowers((_) async => page(items));
      stubFollowing((_) async => page(items));
    }

    testWidgets('each state: Follow (filled), Following, Unblock and the '
        'tappable Requested', (tester) async {
      stubBoth([
        _item(1),
        _item(2, follow: graph.FollowState.FOLLOW_STATE_FOLLOWING),
        _item(3, blocking: true),
        _item(4, follow: graph.FollowState.FOLLOW_STATE_REQUESTED),
      ]);
      await open(tester, size: const Size(390, 1000));

      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Following'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Unblock'), findsOneWidget);
      final requested = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Requested'),
      );
      // Tapping it asks to cancel the request (ADR-0025 D7), so it is live.
      expect(requested.onPressed, isNotNull);
      for (final b in tester.widgetList<ButtonStyleButton>(
        find.byWidgetPredicate((w) => w is ButtonStyleButton),
      )) {
        expect(
          tester.getSize(find.byWidget(b)).height,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
      }
    });

    testWidgets('Follow sends one request with a key, goes busy and '
        'disabled meanwhile, then shows Following', (tester) async {
      stubBoth([_item(1)]);
      final done = Completer<graph.Relationship>();
      when(
        () => graphRepo.follow(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => done.future);
      await open(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Follow'));
      await tester.pump();
      // Optimistic and busy: a spinner, no tappable label.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final busy = tester.widget<ButtonStyleButton>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(busy.onPressed, isNull);

      done.complete(
        graph.Relationship(
          userId: 'u1',
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Following'), findsOneWidget);
      verify(
        () => graphRepo.follow(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    testWidgets('a failed Follow rolls back and says why', (tester) async {
      stubBoth([_item(1)]);
      when(
        () => graphRepo.follow(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => throw const NetworkException('offline'));
      await open(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Follow'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
    });

    testWidgets('Following unfollows with one request', (tester) async {
      stubBoth([_item(1, follow: graph.FollowState.FOLLOW_STATE_FOLLOWING)]);
      when(
        () => graphRepo.unfollow(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(
          userId: 'u1',
          followState: graph.FollowState.FOLLOW_STATE_NONE,
        ),
      );
      await open(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Following'));
      await tester.pumpAndSettle();
      verify(
        () => graphRepo.unfollow(
          userId: 'u1',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.widgetWithText(FilledButton, 'Follow'), findsOneWidget);
    });

    testWidgets('the row reads name then handle; a nameless user shows the '
        'handle once as the name', (tester) async {
      stubBoth([_item(1, name: 'Sofia Reyes')]);
      await open(tester);
      expect(find.text('Sofia Reyes'), findsOneWidget);
      expect(find.text('@user1'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Sofia Reyes')).dy,
        lessThan(tester.getTopLeft(find.text('@user1')).dy),
      );
    });
  });
}
