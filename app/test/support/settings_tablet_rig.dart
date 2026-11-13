import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/text_size_cubit.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/managed_accounts_screen.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/notification_settings_screen.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/profile/presentation/change_handle_screen.dart';
import 'package:dzeroth/features/settings/data/own_privacy_store.dart';
import 'package:dzeroth/features/settings/domain/settings_categories.dart';
import 'package:dzeroth/features/settings/presentation/message_settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/settings_up.dart';
import 'package:dzeroth/features/settings/presentation/widgets/settings_choice_row.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'fake_drafts_repository.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class SettingsRigIdentity extends Mock implements IdentityRepository {}

class _MockMessaging extends Mock implements MessagingRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// Records external links instead of opening them (no platform channel).
class FakeUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

/// The signed-in user's email (the static Email row).
const kSettingsRigEmail = 'alice@example.com';

/// Every flag a Settings row reads, plus the tablet shell's two: Edit
/// profile and Change handle (`profile_snapshot`), Blocked and Muted
/// (`graph`), Download my data and Delete account (`account_lifecycle`),
/// Scheduled posts (`posts` + `scheduled_posts`) and Protect posts
/// (`private_accounts`).
const kSettingsTabletFlags = <String>{
  'profile_snapshot',
  'graph',
  'account_lifecycle',
  'posts',
  'scheduled_posts',
  'private_accounts',
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The same without the two shell flags (legacy chrome, phone layout).
final kSettingsRowFlags = {...kSettingsTabletFlags}
  ..remove(kFeatureUiShell)
  ..remove(kFeatureUiTablet);

/// The Settings flag modes (tablet plan section 2.3): only `ui_shell` +
/// `ui_tablet` draws the tablet layout.
final kSettingsFlagModes = <String, Set<String>>{
  'neither': kSettingsRowFlags,
  'ui_shell only': {...kSettingsRowFlags, kFeatureUiShell},
  'ui_tablet only': {...kSettingsRowFlags, kFeatureUiTablet},
  'ui_shell + ui_tablet': kSettingsTabletFlags,
};

/// The stub leaves: an app bar with the Settings up button (as the real
/// AppBar leaves have) and a text field (state checks).
const kStubLeaves = <String>[
  AppRouter.editProfilePath,
  AppRouter.exportDataPath,
  AppRouter.deleteAccountPath,
];

/// The key of a stub leaf's text field.
Key stubLeafField(String path) => Key('field $path');

/// The real `MainShell` in a real `ShellRoute` around the real
/// `SettingsScreen` (with its `?c=` query), the real Blocked / Muted
/// accounts (`ManagedAccountsScreen`, an AppBar leaf) and Change handle (a
/// form-header leaf) over mocks, stub leaves for the rest, and a root-level
/// `/scheduled` stub (full screen, outside the shell, like the app's).
class SettingsTabletRig {
  late GoRouter router;

  /// The (mock) auth bloc, for `verify`.
  late AuthBloc auth;

  /// The (mock) onboarding bloc, for `verify` (flag refreshes).
  late OnboardingBloc onboarding;

  /// The (mock) identity repository: stub `updateProfile` before an R4
  /// save (read receipts, who can message).
  final identityRepository = SettingsRigIdentity();
  final launcher = FakeUrlLauncher();

  /// The location of the top page, query included (a pushed one too).
  Uri get uri => router.state.uri;

  Future<void> pump(
    WidgetTester tester, {
    String location = AppRouter.settingsPath,
    double width = 1024,
    double height = 900,
    Set<String> flags = kSettingsTabletFlags,
    String? email = kSettingsRigEmail,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TextDirection textDirection = TextDirection.ltr,
    EdgeInsets padding = EdgeInsets.zero,
    MessagingFeatureGate? messagingGate,
    FakeDraftsRepository? drafts,
    OwnPrivacyStore? ownPrivacy,
    TextSizeCubit? textSize,
    NotificationsRepository? notifications,
    PostsRepository? posts,
  }) async {
    UrlLauncherPlatform.instance = launcher;
    final onboarding = this.onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(
          userId: 'u-alice',
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );
    auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'u-alice',
          email: email,
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final graph = _MockGraph();
    for (final list in [graph.listBlockedUsers, graph.listMutedUsers]) {
      when(
        () => list(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));
    }
    when(() => graph.followRequestsUnavailable).thenReturn(false);
    when(() => identityRepository.privateAccountsRefused).thenReturn(false);
    when(() => identityRepository.checkHandleAvailability(any())).thenAnswer(
      (_) async => identity.CheckHandleAvailabilityResponse(available: true),
    );
    final messaging = _MockMessaging();
    if (messagingGate != null) {
      when(() => messaging.gate).thenReturn(messagingGate);
    }

    Widget stubLeaf(String path) => Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          leading: settingsUpButton(context, settingsUpLocation(path)),
          title: Text('leaf $path'),
        ),
        body: ListView(children: [TextField(key: stubLeafField(path))]),
      ),
    );

    router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: AppRouter.scheduledPostsPath,
          builder: (context, state) =>
              Scaffold(appBar: AppBar(title: const Text('Scheduled stub'))),
        ),
        ShellRoute(
          builder: (context, state, child) => MainShell(
            location: state.matchedLocation,
            uri: state.uri,
            child: child,
          ),
          routes: [
            GoRoute(
              path: AppRouter.homePath,
              builder: (context, state) =>
                  const Scaffold(body: Text('home body')),
            ),
            GoRoute(
              path: AppRouter.messagesPath,
              builder: (context, state) =>
                  const Scaffold(body: Text('inbox body')),
            ),
            GoRoute(
              path: AppRouter.settingsPath,
              builder: (context, state) => SettingsScreen(
                categoryId: state.uri.queryParameters[kSettingsCategoryParam],
              ),
            ),
            GoRoute(
              path: AppRouter.blockedAccountsPath,
              builder: (context, state) => const BlockedAccountsScreen(),
            ),
            GoRoute(
              path: AppRouter.mutedAccountsPath,
              builder: (context, state) => const MutedAccountsScreen(),
            ),
            GoRoute(
              path: AppRouter.changeHandlePath,
              builder: (context, state) => const ChangeHandleScreen(),
            ),
            for (final path in kStubLeaves)
              GoRoute(path: path, builder: (context, state) => stubLeaf(path)),
            // R4: the real leaves.
            GoRoute(
              path: AppRouter.notificationSettingsPath,
              builder: (context, state) => const NotificationSettingsScreen(),
            ),
            GoRoute(
              path: AppRouter.messageSettingsPath,
              builder: (context, state) => const MessageSettingsScreen(),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    Widget app = MultiBlocProvider(
      providers: [
        BlocProvider<OnboardingBloc>.value(value: onboarding),
        BlocProvider<AuthBloc>.value(value: auth),
        BlocProvider<UnreadBadgeCubit>.value(value: unread),
        BlocProvider<MessagesBadgeCubit>.value(value: messages),
        BlocProvider<ThemeModeCubit>(
          create: (_) => ThemeModeCubit(_MemoryThemeStore()),
        ),
        if (textSize != null)
          BlocProvider<TextSizeCubit>.value(value: textSize),
      ],
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<IdentityRepository>.value(
            value: identityRepository,
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          // The device's unsent posts (the Unsent posts row, and sign-out's
          // drafts question); none without it.
          if (drafts != null)
            RepositoryProvider<DraftsRepository>.value(value: drafts),
          if (ownPrivacy != null)
            RepositoryProvider<OwnPrivacyStore>.value(value: ownPrivacy),
          if (notifications != null)
            RepositoryProvider<NotificationsRepository>.value(
              value: notifications,
            ),
          if (posts != null)
            RepositoryProvider<PostsRepository>.value(value: posts),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(brightness: brightness),
          routerConfig: router,
          builder: (context, child) => Directionality(
            textDirection: textDirection,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                padding: padding,
                viewPadding: padding,
              ),
              // The app root's text size (F7): a no-op without a cubit.
              child: AppTextSizeScope(child: child!),
            ),
          ),
        ),
      ),
    );
    if (messagingGate != null) {
      app = RepositoryProvider<MessagingRepository>.value(
        value: messaging,
        child: app,
      );
    }
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  /// Resizes the window and settles.
  Future<void> resize(
    WidgetTester tester,
    double width, [
    double? height,
  ]) async {
    tester.view.physicalSize = Size(
      width,
      height ?? tester.view.physicalSize.height,
    );
    await tester.pumpAndSettle();
  }
}

/// The band B list pane (the shell's categories), or nothing.
Finder findCategoriesPane() => find.byType(SettingsCategoriesPane);

/// [finder] inside the list pane.
Finder inCategoriesPane(Finder finder) =>
    find.descendant(of: findCategoriesPane(), matching: finder);

/// [finder] inside the route child of `/settings` (the page, or band B's
/// detail), not in the list pane.
Finder inSettingsPage(Finder finder) =>
    find.descendant(of: find.byType(SettingsScreen), matching: finder);

/// The row titles under [scope], in order: the plain rows and the rows with
/// inline choices (Appearance, Text size).
List<String> settingsRowTitles(WidgetTester tester, Finder scope) => [
  for (final row in tester.widgetList(
    find.descendant(
      of: scope,
      matching: find.byWidgetPredicate(
        (w) => w is SettingsRow || w is SettingsChoiceRow,
      ),
    ),
  ))
    row is SettingsRow ? row.title : (row as SettingsChoiceRow).title,
];

/// The title of the selected row of the categories pane (band B and the
/// desktop master), or null.
String? selectedInCategoriesPane(WidgetTester tester) {
  for (final row in tester.widgetList<SettingsRow>(
    inCategoriesPane(find.byType(SettingsRow)),
  )) {
    if (row.selected) return row.title;
  }
  return null;
}
