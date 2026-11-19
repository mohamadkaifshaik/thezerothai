import '../features/auth/data/auth_repository.dart';

/// How long start-up waits for the auth SDK's first event.
const Duration kRestoredSessionTimeout = Duration(seconds: 5);

/// The uid the auth SDK restored from disk (null: signed out), and whether
/// that answer is [definitive]: it came from the SDK's first real auth event.
/// On the web the persisted user arrives with that event, so it is awaited
/// (briefly). When it does not arrive in time, or the stream fails, the
/// SDK's current user is used and the answer is NOT definitive: a null uid
/// may then only mean "not restored yet" (a late event is still handled by
/// the sign-in claim). The vault resolves pending sign-outs only on a
/// definitive answer.
Future<({String? uid, bool definitive})> readRestoredSession(
  AuthRepository authRepository, {
  Duration timeout = kRestoredSessionTimeout,
}) async {
  try {
    final user = await authRepository.authStateChanges().first.timeout(timeout);
    return (uid: user?.uid, definitive: true);
  } catch (_) {
    return (uid: authRepository.currentUser?.uid, definitive: false);
  }
}
