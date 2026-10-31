import 'dart:typed_data';

import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';

/// W6-19: the REAL `IsolateGifPreparer` (the `compute` path the fakes skip),
/// alone and under `AttachmentsCubit`. Plain `test()` so the isolate really
/// runs (the fake-async zone of `testWidgets` would not complete it).
void main() {
  setUpAll(registerMediaFallbacks);

  const preparer = IsolateGifPreparer();

  Uint8List padded(Uint8List base, int size) =>
      Uint8List(size)..setAll(0, base);

  test(
    'a real GIF comes back unchanged with a JPEG still, via compute',
    () async {
      final bytes = realGifBytes(width: 32, height: 24, frames: 3);

      final out = await preparer.prepare(bytes);

      expect(out.isGif, isTrue);
      expect(out.contentType, 'image/gif');
      expect(out.thumbContentType, 'image/jpeg');
      expect(out.fullBytes, bytes, reason: 're-encoding would drop the frames');
      expect(out.width, 32);
      expect(out.height, 24);
      // JPEG magic number: the thumbnail really is a still JPEG.
      expect(out.thumbBytes.take(3).toList(), [0xFF, 0xD8, 0xFF]);
      expect(out.blurhash, isNotEmpty);
    },
  );

  test('limits are enforced inside the isolate and keep their type', () async {
    // Too many frames and a too-wide screen are found by the decoder in the
    // isolate; the exception must cross the isolate boundary as itself.
    await expectLater(
      preparer.prepare(realGifBytes(width: 2, height: 2, frames: 301)),
      throwsA(GifRefusedException.tooLong),
    );
    await expectLater(
      preparer.prepare(realGifBytes(width: 1281, height: 2)),
      throwsA(GifRefusedException.tooLarge),
    );
    // A signature with a broken body.
    await expectLater(
      preparer.prepare(Uint8List.fromList('GIF89a'.codeUnits + [1, 2, 3])),
      throwsA(isA<GifRefusedException>()),
    );
  });

  test('size and signature are refused before any isolate is started', () {
    // `prepare` is not `async`, so these are thrown synchronously. Callers
    // must `await` inside a try (AttachmentsCubit does); a `.catchError` on
    // the returned future would miss them.
    final big = padded(realGifBytes(), kMaxGifBytes + 1);
    expect(() => preparer.prepare(big), throwsA(GifRefusedException.tooBig));
    expect(
      () => preparer.prepare(Uint8List.fromList([137, 80, 78, 71, 13, 10])),
      throwsA(GifRefusedException.notGif),
    );
    expect(
      () => preparer.prepare(Uint8List(0)),
      throwsA(GifRefusedException.notGif),
    );
  });

  group('under AttachmentsCubit with the real preparer', () {
    late FakeGifSource source;
    late AttachmentsCubit cubit;

    setUp(() {
      source = FakeGifSource();
      cubit = AttachmentsCubit(
        picker: FakeImagePicker(),
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: MockMediaRepository()),
        gifSource: source,
      );
    });

    tearDown(() => cubit.close());

    test(
      'the default preparer is the isolate one: a real GIF attaches',
      () async {
        source.next = realGifBytes(width: 16, height: 16, frames: 2);
        await cubit.pickGif();
        expect(cubit.state.hasGif, isTrue);
        expect(cubit.state.items.single.status, AttachmentStatus.ready);
        expect(cubit.state.refusal, isNull);
      },
    );

    test('over 2 MiB: the size message, nothing attached', () async {
      source.next = padded(realGifBytes(), kMaxGifBytes + 1);
      await cubit.pickGif();
      expect(cubit.state.refusal, GifRefusedException.tooBig.message);
      expect(cubit.state.items, isEmpty);
    });

    test('a PNG: "isn\'t a GIF", nothing attached', () async {
      source.next = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0]);
      await cubit.pickGif();
      expect(cubit.state.refusal, GifRefusedException.notGif.message);
      expect(cubit.state.items, isEmpty);
    });

    test('301 frames: the frame message, then another pick works', () async {
      source.next = realGifBytes(width: 2, height: 2, frames: 301);
      await cubit.pickGif();
      expect(cubit.state.refusal, GifRefusedException.tooLong.message);

      cubit.refusalShown();
      source.next = realGifBytes(width: 4, height: 4);
      await cubit.pickGif();
      expect(cubit.state.hasGif, isTrue);
    });
  });
}
