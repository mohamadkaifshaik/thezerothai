package communities

import (
	"testing"
	"time"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
)

func TestHeaderProto(t *testing.T) {
	t.Parallel()
	created := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	c := Community{ID: "1000000000000000099", Name: "Go", Description: "about", MemberCount: 7, Status: StatusArchived, CreatedAt: created,
		OwnerID: "owner", ModeratorIDs: []string{"mod"}, Rules: []Rule{{Title: "t", Text: "x"}}}
	tests := []struct {
		role Role
		want communitiesv1.CommunityRole
	}{
		{RoleOwner, communitiesv1.CommunityRole_COMMUNITY_ROLE_OWNER},
		{RoleModerator, communitiesv1.CommunityRole_COMMUNITY_ROLE_MODERATOR},
		{RoleMember, communitiesv1.CommunityRole_COMMUNITY_ROLE_MEMBER},
		{RoleBanned, communitiesv1.CommunityRole_COMMUNITY_ROLE_BANNED},
		{RoleNone, communitiesv1.CommunityRole_COMMUNITY_ROLE_NONE},
	}
	for _, tt := range tests {
		got := HeaderProto(c, tt.role)
		if got.GetViewerRole() != tt.want || got.GetCommunityId() != c.ID || got.GetName() != "Go" || got.GetMemberCount() != 7 ||
			got.GetStatus() != communitiesv1.CommunityStatus_COMMUNITY_STATUS_ARCHIVED || !got.GetCreatedAt().AsTime().Equal(created) {
			t.Errorf("role %v: header = %v", tt.role, got)
		}
	}
}
