package communities

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

var testCursorKey = []byte("0123456789abcdef0123456789abcdef")

func newListFixture() *fixture {
	f := newFixture()
	f.svc.d.CursorKey = testCursorKey
	f.svc.now = func() time.Time { return testNow }
	return f
}

func dirCommunity(id string, n int64, st Status) Community {
	return Community{ID: id, Name: "C" + id[len(id)-3:], MemberCount: n, Status: st, Visibility: VisibilityPublic, OwnerID: ownerUID, ModeratorIDs: []string{modUID}}
}

func (f *fixture) seedMembers(cid string, banned bool, uids ...string) {
	rows := make([]MemberRow, len(uids))
	for i, u := range uids {
		rows[i] = MemberRow{UID: u, At: testNow.Add(-time.Duration(i) * time.Minute)}
		f.dir.profiles[u] = profile(u, identity.AccountStatusActive)
	}
	if f.repo.lst.pages == nil {
		f.repo.lst.pages = map[string][]MemberRow{}
	}
	f.repo.lst.pages[pageKey(cid, banned)] = rows
}

func counted(fn func(ctx context.Context)) *budget.Counter {
	ctx, c := budget.WithCounter(context.Background())
	fn(ctx)
	return c
}

func TestListCommunities_FiltersAndRoles(t *testing.T) {
	f := newListFixture()
	f.repo.lst.rank = []Community{
		dirCommunity("0000000000000000601", 90, StatusActive),
		dirCommunity("0000000000000000602", 80, StatusSuspended),
		dirCommunity("0000000000000000603", 70, StatusArchived),
		dirCommunity("0000000000000000604", 60, StatusActive),
		dirCommunity("0000000000000000605", 50, StatusActive),
		dirCommunity("0000000000000000606", 40, StatusActive),
	}
	f.repo.mships = map[string]Memberships{"u1": {Joined: []string{"0000000000000000604"}, Banned: []string{"0000000000000000605"}}}
	tests := []struct {
		uid  string
		want []Role
	}{
		{"u1", []Role{RoleNone, RoleMember, RoleBanned, RoleNone}},
		{ownerUID, []Role{RoleOwner, RoleOwner, RoleOwner, RoleOwner}},
		{modUID, []Role{RoleModerator, RoleModerator, RoleModerator, RoleModerator}},
	}
	for _, tc := range tests {
		t.Run(tc.uid, func(t *testing.T) {
			got, err := f.svc.ListCommunities(context.Background(), tc.uid, "")
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 4 {
				t.Fatalf("%d rows, want the 4 ACTIVE ones (SUSPENDED and ARCHIVED are absent)", len(got))
			}
			wantIDs := []string{"0000000000000000601", "0000000000000000604", "0000000000000000605", "0000000000000000606"}
			for i, v := range got {
				if v.Community.ID != wantIDs[i] || v.Role != tc.want[i] {
					t.Errorf("row %d = %s/%v, want %s/%v", i, v.Community.ID, v.Role, wantIDs[i], tc.want[i])
				}
			}
		})
	}
}

func TestListCommunities_WarmEntryAndTTL(t *testing.T) {
	f := newListFixture()
	f.repo.lst.rank = []Community{dirCommunity("0000000000000000601", 5, StatusActive)}
	f.repo.mships = map[string]Memberships{}
	cold := counted(func(ctx context.Context) {
		if _, err := f.svc.ListCommunities(ctx, "u1", ""); err != nil {
			t.Fatal(err)
		}
	})
	if cold.Reads() != 2 { // 1 directory row + the caller's memberships
		t.Errorf("cold reads = %d, want 2", cold.Reads())
	}
	warm := counted(func(ctx context.Context) {
		if _, err := f.svc.ListCommunities(ctx, "u2", ""); err != nil {
			t.Fatal(err)
		}
	})
	if warm.Reads() != 1 || f.repo.lst.dirCalls != 1 { // only u2's memberships; the shared entry is warm
		t.Errorf("warm reads = %d, refills = %d, want 1 and 1", warm.Reads(), f.repo.lst.dirCalls)
	}
	again := counted(func(ctx context.Context) { _, _ = f.svc.ListCommunities(ctx, "u1", "") })
	if again.Reads() != 0 {
		t.Errorf("fully warm reads = %d, want 0", again.Reads())
	}
	f.svc.now = func() time.Time { return testNow.Add(DirectoryTTL + time.Second) }
	_, _ = f.svc.ListCommunities(context.Background(), "u1", "")
	if f.repo.lst.dirCalls != 2 {
		t.Errorf("refills after the TTL = %d, want 2", f.repo.lst.dirCalls)
	}
}

func TestListCommunities_PageTokenIsValidationAt0Reads(t *testing.T) {
	f := newListFixture()
	c := counted(func(ctx context.Context) {
		_, err := f.svc.ListCommunities(ctx, "u1", "x")
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "page_token"})
	})
	if c.Reads() != 0 || f.repo.lst.dirCalls != 0 {
		t.Errorf("reads = %d, refills = %d, want 0", c.Reads(), f.repo.lst.dirCalls)
	}
}

func TestListCommunities_JoinForgetsTheCachedMemberships(t *testing.T) {
	f := newListFixture()
	cid := "0000000000000000601"
	f.repo.lst.rank = []Community{dirCommunity(cid, 5, StatusActive)}
	f.repo.mships = map[string]Memberships{}
	f.seed(dirCommunity(cid, 5, StatusActive))
	f.dir.profiles["u1"] = profile("u1", identity.AccountStatusActive)
	f.repo.joinRes = JoinResult{Outcome: Written, State: MemberJoined}
	got, _ := f.svc.ListCommunities(context.Background(), "u1", "")
	if got[0].Role != RoleNone {
		t.Fatalf("role before the join = %v", got[0].Role)
	}
	if _, err := f.svc.JoinCommunity(context.Background(), "u1", MembershipInput{Key: goodKey, CommunityID: cid}); err != nil {
		t.Fatal(err)
	}
	f.repo.mu.Lock()
	f.repo.mships["u1"] = Memberships{Joined: []string{cid}}
	f.repo.mu.Unlock()
	got, _ = f.svc.ListCommunities(context.Background(), "u1", "")
	if got[0].Role != RoleMember {
		t.Errorf("role after the join = %v, want MEMBER at once on this instance", got[0].Role)
	}
}

func TestListCommunities_RefillIsSingleFlightAndErrorsAreNotCached(t *testing.T) {
	f := newListFixture()
	f.repo.lst.rank = []Community{dirCommunity("0000000000000000601", 5, StatusActive)}
	f.repo.mships = map[string]Memberships{}
	f.repo.lst.dirErr = errors.New("boom")
	if _, err := f.svc.ListCommunities(context.Background(), "u1", ""); err == nil {
		t.Fatal("want the repository error")
	}
	f.repo.mu.Lock()
	f.repo.lst.dirErr = nil
	f.repo.mu.Unlock()
	var wg sync.WaitGroup
	for i := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := f.svc.ListCommunities(context.Background(), fmt.Sprintf("u%d", i), ""); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	f.repo.mu.Lock()
	defer f.repo.mu.Unlock()
	if f.repo.lst.dirCalls < 2 || f.repo.lst.dirCalls > 9 {
		t.Errorf("refills = %d", f.repo.lst.dirCalls)
	}
}

func membersFixture() *fixture {
	f := newListFixture()
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: []string{modUID}})
	f.seedMembers(testCID, false, ownerUID, modUID, "a", "b", "c", "d")
	f.seedMembers(testCID, true, "x", "y")
	f.dir.profiles["d"] = profile("d", identity.AccountStatusDeleting)
	return f
}

func uids(p MembersPage) []string {
	var out []string
	for _, it := range p.Items {
		out = append(out, it.Profile.UserID)
	}
	return out
}

func TestListCommunityMembers_Drops(t *testing.T) {
	tests := []struct {
		name string
		uid  string
		snap graph.Snapshot
		want []string
	}{
		{"plain viewer, no blocks", "viewer", graph.Snapshot{}, []string{ownerUID, modUID, "a", "b", "c"}},
		{"a member the viewer blocks is dropped", "viewer", graph.Snapshot{Blocked: map[string]bool{"a": true}}, []string{ownerUID, modUID, "b", "c"}},
		{"a member who blocks the viewer is dropped", "viewer", graph.Snapshot{BlockedBy: map[string]bool{"b": true}}, []string{ownerUID, modUID, "a", "c"}},
		{"a muted member is shown", "viewer", graph.Snapshot{Muted: map[string]bool{"c": true}}, []string{ownerUID, modUID, "a", "b", "c"}},
		{"the owner sees a member who blocks them (F14)", ownerUID, graph.Snapshot{BlockedBy: map[string]bool{"a": true}}, []string{ownerUID, modUID, "a", "b", "c"}},
		{"a moderator sees both directions (F14)", modUID, graph.Snapshot{BlockedBy: map[string]bool{"a": true}, Blocked: map[string]bool{"b": true}}, []string{ownerUID, modUID, "a", "b", "c"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f := membersFixture()
			f.gr.snap = tc.snap
			page, err := f.svc.ListCommunityMembers(context.Background(), tc.uid, MembersInput{CommunityID: testCID})
			if err != nil {
				t.Fatal(err)
			}
			got := uids(page)
			if fmt.Sprint(got) != fmt.Sprint(tc.want) { // "d" (not ACTIVE) is always absent
				t.Errorf("rows = %v, want %v", got, tc.want)
			}
			if page.NextPageToken != "" {
				t.Errorf("token = %q on a short page", page.NextPageToken)
			}
		})
	}
}

func TestListCommunityMembers_RolesRelationshipAndSince(t *testing.T) {
	f := membersFixture()
	f.gr.snap = graph.Snapshot{Following: map[string]bool{"a": true}, Muted: map[string]bool{"c": true}}
	page, err := f.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: testCID})
	if err != nil {
		t.Fatal(err)
	}
	wantRole := map[string]Role{ownerUID: RoleOwner, modUID: RoleModerator, "a": RoleMember}
	for _, it := range page.Items {
		if want, ok := wantRole[it.Profile.UserID]; ok && it.Role != want {
			t.Errorf("%s role = %v, want %v", it.Profile.UserID, it.Role, want)
		}
		if it.Since.IsZero() {
			t.Errorf("%s has no since", it.Profile.UserID)
		}
		if it.Profile.UserID == "a" && it.Relationship.FollowState != graph.FollowStateFollowing {
			t.Errorf("a relationship = %+v", it.Relationship)
		}
		if it.Profile.UserID == "c" && !it.Relationship.Muting {
			t.Errorf("c relationship = %+v", it.Relationship)
		}
	}
}

func TestListCommunityMembers_BannedPage(t *testing.T) {
	for _, uid := range []string{"viewer", "a", bannedUID, nobodyUID} {
		t.Run("refused/"+uid, func(t *testing.T) {
			f := membersFixture()
			f.repo.members = map[string]MemberState{testCID + "|a": MemberJoined, testCID + "|" + bannedUID: MemberBanned}
			c := counted(func(ctx context.Context) {
				_, err := f.svc.ListCommunityMembers(ctx, uid, MembersInput{CommunityID: testCID, Filter: FilterBanned})
				wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})
			})
			if c.Reads() != 1 || len(f.repo.lst.memberQs) != 0 || f.repo.memberGet != 0 {
				t.Errorf("reads = %d (want the community read only), queries = %d, member docs = %d", c.Reads(), len(f.repo.lst.memberQs), f.repo.memberGet)
			}
		})
	}
	for _, uid := range []string{ownerUID, modUID} {
		t.Run("allowed/"+uid, func(t *testing.T) {
			f := membersFixture()
			f.gr.snap = graph.Snapshot{BlockedBy: map[string]bool{"x": true}} // waived for a moderator
			page, err := f.svc.ListCommunityMembers(context.Background(), uid, MembersInput{CommunityID: testCID, Filter: FilterBanned})
			if err != nil {
				t.Fatal(err)
			}
			if fmt.Sprint(uids(page)) != "[x y]" || page.Items[0].Role != RoleBanned {
				t.Errorf("rows = %v, role %v", uids(page), page.Items[0].Role)
			}
			if !f.repo.lst.memberQs[0].Banned {
				t.Error("the banned query was not used")
			}
		})
	}
}

func TestListCommunityMembers_NotFoundAndValidation(t *testing.T) {
	f := membersFixture()
	f.seed(Community{ID: otherCID, Name: "S", OwnerID: ownerUID, Status: StatusSuspended})
	for name, id := range map[string]string{"suspended, even for the owner": otherCID, "missing": "0000000000000000999"} {
		_, err := f.svc.ListCommunityMembers(context.Background(), ownerUID, MembersInput{CommunityID: id})
		t.Log(name)
		wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	}
	c := counted(func(ctx context.Context) {
		_, err := f.svc.ListCommunityMembers(ctx, "viewer", MembersInput{CommunityID: "12"})
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "community_id"})
	})
	if c.Reads() != 0 {
		t.Errorf("reads = %d", c.Reads())
	}
}

func TestListCommunityMembers_PagingAndCursorBinding(t *testing.T) {
	f := membersFixture()
	f.gr.snap = graph.Snapshot{Blocked: map[string]bool{"b": true, "c": true}}
	in := MembersInput{CommunityID: testCID, PageSize: 2}
	p1, err := f.svc.ListCommunityMembers(context.Background(), "viewer", in)
	if err != nil || p1.NextPageToken == "" || fmt.Sprint(uids(p1)) != "[owner1 mod1]" {
		t.Fatalf("page 1 = %v, %q, %v", uids(p1), p1.NextPageToken, err)
	}
	in.PageToken = p1.NextPageToken
	p2, err := f.svc.ListCommunityMembers(context.Background(), "viewer", in) // a, b: b is dropped
	if err != nil || fmt.Sprint(uids(p2)) != "[a]" || p2.NextPageToken == "" {
		t.Fatalf("page 2 = %v, %q, %v (a short page keeps its token)", uids(p2), p2.NextPageToken, err)
	}
	in.PageToken = p2.NextPageToken
	p3, err := f.svc.ListCommunityMembers(context.Background(), "viewer", in) // c dropped, d inactive: empty, and the page was full
	if err != nil || len(p3.Items) != 0 || p3.NextPageToken == "" {
		t.Fatalf("page 3 = %v, %q, %v", uids(p3), p3.NextPageToken, err)
	}
	in.PageToken = p3.NextPageToken
	p4, err := f.svc.ListCommunityMembers(context.Background(), "viewer", in)
	if err != nil || len(p4.Items) != 0 || p4.NextPageToken != "" {
		t.Fatalf("page 4 = %v, %q, %v", uids(p4), p4.NextPageToken, err)
	}

	expired := cursor.EncodeAt(testCursorKey, membersBinding("viewer", testCID, FilterJoined), cursor.Cursor{CreatedAt: testNow, DocID: "a"}, time.Now().Add(-25*time.Hour))
	wrong := map[string]struct {
		uid   string
		in    MembersInput
		token string
	}{
		"another caller":    {"someone", MembersInput{CommunityID: testCID, PageSize: 2}, p1.NextPageToken},
		"another community": {"viewer", MembersInput{CommunityID: otherCID, PageSize: 2}, p1.NextPageToken},
		"the banned filter": {ownerUID, MembersInput{CommunityID: testCID, PageSize: 2, Filter: FilterBanned}, p1.NextPageToken},
		"tampered":          {"viewer", MembersInput{CommunityID: testCID}, p1.NextPageToken + "A"},
		"garbage":           {"viewer", MembersInput{CommunityID: testCID}, "not-a-token"},
		"expired":           {"viewer", MembersInput{CommunityID: testCID}, expired},
		"not a uid":         {"viewer", MembersInput{CommunityID: testCID}, cursor.Encode(testCursorKey, membersBinding("viewer", testCID, FilterJoined), cursor.Cursor{CreatedAt: testNow, DocID: "a/b"})},
	}
	for name, tc := range wrong {
		t.Run(name, func(t *testing.T) {
			tc.in.PageToken = tc.token
			c := counted(func(ctx context.Context) {
				_, err := f.svc.ListCommunityMembers(ctx, tc.uid, tc.in)
				wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "page_token"})
			})
			if c.Reads() != 0 {
				t.Errorf("reads = %d, want 0", c.Reads())
			}
		})
	}
}

func TestListCommunityMembers_UnspecifiedAndJoinedBindTheSame(t *testing.T) {
	if membersBinding("u", testCID, FilterJoined) != membersBinding("u", testCID, MemberFilter(0)) {
		t.Fatal("UNSPECIFIED and JOINED must seal the same binding")
	}
}

func TestListCommunityMembers_ClampsPageSize(t *testing.T) {
	f := membersFixture()
	for in, want := range map[int32]int{0: 20, -3: 20, 7: 7, 500: 50} {
		f.repo.lst.memberQs = nil
		if _, err := f.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: testCID, PageSize: in}); err != nil {
			t.Fatal(err)
		}
		if got := f.repo.lst.memberQs[0].Limit; got != want {
			t.Errorf("page_size %d queried %d, want %d", in, got, want)
		}
	}
}

func TestListCommunityMembers_ColdBudgetAtPage20(t *testing.T) {
	f := newListFixture()
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID})
	names := make([]string, 20)
	for i := range names {
		names[i] = fmt.Sprintf("m%02d", i)
	}
	f.seedMembers(testCID, false, names...)
	c := counted(func(ctx context.Context) {
		if _, err := f.svc.ListCommunityMembers(ctx, "viewer", MembersInput{CommunityID: testCID}); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 42 { // community 1 + page 20 + profiles 20 + graph 1 (the interceptor's 1 is on top: 43)
		t.Errorf("reads = %d, want 42", c.Reads())
	}
}
