import '../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;

/// [list] as it reads once the viewer follows it ([following] true) or no
/// longer does: `followed_by_viewer` set and the follower count moved by one
/// (never below 0). Returns [list] itself when nothing changes.
pb.ListInfo withViewerFollow(pb.ListInfo list, {required bool following}) {
  if (list.followedByViewer == following) return list;
  final count = list.followerCount;
  return list.deepCopy()
    ..followedByViewer = following
    ..followerCount = following ? count + 1 : (count > 0 ? count - 1 : 0);
}

/// Whether the Follow / Following toggle is offered for [list] to the viewer
/// [viewerUserId]: a public List that is not the viewer's own, with a known
/// viewer. (A private List is only ever returned to its owner.)
bool canFollowList(pb.ListInfo list, String? viewerUserId) =>
    viewerUserId != null &&
    viewerUserId.isNotEmpty &&
    !list.isPrivate &&
    list.owner.userId != viewerUserId;
