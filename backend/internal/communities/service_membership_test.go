package communities

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func joinFixture(t *testing.T) *fixture {
	t.Helper()
	f := newFixture(ownerUID)
	f.svc.now = func() time.Time { return testNow }
	f.dir.profiles[memberUID] = profile(memberUID, identity.AccountStatusActive)
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: []string{modUID}, MemberCount: 4, CreatedAt: testNow})
	return f
}

func in(cid string) MembershipInput { return MembershipInput{Key: goodKey, CommunityID: cid} }

func TestMembership_Validation(t *testing.T) {
	tests := []struct {
		name  string
		in    MembershipInput
		field string
	}{
		{"short key", MembershipInput{Key: "x", CommunityID: testCID}, "idempotency_key"},
		{"short id", MembershipInput{Key: goodKey, CommunityID: "12"}, "community_id"},
		{"empty id", MembershipInput{Key: goodKey}, "community_id"},
	}
	for _, op := range []string{"join", "leave"} {
		for _, tt := range tests {
			t.Run(op+"/"+tt.name, func(t *testing.T) {
				f := joinFixture(t)
				var err error
				if op == "join" {
					_, err = f.svc.JoinCommunity(context.Background(), memberUID, tt.in)
				} else {
					_, err = f.svc.LeaveCommunity(context.Background(), memberUID, tt.in)
				}
				wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
				if f.repo.gets+len(f.repo.joins)+len(f.repo.leaves) != 0 {
					t.Error("repo reached with invalid input")
				}
			})
		}
	}
}

func TestJoin_RefusalsBeforeTheTransaction(t *testing.T) {
	tests := []struct {
		name    string
		c       Community
		wantErr func(*testing.T, error)
	}{
		{"missing", Community{}, func(t *testing.T, err error) {
			wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		}},
		{"suspended, even for the owner", Community{ID: testCID, Status: StatusSuspended, OwnerID: ownerUID}, func(t *testing.T, err error) {
			wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		}},
		{"archived", Community{ID: testCID, Status: StatusArchived}, func(t *testing.T, err error) {
			wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, map[string]string{"reason": "community_archived"})
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := joinFixture(t)
			delete(f.repo.docs, testCID)
			if tt.c.ID != "" {
				f.seed(tt.c)
			}
			_, err := f.svc.JoinCommunity(context.Background(), ownerUID, in(testCID))
			tt.wantErr(t, err)
			if len(f.repo.joins) != 0 {
				t.Error("the transaction ran")
			}
		})
	}
}

func TestJoin_MapsRepoErrors(t *testing.T) {
	tests := []struct {
		name   string
		err    error
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"banned", ErrBanned, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "banned"}},
		{"cap", ErrJoinedLimit, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "communities_joined"}},
		{"gone since the cache", ErrNotFound, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
		{"key reused", ErrKeyReused, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := joinFixture(t)
			f.repo.joinErr = tt.err
			_, err := f.svc.JoinCommunity(context.Background(), memberUID, in(testCID))
			wantAPIErr(t, err, tt.code, tt.reason, tt.meta)
		})
	}
	t.Run("unknown error names no id", func(t *testing.T) {
		f := joinFixture(t)
		f.repo.joinErr = fmt.Errorf("rpc error: documents/communityMemberships/%s", memberUID)
		_, err := f.svc.JoinCommunity(context.Background(), memberUID, in(testCID))
		if err == nil {
			t.Fatal("want an error")
		}
		if got := err.Error(); strings.Contains(got, memberUID) || strings.Contains(got, testCID) {
			t.Errorf("error leaks an id: %v", got)
		}
	})
}

// TestJoin_Params: whatever the account age (there is no daily quota tier any more), the repo gets the same parameters.
func TestJoin_Params(t *testing.T) {
	tests := []struct {
		name    string
		created time.Time
	}{
		{"new account", testNow.Add(-time.Hour)},
		{"old account", testNow.Add(-100 * time.Hour)},
		{"unknown age", time.Time{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := joinFixture(t)
			p := profile(memberUID, identity.AccountStatusActive)
			p.CreatedAt = tt.created
			f.dir.profiles[memberUID] = p
			f.repo.joinRes = JoinResult{Outcome: Written, State: MemberJoined}
			if _, err := f.svc.JoinCommunity(context.Background(), memberUID, in(testCID)); err != nil {
				t.Fatal(err)
			}
			got := f.repo.joins[0]
			if got.MaxJoined != 50 || got.UID != memberUID || got.ID != testCID ||
				got.IdemKey != idempotency.Key(memberUID, rpcJoinCommunity, goodKey) {
				t.Errorf("params = %+v", got)
			}
		})
	}
	t.Run("no profile", func(t *testing.T) {
		f := joinFixture(t)
		delete(f.dir.profiles, memberUID)
		_, err := f.svc.JoinCommunity(context.Background(), memberUID, in(testCID))
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, nil)
	})
	t.Run("directory error", func(t *testing.T) {
		f := joinFixture(t)
		f.dir.err = errors.New("down")
		if _, err := f.svc.JoinCommunity(context.Background(), memberUID, in(testCID)); err == nil || connect.CodeOf(err) != connect.CodeUnknown {
			t.Errorf("err = %v, want a plain redacted error", err)
		}
	})
}

func TestJoin_ResponseAndCache(t *testing.T) {
	tests := []struct {
		name      string
		uid       string
		res       JoinResult
		wantRole  Role
		wantCount int64
	}{
		{"new member", memberUID, JoinResult{Outcome: Written, State: MemberJoined}, RoleMember, 5},
		{"already a member", memberUID, JoinResult{Outcome: Unchanged, State: MemberJoined}, RoleMember, 4},
		{"the owner is already a member", ownerUID, JoinResult{Outcome: Unchanged, State: MemberJoined}, RoleOwner, 4},
		{"a moderator is already a member", modUID, JoinResult{Outcome: Unchanged, State: MemberJoined}, RoleModerator, 4},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := joinFixture(t)
			f.dir.profiles[tt.uid] = profile(tt.uid, identity.AccountStatusActive)
			f.repo.joinRes = tt.res
			v, err := f.svc.JoinCommunity(context.Background(), tt.uid, in(testCID))
			if err != nil {
				t.Fatal(err)
			}
			if v.Role != tt.wantRole || v.Community.MemberCount != tt.wantCount {
				t.Errorf("view = role %v count %d, want %v %d", v.Role, v.Community.MemberCount, tt.wantRole, tt.wantCount)
			}
			// the written state fills the member cache, so the next role lookup reads nothing
			if st, ok := f.svc.cache.getMember(testCID, tt.uid); !ok || st != MemberJoined {
				t.Errorf("member cache = %q %v", st, ok)
			}
			// the community entry is not put from a locally adjusted copy (that would reset its TTL): the cached count is the loaded one
			if c, _ := f.svc.cache.get(testCID); c.MemberCount != 4 {
				t.Errorf("cached count = %d, want the loaded 4", c.MemberCount)
			}
		})
	}
}

func TestJoin_ReplayAnswersFromCaches(t *testing.T) {
	f := joinFixture(t)
	f.repo.joinRes = JoinResult{Outcome: Replayed}
	f.repo.members[testCID+"|"+memberUID] = MemberJoined
	v, err := f.svc.JoinCommunity(context.Background(), memberUID, in(testCID))
	if err != nil {
		t.Fatal(err)
	}
	if v.Role != RoleMember || v.Community.MemberCount != 4 {
		t.Errorf("view = %+v", v)
	}
}

func TestLeave_RefusalsAndMapping(t *testing.T) {
	tests := []struct {
		name   string
		err    error
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"owner", ErrOwnerLeave, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, map[string]string{"reason": "owner"}},
		{"gone since the cache", ErrNotFound, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := joinFixture(t)
			f.repo.leaveErr = tt.err
			_, err := f.svc.LeaveCommunity(context.Background(), ownerUID, in(testCID))
			wantAPIErr(t, err, tt.code, tt.reason, tt.meta)
		})
	}
	t.Run("suspended is NOT_FOUND", func(t *testing.T) {
		f := joinFixture(t)
		f.seed(Community{ID: testCID, Status: StatusSuspended, OwnerID: ownerUID})
		_, err := f.svc.LeaveCommunity(context.Background(), memberUID, in(testCID))
		wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		if len(f.repo.leaves) != 0 {
			t.Error("the transaction ran")
		}
	})
	t.Run("archived is allowed", func(t *testing.T) {
		f := joinFixture(t)
		f.seed(Community{ID: testCID, Status: StatusArchived, MemberCount: 3})
		f.repo.leaveRes = LeaveResult{Outcome: Written}
		v, err := f.svc.LeaveCommunity(context.Background(), memberUID, in(testCID))
		if err != nil || v.Role != RoleNone || v.Community.MemberCount != 2 {
			t.Errorf("view = %+v, err = %v", v, err)
		}
	})
}

func TestLeave_ModeratorHintAndCache(t *testing.T) {
	t.Run("a cached moderator asks for the fresh community read and the written document replaces the entry", func(t *testing.T) {
		f := joinFixture(t)
		f.dir.profiles[modUID] = profile(modUID, identity.AccountStatusActive)
		// warm the cache with the moderator listed
		if _, err := f.svc.GetCommunity(context.Background(), modUID, testCID); err != nil {
			t.Fatal(err)
		}
		after := Community{ID: testCID, Status: StatusActive, OwnerID: ownerUID, MemberCount: 3, ModlogSeq: 1}
		f.repo.leaveRes = LeaveResult{Outcome: Written, State: MemberNone, Community: &after}
		v, err := f.svc.LeaveCommunity(context.Background(), modUID, in(testCID))
		if err != nil {
			t.Fatal(err)
		}
		if !f.repo.leaves[0].ModeratorHint || f.repo.leaves[0].ModlogMax != 100 {
			t.Errorf("params = %+v", f.repo.leaves[0])
		}
		if v.Role != RoleNone || v.Community.MemberCount != 3 {
			t.Errorf("view = %+v", v)
		}
		d, err := f.svc.GetCommunity(context.Background(), modUID, testCID)
		if err != nil {
			t.Fatal(err)
		}
		if len(d.Moderators) != 0 || d.View.Role != RoleNone {
			t.Errorf("GetCommunity after the leave still lists the moderator: %+v", d)
		}
	})
	t.Run("a plain member sends no hint and the cached community is left alone", func(t *testing.T) {
		f := joinFixture(t)
		f.repo.leaveRes = LeaveResult{Outcome: Written}
		v, err := f.svc.LeaveCommunity(context.Background(), memberUID, in(testCID))
		if err != nil {
			t.Fatal(err)
		}
		if f.repo.leaves[0].ModeratorHint {
			t.Error("hint set for a plain member")
		}
		if v.Community.MemberCount != 3 {
			t.Errorf("count = %d", v.Community.MemberCount)
		}
		if c, _ := f.svc.cache.get(testCID); c.MemberCount != 4 {
			t.Errorf("cached count = %d, want the loaded 4", c.MemberCount)
		}
		if st, ok := f.svc.cache.getMember(testCID, memberUID); !ok || st != MemberNone {
			t.Errorf("member cache = %q %v", st, ok)
		}
	})
	t.Run("a banned non-member keeps the ban in the cache and the response", func(t *testing.T) {
		f := joinFixture(t)
		f.repo.leaveRes = LeaveResult{Outcome: Unchanged, State: MemberBanned}
		v, err := f.svc.LeaveCommunity(context.Background(), bannedUID, in(testCID))
		if err != nil || v.Role != RoleBanned || v.Community.MemberCount != 4 {
			t.Errorf("view = %+v, err = %v", v, err)
		}
		if st, _ := f.svc.cache.getMember(testCID, bannedUID); st != MemberBanned {
			t.Errorf("member cache = %q", st)
		}
	})
	t.Run("replay answers from the caches", func(t *testing.T) {
		f := joinFixture(t)
		f.repo.leaveRes = LeaveResult{Outcome: Replayed}
		v, err := f.svc.LeaveCommunity(context.Background(), memberUID, in(testCID))
		if err != nil || v.Role != RoleNone {
			t.Errorf("view = %+v, err = %v", v, err)
		}
	})
}

func TestListMyCommunities(t *testing.T) {
	f := joinFixture(t)
	ids := []string{"0000000000000000601", "0000000000000000602", "0000000000000000603", "0000000000000000604", "0000000000000000605", "0000000000000000606"}
	f.seed(Community{ID: ids[0], Name: "one", OwnerID: "x"})
	f.seed(Community{ID: ids[1], Name: "two", OwnerID: memberUID})
	f.seed(Community{ID: ids[2], Name: "three", OwnerID: "x", ModeratorIDs: []string{memberUID}})
	f.seed(Community{ID: ids[3], Name: "archived", OwnerID: "x", Status: StatusArchived})
	f.seed(Community{ID: ids[4], Name: "suspended", OwnerID: "x", Status: StatusSuspended})
	f.seed(Community{ID: ids[5], Name: "my suspended", OwnerID: memberUID, Status: StatusSuspended})
	// 0000...607 is joined but its document is gone; ids[0] appears twice (the newest occurrence wins)
	f.repo.mships[memberUID] = Memberships{Joined: append(append([]string{}, ids...), "0000000000000000607", ids[0])}

	got, err := f.svc.ListMyCommunities(context.Background(), memberUID, "")
	if err != nil {
		t.Fatal(err)
	}
	var order []string
	roles := map[string]Role{}
	for _, v := range got.Items {
		order = append(order, v.Community.Name)
		roles[v.Community.Name] = v.Role
	}
	want := []string{"one", "my suspended", "archived", "three", "two"}
	if fmt.Sprint(order) != fmt.Sprint(want) {
		t.Errorf("order = %v, want newest join first, SUSPENDED of others left out, gone skipped, duplicates dropped: %v", order, want)
	}
	if roles["two"] != RoleOwner || roles["three"] != RoleModerator || roles["one"] != RoleMember || roles["archived"] != RoleMember || roles["my suspended"] != RoleOwner {
		t.Errorf("roles = %v", roles)
	}
	if got.CanCreate {
		t.Error("can_create for a non-creator")
	}
	// the documents are cached now: a second call reads the memberships and the one missing doc only
	f.repo.manyGets = nil
	if _, err := f.svc.ListMyCommunities(context.Background(), memberUID, ""); err != nil {
		t.Fatal(err)
	}
	if len(f.repo.manyGets) != 1 || len(f.repo.manyGets[0]) != 1 {
		t.Errorf("warm GetAll = %v, want only the id with no document", f.repo.manyGets)
	}
}

func TestListMyCommunities_EdgeCases(t *testing.T) {
	t.Run("page_token is VALIDATION before any fetch", func(t *testing.T) {
		f := joinFixture(t)
		_, err := f.svc.ListMyCommunities(context.Background(), memberUID, "tok")
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "page_token"})
		if f.repo.mshipsGet != 0 {
			t.Error("read before validating")
		}
	})
	t.Run("no memberships, creators see can_create", func(t *testing.T) {
		f := joinFixture(t)
		got, err := f.svc.ListMyCommunities(context.Background(), ownerUID, "")
		if err != nil || len(got.Items) != 0 || !got.CanCreate || len(f.repo.manyGets) != 0 {
			t.Errorf("got %+v, err %v, GetAll calls %d", got, err, len(f.repo.manyGets))
		}
	})
	t.Run("GetAll error is internal", func(t *testing.T) {
		f := joinFixture(t)
		f.repo.mships[memberUID] = Memberships{Joined: []string{testCID}}
		f.repo.manyErr = errors.New("boom")
		if _, err := f.svc.ListMyCommunities(context.Background(), memberUID, ""); err == nil || connect.CodeOf(err) != connect.CodeUnknown {
			t.Errorf("err = %v, want a plain redacted error", err)
		}
	})
}

func TestReader(t *testing.T) {
	f := joinFixture(t)
	var r Reader = f.svc
	ctx := context.Background()
	c, err := r.Get(ctx, testCID)
	if err != nil || c.ID != testCID {
		t.Fatalf("Get = %+v, %v", c, err)
	}
	if _, err := r.Get(ctx, otherCID); !errors.Is(err, ErrNotFound) {
		t.Errorf("Get of a missing community: %v", err)
	}
	f.repo.members[testCID+"|"+memberUID] = MemberJoined
	f.repo.members[testCID+"|"+bannedUID] = MemberBanned
	for uid, want := range map[string]Role{ownerUID: RoleOwner, modUID: RoleModerator, memberUID: RoleMember, bannedUID: RoleBanned, nobodyUID: RoleNone} {
		if got, err := r.Role(ctx, testCID, uid); err != nil || got != want {
			t.Errorf("Role(%s) = %v, %v, want %v", uid, got, err, want)
		}
	}
	if _, err := r.Role(ctx, otherCID, memberUID); !errors.Is(err, ErrNotFound) {
		t.Errorf("Role of a missing community: %v", err)
	}
	f.repo.mships[memberUID] = Memberships{Joined: []string{testCID}}
	if m, err := r.Memberships(ctx, memberUID); err != nil || len(m.Joined) != 1 {
		t.Errorf("Memberships = %+v, %v", m, err)
	}
}

func TestMembership_ContentionIsRetryableAndLogged(t *testing.T) {
	for _, op := range []string{"join", "leave"} {
		t.Run(op, func(t *testing.T) {
			f := joinFixture(t)
			aborted := status.Error(codes.Aborted, "too much contention on these documents")
			f.repo.joinErr, f.repo.leaveErr = aborted, aborted
			ctx, info := logger.WithRequestInfo(context.Background())
			var err error
			if op == "join" {
				_, err = f.svc.JoinCommunity(ctx, memberUID, in(testCID))
			} else {
				_, err = f.svc.LeaveCommunity(ctx, memberUID, in(testCID))
			}
			wantAPIErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
			if got, _ := info.Get(fieldOutcome); got != outcomeContention {
				t.Errorf("outcome = %v, want %q", got, outcomeContention)
			}
			if got, _ := info.Get(fieldOp); got != op {
				t.Errorf("community_op = %v, want %q", got, op)
			}
		})
	}
}

func TestNoteAttempts_RecordsTheCommunityField(t *testing.T) {
	ctx, info := logger.WithRequestInfo(context.Background())
	noteAttempts(ctx, 3)
	if got, _ := info.Get(fieldCommunityTxn); fmt.Sprint(got) != "3" {
		t.Errorf("community_txn_attempts = %v, want 3", got)
	}
	if got, _ := info.Get("txn_attempts"); fmt.Sprint(got) != "3" {
		t.Errorf("txn_attempts = %v, want 3", got)
	}
}

func TestMemberCountDelta_IsABlindIncrement(t *testing.T) {
	for _, n := range []int64{1, -1} {
		u := memberCountDelta(n)
		if u.Path != "memberCount" || u.Value == nil {
			t.Errorf("delta %d = %+v (%T), want a FieldValue.Increment on memberCount", n, u, u.Value)
		}
	}
}
