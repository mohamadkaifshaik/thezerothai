package apiserver

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"
	"github.com/dzeroth/dzeroth/backend/internal/billing"
)

type billingVerificationSource interface {
	Refresh(context.Context, string) (billing.Snapshot, error)
}

// The same verification policy protects Test Store and real-store mutations.
// A provider outage is never silently converted into a confirmed Free account.
type verifiedBillingAccess struct {
	bindings    billing.SubscriptionReader
	verifier    billingVerificationSource
	now         func() time.Time
	environment billing.Environment
}

func (a verifiedBillingAccess) tier(ctx context.Context, uid string) (billing.Tier, error) {
	unavailable := func() (billing.Tier, error) {
		return billing.TierFree, connect.NewError(connect.CodeUnavailable, errors.New("subscription verification unavailable"))
	}
	ctx, cancel := context.WithTimeout(ctx, billing.RecoveryAttemptBudget)
	defer cancel()
	b, err := a.bindings.LookupBinding(ctx, uid)
	if errors.Is(err, billing.ErrNotFound) {
		return billing.TierFree, nil
	}
	if err != nil || b.UID != uid || b.Environment != a.environment || a.verifier == nil {
		return unavailable()
	}
	snapshot, err := a.verifier.Refresh(ctx, uid)
	if err != nil {
		return unavailable()
	}
	tier, err := billing.EffectiveTier(b, snapshot, a.now())
	if err != nil {
		return unavailable()
	}
	return tier, nil
}

func (a verifiedBillingAccess) postTextLimit(ctx context.Context, uid string) (int, error) {
	tier, err := a.tier(ctx, uid)
	if err != nil {
		return 0, err
	}
	return billing.CapabilitiesFor(tier, billing.FeatureAvailability{LongPosts: true}).MaxPostRunes, nil
}

func (a verifiedBillingAccess) publishArticle(ctx context.Context, uid string) error {
	tier, err := a.tier(ctx, uid)
	if err != nil {
		return err
	}
	if !billing.CapabilitiesFor(tier, billing.FeatureAvailability{Articles: true}).PublishArticle {
		return connect.NewError(connect.CodePermissionDenied, errors.New("premium subscription required"))
	}
	return nil
}
