import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/domain/notification_prefs.dart';
import 'package:dzeroth/features/notifications/domain/notifications_feature_flag.dart';
import 'package:dzeroth/features/notifications/presentation/notification_settings_screen.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/data/own_privacy_store.dart';
import 'package:dzeroth/features/settings/domain/message_privacy.dart';
import 'package:dzeroth/features/settings/presentation/message_settings_messages.dart';
import 'package:dzeroth/features/settings/presentation/message_settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/widgets/message_privacy_rows.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_chip.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockIdentity extends Mock implements IdentityRepository {}

AuthState _signedIn(String uid) => AuthState(
  status: AuthStatus.authenticated,
  user: AppUser(
    uid: uid,
    email: '$uid@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  ),
);

const _aPrefs = NotificationPushPrefs(
  plans: false,
  mentionsReplies: false,
  likesReposts: false,
  followers: false,
  messages: false,
);
const _bPrefs = NotificationPushPrefs(
  plans: true,
  mentionsReplies: true,
  likesReposts: true,
  followers: true,
  messages: true,
);

/// R4 review fixes (security M1, m1, m2; UX must- and should-fix). Each
/// test failed before its fix.
void main() {
  late _MockAuth auth;
  late StreamController<AuthState> authStates;
  late _MockOnboarding onboarding;
  late StreamController<OnboardingState> onboardingStates;
  late _MockNotifications notifications;
  late _MockIdentity identityRepo;

  setUpAll(() {
    registerFallbackValue(_aPrefs);
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  setUp(() {
    auth = _MockAuth();
    authStates = StreamController<AuthState>.broadcast();
    onboarding = _MockOnboarding();
    onboardingStates = StreamController<OnboardingState>.broadcast();
    notifications = _MockNotifications();
    identityRepo = _MockIdentity();
  });

  tearDown(() async {
    await authStates.close();
    await onboardingStates.close();
  });

  OnboardingState ready(Set<String> flags, {bool refreshFailed = false}) =>
      OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        refreshFailed: refreshFailed,
      );

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    required AuthState authState,
    required OnboardingState onboardingState,
    OwnPrivacyStore? store,
    double width = 360,
    double textScale = 1,
    bool use24h = false,
  }) async {
    whenListen(auth, authStates.stream, initialState: authState);
    whenListen(
      onboarding,
      onboardingStates.stream,
      initialState: onboardingState,
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<NotificationsRepository>.value(
            value: notifications,
          ),
          RepositoryProvider<IdentityRepository>.value(value: identityRepo),
          if (store != null)
            RepositoryProvider<OwnPrivacyStore>.value(value: store),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                alwaysUse24HourFormat: use24h,
              ),
              child: child!,
            ),
            home: Scaffold(body: page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('M1: the push prefs belong to the signed-in account', () {
    testWidgets('an A to B switch with the page open loads B and never '
        "saves from A's values", (tester) async {
      var user = 'uid-a';
      when(() => notifications.getPushPrefs())
          .thenAnswer((_) async => user == 'uid-a' ? _aPrefs : _bPrefs);
      when(
        () => notifications.updatePushPrefs(
          idempotencyKey: any(named: 'idempotencyKey'),
          prefs: any(named: 'prefs'),
        ),
      ).thenAnswer(
        (i) async => i.namedArguments[#prefs] as NotificationPushPrefs,
      );
      await pump(
        tester,
        const NotificationSettingsBody(),
        authState: _signedIn('uid-a'),
        onboardingState: ready({
          kFeatureNotifications,
          kFeatureNotificationPrefs,
        }),
      );
      expect(
        tester
            .widget<SettingsRow>(find.widgetWithText(SettingsRow, 'Followers'))
            .toggled,
        isFalse,
      );

      user = 'uid-b';
      when(() => auth.state).thenReturn(_signedIn('uid-b'));
      authStates.add(_signedIn('uid-b'));
      await tester.pumpAndSettle();

      verify(() => notifications.getPushPrefs()).called(2);
      expect(
        tester
            .widget<SettingsRow>(find.widgetWithText(SettingsRow, 'Followers'))
            .toggled,
        isTrue,
        reason: "B's own values",
      );
      await tester.tap(find.widgetWithText(SettingsRow, 'Followers'));
      await tester.pumpAndSettle();
      final sent =
          verify(
                () => notifications.updatePushPrefs(
                  idempotencyKey: any(named: 'idempotencyKey'),
                  prefs: captureAny(named: 'prefs'),
                ),
              ).captured.single
              as NotificationPushPrefs;
      expect(sent, _bPrefs.withGroup(NotificationPrefsGroup.followers, false));
    });
  });

  group('m2: a DM policy this app does not know', () {
    // Profile.dm_policy (field 19) = 3, a value from a newer server.
    identity.Profile futurePolicy() => identity.Profile.fromBuffer([
      ...identity.Profile(userId: 'uid-a').writeToBuffer(),
      0x98, 0x01, 0x03, //
    ]);

    test('is unknown, never Everyone', () {
      final store = OwnPrivacyStore()..record(futurePolicy());
      expect(store.value?.whoCanMessage, isNull);
    });

    testWidgets('no pill is selected, the way back to Everyone stays', (
      tester,
    ) async {
      final store = OwnPrivacyStore()..record(futurePolicy());
      await pump(
        tester,
        const MessageSettingsScreen(),
        authState: _signedIn('uid-a'),
        onboardingState: ready({kFeatureMessaging}),
        store: store,
      );
      final pills = tester.widgetList<AppFilterPill>(
        find.byType(AppFilterPill),
      );
      expect([for (final p in pills) p.label], ['Everyone']);
      expect([for (final p in pills) p.selected], [false]);
    });
  });

  group('UX 2: Message settings while loading or offline', () {
    testWidgets('flag on, nothing confirmed yet: a placeholder, not "not '
        'available"', (tester) async {
      await pump(
        tester,
        const MessageSettingsScreen(),
        authState: _signedIn('uid-a'),
        onboardingState: ready({kFeatureMessaging, kFeatureDmPolicy}),
        store: OwnPrivacyStore(),
      );
      expect(find.text(kMessageSettingsUnavailableTitle), findsNothing);
      expect(find.bySemanticsLabel('Loading message settings'), findsOneWidget);
    });

    testWidgets('a failed refresh: the error with Retry', (tester) async {
      await pump(
        tester,
        const MessageSettingsScreen(),
        authState: _signedIn('uid-a'),
        onboardingState: ready({
          kFeatureMessaging,
          kFeatureReadReceipts,
        }, refreshFailed: true),
        store: OwnPrivacyStore(),
      );
      expect(find.text(kMessageSettingsUnavailableTitle), findsNothing);
      await tester.tap(find.text('Retry'));
      verify(() => onboarding.add(const OnboardingRefreshRequested()))
          .called(1);
    });
  });

  group('UX 3 and 4: explanations and saving feedback', () {
    testWidgets('the read receipts explanation is whole at 360 x2.0', (
      tester,
    ) async {
      await pump(
        tester,
        const MessageSettingsScreen(),
        authState: _signedIn('uid-a'),
        onboardingState: ready({kFeatureMessaging, kFeatureReadReceipts}),
        store: OwnPrivacyStore()
          ..record(identity.Profile(userId: 'uid-a', readReceipts: true)),
        textScale: 2,
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(kReadReceiptsSubtitle),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
    });

    testWidgets('the push explanations are whole at 360 x2.0', (tester) async {
      when(() => notifications.getPushPrefs()).thenAnswer((_) async => _bPrefs);
      await pump(
        tester,
        const NotificationSettingsBody(),
        authState: _signedIn('uid-a'),
        onboardingState: ready({
          kFeatureNotifications,
          kFeatureNotificationPrefs,
        }),
        textScale: 2,
      );
      for (final group in [
        NotificationPrefsGroup.mentionsReplies,
        NotificationPrefsGroup.likesReposts,
        NotificationPrefsGroup.followers,
      ]) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(group.description),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: group.label);
      }
    });

    testWidgets('a saving switch shows progress, announced as Saving and '
        'disabled', (tester) async {
      final handle = tester.ensureSemantics();
      final pending = Completer<identity.Profile>();
      when(
        () => identityRepo.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          readReceipts: any(named: 'readReceipts'),
        ),
      ).thenAnswer((_) => pending.future);
      await pump(
        tester,
        const MessageSettingsScreen(),
        authState: _signedIn('uid-a'),
        onboardingState: ready({kFeatureMessaging, kFeatureReadReceipts}),
        store: OwnPrivacyStore()..record(identity.Profile(userId: 'uid-a')),
      );
      await tester.tap(find.byType(ReadReceiptsRow));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(ReadReceiptsRow),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ReadReceiptsRow),
          matching: find.byType(Switch),
        ),
        findsNothing,
      );
      expect(
        tester.getSemantics(find.byType(ReadReceiptsRow)),
        isSemantics(value: 'Saving', isEnabled: false, hasEnabledState: true),
      );
      pending.complete(identity.Profile(userId: 'uid-a', readReceipts: true));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ReadReceiptsRow),
          matching: find.byType(Switch),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('UX 8 and 9: copy', () {
    test('read receipts and the F9 note', () {
      expect(
        kReadReceiptsSubtitle,
        "When off, you won't send or see read receipts. They only show when "
        'you both have them on.',
      );
      expect(
        kWhoCanMessageNote,
        "Conversations you've already accepted keep working either way.",
      );
    });
  });
}
