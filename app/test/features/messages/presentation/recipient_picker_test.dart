import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/recipient_picker_cubit.dart';
import 'package:dzeroth/features/messages/presentation/draft_thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart'
    show kThreadReadOnlyText;
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/not_encrypted_note.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/follow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_people_source.dart';
import '../../../support/fake_send_repository.dart';
import '../../../support/messaging_fixtures.dart';
import '../../../support/thread_test_support.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

const _me = 'u-me';

/// The picker inside a router, over fakes (W7-17).
class _Rig {
  _Rig({FakePeopleSource? source})
    : source =
          source ?? FakePeopleSource(people: [person(1), person(2), person(3)]);

  final repo = FakeSendRepository();
  final onboarding = _MockOnboardingBloc();
  final identityRepo = _MockIdentity();
  final graphRepo = _MockGraph();
  final FakePeopleSource source;
  late final GoRouter router;

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'messaging', 'graph'},
    Size size = const Size(400, 800),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: _me, handle: 'me'),
      ),
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/messages/new',
          pageBuilder: (context, state) =>
              RecipientPickerPage(key: state.pageKey, source: source),
        ),
        GoRoute(
          path: '/messages/new/draft',
          builder: (context, state) =>
              DraftThreadScreen(peer: state.extra! as common.AuthorSnapshot),
        ),
        GoRoute(
          path: '/messages/:id',
          builder: (context, state) =>
              Scaffold(body: Text('thread ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<IdentityRepository>.value(value: identityRepo),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: MaterialApp.router(
              theme: buildAppTheme(brightness: brightness),
              routerConfig: router,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(router.push('/messages/new'));
    await tester.pumpAndSettle();
  }

  Finder get field => find.byKey(kRecipientFieldKey);

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(field, text);
    await tester.pump();
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const <String>[]);
  });

  group('the picker at 3 widths', () {
    for (final width in [360.0, 600.0, 1200.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('Following rows without a Follow button, no overflow '
              '[${width.toInt()}dp x$scale ${brightness.name}]', (
            tester,
          ) async {
            final rig = _Rig();
            await rig.open(
              tester,
              size: Size(width, 800),
              textScale: scale,
              brightness: brightness,
            );

            expect(find.text('New message'), findsOneWidget);
            expect(find.text('To:'), findsOneWidget);
            expect(find.text('User 1'), findsOneWidget);
            expect(find.byType(UserListRow), findsNWidgets(3));
            expect(find.byType(FollowButton), findsNothing);
            expect(find.text('Follow'), findsNothing);
            expect(rig.source.pageCalls, 1);
            expect(tester.takeException(), isNull);

            final dialog = tester.getSize(find.byType(RecipientPicker));
            if (width < 600) {
              // Full screen under 600 dp.
              expect(dialog.width, width);
              expect(dialog.height, 800);
            } else {
              // A card at most 600 dp wide above.
              expect(dialog.width, lessThanOrEqualTo(600));
              expect(dialog.height, 640);
            }
          });
        }
      }
    }
  });

  group('not end-to-end encrypted line (W7-31)', () {
    for (final width in [360.0, 600.0, 1200.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('shows once, readable, no overflow '
              '[${width.toInt()}dp x$scale ${brightness.name}]', (
            tester,
          ) async {
            final handle = tester.ensureSemantics();
            final rig = _Rig();
            await rig.open(
              tester,
              size: Size(width, 800),
              textScale: scale,
              brightness: brightness,
            );

            expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
            expect(tester.takeException(), isNull);
            expect(
              tester.getSemantics(find.text(kMessagesNotEncryptedText)).label,
              contains(kMessagesNotEncryptedText),
            );
            // Quiet: the secondary colour, not a banner.
            final style = tester
                .widget<Text>(find.text(kMessagesNotEncryptedText))
                .style;
            expect(
              style?.color,
              Theme.of(tester.element(find.byType(RecipientPicker)))
                  .colorScheme
                  .onSurfaceVariant,
            );
            handle.dispose();
          });
        }
      }
    }

    testWidgets('is absent where messaging is off', (tester) async {
      final rig = _Rig();
      await rig.open(tester, features: const {});

      expect(find.text(kMessagesNotEncryptedText), findsNothing);
    });
  });

  group('typing without search', () {
    testWidgets('filters the loaded rows in place and never asks the '
        'source to search', (tester) async {
      final source = FakePeopleSource(
        people: [
          person(1, handle: 'ada_l', name: 'Ada Lovelace'),
          person(2, handle: 'grace', name: 'Grace Hopper'),
        ],
        searchesRemotely: true,
        remoteResults: [person(9)],
      );
      final rig = _Rig(source: source);
      // `search` is NOT enabled for the caller.
      await rig.open(tester, features: const {'messaging', 'graph'});

      await rig.type(tester, 'ab');
      await tester.pump(const Duration(seconds: 1));
      await rig.type(tester, 'hop');
      await tester.pump(const Duration(seconds: 1));

      expect(source.searchCalls, isEmpty);
      expect(source.pageCalls, 1);
      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsNothing);
    });

    testWidgets('no match: the empty line, plus "Message @handle" for a '
        'valid handle', (tester) async {
      final rig = _Rig();
      await rig.open(tester);

      await rig.type(tester, '@zed_9');

      expect(find.text(kRecipientNoMatchText), findsOneWidget);
      expect(find.byKey(kRecipientHandleRowKey), findsOneWidget);
      expect(find.text('Message @zed_9'), findsOneWidget);

      // Not a handle (too short, a space): no row.
      await rig.type(tester, 'z z');
      expect(find.byKey(kRecipientHandleRowKey), findsNothing);
    });

    testWidgets('a handle already in the Following rows has no extra row', (
      tester,
    ) async {
      final rig = _Rig();
      await rig.open(tester);
      await rig.type(tester, 'user2');
      expect(find.byKey(kRecipientHandleRowKey), findsNothing);
      expect(find.byType(UserListRow), findsOneWidget);
    });

    testWidgets('"Message @handle" resolves with GetProfile and opens a '
        'draft', (tester) async {
      final rig = _Rig();
      when(() => rig.identityRepo.getProfile(handle: 'zed_9')).thenAnswer(
        (_) async => identity.Profile(
          userId: 'u-zed',
          handle: 'zed_9',
          displayName: 'Zed',
        ),
      );
      await rig.open(tester);
      await rig.type(tester, 'zed_9');

      await tester.tap(find.byKey(kRecipientHandleRowKey));
      await tester.pumpAndSettle();

      verify(() => rig.identityRepo.getProfile(handle: 'zed_9')).called(1);
      expect(find.byType(DraftThreadScreen), findsOneWidget);
      expect(find.text('New message to Zed'), findsOneWidget);
      // The picker was replaced, not stacked.
      expect(find.byType(RecipientPicker), findsNothing);
    });

    testWidgets('an unknown handle says so, once, and stays', (tester) async {
      final rig = _Rig();
      when(() => rig.identityRepo.getProfile(handle: 'nobody'))
          .thenAnswer((_) async => throw const NotFoundException('x'));
      await rig.open(tester);
      await rig.type(tester, 'nobody');

      await tester.tap(find.byKey(kRecipientHandleRowKey));
      await tester.pumpAndSettle();

      expect(find.text("We couldn't find @nobody."), findsOneWidget);
      expect(find.byType(RecipientPicker), findsOneWidget);
    });

    testWidgets('your own handle is refused locally', (tester) async {
      final rig = _Rig();
      when(
        () => rig.identityRepo.getProfile(handle: 'meme'),
      ).thenAnswer((_) async => identity.Profile(userId: _me, handle: 'meme'));
      await rig.open(tester);
      await rig.type(tester, 'meme');

      await tester.tap(find.byKey(kRecipientHandleRowKey));
      await tester.pumpAndSettle();

      expect(find.text("You can't message yourself."), findsOneWidget);
      expect(find.byType(DraftThreadScreen), findsNothing);
    });
  });

  group('typeahead through the source (search on)', () {
    testWidgets('typing "ab" makes at most one search call', (tester) async {
      final source = FakePeopleSource(
        people: [person(1)],
        searchesRemotely: true,
        remoteResults: [person(7, handle: 'abby', name: 'Abby')],
      );
      final rig = _Rig(source: source);
      await rig.open(tester, features: const {'messaging', 'graph', 'search'});

      await rig.type(tester, 'a');
      await tester.pump(const Duration(milliseconds: 100));
      await rig.type(tester, 'ab');
      expect(source.searchCalls, isEmpty, reason: 'debounced');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(source.searchCalls, ['ab']);
      expect(find.text('Abby'), findsOneWidget);
      // The Following rows are not shown over typeahead results.
      expect(find.text('User 1'), findsNothing);
    });

    testWidgets('a single character asks nothing', (tester) async {
      final source = FakePeopleSource(
        people: [person(1)],
        searchesRemotely: true,
      );
      final rig = _Rig(source: source);
      await rig.open(tester, features: const {'messaging', 'graph', 'search'});
      await rig.type(tester, 'a');
      await tester.pump(const Duration(seconds: 1));
      expect(source.searchCalls, isEmpty);
    });

    testWidgets('search on but the source cannot search (W4 not built): '
        'the local filter answers', (tester) async {
      final source = FakePeopleSource(
        people: [person(1, handle: 'abel', name: 'Abel')],
      );
      final rig = _Rig(source: source);
      await rig.open(tester, features: const {'messaging', 'graph', 'search'});
      await rig.type(tester, 'ab');
      await tester.pump(const Duration(seconds: 1));
      expect(source.searchCalls, isEmpty);
      expect(find.text('Abel'), findsOneWidget);
    });
  });

  group('flag combinations: messaging x search x graph', () {
    for (final messaging in [true, false]) {
      for (final search in [true, false]) {
        for (final graph in [true, false]) {
          testWidgets('messaging=$messaging search=$search graph=$graph', (
            tester,
          ) async {
            final source = FakePeopleSource(
              people: [person(1)],
              searchesRemotely: search,
            );
            final rig = _Rig(source: source);
            await rig.open(
              tester,
              features: {
                if (messaging) 'messaging',
                if (search) 'search',
                if (graph) 'graph',
              },
            );

            if (!messaging) {
              expect(find.text("Messages aren't available yet"), findsOne);
              expect(find.byKey(kRecipientFieldKey), findsNothing);
              expect(source.pageCalls, 0);
              return;
            }
            expect(find.byKey(kRecipientFieldKey), findsOneWidget);
            if (graph) {
              expect(find.text('User 1'), findsOneWidget);
              expect(source.pageCalls, 1);
            } else {
              // No Following list without graph: a hint, no request.
              expect(find.text('Type a handle'), findsOneWidget);
              expect(source.pageCalls, 0);
            }
            await rig.type(tester, 'ab');
            await tester.pump(const Duration(seconds: 1));
            await tester.pumpAndSettle();
            expect(source.searchCalls.length, search ? 1 : 0);
            // Typeahead results replace the handle row; without them a
            // valid handle can always be typed.
            await rig.type(tester, 'abc');
            await tester.pumpAndSettle();
            expect(
              find.byKey(kRecipientHandleRowKey),
              search ? findsNothing : findsOneWidget,
            );
          });
        }
      }
    }
  });

  group('picking a person', () {
    testWidgets('with a cached conversation opens it, no draft', (
      tester,
    ) async {
      final rig = _Rig();
      rig.repo.cachedByPeer['u2'] = threadConv(id: hexId(0xaa));
      await rig.open(tester);

      await tester.tap(find.text('User 2'));
      await tester.pumpAndSettle();

      expect(find.text('thread ${hexId(0xaa)}'), findsOneWidget);
      expect(find.byType(DraftThreadScreen), findsNothing);
      expect(rig.repo.sendKeys, isEmpty);
    });

    testWidgets('without one opens a draft; the first send names the '
        'recipient, then the real conversation opens', (tester) async {
      final rig = _Rig();
      await rig.open(tester);

      await tester.tap(find.text('User 3'));
      await tester.pumpAndSettle();
      expect(find.byType(DraftThreadScreen), findsOneWidget);
      expect(find.text('Write your first message below.'), findsOneWidget);
      // Nothing was sent or read to open it.
      expect(rig.repo.sendKeys, isEmpty);

      await tester.enterText(
        find.byKey(MessageComposer.fieldKey),
        'hello there',
      );
      await tester.pump();
      await tester.tap(find.byKey(MessageComposer.sendKey));
      await tester.pumpAndSettle();

      expect(rig.repo.sendRecipients, ['u3']);
      expect(rig.repo.sendTexts, ['hello there']);
      expect(rig.repo.sendKeys, hasLength(1));
      expect(find.text('thread ${rig.repo.createdConversationId}'), findsOne);
      expect(find.byType(DraftThreadScreen), findsNothing);
    });

    testWidgets('a failed first send keeps the draft; the retry reuses the '
        'key and the recipient', (tester) async {
      final rig = _Rig();
      rig.repo.failures.add(const NetworkException('offline'));
      await rig.open(tester);
      await tester.tap(find.text('User 3'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(MessageComposer.fieldKey), 'hi');
      await tester.pump();
      await tester.tap(find.byKey(MessageComposer.sendKey));
      await tester.pumpAndSettle();
      expect(find.byType(DraftThreadScreen), findsOneWidget);
      expect(find.text('Not sent. Tap to retry'), findsOneWidget);

      await tester.tap(find.text('Not sent. Tap to retry'));
      await tester.pumpAndSettle();

      expect(rig.repo.sendKeys, hasLength(2));
      expect(rig.repo.sendKeys[0], rig.repo.sendKeys[1]);
      expect(rig.repo.sendRecipients, ['u3', 'u3']);
      expect(find.text('thread ${rig.repo.createdConversationId}'), findsOne);
    });

    testWidgets('CANNOT_MESSAGE on the first send makes the draft '
        'read-only', (tester) async {
      final rig = _Rig();
      rig.repo.failures.add(const CannotMessageException());
      await rig.open(tester);
      await tester.tap(find.text('User 3'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(MessageComposer.fieldKey), 'hi');
      await tester.pump();
      await tester.tap(find.byKey(MessageComposer.sendKey));
      await tester.pumpAndSettle();

      expect(find.text(kThreadReadOnlyText), findsOneWidget);
      expect(find.byKey(MessageComposer.fieldKey), findsNothing);
    });
  });

  group('MessageComposerCubit draft mode', () {
    test('the first send uses recipient_user_id, later ones the '
        'conversation id', () async {
      final repo = FakeSendRepository();
      final created = <String>[];
      final cubit = MessageComposerCubit(
        repository: repo,
        recipientUserId: 'u-peer',
        onConversationCreated: created.add,
      );
      addTearDown(cubit.close);
      expect(cubit.conversationId, isNull);

      cubit.textChanged('one');
      await cubit.send();
      expect(repo.sendRecipients, ['u-peer']);
      expect(created, [repo.createdConversationId]);
      expect(cubit.conversationId, repo.createdConversationId);

      cubit.textChanged('two');
      await cubit.send();
      expect(repo.sendRecipients, ['u-peer', null]);
      expect(created, hasLength(1), reason: 'announced once');
    });
  });

  group('RecipientPickerCubit', () {
    test('debounces: two keys inside 300 ms make one call', () async {
      final source = FakePeopleSource(searchesRemotely: true);
      final cubit = RecipientPickerCubit(
        source: source,
        identityRepository: _MockIdentity(),
        searchEnabled: true,
        debounce: const Duration(milliseconds: 20),
      );
      addTearDown(cubit.close);
      cubit
        ..queryChanged('a')
        ..queryChanged('ab')
        ..queryChanged('abc');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(source.searchCalls, ['abc']);
      expect(cubit.state.remote, isNotNull);
    });

    test('a RATE_LIMITED answer stops typeahead for the screen', () async {
      final source = _ThrowingSource();
      final cubit = RecipientPickerCubit(
        source: source,
        identityRepository: _MockIdentity(),
        searchEnabled: true,
        debounce: Duration.zero,
      );
      addTearDown(cubit.close);
      cubit.queryChanged('ab');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(cubit.state.searchError, isA<RateLimitedException>());
      cubit.queryChanged('abc');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(source.calls, 1, reason: 'no second call after the limit');
    });
  });
}

class _ThrowingSource extends FakePeopleSource {
  _ThrowingSource() : super(searchesRemotely: true);
  int calls = 0;

  @override
  Future<List<graph.UserListItem>> search(String query) async {
    calls++;
    throw const RateLimitedException('slow down');
  }
}
