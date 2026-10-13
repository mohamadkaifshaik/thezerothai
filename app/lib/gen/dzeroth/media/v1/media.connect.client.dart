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
  /// (magic bytes) -> SafeSearch on every image while the monthly Vision counter is below VISION_MONTHLY_CAP
  /// (default 10,000, ADR-0005 amendment; the full image, plus the thumbnail when VISION_SCREEN_THUMB is on, the
  /// default) -> copy full+thumb to the public bucket -> READY; or REJECTED (objects deleted). Counter exhausted =>
  /// READY_UNSCREENED for accounts older than 7 days and REJECTED for newer ones, or REJECTED for everyone when
  /// VISION_EXHAUSTED_POLICY=reject (ADR-0005). Naturally idempotent: items already READY/REJECTED are returned as-is.
  /// GCS per image: 2 Class A (copies) + 4 Class B (attrs and a ranged read of the full image and of the
  /// thumbnail) + 1-2 Vision fetches; deletes are free.
  /// Firestore: reads 2n+1 worst case (n media docs, Vision counter cached 60 s, +1 per item when the upload
  /// is missing, screening fails or a concurrent finalize race is lost), plus 1 interceptor read; writes n+1.
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
