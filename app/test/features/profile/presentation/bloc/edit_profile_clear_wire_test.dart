import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/profile/presentation/bloc/edit_profile_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_transport.dart';

/// W3-22 M-1 (c): what Edit profile really puts on the wire when it removes a
/// saved banner, location or website without `profile_extras` (ADR-0024
/// Amendment 1 A2). The other Edit profile tests use a recording fake
/// repository, which cannot tell a present empty field from an absent one; the
/// server can (field presence is the signal), so this goes through the real
/// `IdentityRepository` and the protobuf encoding the API client writes.
void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late List<identity.UpdateProfileRequest> sent;

  final saved = identity.Profile(
    userId: 'me',
    handle: 'kaif',
    displayName: 'Kaif',
    bio: 'hello',
    location: 'Pune',
    website: 'https://a.example',
    bannerUrl: 'https://cdn.example/b.jpg',
    bannerThumbUrl: 'https://cdn.example/b_t.jpg',
  );

  EditProfileCubit cubit({bool extras = false}) {
    final repo = IdentityRepository(
      apiClient: ApiClient.withTransport(transport),
      database: db,
    );
    final c = EditProfileCubit(
      identityRepository: repo,
      initial: saved,
      extrasEnabled: extras,
    );
    addTearDown(c.close);
    return c;
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    sent = [];
    transport = FakeTransport((procedure, input) async {
      // Over the wire, as the server receives it.
      final request = input as identity.UpdateProfileRequest;
      sent.add(
        identity.UpdateProfileRequest.fromBuffer(request.writeToBuffer()),
      );
      return identity.UpdateProfileResponse(
        profile: identity.Profile(
          userId: 'me',
          handle: 'kaif',
          displayName: 'Kaif',
        ),
      );
    });
  });

  tearDown(() => db.close());

  test('Remove banner, location and website: all three are present and '
      'empty, and nothing else is', () async {
    final c = cubit();

    c.removeBanner();
    c.removeLocation();
    c.removeWebsite();
    await c.save();

    final request = sent.single;
    expect(request.hasBannerMediaId(), isTrue);
    expect(request.bannerMediaId, '');
    expect(request.hasLocation(), isTrue);
    expect(request.location, '');
    expect(request.hasWebsite(), isTrue);
    expect(request.website, '');
    expect(request.hasDisplayName(), isFalse);
    expect(request.hasBio(), isFalse);
    expect(request.hasAvatarMediaId(), isFalse);
    expect(request.hasPinnedPostId(), isFalse);
    expect(c.state.status, EditProfileStatus.saved);
  });

  test('a name change next to a removal: the extras are still only the '
      'empty one', () async {
    final c = cubit();

    c.displayNameChanged('Kaif S');
    c.removeLocation();
    await c.save();

    final request = sent.single;
    expect(request.displayName, 'Kaif S');
    expect(request.hasLocation(), isTrue);
    expect(request.location, '');
    expect(request.hasWebsite(), isFalse);
    expect(request.hasBannerMediaId(), isFalse);
  });

  test('a name change alone leaves every extra out', () async {
    final c = cubit();

    c.displayNameChanged('Kaif S');
    await c.save();

    final request = sent.single;
    expect(request.hasLocation(), isFalse);
    expect(request.hasWebsite(), isFalse);
    expect(request.hasBannerMediaId(), isFalse);
  });
}
