import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
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
/// - The coarse flag comes from `GetMe.enabled_features` via [isPostsEnabled].
///   When it is off, [run] throws [FeatureDisabledException] **without
///   calling the API**: no posts or timeline RPC is ever sent.
/// - FEATURE_DISABLED with `metadata["feature"]` hides only that
///   sub-feature; one without `feature` hides all of posts. Both are
///   remembered until [reset] (call it after a fresh `GetMe`).
class PostsFeatureGate extends ChangeNotifier {
  PostsFeatureGate({
    required bool Function() isPostsEnabled,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _isPostsEnabled = isPostsEnabled,
       _onUnexpectedError = onUnexpectedError;

  final bool Function() _isPostsEnabled;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  bool _wholeServiceDisabled = false;
  final Set<String> _disabledSubFeatures = {};

  /// Whether posts and timeline RPCs may be called at all.
  bool get postsEnabled => _isPostsEnabled() && !_wholeServiceDisabled;

  /// Whether the sub-feature [name] (`replies`, `quotes`, `media`) is usable.
  bool subFeatureEnabled(String name) =>
      postsEnabled && !_disabledSubFeatures.contains(name);

  /// Records a FEATURE_DISABLED answer: hides only `exception.feature`, or
  /// all of posts when the server named no feature.
  void recordDisabled(FeatureDisabledException exception) {
    final feature = exception.feature;
    final bool changed;
    if (feature == null || feature.isEmpty) {
      changed = !_wholeServiceDisabled;
      _wholeServiceDisabled = true;
    } else {
      changed = _disabledSubFeatures.add(feature);
    }
    if (changed) notifyListeners();
  }

  /// Forgets what FEATURE_DISABLED answers taught us (after a fresh GetMe).
  void reset() {
    if (!_wholeServiceDisabled && _disabledSubFeatures.isEmpty) return;
    _wholeServiceDisabled = false;
    _disabledSubFeatures.clear();
    notifyListeners();
  }

  /// Runs an API [call] for the posts/timeline services.
  ///
  /// [requires] names a sub-feature the call needs (for example
  /// [kPostsSubFeatureMedia] for a CreatePost with media): if it is known to
  /// be off the call is not sent. Errors are converted by [guardApiCall];
  /// FEATURE_DISABLED is recorded; an unexpected [UnknownApiException] is
  /// reported to `onUnexpectedError` (Crashlytics non-fatal, T14).
  Future<T> run<T>(
    Future<T> Function() call, {
    Iterable<String> requires = const [],
  }) async {
    if (!postsEnabled) {
      throw const FeatureDisabledException('Posts are not available.');
    }
    for (final name in requires) {
      if (_disabledSubFeatures.contains(name)) {
        throw FeatureDisabledException(
          'This part of posts is not available.',
          feature: name,
        );
      }
    }
    try {
      return await guardApiCall(call);
    } on FeatureDisabledException catch (error) {
      recordDisabled(error);
      rethrow;
    } on UnknownApiException catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      rethrow;
    }
  }
}
