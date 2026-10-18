import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/app_exception.dart';

/// Name of the posts feature flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0010 D1). A missing name means off.
/// It gates PostService, TimelineService and all posts UI; never hardcode
/// `'posts'` anywhere else.
const kFeaturePosts = 'posts';

/// Sub-feature names the server puts in `metadata["feature"]` of a
/// FEATURE_DISABLED CreatePost (ADR-0010 D2), checked in this order.
const kPostsSubFeatureReplies = 'replies';
const kPostsSubFeatureQuotes = 'quotes';
const kPostsSubFeatureMedia = 'media';

/// Client-side view of the posts flag and its sub-features (ADR-0010 D1/D2),
/// shared by [PostsRepository] and [TimelineRepository] so both obey it.
///
/// A [ServiceFeatureGate] (coarse flag, refresh throttle, unexpected-error
/// hook) that adds only the sub-feature set: FEATURE_DISABLED with
/// `metadata["feature"]` hides just that sub-feature; one without `feature`
/// hides all of posts. Both are remembered until [reset] (after a fresh
/// `GetMe`).
class PostsFeatureGate extends ServiceFeatureGate {
  PostsFeatureGate({
    required bool Function() isPostsEnabled,
    super.onUnexpectedError,
    void Function()? onWholeServiceDisabled,
    super.now,
  }) : super(
         isEnabled: isPostsEnabled,
         onDisabledByServer: onWholeServiceDisabled,
       );

  final Set<String> _disabledSubFeatures = {};

  /// Whether posts and timeline RPCs may be called at all.
  bool get postsEnabled => enabled;

  /// Whether the sub-feature [name] (`replies`, `quotes`, `media`) is usable.
  bool subFeatureEnabled(String name) =>
      postsEnabled && !_disabledSubFeatures.contains(name);

  @override
  void recordDisabled(FeatureDisabledException exception) {
    final feature = exception.feature;
    if (feature == null || feature.isEmpty) {
      super.recordDisabled(exception);
    } else if (_disabledSubFeatures.add(feature)) {
      notifyListeners();
    }
  }

  @override
  void reset() {
    final had = _disabledSubFeatures.isNotEmpty;
    _disabledSubFeatures.clear();
    if (had && !disabledByServer) notifyListeners();
    super.reset();
  }

  /// Runs an API [call] for the posts/timeline services.
  ///
  /// [requires] names a sub-feature the call needs (for example
  /// [kPostsSubFeatureMedia] for a CreatePost with media): if it is known to
  /// be off the call is not sent.
  @override
  Future<T> run<T>(
    Future<T> Function() call, {
    Iterable<String> requires = const [],
  }) {
    if (postsEnabled) {
      for (final name in requires) {
        if (_disabledSubFeatures.contains(name)) {
          throw FeatureDisabledException(
            'This part of posts is not available.',
            feature: name,
          );
        }
      }
    }
    return super.run(call);
  }
}
