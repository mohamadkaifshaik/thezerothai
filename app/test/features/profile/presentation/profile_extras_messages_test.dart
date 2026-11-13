import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/presentation/media_error_messages.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/features/profile/presentation/profile_edit_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

/// The words of Edit profile's extras: friendly, typed, never the raw
/// server text.
void main() {
  EditProfileState failed(
    AppException error, {
    bool avatarFailed = false,
    bool avatarDropped = false,
    bool pickFailed = false,
    bool extrasDisabled = false,
  }) => EditProfileState(
    displayName: 'Kaif',
    bio: '',
    error: error,
    avatarFailed: avatarFailed,
    avatarDropped: avatarDropped,
    pickFailed: pickFailed,
    extrasDisabled: extrasDisabled,
  );

  test('no error, no message', () {
    expect(
      editProfileErrorMessage(const EditProfileState(displayName: '', bio: '')),
      isNull,
    );
  });

  test('FEATURE_DISABLED profile_extras is its own friendly text', () {
    const error = FeatureDisabledException('x', feature: kFeatureProfileExtras);

    expect(updateProfileErrorMessage(error), kProfileExtrasUnavailableMessage);
    expect(kProfileExtrasUnavailableMessage, contains('name and bio'));
    expect(
      updateProfileErrorMessage(const FeatureDisabledException('x')),
      "Editing your profile isn't available right now.",
    );
  });

  test('location and website validation are worded for their field', () {
    expect(
      updateProfileErrorMessage(
        const ValidationException('x', field: 'location'),
      ),
      contains('location can be at most 30 characters'),
    );
    expect(
      updateProfileErrorMessage(
        const ValidationException('x', field: 'website'),
      ),
      contains('https://'),
    );
  });

  test('the avatar words its failures for the photo', () {
    expect(
      avatarErrorMessage(const NetworkException('x')),
      contains('Your photo was not saved'),
    );
    expect(
      avatarErrorMessage(const MediaNotReadyException('x')),
      "The photo didn't finish uploading. Try again.",
    );
    expect(
      avatarErrorMessage(const UnknownApiException('x')),
      "Couldn't update your photo. Please try again.",
    );
    expect(
      avatarErrorMessage(
        const ValidationException('Not allowed', field: 'media'),
      ),
      'Not allowed',
    );
  });

  test('which text a failed save shows follows what failed', () {
    const any = UnknownApiException('x');
    expect(
      editProfileErrorMessage(failed(any, pickFailed: true)),
      kPickFailedMessage,
    );
    expect(
      editProfileErrorMessage(
        failed(any, extrasDisabled: true, avatarFailed: true),
      ),
      kProfileExtrasUnavailableMessage,
    );
    expect(
      editProfileErrorMessage(failed(any, avatarDropped: true)),
      kAvatarGoneMessage,
    );
    expect(
      editProfileErrorMessage(failed(any, avatarFailed: true)),
      "Couldn't update your photo. Please try again.",
    );
    expect(
      editProfileErrorMessage(failed(any)),
      "Couldn't save your changes. Please try again.",
    );
  });
}
