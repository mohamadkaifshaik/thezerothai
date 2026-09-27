import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_user.freezed.dart';

/// The subset of a signed-in Firebase user the rest of the app needs.
/// Deliberately not the raw `firebase_auth.User` so that presentation and
/// domain code never depend on the Firebase SDK directly (only
/// `features/auth/data` does).
@freezed
abstract class AppUser with _$AppUser {
  const factory AppUser({
    required String uid,
    required bool emailVerified,
    required bool isPasswordProvider,
    String? email,
    String? displayName,
  }) = _AppUser;
}
