package communities

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Targets in every account state the directory can answer; "missing" has no profile at all.
var oracleTargets = map[string]identity.AccountStatus{
	"t-active":    identity.AccountStatusActive,
	"t-suspended": identity.AccountStatusSuspended,
	"t-deleting":  identity.AccountStatusDeleting,
	"t-missing":   identity.AccountStatusUnspecified, // no profile
}

var allRoleActions = []RoleAction{RoleActionBan, RoleActionUnban, RoleActionMakeModerator, RoleActionRemoveModerator}

// oracleFixture seeds testCID (owner ownerUID, moderator modUID), a SUSPENDED otherCID, and the oracle targets.
func oracleFixture() (*fixture, *fakeModRepo) {
	f, m := modFixture()
	f.seed(Community{ID: testCID, Name: "Go", OwnerID: ownerUID, ModeratorIDs: []string{modUID}, MemberCount: 3, Status: StatusActive})
	f.seed(Community{ID: otherCID, Name: "Gone", OwnerID: ownerUID, ModeratorIDs: []string{modUID}, Status: StatusSuspended})
	for u, st := range oracleTargets {
		if st != identity.AccountStatusUnspecified {
			f.dir.profiles[u] = profile(u, st)
		}
	}
	return f, m
}

func apiErrOf(t *testing.T, err error) apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want an *apierr.Error", err)
	}
	return apierr.Error{Code: ae.Code, Reason: ae.Reason, Message: ae.Message, Metadata: ae.Metadata, RetryAfter: ae.RetryAfter}
}

// An unauthorized SetMemberRole caller must learn nothing about the target: the answer (code, reason, message, details) is the
// same for an ACTIVE, SUSPENDED, DELETING or never-existing target, and the target is never looked up nor the repository run.
func TestSetMemberRole_UnauthorizedCallerLearnsNothingAboutTheTarget(t *testing.T) {
	const missingCID = "0000000000000000599"
	callers := []struct {
		name   string
		uid    string
		cid    string
		action []RoleAction
		code   connect.Code
		reason string // metadata "reason"; "" for NOT_FOUND
	}{
		{"non-member", nobodyUID, testCID, []RoleAction{RoleActionBan, RoleActionUnban}, connect.CodePermissionDenied, "not_moderator"},
		{"plain member", memberUID, testCID, []RoleAction{RoleActionBan, RoleActionUnban}, connect.CodePermissionDenied, "not_moderator"},
		{"banned user", bannedUID, testCID, []RoleAction{RoleActionBan, RoleActionUnban}, connect.CodePermissionDenied, "not_moderator"},
		{"non-member owner-only", nobodyUID, testCID, []RoleAction{RoleActionMakeModerator, RoleActionRemoveModerator}, connect.CodePermissionDenied, "not_owner"},
		{"plain member owner-only", memberUID, testCID, []RoleAction{RoleActionMakeModerator, RoleActionRemoveModerator}, connect.CodePermissionDenied, "not_owner"},
		{"moderator owner-only", modUID, testCID, []RoleAction{RoleActionMakeModerator, RoleActionRemoveModerator}, connect.CodePermissionDenied, "not_owner"},
		{"nonexistent community", nobodyUID, missingCID, allRoleActions, connect.CodeNotFound, ""},
		{"nonexistent community as an owner elsewhere", ownerUID, missingCID, allRoleActions, connect.CodeNotFound, ""},
		{"suspended community", ownerUID, otherCID, allRoleActions, connect.CodeNotFound, ""},
	}
	for _, c := range callers {
		for _, a := range c.action {
			t.Run(fmt.Sprintf("%s/%s", c.name, a), func(t *testing.T) {
				f, m := oracleFixture()
				f.repo.members[testCID+"|"+memberUID] = MemberJoined
				f.repo.members[testCID+"|"+bannedUID] = MemberBanned
				var first *apierr.Error
				for target := range oracleTargets {
					_, err := f.svc.SetMemberRole(context.Background(), c.uid, RoleInput{Key: goodKey, CommunityID: c.cid, UserID: target, Action: a})
					got := apiErrOf(t, err)
					if got.Code != c.code || (c.reason != "" && got.Metadata["reason"] != c.reason) {
						t.Errorf("target %s: %v %q %v, want %v %q", target, got.Code, got.Message, got.Metadata, c.code, c.reason)
					}
					if first == nil {
						first = &got
					} else if !reflect.DeepEqual(*first, got) {
						t.Errorf("target %s answered %+v, another target %+v: the answer depends on the target", target, got, *first)
					}
				}
				if f.dir.asked != 0 {
					t.Errorf("the target was looked up %d times for an unauthorized caller", f.dir.asked)
				}
				if len(m.roles) != 0 {
					t.Errorf("the repository ran %d times for an unauthorized caller", len(m.roles))
				}
			})
		}
	}
}

// The authorized path is unchanged: the owner (every action) and a moderator (BAN, UNBAN) still get "user not found" for a
// target that is not ACTIVE, before the repository runs, and reach the repository for an ACTIVE one.
func TestSetMemberRole_AuthorizedCallerStillSeesTheTargetCheck(t *testing.T) {
	tests := []struct {
		uid     string
		actions []RoleAction
	}{{ownerUID, allRoleActions}, {modUID, []RoleAction{RoleActionBan, RoleActionUnban}}}
	for _, tc := range tests {
		for _, a := range tc.actions {
			for target, st := range oracleTargets {
				t.Run(fmt.Sprintf("%s/%s/%s", tc.uid, a, target), func(t *testing.T) {
					f, m := oracleFixture()
					c := f.repo.docs[testCID]
					m.roleRes = SetRoleResult{Outcome: Unchanged, Community: c}
					_, err := f.svc.SetMemberRole(context.Background(), tc.uid, RoleInput{Key: goodKey, CommunityID: testCID, UserID: target, Action: a})
					if st == identity.AccountStatusActive {
						if err != nil || len(m.roles) != 1 {
							t.Fatalf("ACTIVE target: err %v, repository calls %d", err, len(m.roles))
						}
						return
					}
					wantAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
					if got := apiErrOf(t, err); got.Message != userNotFound {
						t.Errorf("message = %q, want %q", got.Message, userNotFound)
					}
					if len(m.roles) != 0 {
						t.Error("the repository ran for a target that is not ACTIVE")
					}
				})
			}
		}
	}
}

// The pre-check is a fresh read: a moderator appointed after this instance cached the community is not refused from the stale entry,
// and a moderator removed since is refused without the target being looked up.
func TestSetMemberRole_PreCheckIgnoresTheCommunityCache(t *testing.T) {
	f, m := oracleFixture()
	stale := f.repo.docs[testCID]
	stale.ModeratorIDs = nil
	f.svc.cache.put(stale) // this instance still thinks modUID is no moderator
	m.roleRes = SetRoleResult{Outcome: Unchanged, Community: f.repo.docs[testCID]}
	if _, err := f.svc.SetMemberRole(context.Background(), modUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: "t-active", Action: RoleActionBan}); err != nil {
		t.Fatalf("a current moderator was refused from a stale cache entry: %v", err)
	}

	f, m = oracleFixture()
	f.svc.cache.put(f.repo.docs[testCID]) // cached while modUID was a moderator
	removed := f.repo.docs[testCID]
	removed.ModeratorIDs = nil
	f.seed(removed)
	_, err := f.svc.SetMemberRole(context.Background(), modUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: "t-deleting", Action: RoleActionBan})
	wantAPIErr(t, err, connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, map[string]string{"reason": "not_moderator"})
	if f.dir.asked != 0 || len(m.roles) != 0 {
		t.Errorf("a removed moderator reached the target lookup (%d) or the repository (%d)", f.dir.asked, len(m.roles))
	}
}

// A failing community read is an internal error, never a target answer.
func TestSetMemberRole_PreCheckReadErrorIsInternal(t *testing.T) {
	f, m := oracleFixture()
	f.repo.getErr = errors.New("rpc error: deadline exceeded")
	_, err := f.svc.SetMemberRole(context.Background(), ownerUID, RoleInput{Key: goodKey, CommunityID: testCID, UserID: "t-deleting", Action: RoleActionBan})
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Errorf("err = %v, want a plain internal error", err)
	}
	if f.dir.asked != 0 || len(m.roles) != 0 {
		t.Error("a failed pre-check went on")
	}
}
