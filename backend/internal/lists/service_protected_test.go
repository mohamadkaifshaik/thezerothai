package lists

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// W5-42 (W5-17 M-2): the lists of a protected owner are visible to the owner and to followers only. A refusal on a single
// list is the D3 NOT_FOUND, byte-identical to a missing list; ListUserLists answers PROTECTED_ACCOUNT (the ListFollowing
// precedent). The rule reads nothing beyond what the D3 checks already read.
func TestProtectedOwner_Matrix(t *testing.T) {
	t.Parallel()
	want := missingErr(t)
	protected := map[string]identity.Profile{testUID: active(testUID, true)}
	tests := []struct {
		name    string
		viewer  string
		snaps   map[string]graph.Snapshot
		visible bool
		graphs  int // snapshots read by GetList
	}{
		{"follower sees it", viewerUID, map[string]graph.Snapshot{viewerUID: {Following: set(testUID)}}, true, 2},
		{"non-follower is refused before the owner's graph", viewerUID, nil, false, 1},
		{"pending follow request is not following", viewerUID, map[string]graph.Snapshot{viewerUID: {Requested: set(testUID)}}, false, 1},
		{"owner sees it", testUID, nil, true, 0},
		{"viewer who blocked the owner is refused", viewerUID, map[string]graph.Snapshot{viewerUID: {Blocked: set(testUID)}}, false, 1},
		{"owner blocks a follower", viewerUID, map[string]graph.Snapshot{viewerUID: {Following: set(testUID)}, testUID: {Blocked: set(viewerUID)}}, false, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			ctx := context.Background()
			e := newReadEnv(protected, tt.snaps, pubList("m1"))
			v, err := e.svc.GetList(ctx, tt.viewer, testListID)
			if len(e.g.asked) != tt.graphs {
				t.Errorf("GetList graph snapshots = %v, want %d", e.g.asked, tt.graphs)
			}
			if tt.visible {
				if err != nil || v.Header.ID != testListID {
					t.Fatalf("GetList = %+v, %v", v, err)
				}
			} else {
				if err == nil {
					t.Fatal("GetList served a protected owner's list")
				}
				sameError(t, err, want)
			}
			// the other single-list paths decide through the same resolve
			_, merr := e.svc.Members(ctx, tt.viewer, testListID)
			_, lmErr := e.svc.ListListMembers(ctx, tt.viewer, testListID, 20, "")
			_, repErr := e.svc.ReportableList(ctx, tt.viewer, testListID)
			if tt.visible != (merr == nil) || tt.visible != (lmErr == nil) {
				t.Errorf("Members err = %v, ListListMembers err = %v, visible %v", merr, lmErr, tt.visible)
			}
			if !tt.visible {
				if !errors.Is(merr, ErrNotFound) { // the Reader answer GetListTimeline maps to the same NotFoundError
					t.Errorf("Members err = %v, want ErrNotFound", merr)
				}
				sameError(t, lmErr, want)
			}
			switch {
			case tt.visible && tt.viewer == testUID:
				if !errors.Is(repErr, ErrOwnList) {
					t.Errorf("owner report = %v, want ErrOwnList", repErr)
				}
			case tt.visible:
				if repErr != nil {
					t.Errorf("follower report = %v, want reportable", repErr)
				}
			default:
				if !errors.Is(repErr, ErrNotFound) {
					t.Errorf("report = %v, want ErrNotFound (cannot report what you cannot see)", repErr)
				}
			}
			// ListUserLists
			ul, uerr := e.svc.ListUserLists(ctx, tt.viewer, UserListsInput{OwnerID: testUID})
			switch {
			case tt.viewer == testUID || (tt.visible && tt.viewer != testUID):
				if uerr != nil || len(ul.Lists) != 1 {
					t.Errorf("ListUserLists = %+v, %v; want the list", ul, uerr)
				}
			case tt.name == "owner blocks a follower":
				wantAPI(t, uerr, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
			default:
				wantAPI(t, uerr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, nil)
			}
		})
	}
}

// I-3 (W5-17): a viewer who blocked a PUBLIC owner can still read that owner's lists, like viewing a blocked profile. Only the
// owner blocking the viewer, or the viewer's blockedBy naming the owner, refuses.
func TestPublicOwner_ViewerWhoBlockedTheOwnerStillSees(t *testing.T) {
	t.Parallel()
	e := newReadEnv(nil, map[string]graph.Snapshot{viewerUID: {Blocked: set(testUID)}}, pubList("m1"))
	if _, err := e.svc.GetList(context.Background(), viewerUID, testListID); err != nil {
		t.Fatalf("GetList = %v", err)
	}
	if ul, err := e.svc.ListUserLists(context.Background(), viewerUID, UserListsInput{OwnerID: testUID}); err != nil || len(ul.Lists) != 1 {
		t.Fatalf("ListUserLists = %+v, %v", ul, err)
	}
}

// A public owner is unaffected, and the protected rule follows the profile: unprotecting re-opens the list for everyone.
func TestProtectedOwner_UnprotectingReopens(t *testing.T) {
	t.Parallel()
	e := newReadEnv(map[string]identity.Profile{testUID: active(testUID, false)}, nil, pubList("m1"))
	if _, err := e.svc.GetList(context.Background(), viewerUID, testListID); err != nil {
		t.Fatalf("public owner: %v", err)
	}
}
