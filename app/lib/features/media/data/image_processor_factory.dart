// The app's default ImageProcessor: package:image in an isolate off the
// web; on the web, the worker-backed RasterImageProcessor (falling back to
// package:image when the browser cannot run it).
export 'image_processor_factory_stub.dart'
    if (dart.library.js_interop) 'image_processor_factory_web.dart';
