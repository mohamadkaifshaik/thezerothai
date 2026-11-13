import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/image_upload_slot.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';

/// The one upload helper behind the avatar and slot editors: the
/// purpose is a parameter, the media id is remembered across retries and one
/// slot is always one single-item upload.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeImageProcessor processor;
  late MediaUploader uploader;

  ImageUploadSlot avatarSlot() => ImageUploadSlot(
    uploader: uploader,
    processor: processor,
    uploadPurpose: pb.MediaPurpose.MEDIA_PURPOSE_AVATAR,
    imagePurpose: ImagePurpose.avatar,
    jobId: 'avatar',
  );

  setUp(() {
    repo = MockMediaRepository();
    processor = FakeImageProcessor();
    uploader = MediaUploader(repository: repo);
  });

  test('nothing chosen: nothing to upload, no calls', () async {
    final slot = avatarSlot();

    expect(slot.hasImage, isFalse);
    expect(slot.needsUpload, isFalse);
    expect(await slot.ensureUploaded(), isNull);
    verifyZeroInteractions(repo);
  });

  test(
    'choose prepares for the slot purpose and exposes the preview',
    () async {
      final slot = avatarSlot();

      await slot.choose(imageBytes('a'));

      expect(processor.purposes, [ImagePurpose.avatar]);
      expect(slot.hasImage, isTrue);
      expect(slot.needsUpload, isTrue);
      expect(slot.preview, isNotNull);
    },
  );

  test('a file that cannot be used leaves the previous choice alone', () async {
    final slot = avatarSlot();
    await slot.choose(imageBytes('a'));
    final before = slot.preview;

    await expectLater(
      slot.choose(badBytes),
      throwsA(isA<UnsupportedImageException>()),
    );

    expect(slot.preview, same(before));
    expect(slot.needsUpload, isTrue);
  });

  test('uploads once with the slot purpose and exactly one item, then '
      'remembers the media id', () async {
    stubHappyUpload(repo);
    final slot = avatarSlot();
    await slot.choose(imageBytes('a'));

    expect(await slot.ensureUploaded(), 'm1');
    expect(await slot.ensureUploaded(), 'm1');

    expect(slot.needsUpload, isFalse);
    final captured = verify(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: captureAny(named: 'purpose'),
        images: captureAny(named: 'images'),
      ),
    ).captured;
    expect(captured, hasLength(2)); // one call: purpose + images
    expect(captured[0], pb.MediaPurpose.MEDIA_PURPOSE_AVATAR);
    expect(captured[1] as List<ProcessedImage>, hasLength(1));
    verify(() => repo.putObject(any(), any())).called(2); // full + thumb
    verify(
      () => repo.finalizeUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        items: any(named: 'items'),
      ),
    ).called(1);
  });

  test('a new choice forgets the old media id and uploads again', () async {
    stubHappyUpload(repo);
    final slot = avatarSlot();
    await slot.choose(imageBytes('a'));
    expect(await slot.ensureUploaded(), 'm1');

    await slot.choose(imageBytes('b'));

    expect(slot.needsUpload, isTrue);
    expect(await slot.ensureUploaded(), 'm2');
  });

  test('a refused image is discarded and explains itself', () async {
    stubHappyUpload(repo, result: (id) => rejectedResult(id, 'Not allowed'));
    final slot = avatarSlot();
    await slot.choose(imageBytes('a'));

    await expectLater(
      slot.ensureUploaded(),
      throwsA(
        isA<ValidationException>()
            .having((e) => e.field, 'field', 'media')
            .having((e) => e.message, 'message', 'Not allowed'),
      ),
    );

    expect(slot.hasImage, isFalse);
  });

  test('a failed upload keeps the choice for a retry', () async {
    when(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenThrow(const NetworkException('offline'));
    final slot = avatarSlot();
    await slot.choose(imageBytes('a'));

    await expectLater(slot.ensureUploaded(), throwsA(isA<NetworkException>()));

    expect(slot.hasImage, isTrue);
    expect(slot.needsUpload, isTrue);
  });

  test('discard forgets the choice', () async {
    final slot = avatarSlot();
    await slot.choose(imageBytes('a'));

    slot.discard();

    expect(slot.hasImage, isFalse);
    expect(slot.preview, isNull);
  });
}
