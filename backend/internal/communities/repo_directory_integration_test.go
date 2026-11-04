//go:build integration

package communities

import (
	"context"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func newListEnv(t *testing.T) *env {
	t.Helper()
	e := newEnv(t, 100)
	e.svc.d.CursorKey = testCursorKey
	return e
}

// seedDirCommunity writes one community document with an explicit memberCount and status.
func (e *env) seedDirCommunity(t *testing.T, cid string, n int64, st Status) {
	t.Helper()
	e.seedCommunity(t, Community{ID: cid, Name: "Dir " + cid[len(cid)-3:], OwnerID: "owner", MemberCount: n, Status: st}, nil)
}

// seedMemberAt writes a member doc with its state timestamp, i minutes before base.
func (e *env) seedMemberAt(t *testing.T, cid, uid string, st MemberState, base time.Time, i int) {
	t.Helper()
	at := base.Add(-time.Duration(i) * time.Minute).UTC()
	md := memberDoc{UID: uid, State: string(st)}
	if st == MemberJoined {
		md.JoinedAt = &at
	} else {
		md.BannedAt = &at
	}
	if _, err := e.repo.memberRef(cid, uid).Set(context.Background(), md); err != nil {
		t.Fatal(err)
	}
}

func TestDirectory_OrderFilterAndWarmEntry(t *testing.T) {
	e := newListEnv(t)
	cids := []string{"0000000000000000801", "0000000000000000802", "0000000000000000803", "0000000000000000804", "0000000000000000805"}
	e.seedDirCommunity(t, cids[0], 10, StatusActive)
	e.seedDirCommunity(t, cids[1], 99, StatusSuspended)
	e.seedDirCommunity(t, cids[2], 50, StatusActive)
	e.seedDirCommunity(t, cids[3], 70, StatusArchived)
	e.seedDirCommunity(t, cids[4], 30, StatusActive)
	e.seedMemberships(t, "member", Memberships{Joined: []string{cids[2]}, Banned: []string{cids[4]}})

	got, err := e.svc.ListCommunities(context.Background(), "member", "")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{cids[2], cids[4], cids[0]}
	if len(got) != 3 {
		t.Fatalf("directory = %d rows, want 3 (SUSPENDED and ARCHIVED absent)", len(got))
	}
	for i, v := range got {
		if v.Community.ID != want[i] {
			t.Errorf("row %d = %s, want %s (memberCount descending)", i, v.Community.ID, want[i])
		}
	}
	if got[0].Role != RoleMember || got[1].Role != RoleBanned || got[2].Role != RoleNone {
		t.Errorf("roles = %v %v %v", got[0].Role, got[1].Role, got[2].Role)
	}
	// the shared entry is warm: with the first community deleted behind the cache, the same viewer and another viewer still get all 3 rows
	if _, err := e.client.Doc("communities/" + cids[0]).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, uid := range []string{"member", "stranger"} {
		warm, err := e.svc.ListCommunities(context.Background(), uid, "")
		if err != nil || len(warm) != 3 {
			t.Fatalf("warm directory for %s = %d rows, %v, want the cached 3", uid, len(warm), err)
		}
	}
}

func TestDirectory_RowsStopAtTheDirectoryMax(t *testing.T) {
	for _, n := range []int{20, 50} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			e := newListEnv(t)
			for i := range n + 5 { // more documents than the directory holds
				e.seedDirCommunity(t, fmt.Sprintf("%019d", 900+i), int64(1000-i), StatusActive)
			}
			rows := min(n+5, DirectoryMax)
			got, err := e.svc.ListCommunities(context.Background(), "member", "")
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != rows {
				t.Errorf("rows = %d, want %d", len(got), rows)
			}
		})
	}
}

func TestDirectory_SuspendedAfterTheTTLDisappears(t *testing.T) {
	e := newListEnv(t)
	cid := "0000000000000000811"
	e.seedDirCommunity(t, cid, 5, StatusActive)
	if got, _ := e.svc.ListCommunities(context.Background(), "member", ""); len(got) != 1 {
		t.Fatalf("rows = %d", len(got))
	}
	if _, err := e.repo.ref(cid).Update(context.Background(), []firestore.Update{{Path: "status", Value: string(StatusSuspended)}}); err != nil {
		t.Fatal(err)
	}
	e.svc.now = func() time.Time { return time.Now().Add(DirectoryTTL + time.Second) }
	if got, _ := e.svc.ListCommunities(context.Background(), "member", ""); len(got) != 0 {
		t.Errorf("rows = %d after the entry expired, want the suspended community gone", len(got))
	}
}

func (e *env) seedPageCommunity(t *testing.T, cid string, joined, banned int) {
	t.Helper()
	base := time.Now().Add(-time.Hour)
	e.seedCommunity(t, Community{ID: cid, Name: "Members", OwnerID: "owner", ModeratorIDs: []string{"mod1"}, MemberCount: int64(joined)}, nil)
	for i := range joined {
		uid := fmt.Sprintf("j%03d", i)
		e.dir.profiles[uid] = profile(uid, identity.AccountStatusActive)
		e.seedMemberAt(t, cid, uid, MemberJoined, base, i)
	}
	for i := range banned {
		uid := fmt.Sprintf("b%03d", i)
		e.dir.profiles[uid] = profile(uid, identity.AccountStatusActive)
		e.seedMemberAt(t, cid, uid, MemberBanned, base, i)
	}
}

func TestMembers_FirstPageAt20And50(t *testing.T) {
	for _, size := range []int32{20, 50} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			e := newListEnv(t)
			cid := "0000000000000000821"
			e.seedPageCommunity(t, cid, 60, 0)
			page, err := e.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: cid, PageSize: size})
			if err != nil {
				t.Fatal(err)
			}
			if len(page.Items) != int(size) || page.NextPageToken == "" {
				t.Errorf("rows = %d, token %q", len(page.Items), page.NextPageToken)
			}
			// the second call is served warm and answers the same page
			again, err := e.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: cid, PageSize: size})
			if err != nil || fmt.Sprint(uids(again)) != fmt.Sprint(uids(page)) {
				t.Errorf("second call = %v, %v, want the same page %v", uids(again), err, uids(page))
			}
		})
	}
}

func TestMembers_PagingWalksEveryMemberOnceNewestFirst(t *testing.T) {
	e := newListEnv(t)
	cid := "0000000000000000822"
	e.seedPageCommunity(t, cid, 55, 3)
	var seen []string
	token := ""
	for pages := 0; ; pages++ {
		if pages > 10 {
			t.Fatal("paging does not end")
		}
		p, err := e.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: cid, PageSize: 20, PageToken: token})
		if err != nil {
			t.Fatal(err)
		}
		for _, it := range p.Items {
			seen = append(seen, it.Profile.UserID)
			if it.Since.IsZero() {
				t.Errorf("%s has no since", it.Profile.UserID)
			}
		}
		if token = p.NextPageToken; token == "" {
			break
		}
	}
	if len(seen) != 55 {
		t.Fatalf("saw %d members, want 55 (banned users never on the JOINED page)", len(seen))
	}
	for i, u := range seen {
		if u != fmt.Sprintf("j%03d", i) {
			t.Fatalf("row %d = %s, want j%03d (joinedAt descending)", i, u, i)
		}
	}
}

func TestMembers_BannedPageForModeratorsOnly(t *testing.T) {
	e := newListEnv(t)
	cid := "0000000000000000823"
	e.seedPageCommunity(t, cid, 5, 4)
	for _, uid := range []string{"member", "stranger", "b000"} {
		_, err := e.svc.ListCommunityMembers(context.Background(), uid, MembersInput{CommunityID: cid, Filter: FilterBanned})
		wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})
	}
	for _, uid := range []string{"owner", "mod1"} {
		page, err := e.svc.ListCommunityMembers(context.Background(), uid, MembersInput{CommunityID: cid, Filter: FilterBanned})
		if err != nil {
			t.Fatal(err)
		}
		if len(page.Items) != 4 || page.Items[0].Profile.UserID != "b000" || page.Items[0].Role != RoleBanned {
			t.Errorf("%s: banned page = %v", uid, uids(page))
		}
	}
}

func TestMembers_BanMovesARowFromOnePageToTheOther(t *testing.T) {
	e := newListEnv(t)
	cid := "0000000000000000824"
	e.seedPageCommunity(t, cid, 3, 0)
	// a ban: bannedAt set, joinedAt removed
	at := time.Now().UTC()
	if _, err := e.repo.memberRef(cid, "j001").Set(context.Background(), memberDoc{UID: "j001", State: string(MemberBanned), BannedAt: &at}); err != nil {
		t.Fatal(err)
	}
	joined, err := e.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: cid})
	if err != nil || fmt.Sprint(uids(joined)) != "[j000 j002]" {
		t.Fatalf("joined = %v, %v", uids(joined), err)
	}
	banned, err := e.svc.ListCommunityMembers(context.Background(), "owner", MembersInput{CommunityID: cid, Filter: FilterBanned})
	if err != nil || fmt.Sprint(uids(banned)) != "[j001]" {
		t.Fatalf("banned = %v, %v", uids(banned), err)
	}
}

func TestMembers_BlocksAndTamperedToken(t *testing.T) {
	e := newListEnv(t)
	cid := "0000000000000000825"
	e.seedPageCommunity(t, cid, 4, 0)
	e.gr.snap = graph.Snapshot{BlockedBy: map[string]bool{"j001": true}, Blocked: map[string]bool{"j002": true}}
	p, err := e.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: cid, PageSize: 3})
	if err != nil || fmt.Sprint(uids(p)) != "[j000]" || p.NextPageToken == "" {
		t.Fatalf("page = %v, %q, %v (the member who blocks the viewer and the one the viewer blocks are absent)", uids(p), p.NextPageToken, err)
	}
	owner, err := e.svc.ListCommunityMembers(context.Background(), "owner", MembersInput{CommunityID: cid, PageSize: 3})
	if err != nil || fmt.Sprint(uids(owner)) != "[j000 j001 j002]" {
		t.Fatalf("owner page = %v, %v (F14: moderators see every member)", uids(owner), err)
	}
	for name, tok := range map[string]string{"tampered": p.NextPageToken + "x", "foreign": owner.NextPageToken} {
		t.Run(name, func(t *testing.T) {
			_, err := e.svc.ListCommunityMembers(context.Background(), "viewer", MembersInput{CommunityID: cid, PageSize: 3, PageToken: tok})
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "page_token"})
		})
	}
}
