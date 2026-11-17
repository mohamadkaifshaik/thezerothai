import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/search_repository.dart';
import 'bloc/explore_media_state.dart';
import 'bloc/trending_feed_cubit.dart';
import 'bloc/trending_media_cubit.dart';
import 'bloc/trending_paged_cubit.dart';

/// The two sections of the Trending tab.
enum TrendingSection { posts, media }

/// What the Trending tab remembers while Explore is open: the section shown,
/// the hashtag filter, and the cubits of both sections. Owned by Explore's
/// state (like its Plans and Nearby cubits), so a switch of Explore tab
/// keeps everything.
///
/// - A section's cubit is made (and so asks) only when the section is first
///   asked for ([posts], [media]), so a hidden section asks nothing.
/// - One tagged cubit per section at a time: made for the selected hashtag,
///   closed when the tag changes or clears. Clearing the tag shows the
///   untagged cubit again, pages and all.
/// - A section whose cubit answers FEATURE_DISABLED is switched off
///   ([postsOff], [mediaOff]) for the session.
class TrendingSectionsModel extends ChangeNotifier {
  TrendingSectionsModel({
    required SearchRepository repository,
    String? initialTag,
  }) : _repository = repository,
       _tag = initialTag;

  final SearchRepository _repository;

  TrendingSection _section = TrendingSection.posts;
  String? _tag;
  bool _postsOff = false;
  bool _mediaOff = false;

  TrendingFeedCubit? _posts;
  TrendingFeedCubit? _postsTagged;
  TrendingMediaCubit? _media;
  TrendingMediaCubit? _mediaTagged;
  final Map<Object, StreamSubscription<Object?>> _subs = {};
  bool _disposed = false;

  /// The section the phone and tablet control shows.
  TrendingSection get section => _section;

  /// The selected hashtag (no `#`), or null.
  String? get tag => _tag;

  bool get postsOff => _postsOff;
  bool get mediaOff => _mediaOff;

  set section(TrendingSection value) {
    if (_section == value) return;
    _section = value;
    notifyListeners();
  }

  /// Filters both sections to [tag], or clears the filter ([tag] null, or the
  /// tag already selected).
  void selectTag(String? tag) {
    final next = tag == _tag ? null : tag;
    if (next == _tag) return;
    _drop(_postsTagged);
    _drop(_mediaTagged);
    _postsTagged = null;
    _mediaTagged = null;
    _tag = next;
    notifyListeners();
  }

  /// Opens with [tag] selected (a link's `?tag=`), without toggling it off.
  void openTag(String tag) {
    if (tag == _tag) return;
    selectTag(tag);
  }

  /// The Posts cubit of the current source, made (and started) on first ask.
  TrendingFeedCubit posts() {
    if (_tag == null) return _posts ??= _watchPosts(_newPosts(null));
    return _postsTagged ??= _watchPosts(_newPosts(_tag));
  }

  /// The Media cubit of the current source, made (and started) on first ask.
  TrendingMediaCubit media() {
    if (_tag == null) return _media ??= _watchMedia(_newMedia(null));
    return _mediaTagged ??= _watchMedia(_newMedia(_tag));
  }

  TrendingFeedCubit _newPosts(String? tag) =>
      TrendingFeedCubit(repository: _repository, tag: tag);

  TrendingMediaCubit _newMedia(String? tag) =>
      TrendingMediaCubit(repository: _repository, tag: tag);

  TrendingFeedCubit _watchPosts(TrendingFeedCubit cubit) {
    _subs[cubit] = cubit.stream.listen((s) {
      if (s.status == PagedStatus.unavailable && !_postsOff) {
        _postsOff = true;
        if (!_disposed) notifyListeners();
      }
    });
    unawaited(cubit.start());
    return cubit;
  }

  TrendingMediaCubit _watchMedia(TrendingMediaCubit cubit) {
    _subs[cubit] = cubit.stream.listen((s) {
      if (s.status == ExploreMediaStatus.unavailable && !_mediaOff) {
        _mediaOff = true;
        if (!_disposed) notifyListeners();
      }
    });
    unawaited(cubit.start());
    return cubit;
  }

  void _drop(PagedTrendingCubit<Object?>? cubit) {
    if (cubit == null) return;
    unawaited(_subs.remove(cubit)?.cancel());
    unawaited(cubit.close());
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in <PagedTrendingCubit<Object?>?>[
      _posts,
      _postsTagged,
      _media,
      _mediaTagged,
    ]) {
      _drop(c);
    }
    super.dispose();
  }
}
