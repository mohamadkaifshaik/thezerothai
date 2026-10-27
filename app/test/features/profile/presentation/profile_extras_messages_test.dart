import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/presentation/media_error_messages.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/features/profile/presentation/profile_edit_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

/// The words of Edit profile's extras (W3-15): friendly, typed, never the raw
/// server text.
void main() {
  EditProfileState failed(
    AppException error, {
    bool avatarFailed = false,
    bool bannerFailed = false,
    bool avatarDropped = false,
    bool bannerDropped = false,
    bool pickFailed = false,
    bool extrasDisabled = false,
  }) => EditProfileState(
    displayName: 'Kaif',
    bio: '',
    error: error,
    avatarFailed: avatarFailed,
    bannerFailed: bannerFailed,
    avatarDropped: avatarDropped,
    bannerDropped: bannerDropped,
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
    expect(bannerErrorMessage(error), kProfileExtrasUnavailableMessage);
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

  test('the banner words its failures for the banner, the avatar for the '
      'photo', () {
    expect(
      bannerErrorMessage(const NetworkException('x')),
      contains('Your banner was not saved'),
    );
    expect(
      avatarErrorMessage(const NetworkException('x')),
      contains('Your photo was not saved'),
    );
    expect(
      bannerErrorMessage(const MediaNotReadyException('x')),
      "The banner didn't finish uploading. Try again.",
    );
    expect(
      bannerErrorMessage(const UnknownApiException('x')),
      "Couldn't update your banner. Please try again.",
    );
    expect(
      bannerErrorMessage(const QuotaExceededException('uploads')),
      avatarErrorMessage(const QuotaExceededException('uploads')),
    );
    expect(
      bannerErrorMessage(
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
        failed(any, extrasDisabled: true, bannerFailed: true),
      ),
      kProfileExtrasUnavailableMessage,
    );
    expect(
      editProfileErrorMessage(
        failed(any, avatarDropped: true, bannerDropped: true),
      ),
      kImagesGoneMessage,
    );
    expect(
      editProfileErrorMessage(failed(any, avatarDropped: true)),
      kAvatarGoneMessage,
    );
    expect(
      editProfileErrorMessage(failed(any, bannerDropped: true)),
      kBannerGoneMessage,
    );
    expect(
      editProfileErrorMessage(failed(any, bannerFailed: true)),
      "Couldn't update your banner. Please try again.",
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
