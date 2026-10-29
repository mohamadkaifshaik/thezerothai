import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';

import 'posts_fixtures.dart';

/// What the server sends for the caller's own REPOST of a protected author's
/// post they can no longer see, on their own profile (W3-41a): the REPOST row
/// with `embed_viewer_state = PROTECTED`, `reposted_by_viewer = true`,
/// `viewer_reply_permission = UNKNOWN` and the embed reduced to the original's
/// `post_id` plus its author. [leak] adds the copied text a hostile or older
/// server could still send, to prove the row shows none of it.
pb.PostView ownProtectedRepostView({
  int original = 7,
  int repost = 70,
  String viewerId = 'me',
  bool reposted = true,
  bool leak = false,
}) => pb.PostView(
  post: pb.Post(
    postId: postId(repost),
    kind: PostKind.POST_KIND_REPOST,
    author: common.AuthorSnapshot(
      userId: viewerId,
      handle: 'me',
      displayName: 'Me Myself',
    ),
    embedded: pb.EmbeddedPost(
      postId: postId(original),
      text: leak ? 'secret words that must not show' : '',
      author: common.AuthorSnapshot(
        userId: 'u-locked',
        handle: 'locked',
        displayName: 'Locked Author',
        avatarUrl: 'https://cdn.example/locked.jpg',
      ),
    ),
  ),
  likedByViewer: false,
  repostedByViewer: reposted,
  viewerReplyPermission: ReplyPermission.REPLY_PERMISSION_UNKNOWN,
  embedViewerState: pb.EmbedViewerState.EMBED_VIEWER_STATE_PROTECTED,
);

/// A row of the caller's own Likes or Bookmarks that the server withheld
/// (W3-41a): the post stripped to `post_id`, `kind` and the author snapshot,
/// `withheld = true`, and the viewer flag of the list still true.
pb.PostView withheldView(
  int n, {
  bool liked = true,
  bool bookmarked = false,
  PostKind kind = PostKind.POST_KIND_POST,
}) => pb.PostView(
  post: pb.Post(
    postId: postId(n),
    kind: kind,
    author: common.AuthorSnapshot(
      userId: 'u-locked$n',
      handle: 'locked$n',
      displayName: 'Locked Author $n',
      avatarUrl: 'https://cdn.example/locked$n.jpg',
    ),
  ),
  likedByViewer: liked,
  bookmarkedByViewer: bookmarked,
  withheld: true,
);
