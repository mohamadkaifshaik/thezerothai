package apiserver

import (
	"log/slog"
	"slices"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
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

// TestFeatureRegistry_IncludesShareFlags (shares design §4.6, plus the 2026-11-14 smaller-features flags): every mode
// of FEATURE_DM_POST_SHARE, FEATURE_SHARE_COUNT and the smaller-features flags reaches the registry Build wires, and unset is off for everyone.
func TestFeatureRegistry_IncludesShareFlags(t *testing.T) {
	for _, flag := range []struct{ env, wire string }{
		{"FEATURE_DM_POST_SHARE", "dm_post_share"},
		{"FEATURE_DM_SHARE_CHECK", "dm_share_check"},
		{"FEATURE_SHARE_COUNT", "share_count"},
		{"FEATURE_HANDLE_SUGGESTIONS", "handle_suggestions"},
		{"FEATURE_LIST_FOLLOWS", "list_follows"},
		{"FEATURE_LIST_SUGGESTIONS", "list_suggestions"},
		{"FEATURE_BOOKMARK_HISTORY", "bookmark_history"},
		{"FEATURE_ARTICLE_IMAGES", "article_images"},
		{"FEATURE_EXPORT_ZIP", "export_zip"},
		{"FEATURE_MESSAGE_SEARCH", "message_search"},
		{"FEATURE_SEARCH_LISTS", "search_lists"},
		{"FEATURE_SEARCH_FILTERS", "search_filters"},
		{"FEATURE_LOCATION", "location"},
		{"FEATURE_DM_SUGGESTIONS", "dm_suggestions"},
		{"FEATURE_POST_VIEWS", "post_views"},
		{"FEATURE_CREATOR_INSIGHTS", "creator_insights"},
		{"FEATURE_PUBLIC_IDS", "public_ids"},
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

// TestFeatureRegistry_IncludesE2EEDM: the registry built from config reports `e2ee_dm` in EnabledFeatures for an
// allowlisted uid only, and not at all when unset (a spec left out of featureRegistry would be silently off). Messaging is
// on here: the effective e2ee_dm also needs it (TestFeatureRegistry_E2EECoupling).
func TestFeatureRegistry_IncludesE2EEDM(t *testing.T) {
	t.Setenv("FEATURE_MESSAGING", "on")
	t.Setenv("FEATURE_E2EE_DM", "")
	t.Setenv("FEATURE_E2EE_DM_ALLOWLIST", "")
	t.Setenv("FEATURE_E2EE_DM_PERCENT", "")
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if slices.Contains(featureRegistry(cfg).EnabledFeatures("uid-a"), "e2ee_dm") {
		t.Error("e2ee_dm must default off")
	}
	t.Setenv("FEATURE_E2EE_DM", "allowlist")
	t.Setenv("FEATURE_E2EE_DM_ALLOWLIST", "uid-a")
	cfg, err = config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	reg := featureRegistry(cfg)
	if !slices.Contains(reg.EnabledFeatures("uid-a"), "e2ee_dm") {
		t.Error("e2ee_dm should be reported for uid-a")
	}
	if slices.Contains(reg.EnabledFeatures("uid-z"), "e2ee_dm") {
		t.Error("e2ee_dm must not be reported for uid-z")
	}
}

// TestFeatureRegistry_E2EECoupling (P6 §1.3, as ruled in the 6-1 security review): the effective e2ee_dm is e2ee_dm &&
// messaging and the effective e2ee_required is e2ee_required && messaging, NOT gated by e2ee_dm, for Enabled and GetMe's
// EnabledFeatures alike: a user with required effective and e2ee_dm off (the fail-closed state) gets e2ee_required in
// GetMe without e2ee_dm. GloballyOff (the kill switch K1 and RemoveKeyDevice read) keeps reading the raw flag.
// e2ee_required is unset (off) by default.
func TestFeatureRegistry_E2EECoupling(t *testing.T) {
	const in, out = "uid-a", "uid-z"
	type want struct{ dm, required bool }
	for _, tc := range []struct {
		name                          string
		messaging, e2eeDM, required   string // mode; "allowlist" lists uid-a only
		forIn, forOut                 want
		dmGloballyOff, reqGloballyOff bool
	}{
		{"all unset", "", "", "", want{}, want{}, true, true},
		{"e2ee_dm on, messaging off", "off", "on", "", want{}, want{}, false, true},
		{"e2ee_dm on, messaging allowlist", "allowlist", "on", "", want{dm: true}, want{}, false, true},
		{"e2ee_dm and messaging on", "on", "on", "", want{dm: true}, want{dm: true}, false, true},
		// Fail closed: required stays effective with e2ee_dm off (nothing can be exchanged; the client sees it in GetMe).
		{"required on, e2ee_dm off", "on", "off", "on", want{required: true}, want{required: true}, true, false},
		{"required on, e2ee_dm unset", "on", "", "on", want{required: true}, want{required: true}, true, false},
		{"required on, e2ee_dm allowlist", "on", "allowlist", "on", want{dm: true, required: true}, want{required: true}, false, false},
		{"required on, e2ee_dm off, messaging allowlist", "allowlist", "off", "on", want{required: true}, want{}, true, false},
		// Messaging off: required is not effective (messaging refuses first anyway).
		{"required on, messaging off", "off", "on", "on", want{}, want{}, false, false},
		{"required on, messaging allowlist", "allowlist", "on", "on", want{dm: true, required: true}, want{}, false, false},
		{"required allowlist, all else on", "on", "on", "allowlist", want{dm: true, required: true}, want{dm: true}, false, false},
		{"everything on", "on", "on", "on", want{dm: true, required: true}, want{dm: true, required: true}, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for env, mode := range map[string]string{"FEATURE_MESSAGING": tc.messaging, "FEATURE_E2EE_DM": tc.e2eeDM, "FEATURE_E2EE_REQUIRED": tc.required} {
				t.Setenv(env, mode)
				t.Setenv(env+"_PERCENT", "")
				list := ""
				if mode == "allowlist" {
					list = in
				}
				t.Setenv(env+"_ALLOWLIST", list)
			}
			cfg, err := config.Load()
			if err != nil {
				t.Fatalf("config.Load: %v", err)
			}
			if cfg.FeatureE2EERequired.Name != messaging.E2EERequiredFlag {
				t.Fatalf("config wire name %q != messaging.E2EERequiredFlag %q", cfg.FeatureE2EERequired.Name, messaging.E2EERequiredFlag)
			}
			reg := featureRegistry(cfg)
			for uid, w := range map[string]want{in: tc.forIn, out: tc.forOut} {
				if got := reg.Enabled(uid, keys.FlagName); got != w.dm {
					t.Errorf("%s: e2ee_dm = %v, want %v", uid, got, w.dm)
				}
				if got := reg.Enabled(uid, messaging.E2EERequiredFlag); got != w.required {
					t.Errorf("%s: e2ee_required = %v, want %v", uid, got, w.required)
				}
				feats := reg.EnabledFeatures(uid)
				if got := slices.Contains(feats, keys.FlagName); got != w.dm {
					t.Errorf("%s: enabled_features has e2ee_dm = %v, want %v (%v)", uid, got, w.dm, feats)
				}
				if got := slices.Contains(feats, messaging.E2EERequiredFlag); got != w.required {
					t.Errorf("%s: enabled_features has e2ee_required = %v, want %v (%v)", uid, got, w.required, feats)
				}
			}
			if got := reg.GloballyOff(keys.FlagName); got != tc.dmGloballyOff {
				t.Errorf("GloballyOff(e2ee_dm) = %v, want %v (the raw flag)", got, tc.dmGloballyOff)
			}
			if got := reg.GloballyOff(messaging.E2EERequiredFlag); got != tc.reqGloballyOff {
				t.Errorf("GloballyOff(e2ee_required) = %v, want %v (the raw flag)", got, tc.reqGloballyOff)
			}
		})
	}
}

// leveled is one expected startup line: the warning and the level Build logs it at.
type leveled struct {
	w     flags.CouplingWarning
	level slog.Level
}

func checkCoupling(t *testing.T, reg *flags.Registry, want []leveled) {
	t.Helper()
	got := featureCouplingWarnings(reg)
	if len(got) != len(want) {
		t.Fatalf("warnings = %+v\nwant %+v", got, want)
	}
	for i := range got {
		if got[i] != want[i].w {
			t.Errorf("warning %d = %+v\nwant %+v", i, got[i], want[i].w)
		}
		if lv := couplingLevel(got[i]); lv != want[i].level {
			t.Errorf("warning %d (%s) level = %v, want %v", i, got[i].Reason, lv, want[i].level)
		}
	}
}

// TestFeatureCouplingWarnings: the startup feature_flag_coupling lines Build logs (modes and counts only, never uids):
// one per coupled flag that is not off while its parent is off or narrower (e2ee_dm and e2ee_required under messaging:
// INFO, the planned ramp), one when e2ee_required is not off while e2ee_dm is off or narrower (WARN, the fail-closed
// state), and one when messaging reaches users e2ee_required does not cover (WARN: readable DMs are stored for them).
func TestFeatureCouplingWarnings(t *testing.T) {
	const info, warn = slog.LevelInfo, slog.LevelWarn
	spec := func(name string, m flags.Mode) flags.Spec {
		return flags.Spec{Name: name, Mode: m, Allowlist: map[string]struct{}{}}
	}
	narrower := func(flag, parent string, fm, pm flags.Mode, reason string) flags.CouplingWarning {
		return flags.CouplingWarning{Flag: flag, Parent: parent, FlagMode: fm, ParentMode: pm, Reason: reason}
	}
	const msg, dm, req = messaging.FlagName, keys.FlagName, messaging.E2EERequiredFlag
	for _, tc := range []struct {
		name            string
		msgM, dmM, reqM flags.Mode
		want            []leveled
	}{
		{"all off", flags.Off, flags.Off, flags.Off, nil},
		{"all on", flags.On, flags.On, flags.On, nil},
		{"pilot allowlists (empty)", flags.Allowlist, flags.Allowlist, flags.Allowlist, nil},
		{"the planned ramp: messaging percent, e2ee_dm and required on", flags.Percent, flags.On, flags.On, []leveled{
			{narrower(dm, msg, flags.On, flags.Percent, flags.ReasonParentNarrower), info},
			{narrower(req, msg, flags.On, flags.Percent, flags.ReasonParentNarrower), info},
		}},
		{"e2ee_dm on while messaging ramps, required off", flags.Percent, flags.On, flags.Off, []leveled{
			{narrower(dm, msg, flags.On, flags.Percent, flags.ReasonParentNarrower), info},
			{narrower(msg, req, flags.Percent, flags.Off, reasonMessagingWithoutRequired), warn},
		}},
		{"required allowlist with messaging off", flags.Off, flags.Off, flags.Allowlist, []leveled{
			{narrower(req, msg, flags.Allowlist, flags.Off, flags.ReasonParentNarrower), info},
			{narrower(req, dm, flags.Allowlist, flags.Off, reasonRequiredFailsClosed), warn},
		}},
		{"e2ee_dm killed under required", flags.On, flags.Off, flags.On, []leveled{
			{narrower(req, dm, flags.On, flags.Off, reasonRequiredFailsClosed), warn},
		}},
		{"required on, e2ee_dm allowlist", flags.On, flags.Allowlist, flags.On, []leveled{
			{narrower(req, dm, flags.On, flags.Allowlist, reasonRequiredFailsClosed), warn},
		}},
		// messaging_without_required: not off over off; on over allowlist or percent; percent over allowlist or off.
		{"messaging allowlist, required off (stage D1)", flags.Allowlist, flags.Allowlist, flags.Off, []leveled{
			{narrower(msg, req, flags.Allowlist, flags.Off, reasonMessagingWithoutRequired), warn},
		}},
		{"messaging on, required allowlist", flags.On, flags.On, flags.Allowlist, []leveled{
			{narrower(msg, req, flags.On, flags.Allowlist, reasonMessagingWithoutRequired), warn},
		}},
		{"messaging on, required percent", flags.On, flags.On, flags.Percent, []leveled{
			{narrower(msg, req, flags.On, flags.Percent, reasonMessagingWithoutRequired), warn},
		}},
		{"messaging percent, required allowlist", flags.Percent, flags.On, flags.Allowlist, []leveled{
			{narrower(dm, msg, flags.On, flags.Percent, flags.ReasonParentNarrower), info},
			{narrower(msg, req, flags.Percent, flags.Allowlist, reasonMessagingWithoutRequired), warn},
		}},
		{"messaging percent, required percent", flags.Percent, flags.Percent, flags.Percent, nil},
		{"messaging on, required off", flags.On, flags.On, flags.Off, []leveled{
			{narrower(msg, req, flags.On, flags.Off, reasonMessagingWithoutRequired), warn},
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			checkCoupling(t, coupleE2EE(flags.NewRegistry(spec(msg, tc.msgM), spec(dm, tc.dmM), spec(req, tc.reqM))), tc.want)
		})
	}
}

// TestFeatureCouplingWarnings_AllowlistCounts: two allowlists are silent by mode (the dev and first prod stages), so each
// line counts the "should be covered" side's entries the other flag's own spec does not enable, and any count above 0 is
// WARN, a messaging parent included. The count is the only trace of the lists: no uid in any field.
func TestFeatureCouplingWarnings_AllowlistCounts(t *testing.T) {
	const info, warn = slog.LevelInfo, slog.LevelWarn
	const msg, dm, req = messaging.FlagName, keys.FlagName, messaging.E2EERequiredFlag
	list := func(name string, uids ...string) flags.Spec {
		s := flags.Spec{Name: name, Mode: flags.Allowlist, Allowlist: map[string]struct{}{}}
		for _, u := range uids {
			s.Allowlist[u] = struct{}{}
		}
		return s
	}
	al := flags.Allowlist
	for _, tc := range []struct {
		name    string
		m, d, r flags.Spec
		want    []leveled
	}{
		{"same pilot uids everywhere", list(msg, "uid-a", "uid-b"), list(dm, "uid-a", "uid-b"), list(req, "uid-b", "uid-a"), nil},
		{"messaging reaches a uid required does not", list(msg, "uid-a", "uid-b", "uid-c"), list(dm, "uid-a", "uid-b", "uid-c"), list(req, "uid-a"), []leveled{
			{flags.CouplingWarning{Flag: msg, Parent: req, FlagMode: al, ParentMode: al, Reason: reasonMessagingWithoutRequired, Uncovered: 2}, warn},
		}},
		{"required reaches a uid e2ee_dm does not", list(msg, "uid-a", "uid-b"), list(dm, "uid-a"), list(req, "uid-a", "uid-b"), []leveled{
			{flags.CouplingWarning{Flag: req, Parent: dm, FlagMode: al, ParentMode: al, Reason: reasonRequiredFailsClosed, Uncovered: 1}, warn},
		}},
		{"e2ee_dm lists a uid messaging does not", list(msg, "uid-a"), list(dm, "uid-a", "uid-x"), list(req, "uid-a"), []leveled{
			{flags.CouplingWarning{Flag: dm, Parent: msg, FlagMode: al, ParentMode: al, Reason: flags.ReasonParentNarrower, Uncovered: 1}, warn},
		}},
		{"percent e2ee_dm under a messaging allowlist", list(msg, "uid-a"), flags.Spec{Name: dm, Mode: flags.Percent, Allowlist: map[string]struct{}{}}, list(req, "uid-a"), []leveled{
			{flags.CouplingWarning{Flag: dm, Parent: msg, FlagMode: flags.Percent, ParentMode: al, Reason: flags.ReasonParentNarrower}, info},
			// e2ee_dm at percent 0 with an empty allowlist enables nobody: required's one uid is uncovered.
			{flags.CouplingWarning{Flag: req, Parent: dm, FlagMode: al, ParentMode: flags.Percent, Reason: reasonRequiredFailsClosed, Uncovered: 1}, warn},
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := coupleE2EE(flags.NewRegistry(tc.m, tc.d, tc.r))
			checkCoupling(t, reg, tc.want)
			for _, w := range featureCouplingWarnings(reg) {
				for _, field := range []string{w.Flag, w.Parent, string(w.FlagMode), string(w.ParentMode), w.Reason} {
					if strings.Contains(field, "uid-") {
						t.Errorf("warning %+v carries a uid", w)
					}
				}
			}
		})
	}
}

// couplingLevel: WARN for every finding except a parent_narrower under messaging with nothing uncovered (the planned
// ramp), which is INFO; an unknown parent and a cycle are WARN.
func TestCouplingLevel(t *testing.T) {
	for _, tc := range []struct {
		w    flags.CouplingWarning
		want slog.Level
	}{
		{flags.CouplingWarning{Flag: keys.FlagName, Parent: messaging.FlagName, Reason: flags.ReasonParentNarrower}, slog.LevelInfo},
		{flags.CouplingWarning{Flag: keys.FlagName, Parent: messaging.FlagName, Reason: flags.ReasonParentNarrower, Uncovered: 1}, slog.LevelWarn},
		{flags.CouplingWarning{Flag: "x", Parent: "y", Reason: flags.ReasonParentNarrower}, slog.LevelWarn},
		{flags.CouplingWarning{Flag: "x", Parent: messaging.FlagName, Reason: flags.ReasonUnknownParent}, slog.LevelWarn},
		{flags.CouplingWarning{Flag: "x", Parent: messaging.FlagName, Reason: flags.ReasonCycle}, slog.LevelWarn},
		{flags.CouplingWarning{Reason: reasonRequiredFailsClosed}, slog.LevelWarn},
		{flags.CouplingWarning{Reason: reasonMessagingWithoutRequired}, slog.LevelWarn},
		{flags.CouplingWarning{Flag: messaging.E2EEClaimFlag, Parent: messaging.E2EERequiredFlag, Reason: flags.ReasonParentNarrower}, slog.LevelWarn},
		{flags.CouplingWarning{Flag: messaging.E2EEClaimFlag, Parent: keys.DeviceSignOutFlag, Reason: flags.ReasonParentNarrower}, slog.LevelWarn},
	} {
		if got := couplingLevel(tc.w); got != tc.want {
			t.Errorf("couplingLevel(%+v) = %v, want %v", tc.w, got, tc.want)
		}
	}
}

// TestFeatureRegistry_E2EEClaim (P6 §4.1 items 1 and 5, §4.7, §7.2 c; 6-6 security L1): the registry built from config
// knows `claim_live` under messaging.E2EEClaimFlag, defaults off, and its effective value is claim_live && effective
// e2ee_required (which is e2ee_required && messaging) && device_sign_out, for Enabled and GetMe's EnabledFeatures alike:
// switching E2EE_REQUIRED, MESSAGING or DEVICE_SIGN_OUT off withdraws the headline. GloballyOff keeps reading the raw
// flag, for claim_live and for device_sign_out (the session cut's kill switch is not changed by the coupling).
func TestFeatureRegistry_E2EEClaim(t *testing.T) {
	const in, out = "uid-a", "uid-z"
	for _, tc := range []struct {
		name                                string
		messaging, required, signOut, claim string // mode; "allowlist" lists uid-a only
		forIn, forOut                       bool
		claimGloballyOff                    bool
	}{
		{"all unset", "", "", "", "", false, false, true},
		{"claim unset, required and sign-out on", "on", "on", "on", "", false, false, true},
		{"claim on, required off", "on", "off", "on", "on", false, false, false},
		{"claim on, required unset", "on", "", "on", "on", false, false, false},
		{"claim on, required on, messaging off", "off", "on", "on", "on", false, false, false},
		{"claim on, required allowlist", "on", "allowlist", "on", "on", true, false, false},
		{"claim on, messaging allowlist", "allowlist", "on", "on", "on", true, false, false},
		{"claim on, sign-out off", "on", "on", "off", "on", false, false, false},
		{"claim on, sign-out unset", "on", "on", "", "on", false, false, false},
		{"claim on, sign-out allowlist", "on", "on", "allowlist", "on", true, false, false},
		{"claim allowlist, all else on", "on", "on", "on", "allowlist", true, false, false},
		{"claim off, all else on", "on", "on", "on", "off", false, false, true},
		{"everything on", "on", "on", "on", "on", true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for env, mode := range map[string]string{"FEATURE_MESSAGING": tc.messaging, "FEATURE_E2EE_REQUIRED": tc.required, "FEATURE_DEVICE_SIGN_OUT": tc.signOut, "FEATURE_E2EE_CLAIM": tc.claim} {
				t.Setenv(env, mode)
				t.Setenv(env+"_PERCENT", "")
				list := ""
				if mode == "allowlist" {
					list = in
				}
				t.Setenv(env+"_ALLOWLIST", list)
			}
			cfg, err := config.Load()
			if err != nil {
				t.Fatalf("config.Load: %v", err)
			}
			if cfg.FeatureE2EEClaim.Name != messaging.E2EEClaimFlag {
				t.Fatalf("config wire name %q != messaging.E2EEClaimFlag %q", cfg.FeatureE2EEClaim.Name, messaging.E2EEClaimFlag)
			}
			reg := featureRegistry(cfg)
			for uid, want := range map[string]bool{in: tc.forIn, out: tc.forOut} {
				if got := reg.Enabled(uid, messaging.E2EEClaimFlag); got != want {
					t.Errorf("%s: claim_live = %v, want %v", uid, got, want)
				}
				feats := reg.EnabledFeatures(uid)
				if got := slices.Contains(feats, messaging.E2EEClaimFlag); got != want {
					t.Errorf("%s: enabled_features has claim_live = %v, want %v (%v)", uid, got, want, feats)
				}
			}
			if got := reg.GloballyOff(messaging.E2EEClaimFlag); got != tc.claimGloballyOff {
				t.Errorf("GloballyOff(claim_live) = %v, want %v (the raw flag)", got, tc.claimGloballyOff)
			}
			if got, want := reg.GloballyOff(keys.DeviceSignOutFlag), tc.signOut == "" || tc.signOut == "off"; got != want {
				t.Errorf("GloballyOff(device_sign_out) = %v, want %v (unchanged by the coupling)", got, want)
			}
		})
	}
}

// TestFeatureCouplingWarnings_E2EEClaim: claim_live not off while either parent (e2ee_required, device_sign_out) is off
// or narrower is a parent_narrower line at WARN (neither parent is messaging), counted per allowlist entry without
// naming a uid, one line per parent sorted by parent name. Only claim_live's lines are checked; the others are covered
// by TestFeatureCouplingWarnings.
func TestFeatureCouplingWarnings_E2EEClaim(t *testing.T) {
	const warn = slog.LevelWarn
	const msg, dm, req, claim, so = messaging.FlagName, keys.FlagName, messaging.E2EERequiredFlag, messaging.E2EEClaimFlag, keys.DeviceSignOutFlag
	spec := func(name string, m flags.Mode, uids ...string) flags.Spec {
		s := flags.Spec{Name: name, Mode: m, Allowlist: map[string]struct{}{}}
		for _, u := range uids {
			s.Allowlist[u] = struct{}{}
		}
		return s
	}
	on, off, al := flags.On, flags.Off, flags.Allowlist
	for _, tc := range []struct {
		name          string
		req, claim, s flags.Spec
		want          []leveled
	}{
		{"claim off", spec(req, off), spec(claim, off), spec(so, off), nil},
		{"claim, required and sign-out on", spec(req, on), spec(claim, on), spec(so, on), nil},
		{"same pilot allowlists", spec(req, al, "uid-a"), spec(claim, al, "uid-a"), spec(so, al, "uid-a"), nil},
		{"claim on, required off", spec(req, off), spec(claim, on), spec(so, on), []leveled{
			{flags.CouplingWarning{Flag: claim, Parent: req, FlagMode: on, ParentMode: off, Reason: flags.ReasonParentNarrower}, warn},
		}},
		{"claim on, required allowlist", spec(req, al, "uid-a"), spec(claim, on), spec(so, on), []leveled{
			{flags.CouplingWarning{Flag: claim, Parent: req, FlagMode: on, ParentMode: al, Reason: flags.ReasonParentNarrower}, warn},
		}},
		{"claim on, sign-out off", spec(req, on), spec(claim, on), spec(so, off), []leveled{
			{flags.CouplingWarning{Flag: claim, Parent: so, FlagMode: on, ParentMode: off, Reason: flags.ReasonParentNarrower}, warn},
		}},
		{"claim lists a uid sign-out does not", spec(req, al, "uid-a", "uid-b"), spec(claim, al, "uid-a", "uid-b"), spec(so, al, "uid-a"), []leveled{
			{flags.CouplingWarning{Flag: claim, Parent: so, FlagMode: al, ParentMode: al, Reason: flags.ReasonParentNarrower, Uncovered: 1}, warn},
		}},
		{"claim on, both parents off (sorted by parent)", spec(req, off), spec(claim, on), spec(so, off), []leveled{
			{flags.CouplingWarning{Flag: claim, Parent: so, FlagMode: on, ParentMode: off, Reason: flags.ReasonParentNarrower}, warn},
			{flags.CouplingWarning{Flag: claim, Parent: req, FlagMode: on, ParentMode: off, Reason: flags.ReasonParentNarrower}, warn},
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := coupleE2EE(flags.NewRegistry(spec(msg, on), spec(dm, on), tc.req, tc.claim, tc.s))
			// required narrower than messaging is messaging_without_required; it is covered by TestFeatureCouplingWarnings.
			var got []leveled
			for _, w := range featureCouplingWarnings(reg) {
				if w.Flag == claim {
					got = append(got, leveled{w, couplingLevel(w)})
				}
			}
			if len(got) != len(tc.want) {
				t.Fatalf("claim warnings = %+v\nwant %+v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Errorf("claim warning %d = %+v\nwant %+v", i, got[i], tc.want[i])
				}
				for _, field := range []string{got[i].w.Flag, got[i].w.Parent, got[i].w.Reason} {
					if strings.Contains(field, "uid-") {
						t.Errorf("warning %+v carries a uid", got[i].w)
					}
				}
			}
		})
	}
}

// TestFeatureRegistry_IncludesDeviceSignOut: the registry built from config knows `device_sign_out` under the name keys and
// the session-cut interceptor ask (keys.DeviceSignOutFlag): globally off when unset, on for an allowlisted uid only.
func TestFeatureRegistry_IncludesDeviceSignOut(t *testing.T) {
	t.Setenv("FEATURE_DEVICE_SIGN_OUT", "")
	t.Setenv("FEATURE_DEVICE_SIGN_OUT_ALLOWLIST", "")
	t.Setenv("FEATURE_DEVICE_SIGN_OUT_PERCENT", "")
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if reg := featureRegistry(cfg); !reg.GloballyOff(keys.DeviceSignOutFlag) || reg.Enabled("uid-a", keys.DeviceSignOutFlag) {
		t.Error("device_sign_out must default globally off")
	}
	t.Setenv("FEATURE_DEVICE_SIGN_OUT", "allowlist")
	t.Setenv("FEATURE_DEVICE_SIGN_OUT_ALLOWLIST", "uid-a")
	cfg, err = config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	reg := featureRegistry(cfg)
	if !reg.Enabled("uid-a", keys.DeviceSignOutFlag) || reg.Enabled("uid-z", keys.DeviceSignOutFlag) || reg.GloballyOff(keys.DeviceSignOutFlag) {
		t.Error("allowlist: want on for uid-a only and not globally off")
	}
}

// TestFeatureRegistry_IncludesBeaconQuickJoin: `beacon_quick_join` defaults off, is on for an allowlisted caller only, and
// the config name is the one the beacons service checks (a drift or a spec left out of featureRegistry would leave it
// silently off for everyone).
func TestFeatureRegistry_IncludesBeaconQuickJoin(t *testing.T) {
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if featureRegistry(cfg).Enabled("uid-a", beacons.QuickJoinFlagName) {
		t.Error("beacon_quick_join must default off")
	}
	if cfg.FeatureBeaconQuickJoin.Name != beacons.QuickJoinFlagName {
		t.Errorf("config flag name %q != beacons.QuickJoinFlagName", cfg.FeatureBeaconQuickJoin.Name)
	}
	t.Setenv("FEATURE_BEACON_QUICK_JOIN", "allowlist")
	t.Setenv("FEATURE_BEACON_QUICK_JOIN_ALLOWLIST", "uid-a")
	cfg, err = config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	reg := featureRegistry(cfg)
	if !reg.Enabled("uid-a", beacons.QuickJoinFlagName) || reg.Enabled("uid-z", beacons.QuickJoinFlagName) {
		t.Error("beacon_quick_join should be on for uid-a only")
	}
}

// TestFeatureRegistry_IncludesTrendingPosts: every mode of FEATURE_TRENDING_POSTS reaches the registry Build wires, so
// ExplorePosts is gated by it and GetMe.enabled_features can report `trending_posts`; unset is off for everyone.
func TestFeatureRegistry_IncludesTrendingPosts(t *testing.T) {
	for _, tc := range []struct {
		name        string
		env         map[string]string
		inA, inZ    bool
		globallyOff bool
	}{
		{"unset is off", nil, false, false, true},
		{"off", map[string]string{"FEATURE_TRENDING_POSTS": "off"}, false, false, true},
		{"allowlist", map[string]string{"FEATURE_TRENDING_POSTS": "allowlist", "FEATURE_TRENDING_POSTS_ALLOWLIST": "uid-a"}, true, false, false},
		{"percent 100", map[string]string{"FEATURE_TRENDING_POSTS": "percent", "FEATURE_TRENDING_POSTS_PERCENT": "100"}, true, true, false},
		{"on", map[string]string{"FEATURE_TRENDING_POSTS": "on"}, true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{"FEATURE_TRENDING_POSTS", "FEATURE_TRENDING_POSTS_ALLOWLIST", "FEATURE_TRENDING_POSTS_PERCENT"} {
				t.Setenv(k, tc.env[k])
			}
			cfg, err := config.Load()
			if err != nil {
				t.Fatalf("config.Load: %v", err)
			}
			if cfg.FeatureTrendingPosts.Name != search.FlagTrendingPosts {
				t.Fatalf("config wire name %q != search.FlagTrendingPosts %q", cfg.FeatureTrendingPosts.Name, search.FlagTrendingPosts)
			}
			reg := featureRegistry(cfg)
			if got := reg.Enabled("uid-a", search.FlagTrendingPosts); got != tc.inA {
				t.Errorf("uid-a enabled = %v, want %v", got, tc.inA)
			}
			if got := reg.Enabled("uid-z", search.FlagTrendingPosts); got != tc.inZ {
				t.Errorf("uid-z enabled = %v, want %v", got, tc.inZ)
			}
			if got := reg.GloballyOff(search.FlagTrendingPosts); got != tc.globallyOff {
				t.Errorf("globally off = %v, want %v", got, tc.globallyOff)
			}
		})
	}
}
