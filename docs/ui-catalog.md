# UI catalog (Flutter). One line per reusable widget/provider/helper.

| Item | Location | Use it for |
|---|---|---|
| AppSpacing / AppRadius / AppBreakpoints | app/lib/core/theme/app_theme.dart | spacing, radius and responsive-breakpoint tokens — never hardcode sizes |
| appLightTheme / appDarkTheme / buildAppTheme | app/lib/core/theme/app_theme.dart | Material 3 ThemeData for MaterialApp.router |
| ResponsiveScaffold / AppNavDestination | app/lib/core/widgets/responsive_scaffold.dart | adaptive shell: bottom nav (phone) / rail (tablet) / rail + side column (desktop) |
| AppErrorView | app/lib/core/widgets/app_error_view.dart | typed, friendly rendering of an AppException (degraded mode, quota, rate limit, network, etc.) |
| SplashScreen | app/lib/core/widgets/splash_screen.dart | shown while the initial Firebase auth state is unknown |
| PrivacyPolicyLink / launchPrivacyPolicy / privacyPolicyUri | app/lib/core/widgets/privacy_policy_link.dart | the tappable "Privacy Policy" link (sign-up, sign-in, Settings) and the one place that resolves/opens its URL |
| AppException hierarchy | app/lib/core/network/app_exception.dart | typed domain errors every repository throws; branch on type, never on message text |
| mapConnectError | app/lib/core/network/connect_error_mapper.dart | converts a ConnectException (+ common.ErrorDetail) into an AppException |
| guardApiCall | app/lib/core/network/api_client.dart | wraps a repository's API call, converting thrown errors via mapConnectError |
| ApiClient | app/lib/core/network/api_client.dart | the one Connect-RPC client for the app (identity/graph/media/posts/timeline) |
| AuthTokenProvider / AppCheckTokenProvider | app/lib/core/network/auth_token_provider.dart | interfaces ApiClient depends on for the two auth headers, implemented by AuthRepository / FirebaseAppCheckTokenProvider |
| RequestMetadataInterceptor / AuthHeadersInterceptor / RetryInterceptor | app/lib/core/network/interceptors.dart | connect-dart interceptors: request id, ID token + App Check token, retry-with-backoff for side-effect-free RPCs |
| createPlatformHttpClient | app/lib/core/network/http_client_factory.dart | platform HttpClient for connect-dart transport (dart:io vs fetch) |
| AppDatabase / ProfileCacheEntries | app/lib/core/storage/app_database.dart | drift local cache (profile cache table today; add tables here, not a second database) |
| AppRouter | app/lib/core/router/app_router.dart | the app's single go_router instance + auth/onboarding redirect logic |
| MainShell | app/lib/core/router/main_shell.dart | bottom-nav/rail chrome around Home/Profile/Settings, used by AppRouter's ShellRoute |
| GoRouterRefreshStream | app/lib/core/router/go_router_refresh_stream.dart | turns bloc streams into a Listenable for go_router's refreshListenable |
| AppConfig | app/lib/app/app_config.dart | --dart-define environment config (API base URL, emulator flags, App Check keys) |
| AuthGate | app/lib/features/auth/presentation/widgets/auth_gate.dart | wraps protected routes; swaps in the email-verification prompt when needed |
| EmailPasswordForm | app/lib/features/auth/presentation/widgets/email_password_form.dart | shared email/password fields + validation for sign-in and sign-up |
| SocialSignInButtons | app/lib/features/auth/presentation/widgets/social_sign_in_buttons.dart | Google + (platform-gated) Apple sign-in buttons |
| VerifyEmailView | app/lib/features/auth/presentation/widgets/verify_email_view.dart | full-screen "verify your email" prompt (no dedicated route); reused by CreateProfileScreen (`banner`/`onBack`) for `ERROR_REASON_EMAIL_NOT_VERIFIED` from CreateProfile |
