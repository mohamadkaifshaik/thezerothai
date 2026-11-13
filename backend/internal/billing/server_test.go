package billing

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	billingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

type bindingReaderFunc func(context.Context, string) (Binding, error)

func (f bindingReaderFunc) LookupBinding(ctx context.Context, uid string) (Binding, error) {
	return f(ctx, uid)
}

func TestBillingRPCsRequireCaller(t *testing.T) {
	s := NewServer(nil, nil, nil)
	_, err := s.GetMySubscription(context.Background(), connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
	if connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("status accepted anonymous caller")
	}
	_, err = s.GetAvailablePlans(context.Background(), connect.NewRequest(&billingv1.GetAvailablePlansRequest{}))
	if connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("catalog accepted anonymous caller")
	}
	_, err = s.EnsureBillingIdentity(context.Background(), connect.NewRequest(&billingv1.EnsureBillingIdentityRequest{}))
	if connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("identity accepted anonymous caller")
	}
}

func TestMissingBindingAndUnavailableAreDistinct(t *testing.T) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "owner"})
	for _, tc := range []struct {
		name string
		err  error
		want billingv1.VerificationState
	}{
		{"missing", ErrNotFound, billingv1.VerificationState_VERIFICATION_STATE_NO_SUBSCRIPTION},
		{"storage failure", ErrUnavailable, billingv1.VerificationState_VERIFICATION_STATE_UNAVAILABLE},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := NewServer(nil, bindingReaderFunc(func(_ context.Context, uid string) (Binding, error) {
				if uid != "owner" {
					t.Fatal("caller not used")
				}
				return Binding{}, tc.err
			}), nil)
			r, err := s.GetMySubscription(ctx, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
			if err != nil || r.Msg.VerificationState != tc.want || r.Msg.PurchasesAvailable {
				t.Fatalf("response=%v err=%v", r, err)
			}
		})
	}
}

func TestStoreSalesRequireRealCatalogAndVerification(t *testing.T) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "owner"})
	for _, tc := range []struct {
		name            string
		environment     Environment
		products        map[string]Product
		missingVerifier bool
		want            bool
	}{
		{name: "production", environment: Production, products: map[string]Product{"premium:monthly": {Store: "play_store", Entitlement: ProEntitlement}}, want: true},
		{name: "Play license tester", environment: Sandbox, products: map[string]Product{"premium:monthly": {Store: "play_store", Entitlement: ProEntitlement}}, want: true},
		{name: "test store", environment: Production, products: map[string]Product{"monthly": {Store: "test_store", Entitlement: ProEntitlement}}},
		{name: "empty catalog", environment: Production},
		{name: "no verifier", environment: Production, products: map[string]Product{"premium:monthly": {Store: "play_store", Entitlement: ProEntitlement}}, missingVerifier: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ids, _ := NewIdentityService(bindingStoreFunc(func(_ context.Context, b Binding) (Binding, error) { return b, nil }), tc.environment, nil)
			var reconciler *Reconciler
			if !tc.missingVerifier {
				reconciler = &Reconciler{}
			}
			s := NewServer(ids, bindingReaderFunc(func(context.Context, string) (Binding, error) { return Binding{}, ErrNotFound }), reconciler)
			before, _ := s.GetMySubscription(ctx, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
			if before.Msg.PurchasesAvailable {
				t.Fatal("sales enabled by default")
			}
			s.EnableStorePurchases(tc.products)
			got, err := s.GetMySubscription(ctx, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
			if err != nil || got.Msg.PurchasesAvailable != tc.want {
				t.Fatalf("sales=%t err=%v", got.Msg.PurchasesAvailable, err)
			}
			plans, err := s.GetAvailablePlans(ctx, connect.NewRequest(&billingv1.GetAvailablePlansRequest{}))
			if err != nil || plans.Msg.Plans[1].Purchasable != tc.want || plans.Msg.Plans[0].Purchasable {
				t.Fatal("catalog advertised an unconfigured tier")
			}
		})
	}
}

func TestProductionStatusDoesNotAdoptSandboxBinding(t *testing.T) {
	ids, _ := NewIdentityService(bindingStoreFunc(func(_ context.Context, b Binding) (Binding, error) { return b, nil }), Production, nil)
	s := NewServer(ids, bindingReaderFunc(func(context.Context, string) (Binding, error) { return testBinding(), nil }), &Reconciler{})
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: testBinding().UID})
	got, err := s.GetMySubscription(ctx, connect.NewRequest(&billingv1.GetMySubscriptionRequest{}))
	if err != nil || got.Msg.VerificationState != billingv1.VerificationState_VERIFICATION_STATE_UNAVAILABLE || got.Msg.PurchasesAvailable {
		t.Fatal("production status adopted a sandbox binding")
	}
}
