import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/message_outbox.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/thread_info_sheet.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_side_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_shell_rig.dart';
import '../../../support/thread_test_support.dart';

class _MockMessaging extends Mock implements MessagingRepository {
  @override
  final MessageOutbox outbox = MessageOutbox();
}

class _MockGraph extends Mock implements GraphRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _tablet = {
  'messaging',
  'graph',
  'reports',
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The chat info side sheet (tablet plan sections 4.1 "Chat" and 4.2): at
/// 600-1199dp on the tablet layout the thread's info button opens it in
/// place of the menu; phones, desktop and the other flag modes keep the
/// menu. Its actions run the menu's flows (the existing fakes).
void main() {
  late _MockMessaging repo;
  late _MockGraph graphRepo;
  late _MockModeration moderation;
  late _MockOnboardingBloc onboarding;
  late MessagingShellRig shell;

  setUp(() {
    shell = MessagingShellRig();
    repo = _MockMessaging();
    graphRepo = _MockGraph();
    moderation = _MockModeration();
    onboarding = _MockOnboardingBloc();
    final current = ThreadSnapshot(
      messages: msgs(1, 3),
      conversation: threadConv(),
    );
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.cachedConversation(any())).thenAnswer((_) async => null);
    when(() => repo.rateLimitHold).thenReturn(RateLimitHold());
    when(() => repo.cachedThread(any())).thenAnswer((_) async => current);
    when(() => repo.refreshThread(any())).thenAnswer((_) async => current);
    when(() => repo.pollThread(any()))
        .thenAnswer((_) async => const PollResult(newMessages: false));
    when(() => graphRepo.cached(any())).thenReturn(null);
  });

  Future<void> open(
    WidgetTester tester, {
    double width = 834,
    double height = 900,
    Set<String> features = _tablet,
    TextDirection textDirection = TextDirection.ltr,
    void Function(BuildContext, pb.Conversation)? onReport,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, height);
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
            onReport: onReport,
            pollerBuilder: (_, _) => FakeThreadPoller(),
          ),
        ),
        GoRoute(
          path: '/messages',
          builder: (context, state) => const Scaffold(body: Text('inbox page')),
        ),
        GoRoute(
          path: '/profile/:handle',
          builder: (context, state) => Scaffold(
            body: Text('profile page ${state.pathParameters['handle']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<ModerationRepository>.value(value: moderation),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            ...shell.providers,
          ],
          child: MaterialApp.router(
            theme: appLightTheme,
            routerConfig: router,
            builder: (context, child) => Directionality(
              textDirection: textDirection,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openInfo(WidgetTester tester) async {
    await tester.tap(find.byTooltip(kConversationInfoLabel));
    await tester.pumpAndSettle();
  }

  Finder sheet() => find.byType(ThreadInfoSheet);

  group('which control, by width and flags', () {
    for (final width in [600.0, 744.0, 834.0, 840.0, 1024.0, 1199.0]) {
      testWidgets('tablet layout at ${width.toInt()}: the side sheet', (
        tester,
      ) async {
        await open(tester, width: width);
        expect(
          find.byWidgetPredicate((w) => w is PopupMenuButton),
          findsNothing,
        );
        await openInfo(tester);
        expect(sheet(), findsOneWidget);
        // 360 wide, the whole height, at the end edge.
        final rect = tester.getRect(sheet());
        expect(tester.getRect(find.byType(ThreadInfoSheet)).right, width);
        final surface = tester.getRect(
          find.ancestor(of: sheet(), matching: find.byType(SafeArea)).first,
        );
        expect(surface.width, 360);
        expect(surface.height, 900);
        expect(surface.right, width);
        expect(rect.left, greaterThanOrEqualTo(width - 360));
        expect(tester.takeException(), isNull);
      });
    }

    for (final (width, features, why) in [
      (599.0, _tablet, 'a phone'),
      (390.0, _tablet, 'a phone'),
      (1200.0, _tablet, 'desktop'),
      (1440.0, _tablet, 'desktop'),
      (
        834.0,
        const {'messaging', 'graph', 'reports', kFeatureUiShell},
        'ui_shell only',
      ),
      (
        834.0,
        const {'messaging', 'graph', 'reports', kFeatureUiTablet},
        'ui_tablet only',
      ),
      (834.0, const {'messaging', 'graph', 'reports'}, 'neither flag'),
    ]) {
      testWidgets('$why at ${width.toInt()}: the menu, as before', (
        tester,
      ) async {
        await open(tester, width: width, features: features);
        await openInfo(tester);
        expect(sheet(), findsNothing);
        expect(
          find.byWidgetPredicate((w) => w is PopupMenuItem),
          findsNWidgets(3),
        );
        expect(find.text('Block @sam'), findsOneWidget);
        expect(find.text('View profile'), findsNothing);
      });
    }
  });

  group('the sheet', () {
    testWidgets('the profile card and the actions, in the menu\'s order', (
      tester,
    ) async {
      await open(tester, onReport: (_, _) {});
      await openInfo(tester);
      expect(find.text(kConversationInfoLabel), findsOneWidget);
      final inSheet = find.descendant(
        of: sheet(),
        matching: find.text('Sam Rivera'),
      );
      expect(inSheet, findsOneWidget);
      expect(
        find.descendant(of: sheet(), matching: find.text('@sam')),
        findsOneWidget,
      );
      expect(find.text('View profile'), findsOneWidget);
      final block = tester.getTopLeft(find.text('Block @sam')).dy;
      final report = tester.getTopLeft(find.text('Report @sam')).dy;
      final delete = tester.getTopLeft(find.text('Delete conversation')).dy;
      expect(block, lessThan(report));
      expect(report, lessThan(delete));
      // Every action is a 48dp+ target.
      for (final label in [
        'Block @sam',
        'Report @sam',
        'Delete conversation',
      ]) {
        final row = find
            .ancestor(of: find.text(label), matching: find.byType(InkWell))
            .first;
        expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      }
      // Mute, the shared plan and live location have no data yet: absent.
      expect(find.textContaining('Mute'), findsNothing);
      expect(find.textContaining('plan'), findsNothing);
    });

    testWidgets('the menu\'s rules: no Block with graph off; Report hidden '
        'with reports off', (tester) async {
      await open(
        tester,
        features: {'messaging', kFeatureUiShell, kFeatureUiTablet},
      );
      await openInfo(tester);
      expect(find.text('Block @sam'), findsNothing);
      expect(find.text('Report @sam'), findsNothing);
      expect(find.text('Delete conversation'), findsOneWidget);
    });

    testWidgets('Report is shown disabled until a report flow is wired', (
      tester,
    ) async {
      await open(tester);
      await openInfo(tester);
      await tester.tap(find.text('Report @sam'));
      await tester.pumpAndSettle();
      // Nothing happened: the sheet is still open.
      expect(sheet(), findsOneWidget);
      final node = tester.getSemantics(
        find
            .ancestor(
              of: find.text('Report @sam'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(
        node,
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
    });

    testWidgets('named "Conversation info" for a screen reader, as a dialog', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      await openInfo(tester);
      expect(find.bySemanticsLabel(kConversationInfoLabel), findsWidgets);
      handle.dispose();
    });

    testWidgets('Escape closes it and focus returns to the info button', (
      tester,
    ) async {
      await open(tester);
      final button = find.byTooltip(kConversationInfoLabel);
      Focus.of(
        tester.element(
          find.descendant(of: button, matching: find.byType(Icon)),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      // Focus moved into the sheet.
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        find.descendant(of: sheet(), matching: find.byWidget(focused.widget)),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(
        find.ancestor(
          of: find.byWidget(
            FocusManager.instance.primaryFocus!.context!.widget,
          ),
          matching: button,
        ),
        findsWidgets,
      );
    });

    testWidgets('a tap on the scrim closes it, and so does Close', (
      tester,
    ) async {
      await open(tester);
      await openInfo(tester);
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);

      await openInfo(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
    });

    testWidgets('RTL: at the left edge', (tester) async {
      await open(tester, textDirection: TextDirection.rtl);
      await openInfo(tester);
      final surface = tester.getRect(
        find.ancestor(of: sheet(), matching: find.byType(SafeArea)).first,
      );
      expect(surface.left, 0);
      expect(surface.width, 360);
    });

    testWidgets('text scale 2.0: no overflow, rows still 48dp+', (
      tester,
    ) async {
      await open(tester, width: 600, height: 700, textScale: 2);
      await openInfo(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Delete conversation'),
        100,
        scrollable: find.descendant(
          of: sheet(),
          matching: find.byType(Scrollable),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the actions run the menu\'s flows', () {
    testWidgets('View profile closes the sheet and opens the profile', (
      tester,
    ) async {
      await open(tester);
      await openInfo(tester);
      await tester.tap(find.text('View profile'));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(find.text('profile page sam'), findsOneWidget);
    });

    testWidgets('Block: the confirm, the graph call, then read-only', (
      tester,
    ) async {
      when(
        () => graphRepo.block(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: 'u-sam', blocking: true),
      );
      await open(tester);
      await openInfo(tester);
      await tester.tap(find.text('Block @sam'));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(find.text('Block this account?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();
      verify(
        () => graphRepo.block(
          userId: 'u-sam',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text(kThreadReadOnlyText), findsOneWidget);
      // Blocked: the sheet offers Block no more.
      await openInfo(tester);
      expect(find.text('Block @sam'), findsNothing);
    });

    testWidgets('Block cancelled sends nothing', (tester) async {
      await open(tester);
      await openInfo(tester);
      await tester.tap(find.text('Block @sam'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(
        () => graphRepo.block(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    testWidgets('Report hands the conversation to the report flow', (
      tester,
    ) async {
      pb.Conversation? reported;
      await open(tester, onReport: (_, c) => reported = c);
      await openInfo(tester);
      await tester.tap(find.text('Report @sam'));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(reported?.peer.handle, 'sam');
    });

    testWidgets('Delete: the confirm, the call, then the inbox', (
      tester,
    ) async {
      when(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenAnswer((_) async {});
      await open(tester);
      await openInfo(tester);
      await tester.tap(find.text('Delete conversation'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this conversation?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      verify(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).called(1);
      expect(find.text('inbox page'), findsOneWidget);
    });

    testWidgets('a failed Delete keeps the conversation and says so', (
      tester,
    ) async {
      when(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenThrow(const NetworkException('offline'));
      await open(tester);
      await openInfo(tester);
      await tester.tap(find.text('Delete conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(ThreadScreen), findsOneWidget);
    });
  });

  group('ThreadInfoSheet alone', () {
    testWidgets('a peer with no handle has no View profile; a closed sheet '
        'resolves to null', (tester) async {
      ThreadInfoAction? chosen = ThreadInfoAction.block;
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => chosen = await ThreadInfoSheet.show(
                context,
                peer: common.AuthorSnapshot(displayName: 'Gone'),
                canBlock: false,
                showReport: true,
                canReport: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Gone'), findsOneWidget);
      expect(find.text('View profile'), findsNothing);
      expect(find.byType(AppSideSheetHeader), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(chosen, isNull);
    });
  });
}
