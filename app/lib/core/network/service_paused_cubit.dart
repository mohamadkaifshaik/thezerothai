import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;

/// Whether the API is reachable (ADR-0022: the founder removes the public
/// invoker to pause, and Google's front end then answers HTTP 403).
enum ServicePauseStatus { running, paused, checking }

/// App-wide "the service is paused" flag. `ServicePausedInterceptor` calls
/// [markPaused]; the root shows `ServicePausedView` while it is not
/// [ServicePauseStatus.running]; Retry calls [recheck].
class ServicePausedCubit extends Cubit<ServicePauseStatus> {
  /// [probe] asks the API whether it is still paused (true) or answers again
  /// (false). Without one a re-check simply lifts the screen.
  ServicePausedCubit({Future<bool> Function()? probe})
    : _probe = probe,
      super(ServicePauseStatus.running);

  final Future<bool> Function()? _probe;

  void markPaused() {
    if (state == ServicePauseStatus.running) emit(ServicePauseStatus.paused);
  }

  /// Re-checks once. Still paused (or unreachable) keeps the screen; any other
  /// answer lifts it and the screens underneath load again as usual.
  Future<void> recheck() async {
    if (state != ServicePauseStatus.paused) return;
    emit(ServicePauseStatus.checking);
    var stillPaused = true;
    try {
      stillPaused = await (_probe?.call() ?? Future.value(false));
    } catch (_) {
      stillPaused = true;
    }
    if (isClosed) return;
    emit(stillPaused ? ServicePauseStatus.paused : ServicePauseStatus.running);
  }
}

/// The re-check probe: `GET <baseUrl>/health` (public, 0 Firestore reads).
/// Paused means HTTP 403 (what the front end answers); a network error is also
/// "still paused" because the screen is only lifted by a real answer.
Future<bool> probeServicePaused(
  http.Client client,
  String baseUrl, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    final response = await client
        .get(Uri.parse('$baseUrl/health'))
        .timeout(timeout);
    return response.statusCode == 403;
  } catch (_) {
    return true;
  }
}
