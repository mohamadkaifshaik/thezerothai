import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
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

    test('the extras cannot be edited or picked', () async {
      final c = cubit(
        extras: false,
        media: true,
        initial: editableProfile(banner: true),
      );

      c.locationChanged('Pune');
      c.websiteChanged('https://a.co');
      await c.pickBanner();

      expect(c.state.location, '');
      expect(c.state.website, '');
      expect(c.canChangeBanner, isFalse);
      expect(c.hasChanges, isFalse);
      expect(c.canSave, isFalse);
    });
  });

  // ADR-0024 Amendment 1 A2 (W3-22 M-1): without `profile_extras` the only
  // change an extra can take is a removal, an exact "" (the server accepts a
  // clear from any caller, and refuses a clear next to a set), so a request
  // can never carry a non-empty banner id, location or website.
  group('flag off: removing saved extras', () {
    final saved = editableProfile(
      location: 'Pune',
      website: 'https://a.example',
      banner: true,
    );

    /// Every extras argument of [call] is absent or exactly "".
    void expectClearsOnly(UpdateProfileCall call) {
      for (final value in [call.bannerMediaId, call.location, call.website]) {
        expect(value == null || value.isEmpty, isTrue, reason: '$value');
      }
      expect(call.pinnedPostId, isNull);
    }

    test('Remove location sends only location: ""', () async {
      final c = cubit(extras: false, initial: saved);
      expect(c.hasSavedLocation, isTrue);

      c.removeLocation();
      expect(c.state.locationRemoved, isTrue);
      expect(c.canSave, isTrue);
      await c.save();

      final call = repo.calls.single;
      expect(call.location, '');
      expect(call.website, isNull);
      expect(call.bannerMediaId, isNull);
      expect(call.displayName, isNull);
      expectClearsOnly(call);
      expect(c.state.status, EditProfileStatus.saved);
      expect(c.state.saved!.location, '');
      expect(c.state.saved!.website, 'https://a.example');
    });

    test('Remove website sends only website: ""', () async {
      final c = cubit(extras: false, initial: saved);

      c.removeWebsite();
      await c.save();

      final call = repo.calls.single;
      expect(call.website, '');
      expect(call.location, isNull);
      expect(call.bannerMediaId, isNull);
      expectClearsOnly(call);
    });

    test(
      'Remove banner needs no media: it sends banner_media_id: ""',
      () async {
        // No picker, processor or uploader: the media flag is off.
        final c = cubit(extras: false, media: false, initial: saved);
        expect(c.canChangeBanner, isFalse);

        c.removeBanner();
        expect(c.state.bannerRemoved, isTrue);
        expect(c.canSave, isTrue);
        await c.save();

        final call = repo.calls.single;
        expect(call.bannerMediaId, '');
        expect(call.location, isNull);
        expect(call.website, isNull);
        expectClearsOnly(call);
        expect(c.state.saved!.bannerUrl, '');
      },
    );

    test('all three go in one request, next to a name change, as clears '
        'only', () async {
      final c = cubit(extras: false, media: true, initial: saved);

      c.displayNameChanged('Kaif S');
      c.removeBanner();
      c.removeLocation();
      c.removeWebsite();
      await c.save();

      final call = repo.calls.single;
      expect(call.displayName, 'Kaif S');
      expect(call.bannerMediaId, '');
      expect(call.location, '');
      expect(call.website, '');
      expectClearsOnly(call);
    });

    test('nothing saved, nothing to remove: no change, no request', () async {
      final c = cubit(extras: false, initial: editableProfile());

      expect(c.hasSavedLocation, isFalse);
      expect(c.hasSavedWebsite, isFalse);
      expect(c.hasSavedBanner, isFalse);
      c.removeLocation();
      c.removeWebsite();
      expect(c.state.locationRemoved, isFalse);
      expect(c.state.websiteRemoved, isFalse);
      expect(c.canSave, isFalse);
      await c.save();
      expect(repo.calls, isEmpty);
    });

    test('with the flag on there is no separate removal: empty the field '
        '(it clears)', () {
      final c = cubit(initial: saved);

      c.removeLocation();
      c.removeWebsite();

      expect(c.state.locationRemoved, isFalse);
      expect(c.state.websiteRemoved, isFalse);
      expect(c.hasChanges, isFalse);
    });

    test('a retry of the same removal reuses the idempotency key', () async {
      final c = cubit(extras: false, initial: saved);
      c.removeLocation();
      repo.failures.add(const NetworkException('offline'));

      await c.save();
      expect(c.state.status, EditProfileStatus.editing);
      expect(c.state.locationRemoved, isTrue);
      await c.save();

      expect(repo.calls, hasLength(2));
      expect(repo.calls[1].idempotencyKey, repo.calls[0].idempotencyKey);
      expect(repo.calls[1].location, '');
    });

    test('a server that still refuses it (FEATURE_DISABLED) drops the '
        'pending removals, hides Remove and keeps the name edit', () async {
      final c = cubit(extras: false, initial: saved);
      c.displayNameChanged('Kaif S');
      c.removeLocation();
      c.removeBanner();
      repo.failures.add(
        const FeatureDisabledException('off', feature: kFeatureProfileExtras),
      );

      await c.save();

      expect(c.state.locationRemoved, isFalse);
      expect(c.state.bannerRemoved, isFalse);
      expect(c.state.removalRefused, isTrue);
      expect(c.state.displayName, 'Kaif S');
      // Remove is gone for good: asking again changes nothing.
      c.removeLocation();
      c.removeWebsite();
      c.removeBanner();
      expect(c.state.locationRemoved, isFalse);
      expect(c.state.websiteRemoved, isFalse);
      expect(c.state.bannerRemoved, isFalse);
      await c.save();
      expect(repo.calls.last.displayName, 'Kaif S');
      expect(repo.calls.last.hasExtras, isFalse);
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
