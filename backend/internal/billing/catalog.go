package billing

// PlannedPlan is informational. Store products and localized checkout prices
// must be loaded from the provider before sales can be enabled.
type PlannedPlan struct {
	Tier        Tier
	Entitlement string
	Currency    string
	PriceMinor  int64
	Period      string
	Purchasable bool
}

// PlannedCatalog returns a fresh value so callers cannot mutate shared policy.
// Both founder-approved India prices are retained; neither plan is for sale.
func PlannedCatalog() []PlannedPlan {
	return []PlannedPlan{
		{Tier: TierPlus, Entitlement: PlusEntitlement, Currency: "INR", PriceMinor: 23500, Period: "monthly"},
		{Tier: TierPremium, Entitlement: PremiumEntitlement, Currency: "INR", PriceMinor: 85000, Period: "monthly"},
	}
}
