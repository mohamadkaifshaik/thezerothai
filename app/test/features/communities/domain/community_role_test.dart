import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
import 'package:dzeroth/features/communities/domain/community_role.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the feature name is the wire name of the flag', () {
    expect(kFeatureCommunities, 'communities');
  });

  test('roles come from the wire value; unspecified reads as none', () {
    expect(
      CommunityRole.fromWire(pb.CommunityRole.COMMUNITY_ROLE_OWNER),
      CommunityRole.owner,
    );
    expect(
      CommunityRole.fromWire(pb.CommunityRole.COMMUNITY_ROLE_MODERATOR),
      CommunityRole.moderator,
    );
    expect(
      CommunityRole.fromWire(pb.CommunityRole.COMMUNITY_ROLE_MEMBER),
      CommunityRole.member,
    );
    expect(
      CommunityRole.fromWire(pb.CommunityRole.COMMUNITY_ROLE_BANNED),
      CommunityRole.banned,
    );
    expect(
      CommunityRole.fromWire(pb.CommunityRole.COMMUNITY_ROLE_NONE),
      CommunityRole.none,
    );
    expect(
      CommunityRole.fromWire(pb.CommunityRole.COMMUNITY_ROLE_UNSPECIFIED),
      CommunityRole.none,
    );
  });

  test('membership and moderation follow the server role only', () {
    expect(CommunityRole.owner.isMember, isTrue);
    expect(CommunityRole.moderator.isMember, isTrue);
    expect(CommunityRole.member.isMember, isTrue);
    expect(CommunityRole.banned.isMember, isFalse);
    expect(CommunityRole.none.isMember, isFalse);
    expect(CommunityRole.owner.canModerate, isTrue);
    expect(CommunityRole.moderator.canModerate, isTrue);
    expect(CommunityRole.member.canModerate, isFalse);
    expect(CommunityRole.owner.isOwner, isTrue);
    expect(CommunityRole.moderator.isOwner, isFalse);
  });

  test('Community.role and CommunityMember.memberRole read the fields', () {
    final c = pb.Community(viewerRole: pb.CommunityRole.COMMUNITY_ROLE_BANNED);
    final m = pb.CommunityMember(role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
    expect(c.role, CommunityRole.banned);
    expect(m.memberRole, CommunityRole.member);
    expect(pb.Community().role, CommunityRole.none);
  });
}
