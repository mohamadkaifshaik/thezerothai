import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/media_error_messages.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/features/profile/presentation/profile_edit_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/profile_edit_fixtures.dart';

/// What the server can answer to the extras and what Edit profile does
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
    test(
      'the photo that was sent is dropped and must be chosen again',
      () async {
        picker.nextAvatar = imageBytes('a');
        final c = cubit();
        await c.pickAvatar();
        repo.failures.add(const MediaNotReadyException('gone'));

        await c.save();

        expect(c.state.avatarDropped, isTrue);
        expect(c.state.avatarPreview, isNull);
        expect(editProfileErrorMessage(c.state), kAvatarGoneMessage);
        expect(c.canSave, isFalse);
      },
    );
  });
}
