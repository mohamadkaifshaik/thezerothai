import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/notifications/domain/notification_prefs.dart';
import 'package:dzeroth/features/notifications/domain/notifications_feature_flag.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/notification_settings_action.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/domain/message_privacy.dart';
import 'package:dzeroth/features/settings/presentation/widgets/message_settings_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The two header gears (F6 on Notifications, F3/F9 on Messages), each in
/// its own widget so the hot screens only gained one `actions:` entry.
void main() {
  Future<GoRouter> pump(WidgetTester tester, Set<String> flags) async {
    final onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            appBar: AppBar(
              actions: const [
                NotificationSettingsAction(),
                MessageSettingsAction(),
              ],
            ),
          ),
        ),
        for (final path in [
          AppRouter.notificationSettingsPath,
          AppRouter.messageSettingsPath,
        ])
          GoRoute(
            path: path,
            builder: (context, state) => Scaffold(body: Text('page $path')),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  for (final (flags, notif, messages) in [
    (<String>{}, false, false),
    ({kFeatureNotifications}, false, false),
    ({kFeatureNotificationPrefs}, false, false),
    ({kFeatureNotifications, kFeatureNotificationPrefs}, true, false),
    ({kFeatureReadReceipts}, false, true),
    ({kFeatureDmPolicy}, false, true),
  ]) {
    testWidgets('flags $flags', (tester) async {
      await pump(tester, flags);
      expect(
        find.byTooltip('Notification settings'),
        notif ? findsOneWidget : findsNothing,
      );
      expect(
        find.byTooltip('Message settings'),
        messages ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('each gear pushes its settings page', (tester) async {
    final router = await pump(tester, {
      kFeatureNotifications,
      kFeatureNotificationPrefs,
      kFeatureDmPolicy,
    });
    await tester.tap(find.byTooltip('Notification settings'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, AppRouter.notificationSettingsPath);
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Message settings'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, AppRouter.messageSettingsPath);
  });

  test('the hot screens only gained the gear entry', () {
    // R8 restyles Notifications and R3 Messages in parallel: each screen
    // carries one self-gating action, nothing else of R4.
    final notifications = File(
      'lib/features/notifications/presentation/notifications_screen.dart',
    ).readAsStringSync();
    expect(
      'NotificationSettingsAction()'.allMatches(notifications),
      hasLength(1),
    );
    final conversations = File(
      'lib/features/messages/presentation/conversations_screen.dart',
    ).readAsStringSync();
    expect('MessageSettingsAction()'.allMatches(conversations), hasLength(1));
  });
}
