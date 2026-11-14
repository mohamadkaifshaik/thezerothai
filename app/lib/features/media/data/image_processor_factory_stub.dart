import '../domain/image_processor.dart';

/// Android, iOS and desktop: `package:image` in a background isolate.
ImageProcessor createPlatformImageProcessor() => const IsolateImageProcessor();

/// The same: GIF first-frame thumbnails through `compute`, off the UI isolate.
GifPreparer createPlatformGifPreparer() => const IsolateGifPreparer();
