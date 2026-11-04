import 'package:connectrpc/connect.dart' as connect;
import 'package:flutter/foundation.dart';

import '../network/connect_error_mapper.dart' show findErrorDetail;
import 'crash_scrubber.dart';

/// What leaves the device for one error. The SDK reads the
/// error's `toString()` as the report title, so we hand it this object, never
/// the original: its text is exactly [type], or `type: message` for an
/// allowlisted type after [CrashScrubber].
@immutable
class CrashPayload {
  const CrashPayload(this.type, [this.message]);

  /// The error's type name. Always sent.
  final String type;

  /// Scrubbed and cut; null unless the type is allowlisted.
  final String? message;

  @override
  String toString() =>
      message == null || message!.isEmpty ? type : '$type: $message';
}

/// Builds the [CrashPayload] for [error]. Never throws.
CrashPayload crashPayloadFor(Object error) {
  try {
    if (error is FlutterErrorDetails) return crashPayloadFor(error.exception);
    final type = error.runtimeType.toString();
    if (error is connect.ConnectException) {
      // Code and ErrorReason only: the message comes from the server.
      final reason = findErrorDetail(error)?.reason.name;
      return CrashPayload(
        type,
        reason == null ? error.code.name : '${error.code.name} $reason',
      );
    }
    final text = _allowlistedText(error);
    return CrashPayload(type, text == null ? null : CrashScrubber.scrub(text));
  } catch (_) {
    return const CrashPayload('Error');
  }
}

/// Code-generated types whose message holds no user data. A [FlutterError]
/// qualifies only for overflow and layout errors, and only its first line (the
/// summary): later lines dump widgets and render objects, which can hold text.
String? _allowlistedText(Object error) {
  // First: FlutterError implements AssertionError, so it must not fall into
  // the whole-message branch below.
  if (error is FlutterError) {
    final first = error.toString().split('\n').first;
    return _layoutSummary.hasMatch(first) ? first : null;
  }
  if (error is TypeError || error is AssertionError || error is StateError) {
    return error.toString();
  }
  return null;
}

final RegExp _layoutSummary = RegExp(
  r'overflowed by|not laid out|unbounded|BoxConstraints forces|layout',
  caseSensitive: false,
);
