import 'package:logging/logging.dart';

import '../domain/image_processor.dart';
import '../domain/raster_image_processor.dart';
import 'worker_raster_codec_web.dart';

final _log = Logger('media.image_processor');

/// Web: decode/resize/encode in a Web Worker (app/web/image_worker.js), so
/// the UI keeps running while up to four photos are prepared. A browser
/// without `Worker` / `OffscreenCanvas` (or a worker that breaks the size
/// contract) falls back to `package:image`, which on the web runs on the main
/// thread.
ImageProcessor createPlatformImageProcessor() {
  if (!WorkerRasterCodec.available) return const IsolateImageProcessor();
  return FallbackImageProcessor(
    primary: const RasterImageProcessor(WorkerRasterCodec()),
    fallback: const IsolateImageProcessor(),
    onFallback: (reason) =>
        _log.warning('image worker unavailable, using package:image: $reason'),
  );
}
