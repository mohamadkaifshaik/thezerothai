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

// F9 against the Firestore emulator: users/{uid}.dmPolicy is stored, read back, absent by default, survives a whole-document
// rewrite (ChangeHandle), is hidden by the kill switch and goes to the export; the gate refuses without a write.

func newDMService(t *testing.T, mode flags.Mode) (identity.Service, *identity.FirestoreRepo, func(string) map[string]any) {
	t.Helper()
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	reg := flags.NewRegistry(flags.Spec{Name: identity.DMPolicyFlag, Mode: mode})
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour, identity.WithExtrasFlags(reg))
	if _, err := svc.CreateProfile(context.Background(), itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return svc, repo, func(uid string) map[string]any { return userData(t, client, uid) }
}

func TestUpdateProfile_Integration_DMPolicy(t *testing.T) {
	svc, repo, data := newDMService(t, flags.On)
	ctx := context.Background()
	if _, has := data(itUID)["dmPolicy"]; has {
		t.Fatal("a new profile must not carry dmPolicy (absent = everyone_requests)")
	}
	fo := identity.DMPolicyFollowingOnly
	got, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, DMPolicy: &fo})
	if err != nil {
		t.Fatal(err)
	}
	if got.DMPolicy != fo || data(itUID)["dmPolicy"] != "following_only" {
		t.Errorf("response %q stored %v", got.DMPolicy, data(itUID)["dmPolicy"])
	}
	// The profile the send transaction reads (identity.TxProfiles / the directory) carries it.
	read, err := repo.GetProfile(ctx, itUID)
	if err != nil || read.DMPolicy != fo {
		t.Fatalf("GetProfile = %+v, %v", read, err)
	}
	// A whole-document rewrite (ChangeHandle) keeps it.
	if _, err := svc.ChangeHandle(ctx, itUID, validKeyForIntegration, "alice_two"); err != nil {
		t.Fatal(err)
	}
	if data(itUID)["dmPolicy"] != "following_only" {
		t.Errorf("ChangeHandle dropped dmPolicy: %v", data(itUID)["dmPolicy"])
	}
	// Back to the default removes the field (omitempty), and is idempotent.
	ev := identity.DMPolicyEveryoneRequests
	for i := 0; i < 2; i++ {
		if _, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, DMPolicy: &ev}); err != nil {
			t.Fatal(err)
		}
	}
	if _, has := data(itUID)["dmPolicy"]; has {
		t.Errorf("the default must be stored as absent, got %v", data(itUID)["dmPolicy"])
	}
}

func TestUpdateProfile_Integration_DMPolicyGateWritesNothing(t *testing.T) {
	svc, _, data := newDMService(t, flags.Off)
	fo := identity.DMPolicyFollowingOnly
	if _, err := svc.UpdateProfile(context.Background(), itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, DMPolicy: &fo}); err == nil {
		t.Fatal("FOLLOWING_ONLY was accepted with the flag off")
	}
	if _, has := data(itUID)["dmPolicy"]; has {
		t.Error("a gated request wrote dmPolicy")
	}
}
