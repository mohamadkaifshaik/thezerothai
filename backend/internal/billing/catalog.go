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
// Storefronts supply the localized transaction price.
func PlannedCatalog() []PlannedPlan {
	return []PlannedPlan{
		{Tier: TierPlus, Entitlement: PlusEntitlement, Currency: "INR", PriceMinor: 9900, Period: "monthly"},
	}
}
