package billing

import (
	"errors"
	"testing"
	"time"
)

func testBinding() Binding {
	return Binding{
		UID: "account-a", CustomerID: "dzb_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		Environment: Sandbox, CreatedAt: time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC),
	}
}

func TestEffectiveTier(t *testing.T) {
	b := testBinding()
	now := b.CreatedAt.Add(time.Hour)
	fresh := func() Snapshot {
		return Snapshot{UID: b.UID, CustomerID: b.CustomerID, Environment: b.Environment, VerifiedAt: now}
	}
	tests := []struct {
		name string
		edit func(*Snapshot)
		want Tier
		err  error
	}{
		{name: "verified empty customer is free", want: TierFree},
		{name: "plus", edit: func(s *Snapshot) { s.Grants = []Grant{{PlusEntitlement, now.Add(time.Hour)}} }, want: TierPlus},
		{name: "premium only", edit: func(s *Snapshot) { s.Grants = []Grant{{PremiumEntitlement, now.Add(time.Hour)}} }, want: TierPremium},
		{name: "dzeroth pro maps to premium", edit: func(s *Snapshot) { s.Grants = []Grant{{ProEntitlement, now.Add(time.Hour)}} }, want: TierPremium},
		{name: "highest active tier", edit: func(s *Snapshot) {
			s.Grants = []Grant{{PlusEntitlement, now.Add(time.Hour)}, {PremiumEntitlement, now.Add(time.Hour)}}
		}, want: TierPremium},
		{name: "premium expired plus remains", edit: func(s *Snapshot) {
			s.Grants = []Grant{{PremiumEntitlement, now}, {PlusEntitlement, now.Add(time.Hour)}}
		}, want: TierPlus},
		{name: "expiry boundary exclusive", edit: func(s *Snapshot) { s.Grants = []Grant{{PlusEntitlement, now}} }, want: TierFree},
		{name: "unknown entitlement", edit: func(s *Snapshot) { s.Grants = []Grant{{"premium", now.Add(time.Hour)}} }, want: TierFree},
		{name: "missing expiry", edit: func(s *Snapshot) { s.Grants = []Grant{{PremiumEntitlement, time.Time{}}} }, want: TierFree},
		{name: "missing verification", edit: func(s *Snapshot) { s.VerifiedAt = time.Time{} }, want: TierFree, err: ErrUnavailable},
		{name: "future verification", edit: func(s *Snapshot) { s.VerifiedAt = now.Add(time.Nanosecond) }, want: TierFree, err: ErrUnavailable},
		{name: "stale boundary", edit: func(s *Snapshot) { s.VerifiedAt = now.Add(-MaxVerificationAge) }, want: TierFree, err: ErrUnavailable},
		{name: "just fresh", edit: func(s *Snapshot) {
			s.VerifiedAt = now.Add(-MaxVerificationAge + time.Nanosecond)
			s.Grants = []Grant{{PremiumEntitlement, now.Add(time.Hour)}}
		}, want: TierPremium},
		{name: "wrong owner", edit: func(s *Snapshot) { s.UID = "account-b" }, want: TierFree, err: ErrOwnership},
		{name: "wrong customer", edit: func(s *Snapshot) { s.CustomerID = "another-customer" }, want: TierFree, err: ErrOwnership},
		{name: "production cannot use sandbox", edit: func(s *Snapshot) { s.Environment = Production }, want: TierFree, err: ErrOwnership},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := fresh()
			if tt.edit != nil {
				tt.edit(&s)
			}
			got, err := EffectiveTier(b, s, now)
			if got != tt.want || !errors.Is(err, tt.err) {
				t.Fatalf("tier=%q err=%v; want %q, %v", got, err, tt.want, tt.err)
			}
		})
	}
	if _, err := EffectiveTier(Binding{}, fresh(), now); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("invalid binding: %v", err)
	}
	if _, err := EffectiveTier(b, fresh(), time.Time{}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("missing clock: %v", err)
	}
}

func TestCapabilitiesKeepUnshippedFeaturesDark(t *testing.T) {
	for _, tier := range []Tier{TierFree, TierPlus, TierPremium, "unknown", ""} {
		got := CapabilitiesFor(tier, FeatureAvailability{})
		if got.MaxPostRunes != 280 || got.PublishArticle || got.PolicyVersion != PolicyVersion {
			t.Fatalf("dark policy for %q: %+v", tier, got)
		}
	}
}

func TestCapabilitiesInheritanceAndFreeBaseline(t *testing.T) {
	for _, tt := range []struct {
		tier    Tier
		runes   int
		article bool
	}{
		{TierFree, 280, false}, {TierPlus, 3000, false}, {TierPremium, 15000, true}, {"unrecognized", 280, false},
	} {
		got := CapabilitiesFor(tt.tier, FeatureAvailability{LongPosts: true, Articles: true})
		if got.MaxPostRunes != tt.runes || got.PublishArticle != tt.article {
			t.Fatalf("policy for %q: %+v", tt.tier, got)
		}
	}
	if got := CapabilitiesFor(TierPremium, FeatureAvailability{Articles: true}); got.MaxPostRunes != 280 || !got.PublishArticle {
		t.Fatalf("availability must be independent per feature: %+v", got)
	}
}

func TestPlannedCatalogIsNotForSale(t *testing.T) {
	plans := PlannedCatalog()
	if len(plans) != 2 || plans[0].Tier != TierPlus || plans[0].PriceMinor != 23500 || plans[1].Tier != TierPremium || plans[1].PriceMinor != 85000 {
		t.Fatal("founder-approved India catalog changed")
	}
	for _, p := range plans {
		if p.Purchasable || p.Currency != "INR" || p.Period != "monthly" {
			t.Fatal("planned catalog must not enable a sale")
		}
	}
	plans[0].PriceMinor = 1
	if PlannedCatalog()[0].PriceMinor != 23500 {
		t.Fatal("caller mutated the shared catalog")
	}
}
