//go:build integration

// mute_target_integration_test.go covers /: Mute checks that the target's graph doc exists
// (the same rule as Block) and never branches on the target's content.
package graph_test

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func TestT26_Mute_UnknownTarget_NotFound_SameAsBlock(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	ctx := context.Background()

	var muteErr error
	// Mute (no graph doc => NOT_FOUND)
	{
		ctx := context.Background()
		_, muteErr = w.graph.Mute(ctx, "uid-a", key1, "uid-ghost")
	}
	requireAPIError(t, muteErr, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	_, blockErr := w.graph.Block(ctx, "uid-a", key1, "uid-ghost")
	var me, be *apierr.Error
	if !errors.As(muteErr, &me) || !errors.As(blockErr, &be) {
		t.Fatalf("want apierr on both: mute=%v block=%v", muteErr, blockErr)
	}
	if me.Code != be.Code || me.Reason != be.Reason || me.Message != be.Message || len(me.Metadata) != len(be.Metadata) {
		t.Errorf("Mute NOT_FOUND %+v differs from Block NOT_FOUND %+v (existence oracle)", me, be)
	}
	assertNoQuotaDoc(t, w.client, "uid-a")
	if a := graphArrays(t, w.client, "uid-a"); len(a["muted"]) != 0 {
		t.Errorf("muted = %v, want empty", a["muted"])
	}
}

// The A1 rows of the D9 matrix: blocker, SUSPENDED, DELETING (graph doc present) mute OK at 3R/2W; a purged
// target is NOT_FOUND. A blocker is indistinguishable from a stranger.
func TestT26_Mute_TargetStates(t *testing.T) {
	w := newWired(t)
	for _, u := range [][2]string{{"uid-a", "usera"}, {"uid-blocker", "userblk"}, {"uid-stranger", "userstr"}, {"uid-susp", "usersusp"}, {"uid-del", "userdel"}, {"uid-purged", "userpurged"}} {
		mustCreateProfile(t, w.identity, u[0], u[1])
	}
	ctx := context.Background()
	if _, err := w.graph.Block(ctx, "uid-blocker", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}
	seedUserField(t, w, "uid-susp", "status", "SUSPENDED")
	seedUserField(t, w, "uid-del", "status", "DELETING")

	var stranger graph.Relationship
	// Mute (stranger)
	{
		ctx := context.Background()
		var err error
		stranger, err = w.graph.Mute(ctx, "uid-a", key1, "uid-stranger")
		must(t, "Mute(stranger)", err)
	}
	for _, target := range []string{"uid-blocker", "uid-susp", "uid-del"} {
		{
			ctx := context.Background()
			rel, err := w.graph.Mute(ctx, "uid-a", key2, target)
			must(t, "Mute("+target+")", err)
			if !rel.Muting || rel.FollowState != stranger.FollowState || rel.Blocking != stranger.Blocking {
				t.Errorf("Mute(%s) = %+v, differs from stranger %+v", target, rel, stranger)
			}
		}
	}

	purgeToCompletion(t, w.graph.repo, "uid-purged", graph.Checkpoint{})
	// Mute (purged target)
	{
		ctx := context.Background()
		_, err := w.graph.Mute(ctx, "uid-a", key3, "uid-purged")
		requireAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	}
}
