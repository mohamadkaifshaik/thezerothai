import 'package:firebase_app_check/firebase_app_check.dart';

import 'auth_token_provider.dart';

/// Thin adapter so `ApiClient` depends on [AppCheckTokenProvider], not on
/// `firebase_app_check` directly.
class FirebaseAppCheckTokenProvider implements AppCheckTokenProvider {
  const FirebaseAppCheckTokenProvider();

  @override
  Future<String?> getAppCheckToken() => FirebaseAppCheck.instance.getToken();
}
