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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestRepo_MembersByUID: one batch read; JOINED and BANNED docs with their time, a missing doc absent; over the bound is
// an error, not a silent truncation.
func TestRepo_MembersByUID(t *testing.T) {
	e := newListEnv(t)
	cid := "0000000000000000851"
	base := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	e.seedCommunity(t, Community{ID: cid, Name: "Search", OwnerID: "owner", MemberCount: 2}, nil)
	e.seedMemberAt(t, cid, "owner", MemberJoined, base, 0)
	e.seedMemberAt(t, cid, "b000", MemberBanned, base, 9)
	got, err := e.repo.MembersByUID(context.Background(), cid, []string{"owner", "b000", "nobody"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got["owner"].State != MemberJoined || !got["owner"].At.Equal(base.UTC()) ||
		got["b000"].State != MemberBanned || !got["b000"].At.Equal(base.Add(-9*time.Minute).UTC()) {
		t.Fatalf("entries = %+v", got)
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

// TestSearchCommunityMembers_OnTheEmulator (F36): the real member docs decide. JOINED search keeps members only (a
// non-member and a banned user with a matching handle are dropped); BANNED search for a moderator returns the banned
// user; BANNED for a member is FORBIDDEN; the flag off answers FEATURE_DISABLED with nothing read.
func TestSearchCommunityMembers_OnTheEmulator(t *testing.T) {
	e := newListEnv(t)
	ctx := context.Background()
	cid := "0000000000000000852"
	base := time.Now().Add(-time.Hour).Truncate(time.Millisecond)
	e.seedCommunity(t, Community{ID: cid, Name: "Search", OwnerID: "owner", ModeratorIDs: []string{"mod1"}, MemberCount: 4}, nil)
	for i, uid := range []string{"owner", "mod1", "alice", "alina"} {
		e.dir.profiles[uid] = profile(uid, identity.AccountStatusActive)
		e.seedMemberAt(t, cid, uid, MemberJoined, base, i)
	}
	e.seedMemberAt(t, cid, "albert", MemberBanned, base, 9)
	px := &fakePrefixes{users: []string{"albert", "alex", "alice", "alina", "mod1", "owner"}}
	e.svc.d.Handles = px
	e.svc.d.Flags = flags.NewRegistry(flags.Spec{Name: MemberSearchFlagName, Mode: flags.On})

	items, err := e.svc.SearchCommunityMembers(ctx, "alice", SearchInput{CommunityID: cid, Prefix: "al"})
	if err != nil || itemUIDs(items) != "[alice alina]" {
		t.Fatalf("joined search = %s, %v; want [alice alina] (alex is not a member, albert is banned)", itemUIDs(items), err)
	}
	if !items[0].Since.Equal(base.Add(-2 * time.Minute).UTC()) {
		t.Errorf("alice since = %v, want her joinedAt", items[0].Since)
	}
	items, err = e.svc.SearchCommunityMembers(ctx, "mod1", SearchInput{CommunityID: cid, Prefix: "al", Filter: FilterBanned})
	if err != nil || itemUIDs(items) != "[albert]" || items[0].Role != RoleBanned {
		t.Fatalf("banned search = %s, %v", itemUIDs(items), err)
	}
	_, err = e.svc.SearchCommunityMembers(ctx, "alice", SearchInput{CommunityID: cid, Prefix: "al", Filter: FilterBanned})
	wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})

	e.svc.d.Flags = flags.NewRegistry(flags.Spec{Name: MemberSearchFlagName, Mode: flags.Off})
	calls := len(px.calls)
	_, err = e.svc.SearchCommunityMembers(ctx, "alice", SearchInput{CommunityID: cid, Prefix: "al"})
	wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": MemberSearchFlagName})
	if len(px.calls) != calls {
		t.Error("the flag-off call looked up handles")
	}
}
