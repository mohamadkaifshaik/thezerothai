//go:build integration

package billing

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

func TestFirestoreBindingReplayAndErasure(t *testing.T) {
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("requires isolated demo-dzeroth-local emulator")
	}
	ctx := context.Background()
	c, err := firestore.NewClient(ctx, "demo-dzeroth-local")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	b := testBinding()
	b.UID = "billing-" + strings.ReplaceAll(t.Name(), "/", "-")
	r := NewFirestoreBindings(c)
	if _, err := c.Collection("users").Doc(b.UID).Set(ctx, map[string]any{"status": "ACTIVE"}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _, _ = r.Run(ctx, b.UID, nil); _, _ = c.Collection("users").Doc(b.UID).Delete(ctx) })
	got, err := r.EnsureBinding(ctx, b)
	if err != nil || got != b {
		t.Fatalf("create: %v", err)
	}
	got, err = r.EnsureBinding(ctx, b)
	if err != nil || got != b {
		t.Fatalf("replay: %v", err)
	}
	var exported strings.Builder
	_, first, err := r.BeginVerification(ctx, b.UID)
	if err != nil {
		t.Fatal(err)
	}
	_, second, err := r.BeginVerification(ctx, b.UID)
	if err != nil || second <= first {
		t.Fatalf("generation not advanced: %v", err)
	}
	snapshot := Snapshot{UID: b.UID, CustomerID: b.CustomerID, Environment: b.Environment, VerifiedAt: time.Now().UTC()}
	if err := r.CommitVerification(ctx, b, first, snapshot); err == nil {
		t.Fatal("late provider response overwrote newer attempt")
	}
	if err := r.CommitVerification(ctx, b, second, snapshot); err != nil {
		t.Fatal(err)
	}
	if err := r.WriteSection(ctx, b.UID, &exported); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(exported.String(), b.CustomerID) {
		t.Fatal("export leaked private binding")
	}
	if _, err := c.Collection("users").Doc(b.UID).Update(ctx, []firestore.Update{{Path: "status", Value: "DELETING"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := r.EnsureBinding(ctx, b); err != ErrOwnership {
		t.Fatalf("deleting account: %v", err)
	}
	if _, done, err := r.Run(ctx, b.UID, nil); err != nil || !done {
		t.Fatalf("erase: %v", err)
	}
}
