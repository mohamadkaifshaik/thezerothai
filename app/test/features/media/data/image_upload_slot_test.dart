import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/image_upload_slot.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/media_fixtures.dart';

/// The one upload helper behind the avatar and banner editors (W3-15): the
/// purpose is a parameter, the media id is remembered across retries and one
/// slot is always one single-item upload.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeImageProcessor processor;
  late MediaUploader uploader;

  ImageUploadSlot bannerSlot() => ImageUploadSlot(
    uploader: uploader,
    processor: processor,
    uploadPurpose: pb.MediaPurpose.MEDIA_PURPOSE_BANNER,
    imagePurpose: ImagePurpose.banner,
    jobId: 'banner',
  );

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
    final banner = bannerSlot();

    expect(banner.hasImage, isFalse);
    expect(banner.needsUpload, isFalse);
    expect(await banner.ensureUploaded(), isNull);
    verifyZeroInteractions(repo);
  });

  test(
    'choose prepares for the slot purpose and exposes the preview',
    () async {
      final banner = bannerSlot();

      await banner.choose(imageBytes('a'));

      expect(processor.purposes, [ImagePurpose.banner]);
      expect(banner.hasImage, isTrue);
      expect(banner.needsUpload, isTrue);
      expect(banner.preview, isNotNull);
    },
  );

  test('a file that cannot be used leaves the previous choice alone', () async {
    final banner = bannerSlot();
    await banner.choose(imageBytes('a'));
    final before = banner.preview;

    await expectLater(
      banner.choose(badBytes),
      throwsA(isA<UnsupportedImageException>()),
    );

    expect(banner.preview, same(before));
    expect(banner.needsUpload, isTrue);
  });

  test('uploads once with the slot purpose and exactly one item, then '
      'remembers the media id', () async {
    stubHappyUpload(repo);
    final banner = bannerSlot();
    await banner.choose(imageBytes('a'));

    expect(await banner.ensureUploaded(), 'm1');
    expect(await banner.ensureUploaded(), 'm1');

    expect(banner.needsUpload, isFalse);
    final captured = verify(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: captureAny(named: 'purpose'),
        images: captureAny(named: 'images'),
      ),
    ).captured;
    expect(captured, hasLength(2)); // one call: purpose + images
    expect(captured[0], pb.MediaPurpose.MEDIA_PURPOSE_BANNER);
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
    final banner = bannerSlot();
    await banner.choose(imageBytes('a'));
    expect(await banner.ensureUploaded(), 'm1');

    await banner.choose(imageBytes('b'));

    expect(banner.needsUpload, isTrue);
    expect(await banner.ensureUploaded(), 'm2');
  });

  test('a refused image is discarded and explains itself', () async {
    stubHappyUpload(repo, result: (id) => rejectedResult(id, 'Not allowed'));
    final banner = bannerSlot();
    await banner.choose(imageBytes('a'));

    await expectLater(
      banner.ensureUploaded(),
      throwsA(
        isA<ValidationException>()
            .having((e) => e.field, 'field', 'media')
            .having((e) => e.message, 'message', 'Not allowed'),
      ),
    );

    expect(banner.hasImage, isFalse);
  });

  test('a failed upload keeps the choice for a retry', () async {
    when(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: any(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).thenThrow(const NetworkException('offline'));
    final banner = bannerSlot();
    await banner.choose(imageBytes('a'));

    await expectLater(
      banner.ensureUploaded(),
      throwsA(isA<NetworkException>()),
    );

    expect(banner.hasImage, isTrue);
    expect(banner.needsUpload, isTrue);
  });

  test('discard forgets the choice', () async {
    final banner = bannerSlot();
    await banner.choose(imageBytes('a'));

    banner.discard();

    expect(banner.hasImage, isFalse);
    expect(banner.preview, isNull);
  });

  test('an avatar slot and a banner slot share one uploader without '
      'clashing', () async {
    stubHappyUpload(repo);
    final avatar = avatarSlot();
    final banner = bannerSlot();
    await avatar.choose(imageBytes('a'));
    await banner.choose(imageBytes('b'));

    expect(await avatar.ensureUploaded(), 'm1');
    expect(await banner.ensureUploaded(), 'm2');

    final purposes = verify(
      () => repo.createUpload(
        idempotencyKey: any(named: 'idempotencyKey'),
        purpose: captureAny(named: 'purpose'),
        images: any(named: 'images'),
      ),
    ).captured;
    expect(purposes, [
      pb.MediaPurpose.MEDIA_PURPOSE_AVATAR,
      pb.MediaPurpose.MEDIA_PURPOSE_BANNER,
    ]);
    expect(processor.purposes, [ImagePurpose.avatar, ImagePurpose.banner]);
  });
}
