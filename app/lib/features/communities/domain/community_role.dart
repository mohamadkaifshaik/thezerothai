import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;

/// A person's role in one community, exactly as the server sent it
/// (`Community.viewer_role`, `CommunityMember.role`). The client
/// never derives a role from anything else (not from `owner_id`, a member
/// list or its own actions): after a Join or Leave it takes the role from the
/// answer. A value this build does not know reads as [none] (additive proto).
enum CommunityRole {
  owner,
  moderator,
  member,
  banned,
  none;

  static CommunityRole fromWire(pb.CommunityRole role) => switch (role) {
    pb.CommunityRole.COMMUNITY_ROLE_OWNER => owner,
    pb.CommunityRole.COMMUNITY_ROLE_MODERATOR => moderator,
    pb.CommunityRole.COMMUNITY_ROLE_MEMBER => member,
    pb.CommunityRole.COMMUNITY_ROLE_BANNED => banned,
    _ => none,
  };

  /// Owner and moderators are JOINED members too.
  bool get isMember => this == owner || this == moderator || this == member;

  /// May hide and restore posts, ban and unban, and read the log.
  bool get canModerate => this == owner || this == moderator;

  bool get isOwner => this == owner;
}

extension CommunityRoles on pb.Community {
  /// The caller's role from the server's `viewer_role`.
  CommunityRole get role => CommunityRole.fromWire(viewerRole);
}

extension CommunityMemberRoles on pb.CommunityMember {
  /// The member's role from the server's `role`.
  CommunityRole get memberRole => CommunityRole.fromWire(role);
}
