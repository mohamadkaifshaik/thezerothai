package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_RemovedIDsFlag: FEATURE_REMOVED_IDS defaults to off and is overridable; the read budget's per-call
// worst case is 269 (the removal log refresh is detached, RID-4).
func TestLoad_RemovedIDsFlag(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureRemovedIDs.Name != "removed_ids" || cfg.FeatureRemovedIDs.Mode != flags.Off {
		t.Errorf("FeatureRemovedIDs = %+v, want name removed_ids, mode off", cfg.FeatureRemovedIDs)
	}
	clearEnv(t)
	t.Setenv("FEATURE_REMOVED_IDS", "on")
	if cfg, err = Load(); err != nil || cfg.FeatureRemovedIDs.Mode != flags.On {
		t.Fatalf("override: %+v err=%v", cfg.FeatureRemovedIDs, err)
	}
	clearEnv(t)
	t.Setenv("FEATURE_REMOVED_IDS", "bogus")
	if _, err = Load(); err == nil {
		t.Error("an invalid FEATURE_REMOVED_IDS must fail startup")
	}
	// RID-4: the shared refresh is detached, so the per-call figure is the bare home worst case.
	if ReadBudgetMaxCallReads != 269 || RemovalLogMaxReads != 100 || RemovalWindowMaxReads != 107 {
		t.Errorf("ReadBudgetMaxCallReads = %d, want 269 (shared refresh %d is detached; window %d only for <= 180 authors)",
			ReadBudgetMaxCallReads, RemovalLogMaxReads, RemovalWindowMaxReads)
	}
	// The window query only runs for feeds of at most 180 authors: such a call stays under the global ceiling.
	const windowFeedHomeReads = 2 + (180+1+29)/30 + 2*50 // interceptor + graph + chunks + 2 x page
	if windowFeedHomeReads+RemovalWindowMaxReads > ReadBudgetMaxCallReads {
		t.Errorf("home call with a window query = %d reads, above ReadBudgetMaxCallReads %d", windowFeedHomeReads+RemovalWindowMaxReads, ReadBudgetMaxCallReads)
	}
}
