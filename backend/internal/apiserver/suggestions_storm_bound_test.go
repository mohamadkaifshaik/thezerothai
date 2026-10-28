package apiserver

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// TestSuggestionsStormBound_DefaultsStayUnderTheReadBudget: ADR-0024 Amendment 2 (B1(b), D10 storm arithmetic). With the
// config defaults, one account that burns its whole daily call cap on cold friends-of-friends calls reads
// SUGGESTIONS_CALLS_PER_DAY x (2 + SUGGESTIONS_EDGE_LIMIT + SUGGESTIONS_HYDRATE_MAX) = 50 x 32 = 1,600 documents, under the
// per-uid daily read budget (2,000, ADR-0010 D5), so the call cap is the binding limit. It pins the literals, so a default
// that moved back to 30 edges (42 per call, 2,100 a day, over the budget) fails here.
func TestSuggestionsStormBound_DefaultsStayUnderTheReadBudget(t *testing.T) {
	for _, k := range []string{"SUGGESTIONS_EDGE_LIMIT", "SUGGESTIONS_HYDRATE_MAX", "SUGGESTIONS_CALLS_PER_DAY", "READ_BUDGET_PER_UID_PER_DAY"} {
		t.Setenv(k, "")
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	perCall := int64(2 + cfg.Suggestions.EdgeLimit + cfg.Suggestions.HydrateMax)
	calls := cfg.RateLimit.SuggestionsCallsPerDay
	budget := cfg.RateLimit.ReadBudgetPerUIDPerDay
	if cfg.Suggestions.EdgeLimit != 20 || perCall != 32 || calls != 50 {
		t.Fatalf("defaults: edge limit %d, cold cap %d, calls/day %d; want 20, 32, 50 (ADR-0024 Amendment 2)", cfg.Suggestions.EdgeLimit, perCall, calls)
	}
	if storm := calls * perCall; storm != 1600 || storm > budget {
		t.Fatalf("storm = %d x %d = %d reads/day, want 1600 and <= read budget %d", calls, perCall, storm, budget)
	}
}
