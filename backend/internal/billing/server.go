package billing

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"
	billingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1/billingv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type SubscriptionReader interface {
	LookupBinding(context.Context, string) (Binding, error)
}

type Server struct {
	billingv1connect.UnimplementedBillingServiceHandler
	identities       *IdentityService
	bindings         SubscriptionReader
	reconciler       *Reconciler
	now              func() time.Time
	purchasableTiers map[Tier]bool
}

// EnableSandboxPurchases is restricted to a sandbox identity service. The
// composition root additionally enforces ENV=local; it never enables real sales.
func (s *Server) EnableSandboxPurchases() {
	if s.identities != nil && s.identities.env == Sandbox && s.reconciler != nil {
		s.purchasableTiers = map[Tier]bool{TierPremium: true}
	}
}

// EnableStorePurchases is called only at startup after the composition
// root validates the dev rollout gate. Only reviewed, real-store products may
// advertise checkout; verification and restore remain available with sales off.
func (s *Server) EnableStorePurchases(products map[string]Product) {
	s.purchasableTiers = nil
	if s.identities == nil || !validEnvironment(s.identities.env) || s.bindings == nil || s.reconciler == nil {
		return
	}
	tiers := make(map[Tier]bool)
	for id, p := range products {
		if id == "" || (p.Store != "play_store" && p.Store != "app_store") {
			return
		}
		switch p.Entitlement {
		case PlusEntitlement:
			tiers[TierPlus] = true
		case PremiumEntitlement, ProEntitlement:
			tiers[TierPremium] = true
		default:
			return
		}
	}
	s.purchasableTiers = tiers
}

// NewServer keeps sales dark until every advertised benefit and rollout gate is
// implemented. Provider outages never become confirmed Free subscriptions.
func NewServer(identities *IdentityService, bindings SubscriptionReader, reconciler *Reconciler) *Server {
	return &Server{identities: identities, bindings: bindings, reconciler: reconciler, now: time.Now}
}

func caller(ctx context.Context) (string, error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || !validUID(uid) {
		return "", connect.NewError(connect.CodeUnauthenticated, errors.New("sign in required"))
	}
	return uid, nil
}

func (s *Server) EnsureBillingIdentity(ctx context.Context, req *connect.Request[billingv1.EnsureBillingIdentityRequest]) (*connect.Response[billingv1.EnsureBillingIdentityResponse], error) {
	uid, err := caller(ctx)
	if err != nil {
		return nil, err
	}
	if !idempotency.KeyFormatValid(req.Msg.IdempotencyKey) {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("invalid idempotency key"))
	}
	if s.identities == nil {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("billing unavailable"))
	}
	b, err := s.identities.Ensure(ctx, uid)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("billing identity unavailable"))
	}
	return connect.NewResponse(&billingv1.EnsureBillingIdentityResponse{AppUserId: b.CustomerID}), nil
}

func (s *Server) GetAvailablePlans(ctx context.Context, _ *connect.Request[billingv1.GetAvailablePlansRequest]) (*connect.Response[billingv1.GetAvailablePlansResponse], error) {
	if _, err := caller(ctx); err != nil {
		return nil, err
	}
	return connect.NewResponse(&billingv1.GetAvailablePlansResponse{Plans: []*billingv1.SubscriptionPlan{
		{Tier: billingv1.SubscriptionTier_SUBSCRIPTION_TIER_PLUS, EntitlementId: PlusEntitlement, Period: "monthly", Purchasable: s.purchasableTiers[TierPlus]},
		{Tier: billingv1.SubscriptionTier_SUBSCRIPTION_TIER_PREMIUM, EntitlementId: ProEntitlement, Period: "monthly", Purchasable: s.purchasableTiers[TierPremium]},
	}}), nil
}

func (s *Server) GetMySubscription(ctx context.Context, _ *connect.Request[billingv1.GetMySubscriptionRequest]) (*connect.Response[billingv1.GetMySubscriptionResponse], error) {
	uid, err := caller(ctx)
	if err != nil {
		return nil, err
	}
	out := &billingv1.GetMySubscriptionResponse{PolicyVersion: PolicyVersion, VerificationState: billingv1.VerificationState_VERIFICATION_STATE_UNAVAILABLE}
	if s.bindings == nil {
		return connect.NewResponse(out), nil
	}
	b, err := s.bindings.LookupBinding(ctx, uid)
	if errors.Is(err, ErrNotFound) {
		out.Tier = billingv1.SubscriptionTier_SUBSCRIPTION_TIER_FREE
		out.VerificationState = billingv1.VerificationState_VERIFICATION_STATE_NO_SUBSCRIPTION
		out.PurchasesAvailable = len(s.purchasableTiers) > 0
		return connect.NewResponse(out), nil
	}
	if err != nil || s.reconciler == nil {
		return connect.NewResponse(out), nil
	}
	if s.identities != nil && b.Environment != s.identities.env {
		return connect.NewResponse(out), nil
	}
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	snapshot, err := s.reconciler.Refresh(ctx, uid)
	if err != nil {
		return connect.NewResponse(out), nil
	}
	tier, err := EffectiveTier(b, snapshot, s.now())
	if err != nil {
		return connect.NewResponse(out), nil
	}
	out.VerificationState = billingv1.VerificationState_VERIFICATION_STATE_VERIFIED
	out.PurchasesAvailable = len(s.purchasableTiers) > 0 && tier == TierFree
	out.VerifiedAt = timestamppb.New(snapshot.VerifiedAt)
	end := snapshot.VerifiedAt.Add(MaxVerificationAge)
	out.Tier = billingv1.SubscriptionTier_SUBSCRIPTION_TIER_FREE
	if tier == TierPlus {
		out.Tier = billingv1.SubscriptionTier_SUBSCRIPTION_TIER_PLUS
	}
	if tier == TierPremium {
		out.Tier = billingv1.SubscriptionTier_SUBSCRIPTION_TIER_PREMIUM
	}
	// Only grants supporting the effective tier constrain its validity interval.
	for _, g := range snapshot.Grants {
		if (tier == TierPlus && g.Entitlement == PlusEntitlement) || (tier == TierPremium && (g.Entitlement == PremiumEntitlement || g.Entitlement == ProEntitlement)) {
			if g.AccessUntil.After(s.now()) && g.AccessUntil.Before(end) {
				end = g.AccessUntil
			}
		}
	}
	out.AccessUntil = timestamppb.New(end)
	return connect.NewResponse(out), nil
}
