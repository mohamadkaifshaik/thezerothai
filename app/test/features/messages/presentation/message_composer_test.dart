import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/features/messages/presentation/messaging_error_messages.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/outgoing_bubble.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/shared/widgets/character_counter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/fake_send_repository.dart';
import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_shell_rig.dart';
import '../../../support/theme_harness.dart';
import '../../../support/thread_test_support.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Builds the cubit over [repo] with no thread around it.
MessageComposerCubit cubitFor(
  FakeSendRepository repo, {
  VoidCallback? onCannotMessage,
  VoidCallback? onActivity,
  Future<void> Function()? onSent,
}) => MessageComposerCubit(
  repository: repo,
  conversationId: kThreadId,
  onCannotMessage: onCannotMessage,
  onActivity: onActivity,
  onSent: onSent,
);

void main() {
  group('MessageComposerCubit: one idempotency key per intent', () {
    late FakeSendRepository repo;
    late MessageComposerCubit cubit;

    setUp(() {
      repo = FakeSendRepository();
      cubit = cubitFor(repo);
    });

    tearDown(() => cubit.close());

    test(
      'a failed send is retried with the same key, once on the server',
      () async {
        repo.failures.add(const NetworkException('offline'));
        cubit.textChanged('hello');
        await cubit.send();

        expect(cubit.state.outgoing.single.status, OutgoingStatus.failed);
        expect(cubit.state.error, isA<NetworkException>());
        // The text is not put back in the field, it waits in the failed row.
        expect(cubit.state.draft.text, isEmpty);

        await cubit.retry(cubit.state.outgoing.single.localId);

        expect(repo.sendKeys, hasLength(2));
        expect(repo.sendKeys[0], repo.sendKeys[1]);
        expect(repo.stored, hasLength(1));
        expect(cubit.state.outgoing, isEmpty);
        expect(cubit.state.error, isNull);
      },
    );

    test('a response lost after the server stored it: the retry sends the '
        'same key and there is still one message', () async {
      repo.lostResponses.add(const NetworkException('timeout'));
      cubit.textChanged('are you there');
      await cubit.send();
      expect(cubit.state.outgoing.single.status, OutgoingStatus.failed);
      expect(repo.stored, hasLength(1));

      await cubit.retry(cubit.state.outgoing.single.localId);

      expect(repo.sendKeys[0], repo.sendKeys[1]);
      expect(repo.stored, hasLength(1));
      expect(
        repo.thread.messages.where((m) => m.text == 'are you there'),
        hasLength(1),
      );
      expect(cubit.state.outgoing, isEmpty);
    });

    test('edit and revert keeps the key; a different text gets its own; a '
        'delivered text starts over', () async {
      repo.failures.addAll(const [
        NetworkException('x'),
        NetworkException('x'),
      ]);
      cubit.textChanged('a');
      await cubit.send();
      final first = repo.sendKeys.single;
      cubit.textChanged('b');
      await cubit.send();
      expect(repo.sendKeys[1], isNot(first));

      // Reverting to "a" is the same intent: same key, one message.
      cubit.textChanged('a');
      await cubit.send();
      expect(repo.sendKeys[2], first);
      expect(repo.stored, hasLength(1));

      // "a" was delivered: sending "a" again is a new message, new key.
      cubit.textChanged('a');
      await cubit.send();
      expect(repo.sendKeys[3], isNot(first));
      expect(repo.stored, hasLength(2));
    });

    test('retry is a no-op while another send is in flight', () async {
      repo.failures.add(const NetworkException('x'));
      cubit.textChanged('one');
      await cubit.send();
      final failedId = cubit.state.outgoing.single.localId;

      repo.sendGate = Completer<void>();
      cubit.textChanged('two');
      final sending = cubit.send();
      expect(cubit.state.isSending, isTrue);
      expect(cubit.state.canSend, isFalse);
      await cubit.retry(failedId);
      expect(repo.sendKeys, hasLength(2));
      repo.sendGate!.complete();
      await sending;
    });

    test('281 code points cannot be sent; 280 can', () async {
      cubit.textChanged('a' * 281);
      expect(cubit.state.draft.remaining, -1);
      expect(cubit.state.canSend, isFalse);
      await cubit.send();
      expect(repo.sendKeys, isEmpty);

      cubit.textChanged('a' * 280);
      expect(cubit.state.canSend, isTrue);
      // Emoji count as one code point each, not two UTF-16 units.
      cubit.textChanged('😀' * 280);
      expect(cubit.state.canSend, isTrue);
      cubit.textChanged('😀' * 281);
      expect(cubit.state.canSend, isFalse);
    });

    test('11 lines cannot be sent; 10 can', () async {
      cubit.textChanged(List.filled(11, 'x').join('\n'));
      expect(cubit.state.canSend, isFalse);
      cubit.textChanged(List.filled(10, 'x').join('\n'));
      expect(cubit.state.canSend, isTrue);
    });

    test(
      'CANNOT_MESSAGE drops the row and asks the thread to go read-only',
      () async {
        var readOnly = 0;
        final c = cubitFor(repo, onCannotMessage: () => readOnly++);
        addTearDown(c.close);
        repo.failures.add(const CannotMessageException());
        c.textChanged('hi');
        await c.send();
        expect(readOnly, 1);
        expect(c.state.outgoing, isEmpty);
        expect(c.state.error, isNull);
      },
    );

    test('degraded mode turns Send off until a bubble is tapped', () async {
      repo.failures.add(const DegradedModeException('paused'));
      cubit.textChanged('hi');
      await cubit.send();
      expect(cubit.state.degraded, isTrue);

      cubit.textChanged('something else');
      expect(cubit.state.draft.canPost, isTrue);
      expect(cubit.state.canSend, isFalse);
      await cubit.send();
      expect(repo.sendKeys, hasLength(1));

      await cubit.retry(cubit.state.outgoing.single.localId);
      expect(cubit.state.degraded, isFalse);
      expect(repo.sendKeys, hasLength(2));
      expect(repo.sendKeys[0], repo.sendKeys[1]);
    });

    test('typing and sending call onActivity; a send calls onSent before the '
        'row goes', () async {
      var activity = 0;
      var sentRowThen = <OutgoingStatus>[];
      late MessageComposerCubit c;
      c = cubitFor(
        repo,
        onActivity: () => activity++,
        onSent: () async {
          sentRowThen = [for (final m in c.state.outgoing) m.status];
        },
      );
      addTearDown(c.close);
      c.textChanged('x');
      expect(activity, 1);
      await c.send();
      expect(activity, 2);
      expect(sentRowThen, [OutgoingStatus.sent]);
      expect(c.state.outgoing, isEmpty);
    });
  });

  group('the composer in a conversation', () {
    late FakeSendRepository repo;
    late MockOnboardingBloc onboarding;
    late MessagingShellRig rig;
    late FakeThreadPoller poller;

    setUp(() {
      rig = MessagingShellRig();
      repo = FakeSendRepository();
      onboarding = MockOnboardingBloc();
      poller = FakeThreadPoller();
      repo.thread = ThreadSnapshot(
        messages: [msg(1, secondsAgo: 30, text: 'earlier from Sam')],
        conversation: threadConv(),
        sinceToken: 's',
      );
    });

    Future<void> open(
      WidgetTester tester, {
      Set<String> features = const {'messaging'},
      Brightness brightness = Brightness.light,
      Size size = const Size(400, 800),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(enabledFeatures: features),
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => ThreadScreen(
              conversationId: kThreadId,
              now: kMsgBase.add(const Duration(minutes: 1)),
              onOpenLink: (_) {},
              pollerBuilder: (_, _) => poller,
              composerBuilder: (context, conversation) =>
                  const MessageComposer(),
            ),
          ),
          GoRoute(
            path: '/messages',
            builder: (context, state) => const Scaffold(body: Text('inbox')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<MessagingRepository>.value(value: repo),
            RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              ...rig.providers,
            ],
            child: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(textScale),
              ),
              child: MaterialApp.router(
                theme: brightness == Brightness.dark
                    ? appDarkTheme
                    : appLightTheme,
                routerConfig: router,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder field() => find.byKey(MessageComposer.fieldKey);
    Finder sendButton() => find.byKey(MessageComposer.sendKey);

    bool sendEnabled(WidgetTester tester) =>
        tester.widget<IconButton>(sendButton()).onPressed != null;

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(field(), text);
      await tester.pump();
    }

    Future<void> tapSend(WidgetTester tester) async {
      await tester.tap(sendButton());
      await tester.pump();
    }

    testWidgets('sends: a dimmed "Sending…" bubble becomes the server '
        'message, once', (tester) async {
      await open(tester);
      repo.sendGate = Completer<void>();

      await type(tester, 'hello Sam');
      await tapSend(tester);

      expect(find.text(kOutgoingSendingText), findsOneWidget);
      expect(find.text('hello Sam'), findsOneWidget);
      expect(find.byType(OutgoingBubble), findsOneWidget);
      // The field was emptied for the next message.
      expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
      // Send is off while the message is in flight.
      expect(sendEnabled(tester), isFalse);
      expect(poller.inputs, greaterThan(0));

      repo.sendGate!.complete();
      await tester.pumpAndSettle();

      expect(find.text(kOutgoingSendingText), findsNothing);
      expect(find.byType(OutgoingBubble), findsNothing);
      expect(find.text('hello Sam'), findsOneWidget);
      expect(find.byType(MessageBubble), findsNWidgets(2));
      expect(repo.sendKeys, hasLength(1));
    });

    testWidgets('a failed send shows "Not sent. Tap to retry"; the tap retries '
        'with the same key', (tester) async {
      await open(tester);
      repo.failures.add(const NetworkException('offline'));

      await type(tester, 'ping');
      await tapSend(tester);
      await tester.pumpAndSettle();

      expect(find.text(kOutgoingNotSentText), findsOneWidget);
      expect(
        find.text(messagingErrorMessage(const NetworkException(''))),
        findsOneWidget,
      );

      await tester.tap(find.text(kOutgoingNotSentText));
      await tester.pumpAndSettle();

      expect(repo.sendKeys, hasLength(2));
      expect(repo.sendKeys[0], repo.sendKeys[1]);
      expect(repo.stored, hasLength(1));
      expect(find.text(kOutgoingNotSentText), findsNothing);
      expect(find.text('ping'), findsOneWidget);
    });

    testWidgets('a timeout after the server stored it: the retry sends the '
        'same key and one message remains', (tester) async {
      await open(tester);
      repo.lostResponses.add(const NetworkException('timeout'));

      await type(tester, 'did it arrive');
      await tapSend(tester);
      await tester.pumpAndSettle();
      expect(find.text(kOutgoingNotSentText), findsOneWidget);

      await tester.tap(find.text(kOutgoingNotSentText));
      await tester.pumpAndSettle();

      expect(repo.sendKeys[0], repo.sendKeys[1]);
      expect(repo.stored, hasLength(1));
      expect(find.text('did it arrive'), findsOneWidget);
      expect(find.byType(OutgoingBubble), findsNothing);
    });

    testWidgets('281 code points: Send is off and the counter is red', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'a' * 281);

      expect(sendEnabled(tester), isFalse);
      final counter = find.byType(CharacterCounter);
      expect(counter, findsOneWidget);
      final text = tester.widget<Text>(
        find.descendant(of: counter, matching: find.text('-1')),
      );
      expect(
        text.style?.color,
        Theme.of(tester.element(counter)).colorScheme.error,
      );

      await type(tester, 'a' * 280);
      expect(sendEnabled(tester), isTrue);
    });

    testWidgets('the counter shows only near the limit', (tester) async {
      await open(tester);
      await type(tester, 'short');
      expect(find.byType(CharacterCounter), findsNothing);
      await type(tester, 'a' * 270);
      expect(find.byType(CharacterCounter), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
    });

    testWidgets('too many lines and unsupported characters show the hint', (
      tester,
    ) async {
      await open(tester);
      await type(tester, List.filled(11, 'x').join('\n'));
      expect(find.text('Messages can have at most 10 lines.'), findsOneWidget);
      expect(sendEnabled(tester), isFalse);

      await type(tester, 'bad\u202Echar');
      expect(find.text('Remove the unsupported characters.'), findsOneWidget);
      expect(sendEnabled(tester), isFalse);
    });

    testWidgets('degraded readonly: the banner shows and Send is off', (
      tester,
    ) async {
      await open(tester);
      repo.failures.add(const DegradedModeException('paused'));

      await type(tester, 'hi');
      await tapSend(tester);
      await tester.pumpAndSettle();

      expect(
        find.text(messagingErrorMessage(const DegradedModeException(''))),
        findsOneWidget,
      );
      await type(tester, 'a new thought');
      expect(sendEnabled(tester), isFalse);
      expect(repo.sendKeys, hasLength(1));
      // The failed bubble is the way back.
      expect(find.text(kOutgoingNotSentText), findsOneWidget);
    });

    testWidgets('CANNOT_MESSAGE turns the thread read-only', (tester) async {
      await open(tester);
      repo.failures.add(const CannotMessageException());

      await type(tester, 'hi');
      await tapSend(tester);
      await tester.pumpAndSettle();

      expect(find.text(kThreadReadOnlyText), findsOneWidget);
      expect(field(), findsNothing);
      expect(find.byType(OutgoingBubble), findsNothing);
      expect(find.text(CannotMessageException.userMessage), findsOneWidget);
      expect(
        BlocProvider.of<ThreadCubit>(
          tester.element(find.byType(Scaffold).first),
        ).state.cannotMessage,
        isTrue,
      );
    });

    group('each error has its own text', () {
      final cases = <String, (Object, String)>{
        'request_unanswered': (
          const LimitReachedException('x', quota: 'request_unanswered'),
          'You can send more once they accept your request',
        ),
        'dm_new_daily': (
          const LimitReachedException('x', quota: 'dm_new_daily'),
          "You've started as many new conversations as allowed today. It "
              'resets tomorrow.',
        ),
        'rate limit': (
          const RateLimitedException('x', limitName: 'messages_send_per_min'),
          messagingErrorMessage(
            const RateLimitedException('x', limitName: 'messages_send_per_min'),
          ),
        ),
        'daily rate limit': (
          const RateLimitedException('x', limitName: 'messages_daily'),
          messagingErrorMessage(
            const RateLimitedException('x', limitName: 'messages_daily'),
          ),
        ),
        'offline': (
          const NetworkException('x'),
          'No connection. Check your network and try again.',
        ),
        'feature disabled': (
          const FeatureDisabledException('x', feature: 'messaging'),
          "Messages aren't available right now.",
        ),
      };
      final seen = <String>{};
      for (final entry in cases.entries) {
        testWidgets(entry.key, (tester) async {
          await open(tester);
          repo.failures.add(entry.value.$1);
          await type(tester, 'hello');
          await tapSend(tester);
          await tester.pumpAndSettle();

          expect(find.text(entry.value.$2), findsOneWidget);
          expect(find.text(kOutgoingNotSentText), findsOneWidget);
          // None of them is the server's text or another error's.
          expect(seen.add(entry.value.$2), isTrue);
          // Typing again clears the line; the failed bubble stays.
          await type(tester, 'h');
          expect(find.text(entry.value.$2), findsNothing);
          expect(find.text(kOutgoingNotSentText), findsOneWidget);
        });
      }

      testWidgets('degraded mode', (tester) async {
        await open(tester);
        repo.failures.add(const DegradedModeException('x'));
        await type(tester, 'hello');
        await tapSend(tester);
        await tester.pumpAndSettle();
        expect(find.textContaining('limited mode'), findsOneWidget);
      });
    });

    testWidgets('hidden when messaging is off for the caller', (tester) async {
      await open(tester);
      expect(field(), findsOneWidget);

      whenListen(
        onboarding,
        Stream.value(const OnboardingState(enabledFeatures: {})),
        initialState: const OnboardingState(enabledFeatures: {}),
      );
      final cubit = MessageComposerCubit(
        repository: repo,
        conversationId: kThreadId,
      );
      addTearDown(cubit.close);
      await pumpThemed(
        tester,
        MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<MessageComposerCubit>.value(value: cubit),
          ],
          child: const MessageComposer(),
        ),
      );
      expect(field(), findsNothing);
      expect(sendButton(), findsNothing);
    });

    group('keyboard', () {
      Future<void> withPlatform(
        TargetPlatform platform,
        Future<void> Function() body,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await body();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        testWidgets('Enter sends on ${platform.name}', (tester) async {
          await withPlatform(platform, () async {
            await open(tester);
            await type(tester, 'sent with enter');
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();

            expect(repo.sendTexts, ['sent with enter']);
            expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
          });
        });
      }

      testWidgets('the numpad Enter sends too', (tester) async {
        await withPlatform(TargetPlatform.linux, () async {
          await open(tester);
          await type(tester, 'numpad');
          await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
          await tester.pumpAndSettle();
          expect(repo.sendTexts, ['numpad']);
        });
      });

      testWidgets('Shift+Enter does not send (it adds a line)', (tester) async {
        await withPlatform(TargetPlatform.macOS, () async {
          await open(tester);
          await type(tester, 'line one');
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pumpAndSettle();

          expect(repo.sendKeys, isEmpty);
          expect(
            tester.widget<TextField>(field()).controller!.text,
            'line one',
          );
          // The key was left to the text field (it inserts the newline).
          await type(tester, 'line one\nline two');
          expect(sendEnabled(tester), isTrue);
          await tapSend(tester);
          await tester.pumpAndSettle();
          expect(repo.sendTexts, ['line one\nline two']);
        });
      });

      testWidgets('Enter on a phone adds a line instead of sending', (
        tester,
      ) async {
        for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
          await withPlatform(platform, () async {
            await open(tester);
            await type(tester, 'phone');
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(repo.sendKeys, isEmpty);
            expect(
              tester.widget<TextField>(field()).keyboardType,
              TextInputType.multiline,
            );
            expect(
              tester.widget<TextField>(field()).textInputAction,
              TextInputAction.newline,
            );
          });
        }
      });

      testWidgets('Enter with nothing typed does nothing', (tester) async {
        await withPlatform(TargetPlatform.macOS, () async {
          await open(tester);
          await tester.tap(field());
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(repo.sendKeys, isEmpty);
        });
      });
    });

    group('the matrix', () {
      forEachThemeAndWidth('composer, counter and a failed bubble fit', (
        tester,
        env,
      ) async {
        await open(
          tester,
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        repo.failures.add(
          const LimitReachedException('x', quota: 'request_unanswered'),
        );
        await type(tester, 'a long message ' * 17);
        await tapSend(tester);
        await tester.pumpAndSettle();
        expect(
          find.text('You can send more once they accept your request'),
          findsOneWidget,
        );
        await type(tester, 'b' * 285);

        expect(tester.takeException(), isNull);
        expect(find.byType(CharacterCounter), findsOneWidget);
        expect(find.text(kOutgoingNotSentText), findsOneWidget);
        // 48dp targets.
        expect(
          tester.getSize(sendButton()).shortestSide,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byType(OutgoingBubble)).height,
          greaterThanOrEqualTo(48),
        );
      }, textScales: kMatrixTextScalesLarge);

      forEachThemeAndWidth('degraded banner fits', (tester, env) async {
        await open(
          tester,
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        repo.failures.add(const DegradedModeException('x'));
        await type(tester, 'hi');
        await tapSend(tester);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('limited mode'), findsOneWidget);
      }, textScales: kMatrixTextScalesLarge);
    });
  });
}
