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

// TestFeatureRegistry_IncludesCommunityMemberSearch (F36): every mode of FEATURE_COMMUNITY_MEMBER_SEARCH reaches the
// registry Build wires, and unset is off for everyone.
func TestFeatureRegistry_IncludesCommunityMemberSearch(t *testing.T) {
	for _, tc := range []struct {
		name        string
		env         map[string]string
		inA, inZ    bool
		globallyOff bool
	}{
		{"unset is off", nil, false, false, true},
		{"off", map[string]string{"FEATURE_COMMUNITY_MEMBER_SEARCH": "off"}, false, false, true},
		{"allowlist", map[string]string{"FEATURE_COMMUNITY_MEMBER_SEARCH": "allowlist", "FEATURE_COMMUNITY_MEMBER_SEARCH_ALLOWLIST": "uid-a"}, true, false, false},
		{"percent 100", map[string]string{"FEATURE_COMMUNITY_MEMBER_SEARCH": "percent", "FEATURE_COMMUNITY_MEMBER_SEARCH_PERCENT": "100"}, true, true, false},
		{"on", map[string]string{"FEATURE_COMMUNITY_MEMBER_SEARCH": "on"}, true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{"FEATURE_COMMUNITY_MEMBER_SEARCH", "FEATURE_COMMUNITY_MEMBER_SEARCH_ALLOWLIST", "FEATURE_COMMUNITY_MEMBER_SEARCH_PERCENT"} {
				t.Setenv(k, tc.env[k])
			}
			cfg, err := config.Load()
			if err != nil {
				t.Fatalf("config.Load: %v", err)
			}
			reg := featureRegistry(cfg)
			if got := reg.Enabled("uid-a", "community_member_search"); got != tc.inA {
				t.Errorf("uid-a enabled = %v, want %v", got, tc.inA)
			}
			if got := reg.Enabled("uid-z", "community_member_search"); got != tc.inZ {
				t.Errorf("uid-z enabled = %v, want %v", got, tc.inZ)
			}
			if got := reg.GloballyOff("community_member_search"); got != tc.globallyOff {
				t.Errorf("globally off = %v, want %v", got, tc.globallyOff)
			}
		})
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

// TestFeatureRegistry_IncludesUITablet: every mode of FEATURE_UI_TABLET (client-only, tablet shell) reaches the registry
// Build wires, so GetMe.enabled_features can report `ui_tablet`; unset is off for everyone.
func TestFeatureRegistry_IncludesUITablet(t *testing.T) {
	for _, tc := range []struct {
		name        string
		env         map[string]string
		inA, inZ    bool
		globallyOff bool
	}{
		{"unset is off", nil, false, false, true},
		{"off", map[string]string{"FEATURE_UI_TABLET": "off"}, false, false, true},
		{"allowlist", map[string]string{"FEATURE_UI_TABLET": "allowlist", "FEATURE_UI_TABLET_ALLOWLIST": "uid-a"}, true, false, false},
		{"percent 100", map[string]string{"FEATURE_UI_TABLET": "percent", "FEATURE_UI_TABLET_PERCENT": "100"}, true, true, false},
		{"on", map[string]string{"FEATURE_UI_TABLET": "on"}, true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{"FEATURE_UI_TABLET", "FEATURE_UI_TABLET_ALLOWLIST", "FEATURE_UI_TABLET_PERCENT"} {
				t.Setenv(k, tc.env[k])
			}
			cfg, err := config.Load()
			if err != nil {
				t.Fatalf("config.Load: %v", err)
			}
			reg := featureRegistry(cfg)
			if got := reg.Enabled("uid-a", "ui_tablet"); got != tc.inA {
				t.Errorf("uid-a enabled = %v, want %v", got, tc.inA)
			}
			if got := reg.Enabled("uid-z", "ui_tablet"); got != tc.inZ {
				t.Errorf("uid-z enabled = %v, want %v", got, tc.inZ)
			}
			if got := reg.GloballyOff("ui_tablet"); got != tc.globallyOff {
				t.Errorf("globally off = %v, want %v", got, tc.globallyOff)
			}
		})
	}
}

// TestFeatureRegistry_IncludesShareFlags (shares design §4.6): every mode of FEATURE_DM_POST_SHARE and
// FEATURE_SHARE_COUNT reaches the registry Build wires, and unset is off for everyone.
func TestFeatureRegistry_IncludesShareFlags(t *testing.T) {
	for _, flag := range []struct{ env, wire string }{
		{"FEATURE_DM_POST_SHARE", "dm_post_share"},
		{"FEATURE_SHARE_COUNT", "share_count"},
	} {
		for _, tc := range []struct {
			name        string
			mode, list  string
			percent     string
			inA, inZ    bool
			globallyOff bool
		}{
			{"unset is off", "", "", "", false, false, true},
			{"off", "off", "", "", false, false, true},
			{"allowlist", "allowlist", "uid-a", "", true, false, false},
			{"percent 100", "percent", "", "100", true, true, false},
			{"on", "on", "", "", true, true, false},
		} {
			t.Run(flag.wire+"/"+tc.name, func(t *testing.T) {
				t.Setenv(flag.env, tc.mode)
				t.Setenv(flag.env+"_ALLOWLIST", tc.list)
				t.Setenv(flag.env+"_PERCENT", tc.percent)
				cfg, err := config.Load()
				if err != nil {
					t.Fatalf("config.Load: %v", err)
				}
				reg := featureRegistry(cfg)
				if got := reg.Enabled("uid-a", flag.wire); got != tc.inA {
					t.Errorf("uid-a enabled = %v, want %v", got, tc.inA)
				}
				if got := reg.Enabled("uid-z", flag.wire); got != tc.inZ {
					t.Errorf("uid-z enabled = %v, want %v", got, tc.inZ)
				}
				if got := reg.GloballyOff(flag.wire); got != tc.globallyOff {
					t.Errorf("globally off = %v, want %v", got, tc.globallyOff)
				}
			})
		}
	}
}
