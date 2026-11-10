package communities

import (
	"context"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F24: ListCommunityMembers filter MODERATORS.

// modsFixture: owner1 owns testCID with moderators mod3, mod1, mod2 (appointment order), all JOINED, plus a member "a".
func modsFixture() *fixture {
	f := newListFixture()
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: []string{"mod3", modUID, "mod2"}})
	f.seedMembers(testCID, false, ownerUID, modUID, "mod2", "mod3", "a")
	f.repo.lst.entries = map[string]MemberEntry{}
	for i, u := range []string{ownerUID, modUID, "mod2", "mod3", "a"} {
		f.repo.lst.entries[testCID+"|"+u] = MemberEntry{State: MemberJoined, At: testNow.Add(-time.Duration(i) * time.Hour)}
	}
	return f
}

func TestModeratorOrder(t *testing.T) {
	for _, tc := range []struct {
		name string
		c    Community
		want string
	}{
		{"owner first, moderators by uid", Community{OwnerID: "o", ModeratorIDs: []string{"m3", "m1", "m2"}}, "[o m1 m2 m3]"},
		{"no owner (archived after erasure)", Community{ModeratorIDs: []string{"m2", "m1"}}, "[m1 m2]"},
		{"owner only", Community{OwnerID: "o"}, "[o]"},
		{"duplicates and the owner in moderatorIds are dropped", Community{OwnerID: "o", ModeratorIDs: []string{"m1", "o", "m1", ""}}, "[o m1]"},
	} {
		if got := fmt.Sprint(moderatorOrder(tc.c)); got != tc.want {
			t.Errorf("%s: %s, want %s", tc.name, got, tc.want)
		}
	}
}

func TestResumeAfter(t *testing.T) {
	order := []string{"o", "m1", "m2", "m3"}
	for _, tc := range []struct {
		name  string
		after *cursor.Cursor
		want  string
	}{
		{"first page", nil, "[o m1 m2 m3]"},
		{"after the owner", &cursor.Cursor{DocID: "o"}, "[m1 m2 m3]"},
		{"after a listed moderator", &cursor.Cursor{DocID: "m2"}, "[m3]"},
		{"after the last", &cursor.Cursor{DocID: "m3"}, "[]"},
		{"after a demoted moderator: the greater uids, never the owner again", &cursor.Cursor{DocID: "m15"}, "[m2 m3]"},
	} {
		if got := fmt.Sprint(resumeAfter(order, "o", tc.after)); got != tc.want {
			t.Errorf("%s: %s, want %s", tc.name, got, tc.want)
		}
	}
}

func TestListCommunityMembers_ModeratorsPage(t *testing.T) {
	for _, uid := range []string{"viewer", "a", nobodyUID} {
		t.Run("refused/"+uid, func(t *testing.T) {
			f := modsFixture()
			_, err := f.svc.ListCommunityMembers(context.Background(), uid, MembersInput{CommunityID: testCID, Filter: FilterModerators})
			wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})
			if len(f.repo.lst.byUIDCalls) != 0 || len(f.repo.lst.memberQs) != 0 {
				t.Error("member docs read for a refused caller")
			}
		})
	}
	for _, uid := range []string{ownerUID, modUID} {
		t.Run("allowed/"+uid, func(t *testing.T) {
			f := modsFixture()
			f.gr.snap = graph.Snapshot{BlockedBy: map[string]bool{"mod2": true}} // waived for a moderator (F14)
			page, err := f.svc.ListCommunityMembers(context.Background(), uid, MembersInput{CommunityID: testCID, Filter: FilterModerators})
			if err != nil {
				t.Fatal(err)
			}
			if got := fmt.Sprint(uids(page)); got != "[owner1 mod1 mod2 mod3]" {
				t.Fatalf("rows = %s", got)
			}
			wantRoles := []Role{RoleOwner, RoleModerator, RoleModerator, RoleModerator}
			for i, it := range page.Items {
				if it.Role != wantRoles[i] {
					t.Errorf("row %d role = %v, want %v", i, it.Role, wantRoles[i])
				}
				if want := f.repo.lst.entries[testCID+"|"+it.Profile.UserID].At; !it.Since.Equal(want) {
					t.Errorf("row %d since = %v, want joinedAt %v", i, it.Since, want)
				}
			}
			if page.NextPageToken != "" {
				t.Errorf("token = %q, want none (one page)", page.NextPageToken)
			}
			if len(f.repo.lst.memberQs) != 0 || len(f.repo.lst.byUIDCalls) != 1 {
				t.Errorf("queries = %d, batch reads = %d; want no query and one batch read", len(f.repo.lst.memberQs), len(f.repo.lst.byUIDCalls))
			}
		})
	}
}

func TestListCommunityMembers_ModeratorsDropsAndPaging(t *testing.T) {
	f := modsFixture()
	f.repo.lst.entries[testCID+"|mod2"] = MemberEntry{State: MemberBanned, At: testNow} // inconsistent: not JOINED, left out
	f.dir.profiles["mod3"] = profile("mod3", identity.AccountStatusDeleting)            // not ACTIVE, left out
	ctx := context.Background()
	page, err := f.svc.ListCommunityMembers(ctx, ownerUID, MembersInput{CommunityID: testCID, Filter: FilterModerators, PageSize: 1})
	if err != nil || fmt.Sprint(uids(page)) != "[owner1]" || page.NextPageToken == "" {
		t.Fatalf("page 1 = %v, token %q, %v", uids(page), page.NextPageToken, err)
	}
	// The token is bound to the filter: it does not open the JOINED or BANNED page.
	for _, other := range []MemberFilter{FilterJoined, FilterBanned} {
		_, err := f.svc.ListCommunityMembers(ctx, ownerUID, MembersInput{CommunityID: testCID, Filter: other, PageSize: 1, PageToken: page.NextPageToken})
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "page_token"})
	}
	page, err = f.svc.ListCommunityMembers(ctx, ownerUID, MembersInput{CommunityID: testCID, Filter: FilterModerators, PageSize: 1, PageToken: page.NextPageToken})
	if err != nil || fmt.Sprint(uids(page)) != "[mod1]" || page.NextPageToken == "" {
		t.Fatalf("page 2 = %v, token %q, %v", uids(page), page.NextPageToken, err)
	}
	page, err = f.svc.ListCommunityMembers(ctx, ownerUID, MembersInput{CommunityID: testCID, Filter: FilterModerators, PageSize: 1, PageToken: page.NextPageToken})
	// mod2 is not JOINED (skipped before paging); mod3 is kept by the page but dropped as not ACTIVE: a short last page.
	if err != nil || len(page.Items) != 0 || page.NextPageToken != "" {
		t.Fatalf("page 3 = %v, token %q, %v; want empty and no token", uids(page), page.NextPageToken, err)
	}
}

func TestMemberFilter_String(t *testing.T) {
	for f, want := range map[MemberFilter]string{FilterJoined: "joined", FilterBanned: "banned", FilterModerators: "moderators"} {
		if got := f.String(); got != want {
			t.Errorf("%d.String() = %q, want %q", f, got, want)
		}
	}
}

func TestServer_ListCommunityMembersFilterMapping(t *testing.T) {
	for _, tc := range []struct {
		in      communitiesv1.CommunityMemberFilter
		want    MemberFilter
		invalid bool
	}{
		{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_UNSPECIFIED, FilterJoined, false},
		{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_JOINED, FilterJoined, false},
		{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_BANNED, FilterBanned, false},
		{communitiesv1.CommunityMemberFilter_COMMUNITY_MEMBER_FILTER_MODERATORS, FilterModerators, false},
		{communitiesv1.CommunityMemberFilter(99), 0, true},
	} {
		t.Run(tc.in.String(), func(t *testing.T) {
			svc := &fakeService{}
			s := NewServer(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), svc)
			_, err := s.ListCommunityMembers(authedCtx("u1"), connect.NewRequest(&communitiesv1.ListCommunityMembersRequest{CommunityId: testCID, Filter: tc.in}))
			if tc.invalid {
				wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "filter"})
				if len(svc.membersIn) != 0 {
					t.Error("service called for an unknown filter")
				}
				return
			}
			if err != nil || len(svc.membersIn) != 1 || svc.membersIn[0].Filter != tc.want {
				t.Fatalf("err %v, inputs %+v, want filter %v", err, svc.membersIn, tc.want)
			}
		})
	}
}
