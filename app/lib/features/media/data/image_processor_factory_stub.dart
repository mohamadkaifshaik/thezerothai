import '../domain/image_processor.dart';

/// Android, iOS and desktop: `package:image` in a background isolate.
ImageProcessor createPlatformImageProcessor() => const IsolateImageProcessor();
