import 'dart:async';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:http/http.dart' as http;

import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../../../gen/dzeroth/media/v1/media.pb.dart' as pb;
import '../../posts/domain/composer_attachment_rules.dart' show kFeatureGif;
import '../domain/media_feature_flag.dart';
import '../domain/processed_image.dart';

/// The server's name for the per-uid daily read budget. It covers every RPC
/// including media (ADR-0010 D5), so it is the one limit shared with the
/// read screens through [RateLimitHold].
const _kReadBudgetDaily = 'read_budget_daily';

/// Storage answered a signed-URL PUT with a 4xx: the URL is expired or
/// otherwise unusable, so retrying the same URL cannot work. The uploader
/// drops the URLs and re-signs them by replaying the same CreateUpload key.
class StorageRefusedException implements Exception {
  const StorageRefusedException(this.status);
  final int status;

  @override
  String toString() => 'StorageRefusedException($status)';
}

/// An item for FinalizeUpload.
class FinalizeRequestItem {
  const FinalizeRequestItem({required this.mediaId, required this.blurhash});
  final String mediaId;
  final String blurhash;
}

/// Talks to `MediaService` and PUTs bytes to the signed GCS URLs (bytes never
/// pass through the API, CLAUDE.md rule 7).
///
/// - With the media flag off no RPC is sent ([FeatureDisabledException]); a
///   server FEATURE_DISABLED calls [onFeatureDisabled] so the caller can
///   refresh `GetMe.enabled_features`.
/// - The daily read budget is shared with the timeline through the one
///   session [RateLimitHold]: a held limit is thrown without sending, and a
///   `read_budget_daily` answer is recorded (the short per-minute media
///   bucket is not: it must not freeze unrelated reads).
/// - The signed-URL PUT uses a bare [http.Client], never the API client, so
///   no Firebase ID token or App Check token reaches Cloud Storage.
class MediaRepository {
  MediaRepository({
    required ApiClient apiClient,
    required http.Client httpClient,
    required bool Function() isMediaEnabled,
    bool Function()? isGifEnabled,
    RateLimitHold? rateLimitHold,
    void Function()? onFeatureDisabled,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    Duration putTimeout = const Duration(minutes: 2),
  }) : _apiClient = apiClient,
       _http = httpClient,
       _isMediaEnabled = isMediaEnabled,
       _isGifEnabled = isGifEnabled ?? (() => true),
       _hold = rateLimitHold ?? RateLimitHold(),
       _onFeatureDisabled = onFeatureDisabled,
       _onUnexpectedError = onUnexpectedError,
       _putTimeout = putTimeout;

  final ApiClient _apiClient;
  final http.Client _http;
  final bool Function() _isMediaEnabled;

  /// `gif` in `GetMe.enabled_features` (a GIF upload needs it as well as
  /// `media`); the default keeps callers that never upload GIFs unchanged.
  final bool Function() _isGifEnabled;
  final RateLimitHold _hold;
  final void Function()? _onFeatureDisabled;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final Duration _putTimeout;

  Future<T> _run<T>(Future<T> Function() call) async {
    if (!_isMediaEnabled()) {
      throw const FeatureDisabledException(
        'Photos are not available.',
        feature: kFeatureMedia,
      );
    }
    final held = _hold.check();
    if (held != null) throw held;
    try {
      return await guardApiCall(call);
    } on RateLimitedException catch (error) {
      if (error.limitName == _kReadBudgetDaily) _hold.record(error);
      rethrow;
    } on FeatureDisabledException {
      _onFeatureDisabled?.call();
      rethrow;
    } on UnknownApiException catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      rethrow;
    }
  }

  /// Reserves media ids and signed PUT URLs for [images]. Reuse the same
  /// [idempotencyKey] when retrying the same call (the server replays the
  /// stored result and never charges the quota twice).
  Future<List<pb.UploadTarget>> createUpload({
    required String idempotencyKey,
    required pb.MediaPurpose purpose,
    required List<ProcessedImage> images,
  }) async {
    // With `gif` off no GIF RPC is sent (the server would answer
    // FEATURE_DISABLED feature=gif, 0 reads).
    if (images.any((i) => i.isGif) && !_isGifEnabled()) {
      throw const FeatureDisabledException(
        'GIFs are not available.',
        feature: kFeatureGif,
      );
    }
    final response = await _run(
      () => _apiClient.media.createUpload(
        pb.CreateUploadRequest(
          idempotencyKey: idempotencyKey,
          purpose: purpose,
          items: [
            for (final image in images)
              pb.UploadItem(
                contentType: image.contentType,
                fullSizeBytes: Int64(image.fullBytes.length),
                thumbSizeBytes: Int64(image.thumbBytes.length),
                width: image.width,
                height: image.height,
                fullMd5: image.fullMd5,
                thumbMd5: image.thumbMd5,
                // Empty for photos (= the full image's type); `image/jpeg`
                // for a GIF. The signed thumbnail URL pins it.
                thumbContentType: image.thumbContentType,
              ),
          ],
        ),
      ),
    );
    if (response.targets.length != images.length) {
      // Runs after [_run] returned, so report it here (once).
      const error = UnknownApiException('Unexpected upload response.');
      _onUnexpectedError?.call(error, StackTrace.current);
      throw error;
    }
    return response.targets;
  }

  /// PUTs [bytes] to [target] with exactly the headers the server signed.
  /// Network trouble is a [NetworkException]; a 4xx from storage (expired or
  /// altered upload) is a [StorageRefusedException]; a 5xx is an
  /// [UnknownApiException] (transient).
  Future<void> putObject(pb.SignedUpload target, Uint8List bytes) async {
    final request = http.Request('PUT', Uri.parse(target.url))
      ..headers.addAll(target.headers)
      ..bodyBytes = bytes;
    final int status;
    try {
      final response = await _http.send(request).timeout(_putTimeout);
      await response.stream.drain<void>();
      status = response.statusCode;
    } on TimeoutException {
      throw const NetworkException('The upload timed out.');
    } on Exception {
      throw const NetworkException('The upload could not reach the server.');
    }
    if (status >= 400 && status < 500) {
      // 403 is the normal "URL expired" answer; anything else 4xx is odd.
      if (status != 403) {
        _onUnexpectedError?.call(
          StorageRefusedException(status),
          StackTrace.current,
        );
      }
      throw StorageRefusedException(status);
    }
    if (status < 200 || status >= 300) {
      final error = UnknownApiException('Upload refused ($status).');
      _onUnexpectedError?.call(error, StackTrace.current);
      throw error;
    }
  }

  /// Verifies and moderates the uploaded objects; one result per item.
  Future<List<pb.MediaResult>> finalizeUpload({
    required String idempotencyKey,
    required List<FinalizeRequestItem> items,
  }) async {
    final response = await _run(
      () => _apiClient.media.finalizeUpload(
        pb.FinalizeUploadRequest(
          idempotencyKey: idempotencyKey,
          items: [
            for (final item in items)
              pb.FinalizeItem(mediaId: item.mediaId, blurhash: item.blurhash),
          ],
        ),
      ),
    );
    return response.results;
  }
}
