import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/raster_image_processor.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/raster_fakes.dart';

/// Fix round 1: photos are prepared one at a time, so a worker that never
/// answers must not freeze its tile, nor every photo after it.
void main() {
  setUpAll(registerMediaFallbacks);

  test('a hung worker times out: that photo falls back, the later photos '
      'go through a fresh worker', () {
    fakeAsync((async) {
      final codec = FakeRasterCodec(hangSessions: 1);
      final fallback = FakeImageProcessor();
      final cubit = AttachmentsCubit(
        picker: FakeImagePicker(),
        processor: FallbackImageProcessor(
          primary: RasterImageProcessor(codec),
          fallback: fallback,
        ),
        uploader: MediaUploader(repository: MockMediaRepository()),
      );
      var done = false;
      cubit
          .addImages([imageBytes('a'), imageBytes('b'), imageBytes('c')])
          .then((_) => done = true);
      async.flushMicrotasks();
      expect(
        [for (final a in cubit.state.items) a.status],
        [
          AttachmentStatus.processing,
          AttachmentStatus.processing,
          AttachmentStatus.processing,
        ],
      );

      async.elapse(kRasterStepTimeout + const Duration(seconds: 1));
      expect(done, isTrue);
      expect(
        [for (final a in cubit.state.items) a.status],
        [
          AttachmentStatus.ready,
          AttachmentStatus.ready,
          AttachmentStatus.ready,
        ],
      );
      // Photo 1 from package:image, photos 2 and 3 from new workers.
      expect(cubit.state.items.first.image!.fullMd5, 'full-a');
      expect(fallback.purposes, hasLength(1));
      expect(codec.opened, 3);
      cubit.close();
      async.flushMicrotasks();
    });
  });
}
