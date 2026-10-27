import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

/// The shape of every UpdateProfile request (ADR-0024: field presence is the
/// signal, `""` clears, absent leaves unchanged). These go through the real
/// protobuf encoding the API client uses (`ProtoCodec` writes
/// `writeToBuffer()`), because the in-memory fake transport would not notice
/// an empty `optional string` that never reaches the wire.
void main() {
  const key = 'key-1234567890abcdef';

  identity.UpdateProfileRequest overTheWire(
    identity.UpdateProfileRequest request,
  ) => identity.UpdateProfileRequest.fromBuffer(request.writeToBuffer());

  test('only the given fields are present', () {
    final sent = overTheWire(
      buildUpdateProfileRequest(idempotencyKey: key, displayName: 'Kaif S'),
    );

    expect(sent.idempotencyKey, key);
    expect(sent.hasDisplayName(), isTrue);
    expect(sent.hasBio(), isFalse);
    expect(sent.hasAvatarMediaId(), isFalse);
    expect(sent.hasBannerMediaId(), isFalse);
    expect(sent.hasLocation(), isFalse);
    expect(sent.hasWebsite(), isFalse);
    expect(sent.hasPinnedPostId(), isFalse);
  });

  test('an empty string is a present field on the wire (it clears)', () {
    final sent = overTheWire(
      buildUpdateProfileRequest(
        idempotencyKey: key,
        bannerMediaId: '',
        location: '',
        website: '',
        pinnedPostId: '',
      ),
    );

    expect(sent.hasBannerMediaId(), isTrue);
    expect(sent.bannerMediaId, '');
    expect(sent.hasLocation(), isTrue);
    expect(sent.location, '');
    expect(sent.hasWebsite(), isTrue);
    expect(sent.website, '');
    expect(sent.hasPinnedPostId(), isTrue);
    expect(sent.pinnedPostId, '');
    // The name and bio were not given: they stay out.
    expect(sent.hasDisplayName(), isFalse);
    expect(sent.hasBio(), isFalse);
  });

  test('values are sent as given', () {
    final sent = overTheWire(
      buildUpdateProfileRequest(
        idempotencyKey: key,
        avatarMediaId: 'a1',
        bannerMediaId: 'b1',
        location: 'Mumbai',
        website: 'https://example.com',
        pinnedPostId: '123',
      ),
    );

    expect(sent.avatarMediaId, 'a1');
    expect(sent.bannerMediaId, 'b1');
    expect(sent.location, 'Mumbai');
    expect(sent.website, 'https://example.com');
    expect(sent.pinnedPostId, '123');
  });
}
