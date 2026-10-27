import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cache manager whose every download fails, for widget tests of images that
/// may be missing (a removed or replaced avatar or banner, ADR-0024 Amendment 1
/// A4). By default it fails the way the media bucket does for a missing
/// object: `HttpExceptionWithStatus` 404 (a listing is 401 or 403, and an
/// object GET never is). A widget test cannot load a real network image (every
/// request answers 400 and the default manager needs platform plugins), and
/// `AppAvatar` and `ProfileCoverBand` build `CachedNetworkImageProvider`s that
/// take this manager, so no production seam is needed.
///
/// [requested] lists every URL asked for, in order, so a test can tell a
/// retry from a rebuild.
class FailingImageCacheManager extends Fake implements BaseCacheManager {
  FailingImageCacheManager({this.statusCode = 404, this.error});

  /// The HTTP status the fake download fails with.
  final int statusCode;

  /// Fails with this instead of an HTTP status (a web loader reports none).
  final Object? error;

  final List<String> requested = [];

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    requested.add(url);
    return Stream<FileResponse>.error(
      error ??
          HttpExceptionWithStatus(
            statusCode,
            'Invalid statusCode: $statusCode',
            uri: Uri.parse(url),
          ),
    );
  }
}

/// Makes every `CachedNetworkImage` and `CachedNetworkImageProvider` without
/// its own manager fail with [manager], for the rest of the test (the previous
/// manager comes back afterwards). Call it first in the test body or `setUp`.
FailingImageCacheManager useFailingImageCache({
  FailingImageCacheManager? manager,
}) {
  final failing = manager ?? FailingImageCacheManager();
  final previous = CachedNetworkImageProvider.defaultCacheManager;
  CachedNetworkImageProvider.defaultCacheManager = failing;
  addTearDown(() => CachedNetworkImageProvider.defaultCacheManager = previous);
  return failing;
}
