// File generated in the style of `flutterfire configure`.
//
// *** PLACEHOLDER — THIS FILE HAS NO REAL FIREBASE PROJECT CONFIG ***
//
// This app has not been wired to a Firebase project yet. Before running
// against anything other than the emulator suite, replace this file by
// running (one-time, per environment):
//
//   dart pub global activate flutterfire_cli
//   flutterfire configure --project=dzeroth-dev   # or dzeroth-prod
//
// That command overwrites this file with real, platform-specific
// `FirebaseOptions` (apiKey, appId, messagingSenderId, projectId, ...) for
// each configured platform and is safe to commit — these are public client
// identifiers, not secrets (see CLAUDE.md "No secrets in the app").
//
// Until then, `DefaultFirebaseOptions.isConfigured` is false and
// `app/lib/app/bootstrap.dart` shows a friendly "not configured" screen
// instead of crashing, so the app still builds, analyzes and runs its
// widget tests without a real project.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  const DefaultFirebaseOptions._();

  /// True once this file has been replaced by `flutterfire configure`.
  static const bool isConfigured = false;

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return web;
    }
  }

  static const web = FirebaseOptions(
    apiKey: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    appId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    messagingSenderId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    projectId: 'dzeroth-dev',
    authDomain: 'dzeroth-dev.firebaseapp.com',
    storageBucket: 'dzeroth-dev.appspot.com',
  );

  static const android = FirebaseOptions(
    apiKey: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    appId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    messagingSenderId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    projectId: 'dzeroth-dev',
    storageBucket: 'dzeroth-dev.appspot.com',
  );

  static const ios = FirebaseOptions(
    apiKey: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    appId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    messagingSenderId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    projectId: 'dzeroth-dev',
    storageBucket: 'dzeroth-dev.appspot.com',
    iosBundleId: 'com.dzeroth.app',
  );

  static const macos = FirebaseOptions(
    apiKey: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    appId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    messagingSenderId: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    projectId: 'dzeroth-dev',
    storageBucket: 'dzeroth-dev.appspot.com',
    iosBundleId: 'com.dzeroth.app',
  );
}
