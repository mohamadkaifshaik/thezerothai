import 'dart:convert';

/// Reads, synchronously, the uid of the account the app's session belongs to
/// (null when signed out, or before the auth state is known).
///
/// Wired in `bootstrap.dart` to the auth bloc's user: the session the app has
/// processed, not the auth SDK's current user, which switches first.
typedef SessionUidReader = String? Function();

/// A request was refused before it was sent: the signed-in account changed
/// (or signed out) while it waited for its tokens, or the ID token belongs to
/// another account than the one the request was built for.
///
/// Thrown by the `ApiClient` interceptors; `mapConnectError` turns it into an
/// [UnauthenticatedException] (the "session ended" type callers already
/// handle). Never retried: nothing reached the server.
final class RequestSessionChangedException implements Exception {
  const RequestSessionChangedException();

  @override
  String toString() => 'RequestSessionChangedException';
}

/// The account a Firebase ID token was minted for (`sub`, else `user_id`),
/// read from its payload WITHOUT verifying it: the server verifies the token;
/// this only tells the client whose token it holds. Null when the token is
/// not a readable JWT.
String? idTokenUid(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is! Map) return null;
    final uid = payload['sub'] ?? payload['user_id'];
    return uid is String && uid.isNotEmpty ? uid : null;
  } on FormatException {
    return null;
  }
}
