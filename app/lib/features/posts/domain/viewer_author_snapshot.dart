import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;

/// The signed-in viewer as an [common.AuthorSnapshot], for optimistic rows
/// (a new post or reply before the server answers). Empty fields when the
/// profile has not loaded yet.
common.AuthorSnapshot viewerAuthorSnapshot(identity.Profile? profile) =>
    common.AuthorSnapshot(
      userId: profile?.userId ?? '',
      handle: profile?.handle ?? '',
      displayName: profile?.displayName ?? '',
      avatarUrl: profile?.avatarThumbUrl ?? '',
      verified: profile?.verified ?? false,
    );
