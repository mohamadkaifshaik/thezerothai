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
