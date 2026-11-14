part of 'post_card.dart';

/// The non-layout helpers of [PostCard]: who the viewer is, what the menu
/// acts on, navigation, and the embed placeholder rule.
extension _PostCardOps on PostCard {
  pb.Post get _post => view.post;

  bool get _isOwn =>
      viewerUserId != null &&
      viewerUserId!.isNotEmpty &&
      _post.author.userId == viewerUserId;

  bool _isViewer(String userId) =>
      viewerUserId != null &&
      viewerUserId!.isNotEmpty &&
      userId == viewerUserId;

  /// What Report / Block / Mute act on. A REPOST row that shows its original
  /// targets the ORIGINAL post and author (the account the card displays);
  /// everything else (own posts, QUOTE rows, a REPOST whose original is
  /// hidden) targets the row's own post and author.
  _MenuTarget _menuTarget({pb.EmbeddedPost? original}) {
    if (original != null) {
      return _MenuTarget(
        userId: original.author.userId,
        handle: original.author.handle,
        postId: original.postId,
        isOwn: _isViewer(original.author.userId),
        reportLabel: 'Report post',
        subject: "@${original.author.handle}'s post",
      );
    }
    final isRepost = _post.kind == PostKind.POST_KIND_REPOST;
    return _MenuTarget(
      userId: _post.author.userId,
      handle: _post.author.handle,
      postId: _post.postId,
      isOwn: _isOwn,
      reportLabel: isRepost ? 'Report repost' : 'Report post',
      subject: isRepost
          ? "@${_post.author.handle}'s repost"
          : "@${_post.author.handle}'s post",
    );
  }

  void _openProfile(BuildContext context, String userId) {
    if (userId.isEmpty) return;
    final handler = onOpenProfile;
    if (handler != null) {
      handler(userId);
      return;
    }
    context.push(AppRouter.profileByIdPath(userId));
  }

  Future<void> _openLink(BuildContext context, Uri uri) async {
    final handler = onOpenLink;
    if (handler != null) {
      handler(uri);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (!await launchPostLink(uri)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Couldn't open link.")));
    }
  }

  /// The label opens the community only while `communities` is on (false
  /// when no session is above, as in some tests).
  bool _communityTappable(BuildContext context) {
    if (_post.community.id.isEmpty) return false;
    try {
      return isFeatureEnabled(context, kFeatureCommunities);
    } on ProviderNotFoundException {
      return false;
    }
  }

  void _openCommunity(BuildContext context, String communityId) {
    context.push(AppRouter.communityPath(communityId));
  }

  void _openPost(BuildContext context, String postId) {
    final handler = onOpenPost;
    if (handler != null) {
      handler(postId);
      return;
    }
    context.push(AppRouter.postPath(postId));
  }

  /// Why [embedded] must not be shown, if so: gone (`unavailable`), or its
  /// author is blocked / muted by the viewer. The server says so on the
  /// detail views (`embed_viewer_state`, issue #152), which holds even when
  /// the local relationship cache is cold after a restart; otherwise (an older
  /// server, a feed row cached before the block) the local cache decides, 0
  /// RPCs. The server already drops such copies from feeds. The viewer's own
  /// posts are never hidden.
  EmbedPlaceholder? _placeholderFor(
    BuildContext context,
    pb.EmbeddedPost embedded,
  ) {
    if (embedded.unavailable) return EmbedPlaceholder.unavailable;
    switch (view.embedViewerState) {
      case pb.EmbedViewerState.EMBED_VIEWER_STATE_BLOCKED:
        return EmbedPlaceholder.blocked;
      case pb.EmbedViewerState.EMBED_VIEWER_STATE_MUTED:
        return EmbedPlaceholder.muted;
      case pb.EmbedViewerState.EMBED_VIEWER_STATE_PROTECTED:
        return EmbedPlaceholder.protected;
      default:
        break;
    }
    final authorId = embedded.author.userId;
    if (!graphActionsEnabled || authorId.isEmpty || authorId == viewerUserId) {
      return null;
    }
    final relationship = context.read<GraphRepository>().cached(authorId);
    if (relationship == null) return null;
    if (relationship.blocking) return EmbedPlaceholder.blocked;
    if (relationship.muting) return EmbedPlaceholder.muted;
    return null;
  }
}

/// Whether hashtags open search: the `search` flag, false when no session is
/// above (a card shown outside the app, as in some tests).
bool _searchOn(BuildContext context, {bool listen = true}) {
  try {
    return listen
        ? isFeatureEnabled(context, kFeatureSearch)
        : featureEnabledSnapshot(context, kFeatureSearch);
  } on ProviderNotFoundException {
    return false;
  }
}

void _openHashtag(BuildContext context, String tag) {
  if (_searchOn(context, listen: false)) {
    // The canonical form (NFC, lower case), so the URL, the header and the
    // empty state agree; Top is named, as the plan says.
    context.push(
      searchResultsLocation(
        SearchQuery.parse('#$tag').canonical,
        tab: SearchResultsTab.top.queryValue,
      ),
    );
  } else {
    _showMessage(context, 'Hashtags are coming soon.');
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
