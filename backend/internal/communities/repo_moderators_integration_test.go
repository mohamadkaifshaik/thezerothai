//go:build integration

package communities

import (
	"context"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// seedModsCommunity: owner "owner" and moderators mod2, mod1 (appointment order) on the community document, each with a
// JOINED member doc, plus members j000..j002 and banned b000.
func (e *env) seedModsCommunity(t *testing.T, cid string) time.Time {
	t.Helper()
	base := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	e.seedCommunity(t, Community{ID: cid, Name: "Mods", OwnerID: "owner", ModeratorIDs: []string{"mod2", "mod1"}, MemberCount: 6}, nil)
	for i, uid := range []string{"owner", "mod1", "mod2", "j000", "j001", "j002"} {
		e.dir.profiles[uid] = profile(uid, identity.AccountStatusActive)
		e.seedMemberAt(t, cid, uid, MemberJoined, base, i)
	}
	e.dir.profiles["b000"] = profile("b000", identity.AccountStatusActive)
	e.seedMemberAt(t, cid, "b000", MemberBanned, base, 9)
	return base
}

// TestRepo_MembersByUID: one batch read; JOINED and BANNED docs with their time, a missing doc absent; over the bound is
// an error, not a silent truncation.
func TestRepo_MembersByUID(t *testing.T) {
	e := newListEnv(t)
	cid := "0000000000000000841"
	base := e.seedModsCommunity(t, cid)
	got, err := e.repo.MembersByUID(context.Background(), cid, []string{"owner", "b000", "nobody", "j002"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("entries = %v, want owner, b000 and j002", got)
	}
	if m := got["owner"]; m.State != MemberJoined || !m.At.Equal(base.UTC()) {
		t.Errorf("owner = %+v", m)
	}
	if m := got["b000"]; m.State != MemberBanned || !m.At.Equal(base.Add(-9*time.Minute).UTC()) {
		t.Errorf("b000 = %+v", m)
	}
	if _, ok := got["nobody"]; ok {
		t.Error("a missing doc is in the map")
	}
	if empty, err := e.repo.MembersByUID(context.Background(), cid, nil); err != nil || len(empty) != 0 {
		t.Errorf("no uids = %v, %v", empty, err)
	}
	many := make([]string, maxMembersByUID+1)
	for i := range many {
		many[i] = fmt.Sprintf("u%03d", i)
	}
	if _, err := e.repo.MembersByUID(context.Background(), cid, many); err == nil {
		t.Error("over the bound: no error")
	}
}

// TestMembers_ModeratorsPage (F24): owner and moderators only (anyone else FORBIDDEN not_moderator), owner first then
// moderators by uid, each with role and since = joinedAt; a demoted moderator leaves the page, a moderator who was banned
// (inconsistent doc) is left out; paging with page_size 1 walks every row once.
func TestMembers_ModeratorsPage(t *testing.T) {
	e := newListEnv(t)
	ctx := context.Background()
	cid := "0000000000000000842"
	base := e.seedModsCommunity(t, cid)
	for _, uid := range []string{"j000", "stranger", "b000"} {
		_, err := e.svc.ListCommunityMembers(ctx, uid, MembersInput{CommunityID: cid, Filter: FilterModerators})
		wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})
	}
	for _, uid := range []string{"owner", "mod2"} {
		page, err := e.svc.ListCommunityMembers(ctx, uid, MembersInput{CommunityID: cid, Filter: FilterModerators})
		if err != nil {
			t.Fatal(err)
		}
		if fmt.Sprint(uids(page)) != "[owner mod1 mod2]" || page.NextPageToken != "" {
			t.Fatalf("%s: page = %v, token %q", uid, uids(page), page.NextPageToken)
		}
		if page.Items[0].Role != RoleOwner || page.Items[1].Role != RoleModerator || page.Items[2].Role != RoleModerator {
			t.Errorf("roles = %v %v %v", page.Items[0].Role, page.Items[1].Role, page.Items[2].Role)
		}
		if !page.Items[1].Since.Equal(base.Add(-time.Minute).UTC()) {
			t.Errorf("mod1 since = %v, want its joinedAt", page.Items[1].Since)
		}
	}
	var walked []string
	token := ""
	for range 5 {
		page, err := e.svc.ListCommunityMembers(ctx, "owner", MembersInput{CommunityID: cid, Filter: FilterModerators, PageSize: 1, PageToken: token})
		if err != nil {
			t.Fatal(err)
		}
		walked = append(walked, uids(page)...)
		if token = page.NextPageToken; token == "" {
			break
		}
	}
	if fmt.Sprint(walked) != "[owner mod1 mod2]" {
		t.Fatalf("paged walk = %v", walked)
	}
	// mod1 is banned in an inconsistent write: the member doc decides, and the row is left out.
	e.seedMemberAt(t, cid, "mod1", MemberBanned, base, 0)
	page, err := e.svc.ListCommunityMembers(ctx, "owner", MembersInput{CommunityID: cid, Filter: FilterModerators})
	if err != nil || fmt.Sprint(uids(page)) != "[owner mod2]" {
		t.Fatalf("after mod1's member doc turned BANNED: %v, %v", uids(page), err)
	}
}
