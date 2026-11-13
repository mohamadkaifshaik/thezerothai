//go:build integration

package billing

import (
	"cloud.google.com/go/firestore"
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestWebhookDurabilityFencingRecoveryAndErasure(t *testing.T) {
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("requires isolated demo-dzeroth-local emulator")
	}
	ctx := context.Background()
	client, err := firestore.NewClient(ctx, "demo-dzeroth-local")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	store := NewFirestoreBindings(client)
	b := testBinding()
	b.UID = "billing-webhook-recovery"
	if _, err = client.Collection("users").Doc(b.UID).Set(ctx, map[string]any{"status": "ACTIVE"}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _, _ = store.Run(ctx, b.UID, nil); _, _ = client.Collection("users").Doc(b.UID).Delete(ctx) })
	if _, err = store.EnsureBinding(ctx, b); err != nil {
		t.Fatal(err)
	}
	_, generation, err := store.BeginVerification(ctx, b.UID)
	if err != nil {
		t.Fatal(err)
	}
	event := InboxEvent{ID: "event-1", CustomerID: b.CustomerID, Environment: b.Environment, BodyHash: strings.Repeat("a", 64)}
	if _, err = store.stageWebhook(ctx, event, b.CustomerID); err != nil {
		t.Fatal(err)
	}
	snapshot := Snapshot{UID: b.UID, CustomerID: b.CustomerID, Environment: b.Environment, VerifiedAt: time.Now().UTC(), Grants: []Grant{{Entitlement: ProEntitlement, AccessUntil: time.Now().Add(time.Hour)}}}
	if err = store.CommitVerification(ctx, b, generation, snapshot); err == nil {
		t.Fatal("webhook did not fence old response")
	}
	var duringReadback func()
	fail := true
	calls := 0
	provider := providerFunc(func(context.Context, Binding) (Snapshot, error) {
		calls++
		if duringReadback != nil {
			hook := duringReadback
			duringReadback = nil
			hook()
		}
		if fail {
			return Snapshot{}, ErrUnavailable
		}
		snapshot.VerifiedAt = time.Now().UTC()
		return snapshot, nil
	})
	reconciler, _ := NewReconciler(store, provider, nil)
	processor, _ := NewWebhookProcessor(store, reconciler)
	if err = processor.AcceptEvent(ctx, event); err == nil {
		t.Fatal("provider outage acknowledged")
	}
	fail = false
	if err = processor.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	previous := calls
	if err = processor.AcceptEvent(ctx, event); err != nil || calls != previous {
		t.Fatal("completed duplicate reprocessed")
	}
	// A revocation is read back from provider state, irrespective of event type
	// or ordering; signed event bodies never directly supply access grants.
	snapshot.Grants = nil
	event.ID = "revocation"
	if err = processor.AcceptEvent(ctx, event); err != nil {
		t.Fatal(err)
	}
	revoked, _ := client.Collection("billingCustomers").Doc(b.UID).Get(ctx)
	var rev verificationDocument
	if revoked.DataTo(&rev) != nil {
		t.Fatal("revocation snapshot missing")
	}
	if tier, err := EffectiveTier(b, rev.Snapshot, time.Now()); err != nil || tier != TierFree {
		t.Fatal("revocation retained paid access")
	}
	event.ID = "racing-verification"
	duringReadback = func() {
		next := event
		next.ID = "newer-event"
		if _, err := store.stageWebhook(ctx, next, b.CustomerID); err != nil {
			t.Fatal(err)
		}
	}
	if err = processor.AcceptEvent(ctx, event); err == nil {
		t.Fatal("late readback overwrote newer webhook")
	}
	if err = processor.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	conflict := event
	conflict.BodyHash = strings.Repeat("b", 64)
	if err = processor.AcceptEvent(ctx, conflict); err == nil {
		t.Fatal("event ID conflict accepted")
	}
	for i := 0; i < webhookReceiptLimit+2; i++ {
		event.ID = fmt.Sprint(i)
		if _, err = store.stageWebhook(ctx, event, b.CustomerID); err != nil {
			t.Fatal(err)
		}
	}
	doc, err := client.Collection("billingCustomers").Doc(b.UID).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var work webhookDocument
	if doc.DataTo(&work) != nil || len(work.Receipts) != webhookReceiptLimit || !work.Pending {
		t.Fatal("unbounded receipts or lost work")
	}
	if _, _, err = store.Run(ctx, b.UID, nil); err != nil {
		t.Fatal(err)
	}
	if err = processor.AcceptEvent(ctx, event); err != nil {
		t.Fatal("deleted identity was recreated or retried")
	}
	if _, err = store.LookupBinding(ctx, b.UID); err != ErrNotFound {
		t.Fatal("deleted binding recreated")
	}
}
