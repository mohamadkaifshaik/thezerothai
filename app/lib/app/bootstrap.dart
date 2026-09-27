import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/network/api_client.dart';
import '../core/network/firebase_app_check_token_provider.dart';
import '../core/storage/app_database.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/domain/app_user.dart';
import '../features/auth/presentation/bloc/auth_bloc.dart';
import '../features/auth/presentation/bloc/auth_event.dart';
import '../features/auth/presentation/bloc/auth_state.dart';
import '../features/onboarding/data/identity_repository.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../features/onboarding/presentation/bloc/onboarding_event.dart';
import '../firebase_options.dart';
import 'app_config.dart';
import 'app_widget.dart';

/// Entry point for every flavor/target. Initializes Firebase + App Check,
/// wires the API client and repositories, bridges `AuthBloc` state into
/// `OnboardingBloc`, and runs the app — or a friendly "not configured"
/// screen if `firebase_options.dart` is still the placeholder.
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

  if (!DefaultFirebaseOptions.isConfigured) {
    runApp(const _FirebaseNotConfiguredApp());
    return;
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (config.useEmulators) {
    await fb_auth.FirebaseAuth.instance.useAuthEmulator(
      _emulatorHost(config.authEmulatorHost),
      _emulatorPort(config.authEmulatorHost),
    );
  }

  final debugToken = config.appCheckDebugToken.isEmpty
      ? null
      : config.appCheckDebugToken;
  await FirebaseAppCheck.instance.activate(
    providerAndroid: kDebugMode
        ? AndroidDebugProvider(debugToken: debugToken)
        : const AndroidPlayIntegrityProvider(),
    providerApple: kDebugMode
        ? AppleDebugProvider(debugToken: debugToken)
        : const AppleAppAttestProvider(),
    providerWeb: config.recaptchaSiteKey.isEmpty
        ? null
        : ReCaptchaV3Provider(config.recaptchaSiteKey),
  );

  final authRepository = AuthRepository();
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

  final authBloc =
      AuthBloc(
          authRepository: authRepository,
          googleWebClientId: config.googleWebClientId,
          appleServiceId: config.appleServiceId,
          appleRedirectUri: config.appleRedirectUri,
        )
        ..add(const AuthSubscriptionRequested());
  final onboardingBloc = OnboardingBloc(identityRepository: identityRepository);

  // Bridge: OnboardingBloc reacts to sign-in/sign-out, but never talks to
  // AuthBloc directly (keeps the two features decoupled — see the
  // `flutter-feature` skill).
  AppUser? lastUser;
  authBloc.stream.listen((state) {
    final user = state.user;
    if (user == null && lastUser != null) {
      onboardingBloc.add(const OnboardingUserSignedOut());
      // Wipe the local cache so the next user on a shared device never sees
      // a stale profile (privacy: CLAUDE.md rule 10).
      unawaited(database.clearAll());
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

  runApp(AppWidget(authBloc: authBloc, onboardingBloc: onboardingBloc));
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

class _FirebaseNotConfiguredApp extends StatelessWidget {
  const _FirebaseNotConfiguredApp();

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
              children: const [
                Icon(Icons.settings_suggest_outlined, size: 40),
                SizedBox(height: 16),
                Text(
                  'Firebase is not configured yet.\n\n'
                  'Run `flutterfire configure` to generate '
                  'lib/firebase_options.dart, then restart the app.',
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
