import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../onboarding/data/identity_repository.dart';

/// Whether the Pin / Unpin menu rows are still on offer.
@immutable
class PostPinState {
  const PostPinState({this.refused = false});

  /// The server answered FEATURE_DISABLED `profile_extras` to this cubit's
  /// request (the rows are hidden for the rest of the session, until the
  /// next `GetMe`; see `IdentityRepository.profileExtrasRefused`, which also
  /// remembers an earlier screen's refusal).
  final bool refused;

  @override
  bool operator ==(Object other) =>
      other is PostPinState && other.refused == refused;

  @override
  int get hashCode => refused.hashCode;
}

/// Pins and unpins the viewer's own posts through `UpdateProfile`
/// (`pinned_post_id`; `""` unpins) for the Pin / Unpin rows of a post's
/// overflow menu (W3-17, ADR-0024 D3).
///
/// - One idempotency key per intent (`pin:<post id>` or `unpin`), reused when
///   the same intent is retried after a failure and dropped once it
///   succeeded, so pinning, unpinning and pinning the same post again are
///   three different requests.
/// - On success the server's profile goes to [onProfileUpdated] (the screen
///   passes it to `OnboardingProfileUpdated` and `ProfileCubit.profileUpdated`).
/// - Errors are rethrown for the menu's snackbar (typed, see
///   `pinErrorMessage`); FEATURE_DISABLED `profile_extras` also flips
///   [PostPinState.refused].
class PostPinCubit extends Cubit<PostPinState> {
  PostPinCubit({
    required IdentityRepository identityRepository,
    required void Function(identity.Profile profile) onProfileUpdated,
    Uuid? uuid,
  }) : _identity = identityRepository,
       _onProfileUpdated = onProfileUpdated,
       _uuid = uuid ?? const Uuid(),
       super(const PostPinState());

  final IdentityRepository _identity;
  final void Function(identity.Profile profile) _onProfileUpdated;
  final Uuid _uuid;
  final Map<String, String> _keys = {};

  /// Pins [postId] (replacing any current pin).
  Future<void> pin(String postId) => _run('pin:$postId', postId);

  /// Unpins the current pin.
  Future<void> unpin() => _run('unpin', '');

  Future<void> _run(String intent, String postId) async {
    final key = _keys[intent] ??= _uuid.v4();
    try {
      final profile = await _identity.updatePinnedPost(
        idempotencyKey: key,
        postId: postId,
      );
      _keys.remove(intent);
      _onProfileUpdated(profile);
    } on FeatureDisabledException {
      if (_identity.profileExtrasRefused && !isClosed) {
        emit(const PostPinState(refused: true));
      }
      rethrow;
    }
  }
}
