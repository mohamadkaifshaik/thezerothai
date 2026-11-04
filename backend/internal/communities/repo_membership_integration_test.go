//go:build integration

package communities

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

const (
	joinCID  = "0000000000000000701"
	joinCID2 = "0000000000000000702"
	joinCID3 = "0000000000000000703"
)

func newJoinEnv(t *testing.T) *env {
	t.Helper()
	e := newEnv(t, 100)
	return e
}

// user adds an active profile. Race tests call it while earlier joins already read the directory, so it takes the fake's lock.
func (e *env) user(uid string) string {
	e.dir.mu.Lock()
	defer e.dir.mu.Unlock()
	e.dir.profiles[uid] = profile(uid, identity.AccountStatusActive)
	return uid
}

// seedOwned seeds a community of owner with the owner's member doc and memberships, memberCount 1.
func (e *env) seedOwned(t *testing.T, cid, owner string, mods ...string) {
	t.Helper()
	members := map[string]MemberState{owner: MemberJoined}
	for _, m := range mods {
		members[m] = MemberJoined
	}
	e.seedCommunity(t, Community{ID: cid, Name: "Seed " + cid[len(cid)-3:], OwnerID: owner, ModeratorIDs: mods, MemberCount: int64(len(members)), Status: StatusActive}, members)
	e.seedMemberships(t, owner, Memberships{Joined: []string{cid}, Owned: []string{cid}})
	for _, m := range mods {
		e.seedMemberships(t, m, Memberships{Joined: []string{cid}, Modlogged: []string{cid}})
	}
}

func (e *env) join(ctx context.Context, uid string, n int, cid string) (View, error) {
	return e.svc.JoinCommunity(ctx, uid, MembershipInput{Key: key(n), CommunityID: cid})
}

func (e *env) leave(ctx context.Context, uid string, n int, cid string) (View, error) {
	return e.svc.LeaveCommunity(ctx, uid, MembershipInput{Key: key(n), CommunityID: cid})
}

func (e *env) count(t *testing.T, cid string) int64 {
	t.Helper()
	return e.community(t, cid).MemberCount
}

func (e *env) quotaJoins(t *testing.T, uid string) int64 {
	t.Helper()
	d, ok := e.data(t, "quotas/"+uid)
	if !ok {
		return 0
	}
	n, _ := d["communityJoins"].(int64)
	return n
}

func TestJoin_ColdWarmAndWrites(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	u1, u2 := e.user("u1"), e.user("u2")

	// cold: the community is not cached yet
	v, err := e.join(context.Background(), u1, 1, joinCID)
	if err != nil {
		t.Fatal(err)
	}
	if v.Role != RoleMember || v.Community.MemberCount != 2 {
		t.Errorf("view = role %v, count %d", v.Role, v.Community.MemberCount)
	}
	// warm: the community is cached, another user joins
	if _, err := e.join(context.Background(), u2, 1, joinCID); err != nil {
		t.Fatal(err)
	}

	if got := e.count(t, joinCID); got != 3 {
		t.Errorf("memberCount = %d, want 3", got)
	}
	member, ok := e.data(t, "communities/"+joinCID+"/communityMembers/"+u1)
	if !ok || member["state"] != "JOINED" || member["uid"] != u1 || member["joinedAt"] == nil || member["bannedAt"] != nil {
		t.Errorf("member doc = %v", member)
	}
	if ms, ok := e.memberships(t, u1); !ok || !slices.Equal(ms.Joined, []string{joinCID}) || len(ms.Owned) != 0 || len(ms.Banned) != 0 || len(ms.Modlogged) != 0 {
		t.Errorf("memberships = %+v", ms)
	}
	rec, ok := e.data(t, "idempotency/"+idempotency.Key(u1, "JoinCommunity", key(1)))
	if res, _ := rec["result"].(map[string]any); !ok || res["id"] != joinCID || rec["expireAt"] == nil {
		t.Errorf("idempotency record = %v", rec)
	}
	// the written member state and the community are cached: GetCommunity answers MEMBER with both documents gone
	if _, err := e.client.Doc("communities/" + joinCID + "/communityMembers/" + u1).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.ref(joinCID).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	d, err := e.svc.GetCommunity(context.Background(), u1, joinCID)
	if err != nil || d.View.Role != RoleMember {
		t.Fatalf("GetCommunity = %+v, %v", d.View, err)
	}
}

func TestJoin_AlreadyAMemberWritesTheIdempotencyDocOnly(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner", "mod1")
	u1 := e.user("u1")
	if _, err := e.join(context.Background(), u1, 1, joinCID); err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct {
		uid  string
		role Role
	}{{u1, RoleMember}, {"owner", RoleOwner}, {"mod1", RoleModerator}} {
		e.user(tt.uid)
		n := 10
		v, err := e.join(context.Background(), tt.uid, n, joinCID)
		if err != nil || v.Role != tt.role {
			t.Fatalf("view = %+v, err = %v, want %v", v, err, tt.role)
		}
	}
	if got := e.count(t, joinCID); got != 3 {
		t.Errorf("memberCount = %d, want 3 (owner, mod1, u1)", got)
	}
}

func TestJoin_ReplayWritesNothingAndAnotherBodyIsRefused(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	e.seedOwned(t, joinCID2, "owner")
	u1 := e.user("u1")
	if _, err := e.join(context.Background(), u1, 1, joinCID); err != nil {
		t.Fatal(err)
	}
	v, err := e.join(context.Background(), u1, 1, joinCID)
	if err != nil || v.Role != RoleMember {
		t.Fatalf("replay = %+v, %v", v, err)
	}
	if got := e.count(t, joinCID); got != 2 {
		t.Errorf("memberCount after a replay = %d, want 2", got)
	}
	_, err = e.join(context.Background(), u1, 1, joinCID2) // same key, another community
	wantAPIErr(t, err, connect.CodeInvalidArgument, rKeyReused, nil)
	// a late replay cannot undo a newer leave
	if _, err := e.leave(context.Background(), u1, 2, joinCID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.join(context.Background(), u1, 1, joinCID); err != nil {
		t.Fatal(err)
	}
	if st, _ := e.repo.Member(context.Background(), joinCID, u1); st != MemberNone {
		t.Errorf("a replayed Join re-joined: state %q", st)
	}
}

func TestJoin_BannedArchivedSuspendedAndGone(t *testing.T) {
	e := newJoinEnv(t)
	e.seedCommunity(t, Community{ID: joinCID, Name: "Banned here", OwnerID: "owner", MemberCount: 2, Status: StatusActive},
		map[string]MemberState{"owner": MemberJoined, "b1": MemberBanned})
	e.seedCommunity(t, Community{ID: joinCID2, Name: "Archived", OwnerID: "", MemberCount: 0, Status: StatusArchived}, nil)
	e.seedCommunity(t, Community{ID: joinCID3, Name: "Suspended", OwnerID: "owner", MemberCount: 1, Status: StatusSuspended}, nil)
	b1 := e.user("b1")

	_, err := e.join(context.Background(), b1, 1, joinCID)
	wantAPIErr(t, err, connect.CodePermissionDenied, rForbidden, map[string]string{"reason": "banned"})
	if _, ok := e.data(t, "idempotency/"+idempotency.Key(b1, "JoinCommunity", key(1))); ok {
		t.Error("a refusal stored an idempotency record")
	}

	_, err = e.join(context.Background(), b1, 2, joinCID2)
	wantAPIErr(t, err, connect.CodeFailedPrecondition, rState, map[string]string{"reason": "community_archived"})
	if _, ok := e.data(t, "idempotency/"+idempotency.Key(b1, "JoinCommunity", key(2))); ok {
		t.Error("an ARCHIVED refusal stored an idempotency record")
	}
	// SUSPENDED: the one NOT_FOUND, byte-identical to a missing id
	_, errSusp := e.join(context.Background(), "owner", 3, joinCID3)
	_, errGone := e.join(context.Background(), "owner", 4, "0000000000000000799")
	wantAPIErr(t, errSusp, connect.CodeNotFound, rNone, nil)
	if errSusp == nil || errGone == nil || errSusp.Error() != errGone.Error() {
		t.Errorf("SUSPENDED %v and missing %v must be byte-identical", errSusp, errGone)
	}
}

func TestJoin_CommunityDeletedInsideTheCacheWindowIsNotFound(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	u1, u2 := e.user("u1"), e.user("u2")
	if _, err := e.join(context.Background(), u1, 1, joinCID); err != nil { // warms the community entry
		t.Fatal(err)
	}
	if _, err := e.repo.ref(joinCID).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	_, err := e.join(context.Background(), u2, 1, joinCID)
	wantAPIErr(t, err, connect.CodeNotFound, rNone, nil)
	if _, ok := e.data(t, "communities/"+joinCID+"/communityMembers/"+u2); ok {
		t.Error("a member doc was written for a deleted community")
	}
	if ms, _ := e.memberships(t, u2); len(ms.Joined) != 0 {
		t.Errorf("memberships = %+v, the failed commit must roll everything back", ms)
	}
}

func TestJoin_FiftyFirstIsLimitReachedAndTheCapIsExact(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	u := e.user("u1")
	joined := make([]string, 50)
	for i := range joined {
		joined[i] = fmt.Sprintf("%019d", 9000+i)
	}
	e.seedMemberships(t, u, Memberships{Joined: joined})
	_, err := e.join(context.Background(), u, 1, joinCID)
	wantAPIErr(t, err, connect.CodeFailedPrecondition, rLimit, map[string]string{"limit": "communities_joined"})
	// 49 joined: the 50th is allowed, the 51st is refused
	e.seedMemberships(t, u, Memberships{Joined: joined[:49]})
	if _, err := e.join(context.Background(), u, 2, joinCID); err != nil {
		t.Fatalf("the 50th join: %v", err)
	}
	e.seedOwned(t, joinCID2, "owner")
	_, err = e.join(context.Background(), u, 3, joinCID2)
	wantAPIErr(t, err, connect.CodeFailedPrecondition, rLimit, map[string]string{"limit": "communities_joined"})
	if ms, _ := e.memberships(t, u); len(ms.Joined) != 50 {
		t.Errorf("joined = %d, want exactly 50", len(ms.Joined))
	}
}

// TestJoin_NoDailyQuota: a new account joins past the old daily quota (5 for a new account, 20 otherwise), even with a
// legacy quotas/{uid} showing it used up, and no join writes quotas/{uid}.
func TestJoin_NoDailyQuota(t *testing.T) {
	e := newJoinEnv(t)
	young := e.user("young")
	p := profile(young, identity.AccountStatusActive)
	p.CreatedAt = time.Now().Add(-time.Hour)
	e.dir.profiles[young] = p
	if _, err := e.client.Doc("quotas/"+young).Set(context.Background(), map[string]any{"day": quota.Today(), "communityJoins": int64(20)}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 6; i++ {
		cid := fmt.Sprintf("%019d", 7100+i)
		e.seedOwned(t, cid, "owner")
		if _, err := e.join(context.Background(), young, i+1, cid); err != nil {
			t.Fatalf("join %d: %v", i+1, err)
		}
	}
	if got := e.quotaJoins(t, young); got != 20 {
		t.Errorf("quotas.communityJoins = %d, want the seeded 20 untouched", got)
	}
}

func TestJoin_TenJoinsBurstKeepMemberCountExact(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	const n = 10
	errs := make([]error, n)
	attempts := make([]any, n)
	var wg sync.WaitGroup
	for i := range n {
		uid := e.user(fmt.Sprintf("burst%d", i))
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, info := logger.WithRequestInfo(context.Background())
			_, errs[i] = e.join(ctx, uid, 1, joinCID)
			attempts[i], _ = info.Get(fieldCommunityTxn)
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("join %d: %v", i, err)
		}
		if attempts[i] == nil {
			t.Errorf("join %d recorded no %s", i, fieldCommunityTxn)
		}
	}
	if got := e.count(t, joinCID); got != 1+n {
		t.Errorf("memberCount = %d, want %d", got, 1+n)
	}
	docs, err := e.client.Collection("communities").Doc(joinCID).Collection(membersSubcollection).Where("state", "==", "JOINED").Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 1+n {
		t.Errorf("JOINED member docs = %d (err %v), want %d", len(docs), err, 1+n)
	}
	t.Logf("%s per join: %v (the blind Increment never joins a read set, so distinct users do not abort each other)", fieldCommunityTxn, attempts)
}

func TestJoin_SameUserTwoKeysJoinsOnce(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	u := e.user("u1")
	var wg sync.WaitGroup
	for i := range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := e.join(context.Background(), u, 100+i, joinCID); err != nil {
				t.Errorf("join %d: %v", i, err)
			}
		}()
	}
	wg.Wait()
	if got := e.count(t, joinCID); got != 2 {
		t.Errorf("memberCount = %d, want 2: four keys, one membership", got)
	}
	if ms, _ := e.memberships(t, u); !slices.Equal(ms.Joined, []string{joinCID}) {
		t.Errorf("joined = %v", ms.Joined)
	}
}

func TestLeave_UpdatesCountAndRecords(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	u1, u2 := e.user("u1"), e.user("u2")
	for i, u := range []string{u1, u2} {
		if _, err := e.join(context.Background(), u, 1, joinCID); err != nil {
			t.Fatal(i, err)
		}
	}
	// the community is cached by the joins
	v, err := e.leave(context.Background(), u1, 2, joinCID)
	if err != nil || v.Role != RoleNone {
		t.Fatalf("view = %+v, err = %v", v, err) // member_count is the cached count minus one: it may lag other instances and this one by up to 60 s
	}
	if got := e.count(t, joinCID); got != 2 {
		t.Errorf("memberCount = %d, want 2", got)
	}
	if _, ok := e.data(t, "communities/"+joinCID+"/communityMembers/"+u1); ok {
		t.Error("the member doc is still there")
	}
	if ms, _ := e.memberships(t, u1); len(ms.Joined) != 0 {
		t.Errorf("joined = %v", ms.Joined)
	}
	// replay: changes nothing
	if _, err := e.leave(context.Background(), u1, 2, joinCID); err != nil {
		t.Fatal(err)
	}
	if got := e.count(t, joinCID); got != 2 {
		t.Errorf("memberCount after a Leave replay = %d, want 2", got)
	}
	// not a member: no change
	v, err = e.leave(context.Background(), u1, 3, joinCID)
	if err != nil || v.Role != RoleNone {
		t.Fatalf("view = %+v, err = %v", v, err)
	}
	if got := e.count(t, joinCID); got != 2 {
		t.Errorf("a non-member Leave changed memberCount to %d", got)
	}
}

func TestLeave_OwnerBannedAndStates(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	e.seedCommunity(t, Community{ID: joinCID2, Name: "Banned", OwnerID: "owner2", MemberCount: 1, Status: StatusActive},
		map[string]MemberState{"owner2": MemberJoined, "b1": MemberBanned})
	e.seedMemberships(t, "b1", Memberships{Banned: []string{joinCID2}})
	e.seedCommunity(t, Community{ID: joinCID3, Name: "Archived", OwnerID: "", MemberCount: 1, Status: StatusArchived}, map[string]MemberState{"m1": MemberJoined})
	e.seedMemberships(t, "m1", Memberships{Joined: []string{joinCID3}})
	e.user("owner")
	m1, b1 := e.user("m1"), e.user("b1")

	_, err := e.leave(context.Background(), "owner", 1, joinCID)
	wantAPIErr(t, err, connect.CodeFailedPrecondition, rState, map[string]string{"reason": "owner"})
	if _, ok := e.data(t, "idempotency/"+idempotency.Key("owner", "LeaveCommunity", key(1))); ok {
		t.Error("a refusal stored an idempotency record")
	}
	if got := e.count(t, joinCID); got != 1 {
		t.Errorf("memberCount = %d", got)
	}

	v, err := e.leave(context.Background(), b1, 2, joinCID2)
	if err != nil || v.Role != RoleBanned {
		t.Fatalf("banned Leave = %+v, %v, want success with the ban kept", v, err)
	}
	if st, _ := e.repo.Member(context.Background(), joinCID2, b1); st != MemberBanned {
		t.Errorf("state after a banned user's Leave = %q, the ban stays", st)
	}
	if ms, _ := e.memberships(t, b1); !slices.Equal(ms.Banned, []string{joinCID2}) {
		t.Errorf("banned = %v", ms.Banned)
	}

	v, err = e.leave(context.Background(), m1, 3, joinCID3)
	if err != nil || v.Role != RoleNone {
		t.Fatalf("Leave in an ARCHIVED community = %+v, %v", v, err)
	}
	if got := e.count(t, joinCID3); got != 0 {
		t.Errorf("memberCount = %d, want 0", got)
	}
	_, err = e.leave(context.Background(), m1, 4, "0000000000000000799")
	wantAPIErr(t, err, connect.CodeNotFound, rNone, nil)
}

func TestLeave_ModeratorLeavesModeratorIDsAndGetCommunityFollows(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner", "mod1", "mod2")
	owner, mod1, mod2 := e.user("owner"), e.user("mod1"), e.user("mod2")
	ctx := context.Background()

	// warm this instance's cache with the moderators listed
	d, err := e.svc.GetCommunity(ctx, mod1, joinCID)
	if err != nil || len(d.Moderators) != 2 || d.View.Role != RoleModerator {
		t.Fatalf("GetCommunity before = %+v, %v", d, err)
	}
	// the community is read fresh
	v, err := e.leave(context.Background(), mod1, 1, joinCID)
	if err != nil || v.Role != RoleNone {
		t.Fatalf("view = %+v, err = %v", v, err)
	}
	com := e.community(t, joinCID)
	if !slices.Equal(com.ModeratorIDs, []string{"mod2"}) || com.MemberCount != 2 || com.ModlogSeq != 1 || len(com.Modlog) != 1 ||
		com.Modlog[0].Action != ActionModeratorLeft || com.Modlog[0].Actor != mod1 || com.Modlog[0].Seq != 1 || com.Modlog[0].Target != "" {
		t.Errorf("community = %+v", com)
	}
	if ms, _ := e.memberships(t, mod1); len(ms.Joined) != 0 || !slices.Equal(ms.Modlogged, []string{joinCID}) {
		t.Errorf("memberships = %+v, modlogged must stay (I-L)", ms)
	}
	// the same instance's GetCommunity (cache warmed before the leave) no longer lists mod1
	d, err = e.svc.GetCommunity(ctx, owner, joinCID)
	if err != nil || len(d.Moderators) != 1 || d.Moderators[0].Profile.UserID != "mod2" {
		t.Errorf("GetCommunity after on the same instance = %+v, %v", d.Moderators, err)
	}
	// another instance (a cold cache) agrees
	other := New(e.svc.d).(*service)
	d, err = other.GetCommunity(ctx, mod1, joinCID)
	if err != nil || len(d.Moderators) != 1 || d.View.Role != RoleNone {
		t.Errorf("GetCommunity after on a cold instance = %+v, %v", d, err)
	}
	// the second moderator leaves too: seq advances
	if _, err := e.leave(ctx, mod2, 1, joinCID); err != nil {
		t.Fatal(err)
	}
	com = e.community(t, joinCID)
	if len(com.ModeratorIDs) != 0 || com.ModlogSeq != 2 || len(com.Modlog) != 2 || com.Modlog[1].Seq != 2 {
		t.Errorf("after the second moderator: %+v", com)
	}
}

func TestLeave_ModlogIsTrimmedToTheCap(t *testing.T) {
	e := newEnv(t, 2)
	e.seedOwned(t, joinCID, "owner", "mod1", "mod2", "mod3")
	e.user("mod1")
	e.user("mod2")
	e.user("mod3")
	for i, m := range []string{"mod1", "mod2", "mod3"} {
		if _, err := e.leave(context.Background(), m, 1, joinCID); err != nil {
			t.Fatal(i, err)
		}
	}
	com := e.community(t, joinCID)
	if len(com.Modlog) != 2 || com.Modlog[0].Seq != 2 || com.Modlog[1].Seq != 3 || com.ModlogSeq != 3 {
		t.Errorf("modlog = %+v, seq %d, want the newest 2 of 3", com.Modlog, com.ModlogSeq)
	}
}

func TestLeave_ModeratorPromotedElsewhereIsCaughtByModlogged(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	u := e.user("u1")
	ctx := context.Background()
	if _, err := e.join(ctx, u, 1, joinCID); err != nil { // this instance caches the community without u1 as a moderator
		t.Fatal(err)
	}
	// another instance promotes u1: community lists u1 and u1's memberships name the community in modlogged (I-L)
	if _, err := e.repo.ref(joinCID).Update(ctx, []firestore.Update{{Path: "moderatorIds", Value: []string{u}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.membershipsRef(u).Update(ctx, []firestore.Update{{Path: "modlogged", Value: []string{joinCID}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.leave(context.Background(), u, 2, joinCID); err != nil {
		t.Fatal(err)
	}
	if com := e.community(t, joinCID); len(com.ModeratorIDs) != 0 || len(com.Modlog) != 1 || com.Modlog[0].Action != ActionModeratorLeft {
		t.Errorf("community = %+v, the promoted moderator must be gone from moderatorIds", com)
	}
}

func TestLeave_FreshReadOfAnOwnerThroughAStaleHintIsRefused(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	// memberships do not name the community in owned (an inconsistent seed), but the fresh community says owner: still refused
	e.seedMemberships(t, "owner", Memberships{Joined: []string{joinCID}, Modlogged: []string{joinCID}})
	e.user("owner")
	_, err := e.leave(context.Background(), "owner", 1, joinCID)
	wantAPIErr(t, err, connect.CodeFailedPrecondition, rState, map[string]string{"reason": "owner"})
	if got := e.count(t, joinCID); got != 1 {
		t.Errorf("memberCount = %d", got)
	}
}

func TestJoinLeaveRaces_KeepTheInvariantsAndMemberCountExact(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner")
	const users, rounds = 4, 6
	var wg sync.WaitGroup
	var mu sync.Mutex
	maxAttempts := 0
	for i := range users {
		uid := e.user(fmt.Sprintf("racer%d", i))
		wg.Add(1)
		go func() {
			defer wg.Done()
			for r := range rounds {
				ctx, info := logger.WithRequestInfo(context.Background())
				var err error
				if r%2 == 0 {
					_, err = e.join(ctx, uid, 1000+r, joinCID)
				} else {
					_, err = e.leave(ctx, uid, 1000+r, joinCID)
				}
				if err != nil && connect.CodeOf(err) != connect.CodeUnavailable {
					t.Errorf("%s round %d: %v", uid, r, err)
				}
				if a, ok := info.Get(fieldCommunityTxn); ok {
					mu.Lock()
					n, _ := strconv.Atoi(fmt.Sprint(a))
					maxAttempts = max(maxAttempts, n)
					mu.Unlock()
				}
			}
		}()
	}
	wg.Wait()
	// every user ended with a leave (the last round is odd): nobody is a member, so only the owner remains
	if got := e.count(t, joinCID); got != 1 {
		t.Errorf("memberCount = %d, want 1 after every racer left", got)
	}
	docs, err := e.client.Collection("communities").Doc(joinCID).Collection(membersSubcollection).Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 1 {
		t.Errorf("member docs = %d (err %v), want the owner only", len(docs), err)
	}
	for i := range users {
		uid := fmt.Sprintf("racer%d", i)
		if ms, _ := e.memberships(t, uid); len(ms.Joined) != 0 {
			t.Errorf("%s joined = %v, want none (I-M)", uid, ms.Joined)
		}
	}
	t.Logf("max %s over %d racing calls: %d", fieldCommunityTxn, users*rounds, maxAttempts)
}

func TestModeratorLeaveRacingAJoinBurstStaysConsistent(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner", "mod1")
	mod := e.user("mod1")
	if _, err := e.svc.GetCommunity(context.Background(), mod, joinCID); err != nil { // the cache lists mod1, so the leave works on the hot doc
		t.Fatal(err)
	}
	const n = 8
	var wg sync.WaitGroup
	var attempts any
	var leaveErr error
	for i := range n {
		uid := e.user(fmt.Sprintf("viral%d", i))
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := e.join(context.Background(), uid, 1, joinCID); err != nil {
				t.Errorf("join %d: %v", i, err)
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		ctx, info := logger.WithRequestInfo(context.Background())
		_, leaveErr = e.leave(ctx, mod, 1, joinCID)
		attempts, _ = info.Get(fieldCommunityTxn)
	}()
	wg.Wait()
	if leaveErr != nil {
		t.Fatalf("the moderator's Leave under join contention: %v", leaveErr)
	}
	if attempts == nil {
		t.Error("the moderator's Leave recorded no community_txn_attempts")
	}
	t.Logf("moderator Leave %s = %v while %d joins hit the same document (ABORTED retries show here)", fieldCommunityTxn, attempts, n)
	com := e.community(t, joinCID)
	if com.MemberCount != 1+n || len(com.ModeratorIDs) != 0 {
		t.Errorf("community = count %d, mods %v, want %d and none", com.MemberCount, com.ModeratorIDs, 1+n)
	}
}

func TestListMyCommunities_FiftyInNewestFirstOrder(t *testing.T) {
	e := newJoinEnv(t)
	ids := make([]string, 50)
	for i := range ids {
		ids[i] = fmt.Sprintf("%019d", 8000+i)
		e.seedCommunity(t, Community{ID: ids[i], Name: fmt.Sprintf("C%02d", i), OwnerID: "someone", MemberCount: 5, Status: StatusActive}, nil)
	}
	e.seedMemberships(t, "u1", Memberships{Joined: ids})
	e.user("u1")
	e.svc.creators["u1"] = struct{}{}

	got, err := e.svc.ListMyCommunities(context.Background(), "u1", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Items) != 50 || !got.CanCreate || got.Items[0].Community.Name != "C49" || got.Items[49].Community.Name != "C00" || got.Items[0].Role != RoleMember {
		t.Errorf("list = %d items, can_create %v, first %q, last %q", len(got.Items), got.CanCreate, got.Items[0].Community.Name, got.Items[49].Community.Name)
	}
	// a page token is refused
	_, err = e.svc.ListMyCommunities(context.Background(), "u1", "x")
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "page_token"})
}

func TestListMyCommunities_JoinOrderRolesAndSuspended(t *testing.T) {
	e := newJoinEnv(t)
	e.seedOwned(t, joinCID, "owner", "mod1")
	e.seedOwned(t, joinCID2, "owner")
	e.seedOwned(t, joinCID3, "owner")
	e.seedMemberships(t, "owner", Memberships{Joined: []string{joinCID, joinCID2, joinCID3}, Owned: []string{joinCID, joinCID2, joinCID3}})
	u := e.user("mod1")
	ctx := context.Background()
	if _, err := e.join(ctx, u, 1, joinCID2); err != nil {
		t.Fatal(err)
	}
	if _, err := e.join(ctx, u, 2, joinCID3); err != nil {
		t.Fatal(err)
	}
	got, err := e.svc.ListMyCommunities(ctx, u, "")
	if err != nil {
		t.Fatal(err)
	}
	var order []string
	for _, v := range got.Items {
		order = append(order, v.Community.ID)
	}
	if !slices.Equal(order, []string{joinCID3, joinCID2, joinCID}) {
		t.Errorf("order = %v, want newest join first", order)
	}
	if got.Items[2].Role != RoleModerator || got.Items[0].Role != RoleMember || got.CanCreate {
		t.Errorf("roles = %v %v, can_create %v", got.Items[2].Role, got.Items[0].Role, got.CanCreate)
	}
	// a SUSPENDED community drops out for non-owners; the owner still sees it
	if _, err := e.repo.ref(joinCID3).Update(ctx, []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	fresh := New(e.svc.d).(*service)
	got, err = fresh.ListMyCommunities(ctx, u, "")
	if err != nil || len(got.Items) != 2 {
		t.Errorf("SUSPENDED community still listed: %d items, %v", len(got.Items), err)
	}
	got, err = fresh.ListMyCommunities(ctx, "owner", "")
	if err != nil || len(got.Items) != 3 || !got.CanCreate {
		t.Errorf("the owner sees %d items (can_create %v), %v, want 3", len(got.Items), got.CanCreate, err)
	}
}

func TestReader_RoleSeesEveryStateAndFillsFromWrites(t *testing.T) {
	e := newJoinEnv(t)
	e.seedCommunity(t, Community{ID: joinCID, Name: "R", OwnerID: "owner", ModeratorIDs: []string{"mod1"}, MemberCount: 3, Status: StatusActive},
		map[string]MemberState{"owner": MemberJoined, "mod1": MemberJoined, "m1": MemberJoined, "b1": MemberBanned})
	r := Reader(e.svc)
	for uid, want := range map[string]Role{"owner": RoleOwner, "mod1": RoleModerator, "m1": RoleMember, "b1": RoleBanned, "nobody": RoleNone} {
		if got, err := r.Role(context.Background(), joinCID, uid); err != nil || got != want {
			t.Errorf("Role(%s) = %v, %v, want %v", uid, got, err, want)
		}
	}
	// after the member leaves on this instance the cached state is NONE with no extra read
	e.user("m1")
	if _, err := e.leave(context.Background(), "m1", 1, joinCID); err != nil {
		t.Fatal(err)
	}
	if got, err := r.Role(context.Background(), joinCID, "m1"); err != nil || got != RoleNone {
		t.Errorf("Role = %v, %v", got, err)
	}
}
