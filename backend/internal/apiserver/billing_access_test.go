package apiserver

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/dzeroth/dzeroth/backend/internal/billing"
)

type billingBindingProbe func(context.Context, string) (billing.Binding, error)

func (f billingBindingProbe) LookupBinding(ctx context.Context, uid string) (billing.Binding, error) {
	return f(ctx, uid)
}

type billingVerificationProbe func(context.Context, string) (billing.Snapshot, error)

func (f billingVerificationProbe) Refresh(ctx context.Context, uid string) (billing.Snapshot, error) {
	return f(ctx, uid)
}

func TestStorePublishingRequiresFreshMatchingEnvironmentAndOwner(t *testing.T) {
	now := time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name, entitlement                             string
		missing, outage, wrongOwner, sandbox, expired bool
		wantLimit                                     int
		wantCode                                      connect.Code
	}{
		{name: "no subscription", missing: true, wantLimit: 280, wantCode: connect.CodePermissionDenied},
		{name: "verified free", wantLimit: 280, wantCode: connect.CodePermissionDenied},
		{name: "plus", entitlement: billing.PlusEntitlement, wantLimit: 3000, wantCode: connect.CodePermissionDenied},
		{name: "premium", entitlement: billing.ProEntitlement, wantLimit: 15000},
		{name: "provider failure", outage: true, wantCode: connect.CodeUnavailable},
		{name: "different owner", wrongOwner: true, wantCode: connect.CodeUnavailable},
		{name: "sandbox cannot grant production access", sandbox: true, entitlement: billing.ProEntitlement, wantCode: connect.CodeUnavailable},
		{name: "stale provider snapshot", expired: true, entitlement: billing.ProEntitlement, wantCode: connect.CodeUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := billing.Binding{UID: "owner", CustomerID: "dzb_" + strings.Repeat("A", 43), Environment: billing.Production, CreatedAt: now.Add(-time.Hour)}
			if tc.wrongOwner {
				b.UID = "other"
			}
			if tc.sandbox {
				b.Environment = billing.Sandbox
			}
			access := verifiedBillingAccess{
				environment: billing.Production,
				now:         func() time.Time { return now },
				bindings: billingBindingProbe(func(_ context.Context, uid string) (billing.Binding, error) {
					if uid != "owner" {
						t.Fatal("wrong caller")
					}
					if tc.missing {
						return billing.Binding{}, billing.ErrNotFound
					}
					return b, nil
				}),
				verifier: billingVerificationProbe(func(ctx context.Context, uid string) (billing.Snapshot, error) {
					if uid != "owner" {
						t.Fatal("wrong verification owner")
					}
					if _, ok := ctx.Deadline(); !ok {
						t.Fatal("unbounded verification")
					}
					if tc.outage {
						return billing.Snapshot{}, errors.New("private provider failure")
					}
					s := billing.Snapshot{UID: b.UID, CustomerID: b.CustomerID, Environment: b.Environment, VerifiedAt: now}
					if tc.expired {
						s.VerifiedAt = now.Add(-billing.MaxVerificationAge)
					}
					if tc.entitlement != "" {
						s.Grants = []billing.Grant{{Entitlement: tc.entitlement, AccessUntil: now.Add(time.Hour)}}
					}
					return s, nil
				}),
			}
			limit, err := access.postTextLimit(context.Background(), "owner")
			if limit != tc.wantLimit || (tc.wantLimit == 0 && connect.CodeOf(err) != tc.wantCode) || (tc.wantLimit != 0 && err != nil) {
				t.Fatalf("limit=%d err=%v", limit, err)
			}
			err = access.publishArticle(context.Background(), "owner")
			if (tc.wantCode == 0 && err != nil) || (tc.wantCode != 0 && connect.CodeOf(err) != tc.wantCode) {
				t.Fatalf("publication err=%v", err)
			}
		})
	}
}
