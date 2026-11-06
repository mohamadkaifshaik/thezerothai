package apiserver

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// TestAccountLifecycleFlagNameMatchesIdentity: the config spec's wire name is the one identity's
// handler checks and GetMe reports; a drift would silently leave the flag off for everyone.
func TestAccountLifecycleFlagNameMatchesIdentity(t *testing.T) {
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if cfg.FeatureAccountLifecycle.Name != identity.AccountLifecycleFlag {
		t.Fatalf("config flag name %q != identity.AccountLifecycleFlag %q", cfg.FeatureAccountLifecycle.Name, identity.AccountLifecycleFlag)
	}
}

// TestFeatureRegistry_IncludesBeacons: the registry Build wires reports `beacons` for an allowlisted caller and not for
// anyone else; a flag loaded by config but left out of the registry would be silently off for everyone.
func TestFeatureRegistry_IncludesBeacons(t *testing.T) {
	t.Setenv("FEATURE_BEACONS", "allowlist")
	t.Setenv("FEATURE_BEACONS_ALLOWLIST", "uid-a")
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	reg := featureRegistry(cfg)
	if !reg.Enabled("uid-a", "beacons") {
		t.Error("beacons should be on for uid-a")
	}
	if reg.Enabled("uid-z", "beacons") {
		t.Error("beacons should be off for uid-z")
	}
}
