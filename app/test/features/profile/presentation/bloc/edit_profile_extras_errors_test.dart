import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/features/profile/presentation/profile_edit_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/profile_edit_fixtures.dart';

/// What the server can answer to the extras (W3-6) and what Edit profile does
/// with each answer.
void main() {
  setUpAll(registerMediaFallbacks);

  late FakeIdentityRepository repo;
  late MockMediaRepository media;
  late FakeImagePicker picker;

  EditProfileCubit cubit() {
    repo = FakeIdentityRepository(editableProfile(location: 'Pune'));
    final c = EditProfileCubit(
      identityRepository: repo,
      initial: repo.profile,
      extrasEnabled: true,
      picker: picker,
      processor: FakeImageProcessor(),
      uploader: MediaUploader(repository: media),
    );
    addTearDown(c.close);
    return c;
  }

  const extrasOff = FeatureDisabledException(
    'off',
    feature: kFeatureProfileExtras,
  );

  setUp(() {
    media = MockMediaRepository();
    picker = FakeImagePicker();
    stubHappyUpload(media);
  });

  group('FEATURE_DISABLED profile_extras', () {
    test('on UpdateProfile: hides the extras, keeps the name edit, and the '
        'retry carries no extra', () async {
      final c = cubit();
      c.displayNameChanged('Kaif S');
      c.locationChanged('Mumbai');
      c.websiteChanged('https://example.com');
      repo.failures.add(extrasOff);

      await c.save();

      expect(c.state.extrasEnabled, isFalse);
      expect(c.state.extrasDisabled, isTrue);
      expect(
        editProfileErrorMessage(c.state),
        kProfileExtrasUnavailableMessage,
      );
      expect(c.state.location, 'Pune');
      expect(c.state.website, '');
      expect(c.state.displayName, 'Kaif S');
      expect(c.canSave, isTrue);

      await c.save();

      final retry = repo.calls.last;
      expect(retry.displayName, 'Kaif S');
      expect(retry.hasExtras, isFalse);
      expect(c.state.status, EditProfileStatus.saved);
    });

    test(
      'on CreateUpload(BANNER): the same, and nothing is left to send',
      () async {
        when(
          () => media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(named: 'images'),
          ),
        ).thenThrow(extrasOff);
        picker.next = [imageBytes('a')];
        final c = cubit();
        await c.pickBanner();

        await c.save();

        expect(c.state.extrasEnabled, isFalse);
        expect(c.state.bannerPreview, isNull);
        expect(repo.calls, isEmpty);
        expect(c.canSave, isFalse);
        expect(
          editProfileErrorMessage(c.state),
          kProfileExtrasUnavailableMessage,
        );
      },
    );

    test(
      'a whole-service FEATURE_DISABLED does not switch the extras off',
      () async {
        final c = cubit();
        c.displayNameChanged('Kaif S');
        repo.failures.add(const FeatureDisabledException('off'));

        await c.save();

        expect(c.state.extrasEnabled, isTrue);
        expect(c.state.extrasDisabled, isFalse);
      },
    );
  });

  group('VALIDATION', () {
    test(
      'field=location shows inline and keeps Save off until it is edited',
      () async {
        final c = cubit();
        c.locationChanged('Mumbai');
        repo.failures.add(const ValidationException('bad', field: 'location'));

        await c.save();

        expect(c.state.locationRejected, isTrue);
        expect(c.state.websiteRejected, isFalse);
        expect(c.canSave, isFalse);
        expect(
          editProfileErrorMessage(c.state),
          contains('location can be at most 30'),
        );
        c.locationChanged('Mumbai, MH');
        expect(c.state.locationRejected, isFalse);
        expect(c.canSave, isTrue);
      },
    );

    test(
      'field=website shows inline and keeps Save off until it is edited',
      () async {
        final c = cubit();
        c.websiteChanged('https://example.com');
        repo.failures.add(const ValidationException('bad', field: 'website'));

        await c.save();

        expect(c.state.websiteRejected, isTrue);
        expect(c.canSave, isFalse);
        c.websiteChanged('https://example.org');
        expect(c.canSave, isTrue);
      },
    );
  });

  group('MEDIA_NOT_READY on UpdateProfile', () {
    const gone = MediaNotReadyException('gone');

    test('with only a banner sent, only the banner is dropped', () async {
      picker.next = [imageBytes('b')];
      final c = cubit();
      await c.pickBanner();
      repo.failures.add(gone);

      await c.save();

      expect(c.state.bannerDropped, isTrue);
      expect(c.state.avatarDropped, isFalse);
      expect(c.state.bannerPreview, isNull);
      expect(editProfileErrorMessage(c.state), kBannerGoneMessage);
      expect(c.canSave, isFalse);
    });

    test('with only a photo sent, only the photo is dropped', () async {
      picker.nextAvatar = imageBytes('a');
      final c = cubit();
      await c.pickAvatar();
      repo.failures.add(gone);

      await c.save();

      expect(c.state.avatarDropped, isTrue);
      expect(c.state.bannerDropped, isFalse);
      expect(c.state.avatarPreview, isNull);
    });

    test(
      'with both sent the answer cannot say which: both are dropped',
      () async {
        picker.nextAvatar = imageBytes('a');
        picker.next = [imageBytes('b')];
        final c = cubit();
        await c.pickAvatar();
        await c.pickBanner();
        repo.failures.add(gone);

        await c.save();

        expect(c.state.avatarDropped, isTrue);
        expect(c.state.bannerDropped, isTrue);
        expect(c.state.avatarPreview, isNull);
        expect(c.state.bannerPreview, isNull);
        expect(editProfileErrorMessage(c.state), kImagesGoneMessage);
      },
    );

    test('a re-picked banner uploads again under a new media id', () async {
      picker.next = [imageBytes('b')];
      final c = cubit();
      await c.pickBanner();
      repo.failures.add(gone);
      await c.save();

      picker.next = [imageBytes('b')];
      await c.pickBanner();
      await c.save();

      expect(repo.calls.last.bannerMediaId, 'm2');
      expect(c.state.status, EditProfileStatus.saved);
    });
  });

  group('photo and banner together', () {
    test(
      'upload the photo then the banner, one single-item call each',
      () async {
        picker.nextAvatar = imageBytes('a');
        picker.next = [imageBytes('b')];
        final c = cubit();
        await c.pickAvatar();
        await c.pickBanner();

        await c.save();

        final captured = verify(
          () => media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: captureAny(named: 'purpose'),
            images: captureAny(named: 'images'),
          ),
        ).captured;
        expect(captured[0], pb.MediaPurpose.MEDIA_PURPOSE_AVATAR);
        expect(captured[2], pb.MediaPurpose.MEDIA_PURPOSE_BANNER);
        expect(captured[1], hasLength(1));
        expect(captured[3], hasLength(1));
        final call = repo.calls.single;
        expect(call.avatarMediaId, 'm1');
        expect(call.bannerMediaId, 'm2');
      },
    );

    test('a banner upload that fails keeps the photo uploaded: the retry '
        'uploads only the banner', () async {
      picker.nextAvatar = imageBytes('a');
      picker.next = [imageBytes('b')];
      final c = cubit();
      await c.pickAvatar();
      await c.pickBanner();
      var calls = 0;
      when(
        () => media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).thenAnswer((invocation) async {
        calls++;
        if (calls == 2) throw const NetworkException('offline');
        return [uploadTarget('m$calls')];
      });

      await c.save();

      expect(c.state.bannerFailed, isTrue);
      expect(c.state.avatarFailed, isFalse);
      expect(repo.calls, isEmpty);

      await c.save();

      expect(calls, 3);
      final call = repo.calls.single;
      expect(call.avatarMediaId, 'm1');
      expect(call.bannerMediaId, 'm3');
    });
  });
}
