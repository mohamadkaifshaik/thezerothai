import 'package:firebase_auth/firebase_auth.dart' as fb_auth;

import 'app_config.dart';

/// Points [auth] at the Auth emulator named by [config], or does nothing when
/// emulators are off.
///
/// Fails closed: a malformed host or a failing `useAuthEmulator` (web
/// included) throws [AppConfigError] instead of letting sign-in continue
/// against the production Identity Toolkit. There is no silent default port
/// here; [AppConfig.resolveAuthEmulatorHost] already settled the host.
Future<void> configureAuthEmulator(
  fb_auth.FirebaseAuth auth,
  AppConfig config,
) async {
  if (!config.useEmulators) return;
  final parts = config.authEmulatorHost.split(':');
  final port = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (parts.first.isEmpty || port == null || port < 1 || port > 65535) {
    throw AppConfigError(
      'AUTH_EMULATOR_HOST "${config.authEmulatorHost}" is not host:port; '
      'refusing to sign in against production.',
    );
  }
  try {
    await auth.useAuthEmulator(parts.first, port);
  } catch (e) {
    throw AppConfigError(
      'Could not switch Auth to the emulator ($e); '
      'refusing to sign in against production.',
    );
  }
}
