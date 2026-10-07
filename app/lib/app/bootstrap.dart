import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/network/api_client.dart';
import '../core/network/firebase_app_check_token_provider.dart';
import '../core/storage/app_database.dart';
import '../features/account/data/account_repository.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/domain/app_user.dart';
import '../features/auth/presentation/bloc/auth_bloc.dart';
import '../features/auth/presentation/bloc/auth_event.dart';
import '../features/auth/presentation/bloc/auth_state.dart';
import '../features/graph/data/graph_repository.dart';
import '../features/onboarding/data/identity_repository.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../features/onboarding/presentation/bloc/onboarding_event.dart';
import '../features/posts/data/posts_repository.dart';
import '../features/timeline/data/timeline_repository.dart';
import '../features/timeline/data/timeline_store.dart';
import '../firebase_options.dart' as dev_firebase;
import '../firebase_options_prod.dart' as prod_firebase;
import 'app_config.dart';
import 'app_widget.dart';
import 'session_wiring.dart';

/// Entry point for every flavor/target. Initializes Firebase + App Check,
/// wires the API client and repositories, bridges `AuthBloc` state into
/// `OnboardingBloc`, and runs the app — or a friendly error screen if the
/// build's dart-defines are invalid. The Firebase project is chosen by
/// `--dart-define=FIREBASE_ENV=dev|prod` (default dev).
Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppConfig config;
  try {
    config = AppConfig.fromEnvironment();
  } on AppConfigError catch (e) {
    // Fail loudly but legibly: a release mobile build with no API_BASE_URL
    // dart-define is a broken CI/release configuration, not a runtime
    // condition a user can work around.
    runApp(_ConfigErrorApp(message: e.message));
    return;
  }

  await Firebase.initializeApp(
    options: switch (config.firebaseEnv) {
      FirebaseEnv.dev => dev_firebase.DefaultFirebaseOptions.currentPlatform,
      FirebaseEnv.prod => prod_firebase.DefaultFirebaseOptions.currentPlatform,
    },
  );

  if (config.useEmulators) {
    await fb_auth.FirebaseAuth.instance.useAuthEmulator(
      _emulatorHost(config.authEmulatorHost),
      _emulatorPort(config.authEmulatorHost),
    );
  }

  await _activateAppCheck(config);

  final authRepository = AuthRepository(
    googleWebClientId: config.googleWebClientId,
    appleServiceId: config.appleServiceId,
    appleRedirectUri: config.appleRedirectUri,
  );
  final apiClient = ApiClient(
    baseUrl: config.apiBaseUrl,
    authTokens: authRepository,
    appCheckTokens: const FirebaseAppCheckTokenProvider(),
  );
  final database = AppDatabase();
  final identityRepository = IdentityRepository(
    apiClient: apiClient,
    database: database,
  );
  final graphRepository = GraphRepository(
    apiClient: apiClient,
    database: database,
  );
  // Warm the in-memory relationship cache from the caller's cached
  // `following` set before the first frame, so FollowButton can render
  // "Following" instantly on a warm start (CLAUDE.md prime directive).
  await graphRepository.primeFromDatabase();

  final authBloc = AuthBloc(authRepository: authRepository)
    ..add(const AuthSubscriptionRequested());
  final onboardingBloc = OnboardingBloc(identityRepository: identityRepository);

  // Posts + timeline (ADR-0010): the gate reads `GetMe.enabled_features` via
  // OnboardingBloc (0 extra reads) and remembers FEATURE_DISABLED answers
  // until the next GetMe changes the flag set.
  final postsGate = buildPostsGate(onboardingBloc);
  final timelineStore = TimelineStore(database);
  final postsRepository = PostsRepository(
    apiClient: apiClient,
    store: timelineStore,
    gate: postsGate,
  );
  final timelineRepository = TimelineRepository(
    apiClient: apiClient,
    store: timelineStore,
    gate: postsGate,
  );

  // Bridge: OnboardingBloc reacts to sign-in/sign-out, but never talks to
  // AuthBloc directly (keeps the two features decoupled — see the
  // `flutter-feature` skill).
  AppUser? lastUser;
  authBloc.stream.listen((state) {
    final user = state.user;
    if (user == null && lastUser != null) {
      onboardingBloc.add(const OnboardingUserSignedOut());
      // Wipe the local cache so the next user on a shared device never sees
      // a stale profile or relationship (privacy: CLAUDE.md rule 10).
      unawaited(
        wipeSessionData(
          database: database,
          timelineRepository: timelineRepository,
        ),
      );
      graphRepository.clearCache();
    } else if (user != null &&
        state.status == AuthStatus.authenticated &&
        user.uid != lastUser?.uid) {
      onboardingBloc.add(OnboardingUserAuthenticated(user));
    }
    lastUser = user;
  });
  if (authBloc.state.isAuthenticated) {
    onboardingBloc.add(OnboardingUserAuthenticated(authBloc.state.user!));
  }

  runApp(
    AppWidget(
      authBloc: authBloc,
      onboardingBloc: onboardingBloc,
      identityRepository: identityRepository,
      graphRepository: graphRepository,
      accountRepository: AccountRepository(apiClient: apiClient),
      authRepository: authRepository,
      database: database,
      postsRepository: postsRepository,
      timelineRepository: timelineRepository,
      postsGate: postsGate,
    ),
  );
}

/// Activates App Check, but never lets it block startup.
///
/// On web, App Check needs a reCAPTCHA Enterprise (Google Cloud Fraud Defense)
/// site key: without one there is no valid provider, and the Firebase JS SDK
/// throws from `initializeAppCheck`. Uncaught, that happens before `runApp`
/// and leaves a white screen. Web App Check is deferred at Stage 0 (ADR-0006
/// amendment: Classic keys are gone, and Enterprise is a flat $8/month past 10k
/// assessments), so web skips it while `RECAPTCHA_SITE_KEY` is empty. Any
/// activation failure is logged and startup continues: the API runs App Check
/// in monitor mode, and `AuthHeadersInterceptor` already sends no App Check
/// header when no token is available.
Future<void> _activateAppCheck(AppConfig config) async {
  if (kIsWeb && config.recaptchaSiteKey.isEmpty) {
    debugPrint('App Check: no RECAPTCHA_SITE_KEY, skipping on web.');
    return;
  }
  final debugToken = config.appCheckDebugToken.isEmpty
      ? null
      : config.appCheckDebugToken;
  try {
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? AndroidDebugProvider(debugToken: debugToken)
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? AppleDebugProvider(debugToken: debugToken)
          : const AppleAppAttestProvider(),
      providerWeb: config.recaptchaSiteKey.isEmpty
          ? null
          : ReCaptchaEnterpriseProvider(config.recaptchaSiteKey),
    );
  } catch (e) {
    debugPrint('App Check activation failed; continuing without it: $e');
  }
}

String _emulatorHost(String hostAndPort) => hostAndPort.split(':').first;

int _emulatorPort(String hostAndPort) {
  final parts = hostAndPort.split(':');
  return parts.length > 1 ? int.tryParse(parts[1]) ?? 9099 : 9099;
}

class _ConfigErrorApp extends StatelessWidget {
  const _ConfigErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 40),
                const SizedBox(height: 16),
                Text(
                  'Configuration error:\n\n$message',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
