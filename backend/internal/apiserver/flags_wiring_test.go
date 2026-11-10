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

// TestFeatureRegistry_IncludesChatSharedPlans: the registry reports `chat_shared_plans` for an allowlisted caller only,
// and it is off when FEATURE_CHAT_SHARED_PLANS is unset (default off); a spec left out of featureRegistry would be silently
// off for everyone.
func TestFeatureRegistry_IncludesChatSharedPlans(t *testing.T) {
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if reg := featureRegistry(cfg); reg.Enabled("uid-a", "chat_shared_plans") {
		t.Error("chat_shared_plans must default off")
	}
	t.Setenv("FEATURE_CHAT_SHARED_PLANS", "allowlist")
	t.Setenv("FEATURE_CHAT_SHARED_PLANS_ALLOWLIST", "uid-a")
	cfg, err = config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	reg := featureRegistry(cfg)
	if !reg.Enabled("uid-a", "chat_shared_plans") || reg.Enabled("uid-z", "chat_shared_plans") {
		t.Error("chat_shared_plans should be on for uid-a only")
	}
}
