package billing

import "time"

// EffectiveTier fails closed for mismatched identities/environments and stale
// verification. Expiry is exclusive. Premium inherits Plus even when only its
// own entitlement is present. Unknown entitlement names grant nothing.
func EffectiveTier(binding Binding, snapshot Snapshot, now time.Time) (Tier, error) {
	if !validBinding(binding) || now.IsZero() {
		return TierFree, ErrInvalidInput
	}
	if snapshot.UID != binding.UID || snapshot.CustomerID != binding.CustomerID || snapshot.Environment != binding.Environment {
		return TierFree, ErrOwnership
	}
	if snapshot.VerifiedAt.IsZero() || snapshot.VerifiedAt.After(now) || !now.Before(snapshot.VerifiedAt.Add(MaxVerificationAge)) {
		return TierFree, ErrUnavailable
	}
	tier := TierFree
	for _, grant := range snapshot.Grants {
		if !now.Before(grant.AccessUntil) {
			continue
		}
		switch grant.Entitlement {
		case PremiumEntitlement, ProEntitlement:
			return TierPremium, nil
		case PlusEntitlement:
			tier = TierPlus
		}
	}
	return tier, nil
}

// FeatureAvailability describes shipped capabilities, independently of payment.
// Zero values are deliberately dark. Do not mark a feature available before its
// authoritative mutation paths, operational ceilings and tests support it.
type FeatureAvailability struct {
	LongPosts bool
	Articles  bool
}

type Capabilities struct {
	Tier           Tier
	PolicyVersion  int
	MaxPostRunes   int
	PublishArticle bool
}

// CapabilitiesFor is a pure policy calculation, not a substitute for verified
// access, account/audience checks or concurrent quota enforcement. Existing Free
// scheduling and Plan quotas are intentionally unchanged by this foundation.
func CapabilitiesFor(tier Tier, available FeatureAvailability) Capabilities {
	out := Capabilities{Tier: TierFree, PolicyVersion: PolicyVersion, MaxPostRunes: 280}
	if tier != TierPlus && tier != TierPremium {
		return out
	}
	out.Tier = tier
	if available.LongPosts {
		out.MaxPostRunes = 3000
		if tier == TierPremium {
			out.MaxPostRunes = 15000
		}
	}
	out.PublishArticle = available.Articles && tier == TierPremium
	return out
}
