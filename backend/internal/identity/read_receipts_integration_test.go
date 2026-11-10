//go:build integration

package identity_test

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F3 on the emulator: users/{uid}.readReceipts is absent by default, written only by an explicit true, survives another
// whole-document profile rewrite, and goes away (to absent) on the undo.
func TestUpdateProfile_Integration_ReadReceipts(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	reg := flags.NewRegistry(flags.Spec{Name: identity.ReadReceiptsFlag, Mode: flags.On})
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithExtrasFlags(reg))
	ctx := context.Background()
	if _, err := svc.CreateProfile(ctx, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	if _, ok := userData(t, client, itUID)["readReceipts"]; ok {
		t.Fatal("readReceipts present on a new profile, want absent (off)")
	}
	on, off := true, false
	got, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, ReadReceipts: &on})
	if err != nil || !got.ReadReceipts {
		t.Fatalf("turn on = %+v, %v", got, err)
	}
	if v, _ := userData(t, client, itUID)["readReceipts"].(bool); !v {
		t.Fatal("readReceipts not stored true")
	}
	bio := "new bio"
	if _, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: "another-key-for-bio-0001", Bio: &bio}); err != nil {
		t.Fatal(err)
	}
	if v, _ := userData(t, client, itUID)["readReceipts"].(bool); !v {
		t.Error("an unrelated whole-document rewrite dropped readReceipts")
	}
	if _, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: "another-key-for-off-0002", ReadReceipts: &off}); err != nil {
		t.Fatal(err)
	}
	if v, _ := userData(t, client, itUID)["readReceipts"].(bool); v {
		t.Error("readReceipts still true after the undo")
	}
}
