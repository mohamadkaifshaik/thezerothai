//
//  Generated code. Do not modify.
//  source: dzeroth/media/v1/media.proto
//

import "package:connectrpc/connect.dart" as connect;
import "media.pb.dart" as dzerothmediav1media;
import "media.connect.spec.dart" as specs;

extension type MediaServiceClient (connect.Transport _transport) {
  /// Reserve 1-4 media ids and get signed PUT URLs (full + thumb each), 10-minute TTL, bound to the exact object
  /// path, Content-Type, Content-MD5 and x-goog-content-length-range (full <= 2 MiB, thumb <= 256 KiB).
  /// Quota: 20 media/day/user (quotas/{uid}). Rejected with DEGRADED_MODE when DEGRADED_MODE != off.
  /// Batch: Create idempotency doc + media docs (PENDING, expireAt = now + 2 d) + quotas.
  /// GCS: 0 ops here (signing uses IAM signBlob, no GCS call). Client PUTs = 2 Class A per image.
  /// Firestore: reads 2/1 (quotas + replay), writes 6/3 (1 image typical).
  Future<dzerothmediav1media.CreateUploadResponse> createUpload(
    dzerothmediav1media.CreateUploadRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MediaService.createUpload,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Verify and moderate uploaded objects, then publish. Per item: GCS object attrs + 512-byte ranged read
  /// (magic bytes) -> SafeSearch on the full image if the monthly Vision counter < 950 -> copy full+thumb to the
  /// public bucket -> READY; or REJECTED (objects deleted). Counter exhausted => READY_UNSCREENED (policy knob,
  /// ADR-0005). Naturally idempotent: items already READY/REJECTED are returned as-is.
  /// GCS per image: 2 Class A (copies) + 3 Class B (attrs, ranged read, Vision fetch); deletes are free.
  /// Firestore: reads 5/2 (media docs + Vision counter, cached 60 s), writes 5/2.
  Future<dzerothmediav1media.FinalizeUploadResponse> finalizeUpload(
    dzerothmediav1media.FinalizeUploadRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MediaService.finalizeUpload,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
