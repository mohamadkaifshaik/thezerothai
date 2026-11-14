//go:build integration

package billing

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	billingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

func TestRealStoreVerificationWithSalesOffAndWebhookRevocation(t *testing.T) {
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
	owner := "billing-real-store-fixture"
	if _, err = client.Collection("users").Doc(owner).Set(ctx, map[string]any{"status": "ACTIVE"}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _, _ = store.Run(ctx, owner, nil); _, _ = client.Collection("users").Doc(owner).Delete(ctx) })
	now := time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	identities, err := NewIdentityService(store, Production, clock)
	if err != nil {
		t.Fatal(err)
	}
	paid, calls := true, 0
	provider := providerFunc(func(_ context.Context, b Binding) (Snapshot, error) {
		calls++
		if b.UID != owner || b.Environment != Production {
			t.Fatal("incorrect store binding")
		}
		s := Snapshot{UID: b.UID, CustomerID: b.CustomerID, Environment: b.Environment, VerifiedAt: now}
		if paid {
			s.Grants = []Grant{{Entitlement: ProEntitlement, AccessUntil: now.Add(time.Hour)}}
		}
		return s, nil
	})
	reconciler, err := NewReconciler(store, provider, clock)
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer(identities, store, reconciler)
	s.now = clock
	caller := authn.WithClaims(ctx, authn.Claims{UID: owner})
	id, err := s.EnsureBillingIdentity(caller, connect.NewRequest(&billingv1.EnsureBillingIdentityRequest{IdempotencyKey: "11111111-1111-4111-8111-111111111111"}))
	if err != nil {
		t.Fatal(err)
	}
	access, err := s.GetMySubscription(caller, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
	if err != nil || access.Msg.Tier != billingv1.SubscriptionTier_SUBSCRIPTION_TIER_PREMIUM || access.Msg.PurchasesAvailable {
		t.Fatal("sales-off mode did not preserve verified paid access")
	}
	s.EnableStorePurchases(map[string]Product{"premium:monthly": {Store: "play_store", Entitlement: ProEntitlement}})
	access, err = s.GetMySubscription(caller, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
	if err != nil || access.Msg.PurchasesAvailable {
		t.Fatal("existing subscriber was offered duplicate checkout")
	}
	paid = false
	processor, err := NewWebhookProcessor(store, reconciler)
	if err != nil {
		t.Fatal(err)
	}
	if err = processor.AcceptEvent(ctx, InboxEvent{ID: "fixture-revocation", CustomerID: id.Msg.AppUserId, Environment: Production, BodyHash: strings.Repeat("a", 64)}); err != nil {
		t.Fatal(err)
	}
	access, err = s.GetMySubscription(caller, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
	if err != nil || access.Msg.Tier != billingv1.SubscriptionTier_SUBSCRIPTION_TIER_FREE || !access.Msg.PurchasesAvailable {
		t.Fatal("verified revocation did not revoke paid access")
	}
	// A status read in read-only composition cannot call or commit a verifier.
	readOnly := NewServer(nil, store, nil)
	readOnly.EnableStorePurchases(map[string]Product{"premium:monthly": {Store: "play_store", Entitlement: ProEntitlement}})
	before := calls
	access, err = readOnly.GetMySubscription(caller, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
	if err != nil || access.Msg.PurchasesAvailable || access.Msg.VerificationState != billingv1.VerificationState_VERIFICATION_STATE_UNAVAILABLE || calls != before {
		t.Fatal("read-only status invoked verification or advertised checkout")
	}
}
