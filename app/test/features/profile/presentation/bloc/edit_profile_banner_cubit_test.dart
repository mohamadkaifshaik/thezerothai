import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/profile_edit_fixtures.dart';

/// The banner flow of Edit profile (W3-15): pick, 3:1 prepare, upload on Save
/// (purpose BANNER, one item), UpdateProfile with the media id, Remove, and the
/// retry memory (media id and idempotency key survive a failed UpdateProfile).
void main() {
  setUpAll(registerMediaFallbacks);

  late FakeIdentityRepository repo;
  late MockMediaRepository media;
  late FakeImagePicker picker;
  late FakeImageProcessor processor;

  EditProfileCubit cubit({identity.Profile? initial, bool extras = true}) {
    repo = FakeIdentityRepository(initial ?? editableProfile());
    final c = EditProfileCubit(
      identityRepository: repo,
      initial: repo.profile,
      extrasEnabled: extras,
      picker: picker,
      processor: processor,
      uploader: MediaUploader(repository: media),
    );
    addTearDown(c.close);
    return c;
  }

  setUp(() {
    media = MockMediaRepository();
    picker = FakeImagePicker();
    processor = FakeImageProcessor();
    stubHappyUpload(media);
  });

  List<dynamic> createUploadCalls() => verify(
    () => media.createUpload(
      idempotencyKey: any(named: 'idempotencyKey'),
      purpose: captureAny(named: 'purpose'),
      images: captureAny(named: 'images'),
    ),
  ).captured;

  test('is available with media and the flag only', () {
    expect(cubit().canChangeBanner, isTrue);
    expect(cubit(extras: false).canChangeBanner, isFalse);
    final plain = EditProfileCubit(
      identityRepository: FakeIdentityRepository(editableProfile()),
      initial: editableProfile(),
      extrasEnabled: true,
    );
    addTearDown(plain.close);
    expect(plain.canChangeBanner, isFalse);
  });

  test('picking prepares a 3:1 preview and makes Save available', () async {
    picker.next = [imageBytes('a')];
    final c = cubit();

    await c.pickBanner();

    expect(processor.purposes, [ImagePurpose.banner]);
    expect(c.state.bannerPreview, isNotNull);
    expect(c.state.isPreparingBanner, isFalse);
    expect(c.isBannerChanged, isTrue);
    expect(c.canSave, isTrue);
    expect(picker.lastLimit, 1);
  });

  test('Save uploads a BANNER (one item) and sends its media id', () async {
    picker.next = [imageBytes('a')];
    final c = cubit();
    await c.pickBanner();

    await c.save();

    final captured = createUploadCalls();
    expect(captured[0], pb.MediaPurpose.MEDIA_PURPOSE_BANNER);
    expect(captured[1], hasLength(1));
    final call = repo.calls.single;
    expect(call.bannerMediaId, 'm1');
    expect(call.avatarMediaId, isNull);
    expect(call.displayName, isNull);
    expect(c.state.status, EditProfileStatus.saved);
    expect(c.state.saved!.bannerUrl, isNotEmpty);
  });

  test('a failed UpdateProfile retries with the same media id and key and '
      'never uploads again', () async {
    picker.next = [imageBytes('a')];
    final c = cubit();
    await c.pickBanner();
    repo.failures.add(const NetworkException('offline'));

    await c.save();
    expect(c.state.error, isA<NetworkException>());
    expect(c.state.status, EditProfileStatus.editing);
    expect(c.state.bannerPreview, isNotNull);
    await c.save();

    expect(repo.calls, hasLength(2));
    expect(repo.calls[1].bannerMediaId, 'm1');
    expect(repo.calls[1].idempotencyKey, repo.calls[0].idempotencyKey);
    createUploadCalls(); // verify() throws unless called; one upload only
    verify(() => media.putObject(any(), any())).called(2);
  });

  test('a different banner is a different request: a new key', () async {
    picker.next = [imageBytes('a')];
    final c = cubit();
    await c.pickBanner();
    repo.failures.add(const NetworkException('offline'));
    await c.save();

    picker.next = [imageBytes('b')];
    await c.pickBanner();
    await c.save();

    expect(repo.calls[1].bannerMediaId, 'm2');
    expect(repo.calls[1].idempotencyKey, isNot(repo.calls[0].idempotencyKey));
  });

  group('Remove', () {
    test(
      'with a saved banner it sends an empty media id (no upload)',
      () async {
        final c = cubit(initial: editableProfile(banner: true));

        c.removeBanner();
        expect(c.state.bannerRemoved, isTrue);
        expect(c.canSave, isTrue);
        await c.save();

        final call = repo.calls.single;
        expect(call.bannerMediaId, '');
        expect(call.location, isNull);
        verifyZeroInteractions(media);
        expect(c.state.saved!.bannerUrl, '');
      },
    );

    test('without a saved banner there is nothing to send', () {
      final c = cubit();

      c.removeBanner();

      expect(c.state.bannerRemoved, isFalse);
      expect(c.hasChanges, isFalse);
      expect(c.canSave, isFalse);
    });

    test(
      'after a pick it drops the pick; with a saved banner that removes it',
      () async {
        picker.next = [imageBytes('a')];
        final c = cubit(initial: editableProfile(banner: true));
        await c.pickBanner();

        c.removeBanner();

        expect(c.state.bannerPreview, isNull);
        expect(c.state.bannerRemoved, isTrue);
        await c.save();
        expect(repo.calls.single.bannerMediaId, '');
        verifyZeroInteractions(media);
      },
    );

    test('picking again after Remove replaces the removal', () async {
      picker.next = [imageBytes('a')];
      final c = cubit(initial: editableProfile(banner: true));
      c.removeBanner();

      await c.pickBanner();

      expect(c.state.bannerRemoved, isFalse);
      await c.save();
      expect(repo.calls.single.bannerMediaId, 'm1');
    });
  });

  group('failures', () {
    test(
      'an upload step MEDIA_NOT_READY is a retry, not a dropped banner',
      () async {
        when(
          () => media.finalizeUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            items: any(named: 'items'),
          ),
        ).thenThrow(const MediaNotReadyException('missing'));
        picker.next = [imageBytes('a')];
        final c = cubit();
        await c.pickBanner();

        await c.save();

        expect(c.state.bannerFailed, isTrue);
        expect(c.state.bannerDropped, isFalse);
        expect(c.state.bannerPreview, isNotNull);
        expect(repo.calls, isEmpty);
      },
    );

    test('a refused banner is discarded with the server reason', () async {
      stubHappyUpload(media, result: (id) => rejectedResult(id, 'Not allowed'));
      picker.next = [imageBytes('a')];
      final c = cubit();
      await c.pickBanner();

      await c.save();

      expect(c.state.bannerFailed, isTrue);
      expect((c.state.error as ValidationException).message, 'Not allowed');
      expect(c.state.bannerPreview, isNull);
      expect(c.canSave, isFalse);
    });

    test('an unusable file is reported for the banner', () async {
      picker.next = [badBytes];
      final c = cubit();

      await c.pickBanner();

      expect(c.state.bannerFailed, isTrue);
      expect(c.state.avatarFailed, isFalse);
      expect(c.state.isPreparingBanner, isFalse);
      expect(c.state.bannerPreview, isNull);
    });

    test('a picker failure is reported once and keeps the form', () async {
      picker.failWith = StateError('denied');
      final c = cubit();

      await c.pickBanner();

      expect(c.state.pickFailed, isTrue);
      expect(c.state.bannerFailed, isTrue);
    });
  });
}
