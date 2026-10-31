import 'dart:typed_data';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';

/// The GIF side of the attachments cubit (W6-16, ADR-0029): one GIF, never
/// with photos, checked on the device, uploaded unchanged.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeImagePicker picker;
  late FakeGifSource source;
  late FakeGifPreparer preparer;
  late AttachmentsCubit cubit;

  setUp(() {
    repo = MockMediaRepository();
    picker = FakeImagePicker();
    source = FakeGifSource();
    preparer = FakeGifPreparer();
    cubit = AttachmentsCubit(
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: repo),
      gifSource: source,
      gifPreparer: preparer,
    );
  });

  tearDown(() => cubit.close());

  Uint8List gif(String tag) => imageBytes(tag);

  test('a picked GIF becomes one ready GIF attachment', () async {
    source.next = gif('a');

    await cubit.pickGif();

    expect(cubit.state.count, 1);
    final a = cubit.state.items.single;
    expect(a.isGif, isTrue);
    expect(a.kind, AttachmentKind.gif);
    expect(a.status, AttachmentStatus.ready);
    expect(a.previewBytes, isNotNull, reason: 'the still thumbnail');
    expect(cubit.state.hasGif, isTrue);
    expect(cubit.state.photoCount, 0);
    expect(cubit.state.isSendable, isTrue);
  });

  test('cancelling the picker adds nothing', () async {
    await cubit.pickGif();
    expect(cubit.state.isEmpty, isTrue);
    expect(cubit.state.refusal, isNull);
  });

  test('a picker failure is reported once', () async {
    source.failWith = StateError('denied');
    await cubit.pickGif();
    expect(cubit.state.pickFailed, isTrue);
    cubit.pickFailureShown();
    expect(cubit.state.pickFailed, isFalse);
  });

  test('a refused GIF is not attached and says why, once', () async {
    source.next = badBytes;
    preparer.refusal = GifRefusedException.tooBig;

    await cubit.pickGif();

    expect(cubit.state.isEmpty, isTrue);
    expect(cubit.state.refusal, 'GIFs can be up to 2 MB.');
    cubit.refusalShown();
    expect(cubit.state.refusal, isNull);
  });

  test('anything attached blocks a GIF; a GIF blocks photos', () async {
    picker.next = [imageBytes('p')];
    await cubit.pick();
    source.next = gif('a');
    await cubit.pickGif();
    expect(source.calls, 0, reason: 'the picker is not even opened');
    expect(cubit.state.hasGif, isFalse);

    cubit.remove(cubit.state.items.single.id);
    source.next = gif('a');
    await cubit.pickGif();
    expect(cubit.state.hasGif, isTrue);

    picker.next = [imageBytes('p')];
    picker.calls = 0;
    await cubit.pick();
    expect(picker.calls, 0);
    expect(cubit.state.count, 1);
    expect(cubit.state.isFull, isFalse, reason: 'photos are counted apart');
  });

  test('alt text works as for photos', () async {
    source.next = gif('a');
    await cubit.pickGif();
    cubit.setAltText(cubit.state.items.single.id, ' a dancing cat ');
    expect(cubit.state.items.single.altText, 'a dancing cat');
  });

  test(
    'upload sends the GIF with image/gif and a JPEG thumbnail type',
    () async {
      stubHappyUpload(repo);
      source.next = gif('a');
      await cubit.pickGif();

      final uploaded = await cubit.uploadAll();

      expect(uploaded.mediaIds, ['m1']);
      final sent =
          verify(
                () => repo.createUpload(
                  idempotencyKey: any(named: 'idempotencyKey'),
                  purpose: any(named: 'purpose'),
                  images: captureAny(named: 'images'),
                ),
              ).captured.single
              as List;
      final image = sent.single as dynamic;
      expect(image.contentType, 'image/gif');
      expect(image.thumbContentType, 'image/jpeg');
      expect(cubit.state.items.single.status, AttachmentStatus.uploaded);
    },
  );

  test(
    'a GIF the server rejects keeps the server reason on the tile',
    () async {
      stubHappyUpload(repo, result: (id) => rejectedGif(id));
      source.next = gif('a');
      await cubit.pickGif();

      await expectLater(
        cubit.uploadAll(),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'This GIF is too large or too long.',
          ),
        ),
      );

      final tile = cubit.state.items.single;
      expect(tile.status, AttachmentStatus.rejected);
      expect(tile.rejectionReason, 'This GIF is too large or too long.');
    },
  );

  test('every server reason is shown as the server wrote it', () async {
    for (final reason in [
      'This image could not be used. Please choose a different one.',
      "This image can't be used because it may break the community rules.",
      'Image uploads are temporarily limited. Please try again later.',
    ]) {
      final r = MockMediaRepository();
      stubHappyUpload(r, result: (id) => rejectedGif(id, reason));
      final c = AttachmentsCubit(
        picker: picker,
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: r),
        gifSource: source,
        gifPreparer: preparer,
      );
      source.next = gif('a');
      await c.pickGif();
      await expectLater(c.uploadAll(), throwsA(isA<ValidationException>()));
      expect(c.state.items.single.rejectionReason, reason);
      await c.close();
    }
  });
}
