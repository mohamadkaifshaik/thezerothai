import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;

/// The post id a feed row counts a view for, or null when it counts none.
///
/// - A withheld row shows nothing of the post: no view.
/// - A REPOST row counts the original it shows (its embedded id); one whose
///   original is gone (`unavailable`) or missing counts nothing.
/// - Any other row counts its own post.
String? impressionTargetId(pb.PostView view) {
  if (view.withheld) return null;
  final post = view.post;
  if (post.kind == PostKind.POST_KIND_REPOST) {
    if (!post.hasEmbedded() ||
        post.embedded.unavailable ||
        post.embedded.postId.isEmpty) {
      return null;
    }
    return post.embedded.postId;
  }
  return post.postId.isEmpty ? null : post.postId;
}
