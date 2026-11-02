//go:build integration

package communities

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// The budgets are the service's own reads and writes (the account-status interceptor's one read and the cached target profile excluded):
// ADR-0031 lists Hide / Restore 5 / 4 reads and 3 writes (+1 for the actor's first entry), SetMemberRole 7 / 6 reads and at most 5 writes,
// with the interceptor (1) and the target profile (1, cache-first) included.

const (
	modCID    = "0000000000000000801"
	modPostA  = "0000000000000000811"
	modPostB  = "0000000000000000812"
	modPostC  = "0000000000000000813"
	modOutPst = "0000000000000000819" // created into another community
)

func newModEnv(t *testing.T) *env {
	t.Helper()
	e := newEnv(t, 100)
	e.repo.WithPostModerator(posts.NewCommunityModerator(e.client))
	e.dir.free = true
	for _, u := range []string{"banned", "target", "target2"} {
		e.user(u)
	}
	// owner + mod1 (no modlogged yet: its first entry costs one more write) + mod2; member and banned are plain
	e.seedCommunity(t, Community{ID: modCID, Name: "Mod", OwnerID: "owner", ModeratorIDs: []string{"mod1", "mod2"}, MemberCount: 4},
		map[string]MemberState{"owner": MemberJoined, "mod1": MemberJoined, "mod2": MemberJoined, "member": MemberJoined, "banned": MemberBanned})
	e.seedMemberships(t, "owner", Memberships{Joined: []string{modCID}, Owned: []string{modCID}})
	e.seedMemberships(t, "mod1", Memberships{Joined: []string{modCID}})
	e.seedMemberships(t, "mod2", Memberships{Joined: []string{modCID}})
	e.seedMemberships(t, "member", Memberships{Joined: []string{modCID}})
	e.seedMemberships(t, "banned", Memberships{Banned: []string{modCID}})
	e.seedPost(t, modPostA, modCID, true)
	e.seedPost(t, modPostB, modCID, true)
	e.seedPost(t, modPostC, modCID, true)
	e.seedPost(t, modOutPst, "0000000000000000899", true)
	return e
}

// seedPost writes the fields of a community post that moderation touches, plus an author so the document looks real.
func (e *env) seedPost(t *testing.T, id, cid string, listed bool) {
	t.Helper()
	d := map[string]any{
		"authorId": "author", "kind": "POST", "text": "hello", "createdAt": time.Now().UTC(),
		"community": map[string]any{"id": cid, "name": "Mod"},
	}
	if listed {
		d["communityId"] = cid
	}
	if _, err := e.client.Collection("posts").Doc(id).Set(context.Background(), d); err != nil {
		t.Fatal(err)
	}
}

func (e *env) postListed(t *testing.T, id string) (listed, hidden, exists bool) {
	t.Helper()
	d, ok := e.data(t, "posts/"+id)
	if !ok {
		return false, false, false
	}
	_, listed = d["communityId"]
	hidden, _ = d["communityHidden"].(bool)
	return listed, hidden, true
}

func (e *env) hide(ctx context.Context, uid string, n int, post string) error {
	return e.svc.HideCommunityPost(ctx, uid, PostActionInput{Key: key(n), CommunityID: modCID, PostID: post})
}

func (e *env) restore(ctx context.Context, uid string, n int, post string) error {
	return e.svc.RestoreCommunityPost(ctx, uid, PostActionInput{Key: key(n), CommunityID: modCID, PostID: post})
}

func (e *env) role(ctx context.Context, uid string, n int, target string, a RoleAction) (RoleResult, error) {
	return e.svc.SetMemberRole(ctx, uid, RoleInput{Key: key(n), CommunityID: modCID, UserID: target, Action: a})
}

func wantReason(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta string) {
	t.Helper()
	wantAPIErr(t, err, code, reason, map[string]string{"reason": meta})
}

func TestHideRestore_BudgetsEffectsAndLateRetry(t *testing.T) {
	e := newModEnv(t)

	// the first hide by mod1: idempotency, community, actor memberships, post = 4 reads; post, community, memberships, idempotency = 4 writes
	measured(t, "HideCommunityPost first", budgettest.Budget{Reads: 4, Writes: 4}, func(ctx context.Context) {
		if err := e.hide(ctx, "mod1", 1, modPostA); err != nil {
			t.Fatal(err)
		}
	})
	if listed, hidden, exists := e.postListed(t, modPostA); listed || !hidden || !exists {
		t.Errorf("after the hide: listed=%v hidden=%v exists=%v, want the post kept, unlisted and marked hidden", listed, hidden, exists)
	}
	c := e.community(t, modCID)
	if len(c.RecentRemovals) != 1 || c.RecentRemovals[0].PostID != modPostA {
		t.Errorf("recentRemovals = %+v", c.RecentRemovals)
	}
	if len(c.Modlog) != 1 || c.Modlog[0].Action != ActionHide || c.Modlog[0].PostID != modPostA || c.Modlog[0].Actor != "mod1" || c.Modlog[0].Seq != 1 {
		t.Errorf("modlog = %+v", c.Modlog)
	}
	if ms, _ := e.memberships(t, "mod1"); !slices.Contains(ms.Modlogged, modCID) {
		t.Errorf("mod1.modlogged = %v, want the community", ms.Modlogged)
	}
	// the cache holds the written document: this instance's Reader sees the removal at once
	if got, err := e.svc.Get(context.Background(), modCID); err != nil || len(got.RecentRemovals) != 1 {
		t.Errorf("Reader.Get after the hide = %+v, %v", got.RecentRemovals, err)
	}

	// a second hide of another post by the same moderator adds no write for modlogged: 3 writes
	measured(t, "HideCommunityPost second", budgettest.Budget{Reads: 4, Writes: 3}, func(ctx context.Context) {
		if err := e.hide(ctx, "mod1", 2, modPostB); err != nil {
			t.Fatal(err)
		}
	})
	// an already hidden post: the idempotency document only
	measured(t, "HideCommunityPost already hidden", budgettest.Budget{Reads: 4, Writes: 1}, func(ctx context.Context) {
		if err := e.hide(ctx, "owner", 3, modPostA); err != nil {
			t.Fatal(err)
		}
	})
	if c = e.community(t, modCID); len(c.Modlog) != 2 || len(c.RecentRemovals) != 2 {
		t.Errorf("a repeated hide changed the log: modlog %d, removals %d", len(c.Modlog), len(c.RecentRemovals))
	}

	// restore: the entry leaves recentRemovals, the label comes back; the owner's first entry costs the memberships write
	measured(t, "RestoreCommunityPost", budgettest.Budget{Reads: 4, Writes: 4}, func(ctx context.Context) {
		if err := e.restore(ctx, "owner", 4, modPostA); err != nil {
			t.Fatal(err)
		}
	})
	if listed, hidden, _ := e.postListed(t, modPostA); !listed || hidden {
		t.Errorf("after the restore: listed=%v hidden=%v", listed, hidden)
	}
	c = e.community(t, modCID)
	if len(c.RecentRemovals) != 1 || c.RecentRemovals[0].PostID != modPostB || len(c.Modlog) != 3 || c.Modlog[2].Action != ActionRestore {
		t.Errorf("after the restore: removals %+v, modlog %+v", c.RecentRemovals, c.Modlog)
	}
	// restoring a listed post: the idempotency document only
	measured(t, "RestoreCommunityPost not hidden", budgettest.Budget{Reads: 4, Writes: 1}, func(ctx context.Context) {
		if err := e.restore(ctx, "mod1", 5, modPostA); err != nil {
			t.Fatal(err)
		}
	})

	// a late retry of the first hide (same key) after the restore must NOT hide the post again: the standard idempotency document answers
	measured(t, "HideCommunityPost late retry", budgettest.Budget{Reads: 1, Writes: 0}, func(ctx context.Context) {
		if err := e.hide(ctx, "mod1", 1, modPostA); err != nil {
			t.Fatal(err)
		}
	})
	if listed, hidden, _ := e.postListed(t, modPostA); !listed || hidden {
		t.Errorf("the late retry re-hid the post: listed=%v hidden=%v", listed, hidden)
	}
	// the same key for another post is a reused key
	err := e.hide(context.Background(), "mod1", 1, modPostC)
	wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
	rec, ok := e.data(t, "idempotency/"+idempotency.Key("mod1", "HideCommunityPost", key(1)))
	if res, _ := rec["result"].(map[string]any); !ok || res["id"] != modCID || len(res) != 1 {
		t.Errorf("idempotency record = %v, want the community id only", rec)
	}
}

func TestHideRestore_RoleMatrixAndPostRules(t *testing.T) {
	e := newModEnv(t)
	ctx := context.Background()
	n := 100
	tests := []struct {
		actor  string
		wantOK bool
	}{{"owner", true}, {"mod1", true}, {"member", false}, {"banned", false}, {"stranger", false}}
	for _, tc := range tests {
		for _, restore := range []bool{false, true} {
			n++
			post := modPostC
			var err error
			if restore {
				err = e.restore(ctx, tc.actor, n, post)
			} else {
				err = e.hide(ctx, tc.actor, n, post)
			}
			if tc.wantOK {
				if err != nil {
					t.Errorf("%s restore=%v: %v", tc.actor, restore, err)
				}
				continue
			}
			wantReason(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "not_moderator")
		}
	}
	// the refusals wrote nothing
	if c := e.community(t, modCID); len(c.Modlog) != 4 { // a hide and a restore each by the owner and mod1
		t.Errorf("modlog = %d entries after 4 successes and 6 refusals, want 4", len(c.Modlog))
	}

	// a post created into another community, a missing post and a bad id
	wantAPIErr(t, e.hide(ctx, "owner", 200, modOutPst), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	wantAPIErr(t, e.hide(ctx, "owner", 201, "0000000000000000899"), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	wantAPIErr(t, e.hide(ctx, "owner", 202, "nope"), connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
	if listed, _, _ := e.postListed(t, modOutPst); !listed {
		t.Error("a hide in the wrong community changed the post")
	}

	// ARCHIVED and SUSPENDED
	if _, err := e.repo.ref(modCID).Update(ctx, archivedUpdate(StatusArchived)); err != nil {
		t.Fatal(err)
	}
	e.svc.cache.communities.Delete(modCID)
	wantReason(t, e.hide(ctx, "owner", 203, modPostA), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "community_archived")
	if _, err := e.repo.ref(modCID).Update(ctx, archivedUpdate(StatusSuspended)); err != nil {
		t.Fatal(err)
	}
	wantAPIErr(t, e.hide(ctx, "owner", 204, modPostA), connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
}

func TestSetMemberRole_BanUnbanBudgetsAndRecords(t *testing.T) {
	e := newModEnv(t)

	// BAN of a JOINED member by mod1 (first entry): idempotency, community, member doc, target memberships, actor memberships = 5 reads;
	// member doc, community, target memberships, actor memberships, idempotency = 5 writes
	measured(t, "SetMemberRole BAN", budgettest.Budget{Reads: 5, Writes: 5}, func(ctx context.Context) {
		r, err := e.role(ctx, "mod1", 1, "member", RoleActionBan)
		if err != nil || r.Role != RoleBanned || r.View.Community.MemberCount != 3 || r.View.Role != RoleModerator {
			t.Fatalf("BAN = %+v, %v", r, err)
		}
	})
	md, _ := e.data(t, "communities/"+modCID+"/communityMembers/member")
	if md["state"] != "BANNED" || md["bannedAt"] == nil || md["joinedAt"] != nil {
		t.Errorf("member doc after the ban = %v (one write: state BANNED, bannedAt set, joinedAt deleted)", md)
	}
	if got := e.count(t, modCID); got != 3 {
		t.Errorf("memberCount = %d, want 3", got)
	}
	tms, _ := e.memberships(t, "member")
	if len(tms.Joined) != 0 || !slices.Equal(tms.Banned, []string{modCID}) || !slices.Equal(tms.Modlogged, []string{modCID}) {
		t.Errorf("target memberships = %+v (I-L: the target is logged too)", tms)
	}
	if ams, _ := e.memberships(t, "mod1"); !slices.Equal(ams.Modlogged, []string{modCID}) {
		t.Errorf("actor memberships = %+v", ams)
	}
	if got, ok := e.svc.cache.getMember(modCID, "member"); !ok || got != MemberBanned {
		t.Errorf("member cache = %v, %v", got, ok)
	}

	// BAN accepts a non-member: a create, no count change; the actor already logged: 4 writes
	measured(t, "SetMemberRole BAN non-member", budgettest.Budget{Reads: 5, Writes: 4}, func(ctx context.Context) {
		if r, err := e.role(ctx, "mod1", 2, "stranger", RoleActionBan); err != nil || r.Role != RoleBanned || r.View.Community.MemberCount != 3 {
			t.Fatalf("BAN non-member = %+v, %v", r, err)
		}
	})
	if ms, ok := e.memberships(t, "stranger"); !ok || !slices.Equal(ms.Banned, []string{modCID}) || !slices.Equal(ms.Modlogged, []string{modCID}) {
		t.Errorf("a non-member's memberships after the ban = %+v, %v", ms, ok)
	}
	// a repeated ban changes nothing: reads stop at the member doc, the idempotency document is the only write
	measured(t, "SetMemberRole BAN again", budgettest.Budget{Reads: 3, Writes: 1}, func(ctx context.Context) {
		if r, err := e.role(ctx, "owner", 3, "member", RoleActionBan); err != nil || r.Role != RoleBanned {
			t.Fatalf("repeated BAN = %+v, %v", r, err)
		}
	})
	// UNBAN: delete the record, 3 writes + 1 delete (the owner's first entry adds a write)
	measured(t, "SetMemberRole UNBAN", budgettest.Budget{Reads: 5, Writes: 4, Deletes: 1}, func(ctx context.Context) {
		if r, err := e.role(ctx, "owner", 4, "member", RoleActionUnban); err != nil || r.Role != RoleNone {
			t.Fatalf("UNBAN = %+v, %v", r, err)
		}
	})
	if _, ok := e.data(t, "communities/"+modCID+"/communityMembers/member"); ok {
		t.Error("the member doc survived the unban")
	}
	if tms, _ = e.memberships(t, "member"); len(tms.Banned) != 0 || !slices.Equal(tms.Modlogged, []string{modCID}) {
		t.Errorf("target memberships after the unban = %+v (modlogged never shrinks)", tms)
	}
	// unban of a user who is not banned: the idempotency document only
	measured(t, "SetMemberRole UNBAN not banned", budgettest.Budget{Reads: 3, Writes: 1}, func(ctx context.Context) {
		if _, err := e.role(ctx, "owner", 5, "target", RoleActionUnban); err != nil {
			t.Fatal(err)
		}
	})
	// a late retry of the first ban (same key) after the unban must not ban again
	measured(t, "SetMemberRole replay", budgettest.Budget{Reads: 3, Writes: 0}, func(ctx context.Context) {
		if _, err := e.role(ctx, "mod1", 1, "member", RoleActionBan); err != nil {
			t.Fatal(err)
		}
	})
	if _, ok := e.data(t, "communities/"+modCID+"/communityMembers/member"); ok {
		t.Error("the late retry banned the user again")
	}
	if c := e.community(t, modCID); len(c.Modlog) != 3 { // ban member, ban stranger, unban member
		t.Errorf("modlog = %+v, want 3 entries", c.Modlog)
	}
}

func TestSetMemberRole_RoleMatrix(t *testing.T) {
	forbidden := func(reason string) func(*testing.T, error) {
		return func(t *testing.T, err error) {
			wantReason(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, reason)
		}
	}
	ok := func(t *testing.T, err error) {
		if err != nil {
			t.Fatalf("want success, got %v", err)
		}
	}
	tests := []struct {
		name   string
		actor  string
		target string
		action RoleAction
		check  func(*testing.T, error)
	}{
		{"owner bans a member", "owner", "member", RoleActionBan, ok},
		{"moderator bans a member", "mod1", "member", RoleActionBan, ok},
		{"member bans", "member", "target", RoleActionBan, forbidden("not_moderator")},
		{"banned bans", "banned", "target", RoleActionBan, forbidden("not_moderator")},
		{"outsider bans", "stranger", "target", RoleActionBan, forbidden("not_moderator")},
		{"member unbans", "member", "banned", RoleActionUnban, forbidden("not_moderator")},
		{"moderator bans the owner", "mod1", "owner", RoleActionBan, forbidden("not_owner")},
		{"moderator bans a moderator", "mod1", "mod2", RoleActionBan, forbidden("not_owner")},
		{"moderator bans themselves", "mod1", "mod1", RoleActionBan, forbidden("not_owner")},
		{"owner bans a moderator", "owner", "mod1", RoleActionBan, func(t *testing.T, err error) {
			wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "moderator")
		}},
		{"owner bans themselves", "owner", "owner", RoleActionBan, func(t *testing.T, err error) {
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "user_id"})
		}},
		{"owner appoints", "owner", "member", RoleActionMakeModerator, ok},
		{"moderator appoints", "mod1", "member", RoleActionMakeModerator, forbidden("not_owner")},
		{"member appoints", "member", "member", RoleActionMakeModerator, forbidden("not_owner")},
		{"banned appoints", "banned", "member", RoleActionMakeModerator, forbidden("not_owner")},
		{"outsider removes", "stranger", "mod1", RoleActionRemoveModerator, forbidden("not_owner")},
		{"moderator removes", "mod1", "mod2", RoleActionRemoveModerator, forbidden("not_owner")},
		{"owner removes a moderator", "owner", "mod1", RoleActionRemoveModerator, ok},
		{"owner appoints a banned user", "owner", "banned", RoleActionMakeModerator, func(t *testing.T, err error) {
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
		}},
		{"owner appoints a non-member", "owner", "stranger", RoleActionMakeModerator, func(t *testing.T, err error) {
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
		}},
		{"owner appoints the owner", "owner", "owner", RoleActionMakeModerator, func(t *testing.T, err error) {
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, nil)
		}},
	}
	for i, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newModEnv(t)
			e.user("stranger")
			_, err := e.role(context.Background(), tc.actor, 300+i, tc.target, tc.action)
			tc.check(t, err)
			if tc.name == "member bans" { // a refusal wrote nothing
				if c := e.community(t, modCID); len(c.Modlog) != 0 {
					t.Errorf("a refused call logged %+v", c.Modlog)
				}
			}
		})
	}
}

func TestSetMemberRole_ModeratorsOrderAndCap(t *testing.T) {
	e := newModEnv(t)
	ctx := context.Background()
	e.svc.d.Limits.MaxModerators = 3 // mod1, mod2 and one more

	// MAKE: community + target memberships (modlogged) + idempotency + the owner's first entry = 4 writes, appointment order kept
	measured(t, "SetMemberRole MAKE_MODERATOR", budgettest.Budget{Reads: 5, Writes: 4}, func(ctx context.Context) {
		r, err := e.role(ctx, "owner", 1, "member", RoleActionMakeModerator)
		if err != nil || r.Role != RoleModerator {
			t.Fatalf("MAKE = %+v, %v", r, err)
		}
	})
	if c := e.community(t, modCID); !slices.Equal(c.ModeratorIDs, []string{"mod1", "mod2", "member"}) || c.Modlog[0].Target != "member" || c.Modlog[0].Action != ActionMakeModerator {
		t.Errorf("community after MAKE = %+v", c)
	}
	if ms, _ := e.memberships(t, "member"); !slices.Contains(ms.Modlogged, modCID) {
		t.Errorf("the promoted user's modlogged = %v (I-L: the target is logged; Leave's fresh check relies on it)", ms.Modlogged)
	}
	// appointing again changes nothing and reads nothing more
	measured(t, "SetMemberRole MAKE again", budgettest.Budget{Reads: 2, Writes: 1}, func(ctx context.Context) {
		if _, err := e.role(ctx, "owner", 2, "member", RoleActionMakeModerator); err != nil {
			t.Fatal(err)
		}
	})
	// the cap: a fourth moderator is LIMIT_REACHED
	e.user("target")
	if _, err := e.client.Collection("communities").Doc(modCID).Collection(membersSubcollection).Doc("target").Set(ctx, memberDoc{UID: "target", State: "JOINED"}); err != nil {
		t.Fatal(err)
	}
	wantAPIErr(t, mustErr(e.role(ctx, "owner", 3, "target", RoleActionMakeModerator)), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": LimitModerators})
	// REMOVE: the moderator stays a member
	measured(t, "SetMemberRole REMOVE_MODERATOR", budgettest.Budget{Reads: 4, Writes: 3}, func(ctx context.Context) {
		r, err := e.role(ctx, "owner", 4, "mod1", RoleActionRemoveModerator)
		if err != nil || r.Role != RoleMember {
			t.Fatalf("REMOVE = %+v, %v", r, err)
		}
	})
	if c := e.community(t, modCID); !slices.Equal(c.ModeratorIDs, []string{"mod2", "member"}) {
		t.Errorf("moderatorIds = %v", c.ModeratorIDs)
	}
	// removing a user who is no moderator: the idempotency document only
	measured(t, "SetMemberRole REMOVE not a moderator", budgettest.Budget{Reads: 2, Writes: 1}, func(ctx context.Context) {
		if _, err := e.role(ctx, "owner", 5, "banned", RoleActionRemoveModerator); err != nil {
			t.Fatal(err)
		}
	})
	// a banned moderator: remove the role first, then ban
	if _, err := e.role(ctx, "owner", 6, "mod2", RoleActionBan); err == nil {
		t.Error("the owner banned a moderator")
	}
	if _, err := e.role(ctx, "owner", 7, "mod2", RoleActionRemoveModerator); err != nil {
		t.Fatal(err)
	}
	if _, err := e.role(ctx, "owner", 8, "mod2", RoleActionBan); err != nil {
		t.Fatalf("ban after removing the role: %v", err)
	}
}

func mustErr(_ RoleResult, err error) error { return err }

func TestModlog_CapsAndTruncationMarker(t *testing.T) {
	e := newEnv(t, 3) // modlog keeps the newest 3
	e.repo.WithPostModerator(posts.NewCommunityModerator(e.client))
	e.dir.free = true
	e.seedCommunity(t, Community{ID: modCID, Name: "Mod", OwnerID: "owner", MemberCount: 1}, map[string]MemberState{"owner": MemberJoined})
	e.seedMemberships(t, "owner", Memberships{Joined: []string{modCID}, Owned: []string{modCID}})
	e.svc.d.Limits.RecentRemovalsMax = 2
	ctx := context.Background()
	posts := []string{modPostA, modPostB, modPostC}
	for _, p := range posts {
		e.seedPost(t, p, modCID, true)
	}
	for i, p := range posts {
		if err := e.hide(ctx, "owner", 400+i, p); err != nil {
			t.Fatal(err)
		}
	}
	for i, p := range posts[:2] { // two restores make 5 entries in all
		if err := e.restore(ctx, "owner", 410+i, p); err != nil {
			t.Fatal(err)
		}
	}
	c := e.community(t, modCID)
	if len(c.Modlog) != 3 || c.Modlog[0].Seq != 3 || c.Modlog[2].Seq != 5 || c.ModlogSeq != 5 {
		t.Errorf("modlog = %+v seq %d, want the newest 3 of 5", c.Modlog, c.ModlogSeq)
	}
	// the third hide pushed the first post's entry out of the 2-entry list (removalsTruncatedAt), the restores deleted the others
	if c.RemovalsTruncatedAt.IsZero() {
		t.Error("removalsTruncatedAt was not set when the cap dropped an entry")
	}
	if len(c.RecentRemovals) != 1 || c.RecentRemovals[0].PostID != modPostC {
		t.Errorf("recentRemovals = %+v, want only the third post", c.RecentRemovals)
	}
}

func TestModeration_BannedThenUnbannedThenDeletedLeavesNoTrace(t *testing.T) {
	e := newModEnv(t)
	ctx := context.Background()
	e.user("victim")
	if _, err := e.role(ctx, "mod1", 500, "victim", RoleActionBan); err != nil { // a non-member ban: memberships created with banned + modlogged
		t.Fatal(err)
	}
	if _, err := e.role(ctx, "mod1", 501, "victim", RoleActionUnban); err != nil {
		t.Fatal(err)
	}
	if ms, _ := e.memberships(t, "victim"); len(ms.Banned) != 0 || !slices.Contains(ms.Modlogged, modCID) {
		t.Fatalf("victim memberships = %+v, want banned empty and the community in modlogged (I-L)", ms)
	}
	e.purgeAll(t, "victim", 10)
	e.requireNoTrace(t, "victim")
	c := e.community(t, modCID)
	if len(c.Modlog) != 2 || c.Modlog[0].Target != DeletedMarker || c.Modlog[1].Target != DeletedMarker || c.Modlog[0].Actor != "mod1" {
		t.Errorf("modlog after the eraser = %+v, want the target scrubbed", c.Modlog)
	}
	// and a banned user who is deleted while still banned
	if _, err := e.role(ctx, "mod1", 502, "target", RoleActionBan); err != nil {
		t.Fatal(err)
	}
	before := e.count(t, modCID)
	e.purgeAll(t, "target", 10)
	e.requireNoTrace(t, "target")
	if got := e.count(t, modCID); got != before {
		t.Errorf("memberCount %d -> %d: a banned member never counted", before, got)
	}
}

func TestRemovalsAfter_Table(t *testing.T) {
	t0 := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	mk := func(ids ...string) []Removal {
		out := make([]Removal, len(ids))
		for i, id := range ids {
			out[i] = Removal{PostID: id, At: t0.Add(time.Duration(i) * time.Minute)}
		}
		return out
	}
	full := make([]string, 50)
	for i := range full {
		full[i] = fmt.Sprintf("%019d", i+1)
	}
	got, trunc := removalsAfter(Community{RecentRemovals: mk(full...)}, "new", false, t0.Add(time.Hour), 50)
	if len(got) != 50 || got[49].PostID != "new" || got[0].PostID != full[1] || !trunc.Equal(t0) {
		t.Errorf("51st hide: len %d first %s last %s truncated %v", len(got), got[0].PostID, got[49].PostID, trunc)
	}
}

func archivedUpdate(s Status) []firestore.Update {
	return []firestore.Update{{Path: "status", Value: string(s)}}
}
