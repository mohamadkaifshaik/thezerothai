import 'dart:async';

/// Lets the owner of an image job (the composer's `AttachmentsCubit`) stop
/// it: the user removed the photo or left the composer. A processor checks it
/// between steps and stops waiting the moment [cancel] is called; the web
/// worker is terminated, an isolate's result is dropped.
class ProcessingCancellation {
  final Completer<void> _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;

  /// Completes when [cancel] is called (never otherwise).
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Throws [ImageProcessingCancelled] once [cancel] was called.
  void throwIfCancelled() {
    if (isCancelled) throw const ImageProcessingCancelled();
  }

  /// [work], or [ImageProcessingCancelled] as soon as this is cancelled
  /// (whichever comes first; a later error of [work] is ignored).
  Future<T> guard<T>(Future<T> work) {
    throwIfCancelled();
    return Future.any<T>([
      work,
      whenCancelled.then<T>((_) => throw const ImageProcessingCancelled()),
    ]);
  }
}

/// The job was cancelled through its [ProcessingCancellation]; nothing is
/// shown for it (the tile is already gone).
class ImageProcessingCancelled implements Exception {
  const ImageProcessingCancelled();

  @override
  String toString() => 'Image processing cancelled.';
}
