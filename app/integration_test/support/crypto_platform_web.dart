import 'dart:js_interop';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/web_crypto_engine.dart';

import 'vectors_port.dart';

@JS('crossOriginIsolated')
external bool get _crossOriginIsolated;

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSString> text();
}

/// The vectors file the driver serves on 127.0.0.1:[vectorsPort].
Future<String> loadVectorsText() async {
  final response = await _fetch('http://127.0.0.1:$vectorsPort/vectors-v1.json')
      .toDart;
  if (!response.ok) throw StateError('the driver did not serve the vectors');
  return (await response.text().toDart).toDart;
}

/// Stops the engine's worker.
void closeEngine(CryptoEngine engine) => (engine as WebCryptoEngine).close();

/// Whether the page is cross-origin isolated; null off the web.
bool? get crossOriginIsolated => _crossOriginIsolated;
