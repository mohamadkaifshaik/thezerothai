package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_RemovedIDsFlag: FEATURE_REMOVED_IDS defaults to off and is overridable; the read budget's per-call
// worst case includes the removal log (269 + 100).
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
	if ReadBudgetMaxCallReads != 269+RemovalLogMaxReads || RemovalLogMaxReads != 100 {
		t.Errorf("ReadBudgetMaxCallReads = %d, want 269 + 100", ReadBudgetMaxCallReads)
	}
}
