import 'package:connectrpc/connect.dart' as connect;

/// A fake [connect.Transport] for repository tests: routes every unary call
/// to [handler] by RPC procedure name (e.g. `/dzeroth.graph.v1.GraphService/
/// Follow`), so a repository can be exercised through a real
/// `ApiClient.withTransport(...)` without a network or the emulators.
///
/// [handler] returns the decoded response message, or throws (typically a
/// `connect.ConnectException`) to simulate a server error.
class FakeTransport implements connect.Transport {
  FakeTransport(this.handler);

  final Future<Object> Function(String procedure, Object input) handler;

  final List<String> calledProcedures = [];

  @override
  Future<connect.UnaryResponse<I, O>> unary<I extends Object, O extends Object>(
    connect.Spec<I, O> spec,
    I input, [
    connect.CallOptions? options,
  ]) async {
    calledProcedures.add(spec.procedure);
    final result = await handler(spec.procedure, input);
    return connect.UnaryResponse<I, O>(
      spec,
      connect.Headers(),
      result as O,
      connect.Headers(),
    );
  }

  @override
  Future<connect.StreamResponse<I, O>> stream<
    I extends Object,
    O extends Object
  >(connect.Spec<I, O> spec, Stream<I> input, [connect.CallOptions? options]) {
    throw UnimplementedError('FakeTransport does not support streaming RPCs');
  }
}
