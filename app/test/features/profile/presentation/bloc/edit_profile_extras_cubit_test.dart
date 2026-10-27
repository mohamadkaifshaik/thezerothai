import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/profile_edit_fixtures.dart';

/// Request shaping of Edit profile's `profile_extras` fields (W3-15, ADR-0024
/// D1-D3): changed fields only, `""` clears, and nothing extra ever reaches a
/// request while the flag is off.
void main() {
  setUpAll(registerMediaFallbacks);

  late FakeIdentityRepository repo;

  EditProfileCubit cubit({
    bool extras = true,
    identity.Profile? initial,
    bool media = false,
  }) {
    repo = FakeIdentityRepository(initial ?? editableProfile());
    final c = EditProfileCubit(
      identityRepository: repo,
      initial: repo.profile,
      extrasEnabled: extras,
      picker: media ? FakeImagePicker() : null,
      processor: media ? FakeImageProcessor() : null,
      uploader: media ? MediaUploader(repository: MockMediaRepository()) : null,
    );
    addTearDown(c.close);
    return c;
  }

  group('flag off', () {
    test(
      'a name save never carries an extra, whatever the profile holds',
      () async {
        final c = cubit(
          extras: false,
          initial: editableProfile(
            location: 'Pune',
            website: 'https://a.co',
            banner: true,
          ),
        );

        c.displayNameChanged('Kaif S');
        await c.save();

        final call = repo.calls.single;
        expect(call.displayName, 'Kaif S');
        expect(call.hasExtras, isFalse);
      },
    );

    test('the extras cannot be edited, picked or removed', () async {
      final c = cubit(
        extras: false,
        media: true,
        initial: editableProfile(banner: true),
      );

      c.locationChanged('Pune');
      c.websiteChanged('https://a.co');
      c.removeBanner();
      await c.pickBanner();

      expect(c.state.location, '');
      expect(c.state.website, '');
      expect(c.state.bannerRemoved, isFalse);
      expect(c.canChangeBanner, isFalse);
      expect(c.hasChanges, isFalse);
      expect(c.canSave, isFalse);
    });
  });

  group('flag on', () {
    test('only the changed field is sent', () async {
      final c = cubit(
        initial: editableProfile(location: 'Pune', website: 'https://a.co'),
      );

      c.locationChanged('  Mumbai ');
      await c.save();

      final call = repo.calls.single;
      expect(call.location, 'Mumbai');
      expect(call.website, isNull);
      expect(call.bannerMediaId, isNull);
      expect(call.displayName, isNull);
      expect(call.bio, isNull);
    });

    test('unchanged extras are not changes', () {
      final c = cubit(
        initial: editableProfile(location: 'Pune', website: 'https://a.co'),
      );

      c.locationChanged(' Pune ');
      c.websiteChanged('https://a.co ');

      expect(c.hasChanges, isFalse);
      expect(c.canSave, isFalse);
    });

    test('emptying a field sends an empty string (it clears)', () async {
      final c = cubit(
        initial: editableProfile(location: 'Pune', website: 'https://a.co'),
      );

      c.locationChanged('');
      c.websiteChanged('   ');
      await c.save();

      final call = repo.calls.single;
      expect(call.location, '');
      expect(call.website, '');
      expect(c.state.status, EditProfileStatus.saved);
      expect(c.state.saved!.location, '');
    });

    test('name, bio and extras go in one request', () async {
      final c = cubit();

      c.displayNameChanged('Kaif S');
      c.bioChanged('new bio');
      c.locationChanged('Pune');
      c.websiteChanged('https://example.com/a');
      await c.save();

      final call = repo.calls.single;
      expect(call.displayName, 'Kaif S');
      expect(call.bio, 'new bio');
      expect(call.location, 'Pune');
      expect(call.website, 'https://example.com/a');
      expect(call.bannerMediaId, isNull);
    });

    test(
      'a location is trimmed and composed (NFC) before it is sent',
      () async {
        final c = cubit();

        c.locationChanged(' ${String.fromCharCodes([0x65, 0x301])} ');
        await c.save();

        expect(repo.calls.single.location, String.fromCharCodes([0xE9]));
      },
    );

    test('invalid text keeps Save off', () {
      final c = cubit();

      c.locationChanged('a' * 31);
      expect(c.canSave, isFalse);
      c.locationChanged('Pune');
      expect(c.canSave, isTrue);
      c.websiteChanged('example.com');
      expect(c.canSave, isFalse);
      c.websiteChanged('https://example.com');
      expect(c.canSave, isTrue);
    });
  });
}
