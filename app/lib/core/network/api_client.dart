import 'package:connectrpc/connect.dart' as connect;
import 'package:connectrpc/protobuf.dart' show ProtoCodec;
import 'package:connectrpc/protocol/connect.dart' as protocol_connect;

import '../../gen/dzeroth/graph/v1/graph.connect.client.dart';
import '../../gen/dzeroth/identity/v1/identity.connect.client.dart';
import '../../gen/dzeroth/media/v1/media.connect.client.dart';
import '../../gen/dzeroth/posts/v1/posts.connect.client.dart';
import '../../gen/dzeroth/timeline/v1/timeline.connect.client.dart';
import 'app_exception.dart';
import 'auth_token_provider.dart';
import 'connect_error_mapper.dart';
import 'http_client_factory.dart';
import 'interceptors.dart';

/// Single Connect-RPC client for the whole app (CLAUDE.md: "one `ApiClient`
/// with Firebase ID token + App Check token, retry with backoff, request
/// IDs"). Feature repositories depend on this, never on `connectrpc` or
/// `dart:io`/`fetch` directly.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required AuthTokenProvider authTokens,
    required AppCheckTokenProvider appCheckTokens,
  }) : _transport = protocol_connect.Transport(
         baseUrl: baseUrl,
         codec: const ProtoCodec(),
         httpClient: createPlatformHttpClient(),
         interceptors: [
           const RequestMetadataInterceptor().call,
           AuthHeadersInterceptor(authTokens, appCheckTokens).call,
           const RetryInterceptor().call,
         ],
       );

  /// Test-only constructor that injects a pre-built transport (e.g. a fake
  /// or a transport pointed at the Firebase emulator/local API) instead of
  /// building the platform HTTP client.
  ApiClient.withTransport(connect.Transport transport) : _transport = transport;

  final connect.Transport _transport;

  late final identity = IdentityServiceClient(_transport);
  late final graph = GraphServiceClient(_transport);
  late final media = MediaServiceClient(_transport);
  late final posts = PostServiceClient(_transport);
  late final timeline = TimelineServiceClient(_transport);
}

/// Runs [call], converting any thrown error into a typed [AppException].
/// Every repository method that talks to the API should be wrapped in this.
Future<T> guardApiCall<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on AppException {
    rethrow;
  } catch (error) {
    throw mapConnectError(error);
  }
}
