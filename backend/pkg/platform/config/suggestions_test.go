package config

import (
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w3Flags lists the four ADR-0024 D9 flags: env name, wire name, and the Config field.
var w3Flags = []struct {
	env, wire string
	spec      func(Config) flags.Spec
}{
	{"PROFILE_EXTRAS", "profile_extras", func(c Config) flags.Spec { return c.FeatureProfileExtras }},
	{"PROFILE_TABS", "profile_tabs", func(c Config) flags.Spec { return c.FeatureProfileTabs }},
	{"LIKES_LIST", "likes_list", func(c Config) flags.Spec { return c.FeatureLikesList }},
	{"FOLLOW_SUGGESTIONS", "follow_suggestions", func(c Config) flags.Spec { return c.FeatureFollowSuggestions }},
}

// TestLoad_ProfileGraphDefaults pins every ADR-0024 D8/D9/D10 default: the four flags (off), the three per-minute
// buckets, the daily call cap, the suggestion limits and an empty curated list.
func TestLoad_ProfileGraphDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	for _, f := range w3Flags {
		spec := f.spec(cfg)
		if spec.Name != f.wire || spec.Mode != flags.Off {
			t.Errorf("%s = %+v, want name %s, mode off", f.env, spec, f.wire)
		}
		if got := flags.NewRegistry(spec).EnabledFeatures("uid-a"); len(got) != 0 {
			t.Errorf("%s: EnabledFeatures with the flag off = %v, want none", f.env, got)
		}
	}
	rl := cfg.RateLimit
	if rl.SuggestionsPerUserPerMinute != 10 || rl.LikesListPerUserPerMinute != 10 || rl.ProfileRelationshipPerUserPerMinute != 60 {
		t.Errorf("rate limits = %d/%d/%d, want 10/10/60", rl.SuggestionsPerUserPerMinute, rl.LikesListPerUserPerMinute, rl.ProfileRelationshipPerUserPerMinute)
	}
	if rl.SuggestionsCallsPerDay != 50 {
		t.Errorf("SuggestionsCallsPerDay = %d, want 50", rl.SuggestionsCallsPerDay)
	}
	s := cfg.Suggestions
	if s.SampleFollowees != 30 || s.EdgeLimit != 20 || s.HydrateMax != 10 || s.MaxResults != 5 || s.CacheTTL != time.Hour || len(s.UserIDs) != 0 {
		t.Errorf("Suggestions = %+v, want 30/20/10/5/1h and no curated uids (ADR-0024 Amendment 2 B1(b): edge limit 20, cold cap 32)", s)
	}
}

// TestLoad_ProfileGraphOverrides: every key is overridable, and each flag is listed in enabled_features only for the
// allowlisted uids.
func TestLoad_ProfileGraphOverrides(t *testing.T) {
	clearEnv(t)
	for _, f := range w3Flags {
		t.Setenv("FEATURE_"+f.env, "allowlist")
		t.Setenv("FEATURE_"+f.env+"_ALLOWLIST", "uid-a,uid-b")
	}
	t.Setenv("RATE_LIMIT_SUGGESTIONS_PER_MIN", "3")
	t.Setenv("RATE_LIMIT_LIKES_LIST_PER_MIN", "4")
	t.Setenv("RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN", "5")
	t.Setenv("SUGGESTIONS_CALLS_PER_DAY", "6")
	t.Setenv("SUGGESTIONS_SAMPLE_FOLLOWEES", "7")
	t.Setenv("SUGGESTIONS_EDGE_LIMIT", "8")
	t.Setenv("SUGGESTIONS_HYDRATE_MAX", "9")
	t.Setenv("SUGGESTIONS_MAX_RESULTS", "2")
	t.Setenv("SUGGESTIONS_CACHE_TTL", "15m")
	t.Setenv("SUGGESTED_USER_IDS", " uid-1, uid-2 ,uid-1,,uid-3")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	rl := cfg.RateLimit
	if rl.SuggestionsPerUserPerMinute != 3 || rl.LikesListPerUserPerMinute != 4 || rl.ProfileRelationshipPerUserPerMinute != 5 || rl.SuggestionsCallsPerDay != 6 {
		t.Errorf("rate limit overrides = %d/%d/%d/%d", rl.SuggestionsPerUserPerMinute, rl.LikesListPerUserPerMinute, rl.ProfileRelationshipPerUserPerMinute, rl.SuggestionsCallsPerDay)
	}
	s := cfg.Suggestions
	if s.SampleFollowees != 7 || s.EdgeLimit != 8 || s.HydrateMax != 9 || s.MaxResults != 2 || s.CacheTTL != 15*time.Minute {
		t.Errorf("Suggestions overrides = %+v", s)
	}
	if got := strings.Join(s.UserIDs, ","); got != "uid-1,uid-2,uid-3" {
		t.Errorf("UserIDs = %q, want trimmed, de-duplicated, in order: uid-1,uid-2,uid-3", got)
	}
	for _, f := range w3Flags {
		reg := flags.NewRegistry(f.spec(cfg))
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != f.wire {
			t.Errorf("%s: EnabledFeatures(uid-a) = %v, want [%s]", f.env, got, f.wire)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("%s: EnabledFeatures(uid-z) = %v, want none", f.env, got)
		}
	}
}

// TestLoad_ProfileGraphValidation: a value outside its bound, a non-number, an invalid uid, more than 20 curated uids and
// a bad flag mode each fail startup naming the key. The boundary values themselves load.
func TestLoad_ProfileGraphValidation(t *testing.T) {
	twentyOne := make([]string, 21)
	for i := range twentyOne {
		twentyOne[i] = "u" + string(rune('a'+i))
	}
	twenty := twentyOne[:20]

	for _, tt := range []struct{ key, val, want string }{
		{"RATE_LIMIT_SUGGESTIONS_PER_MIN", "0", "RATE_LIMIT_SUGGESTIONS_PER_MIN"},
		{"RATE_LIMIT_LIKES_LIST_PER_MIN", "-1", "RATE_LIMIT_LIKES_LIST_PER_MIN"},
		{"RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN", "0", "RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN"},
		{"RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN", "many", "RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN"},
		{"SUGGESTIONS_CALLS_PER_DAY", "0", "SUGGESTIONS_CALLS_PER_DAY"},
		{"SUGGESTIONS_CALLS_PER_DAY", "-5", "SUGGESTIONS_CALLS_PER_DAY"},
		{"SUGGESTIONS_SAMPLE_FOLLOWEES", "31", "SUGGESTIONS_SAMPLE_FOLLOWEES"},
		{"SUGGESTIONS_SAMPLE_FOLLOWEES", "0", "SUGGESTIONS_SAMPLE_FOLLOWEES"},
		{"SUGGESTIONS_EDGE_LIMIT", "51", "SUGGESTIONS_EDGE_LIMIT"},
		{"SUGGESTIONS_EDGE_LIMIT", "0", "SUGGESTIONS_EDGE_LIMIT"},
		{"SUGGESTIONS_HYDRATE_MAX", "51", "SUGGESTIONS_HYDRATE_MAX"},
		{"SUGGESTIONS_HYDRATE_MAX", "-1", "SUGGESTIONS_HYDRATE_MAX"},
		{"SUGGESTIONS_MAX_RESULTS", "6", "SUGGESTIONS_MAX_RESULTS"},
		{"SUGGESTIONS_MAX_RESULTS", "0", "SUGGESTIONS_MAX_RESULTS"},
		{"SUGGESTIONS_EDGE_LIMIT", "lots", "SUGGESTIONS_EDGE_LIMIT"},
		{"SUGGESTIONS_CACHE_TTL", "0s", "SUGGESTIONS_CACHE_TTL"},
		{"SUGGESTIONS_CACHE_TTL", "-1h", "SUGGESTIONS_CACHE_TTL"},
		{"SUGGESTIONS_CACHE_TTL", "25h", "SUGGESTIONS_CACHE_TTL"},
		{"SUGGESTIONS_CACHE_TTL", "soon", "SUGGESTIONS_CACHE_TTL"},
		{"SUGGESTED_USER_IDS", "uid-1,bad_uid", "SUGGESTED_USER_IDS"},
		{"SUGGESTED_USER_IDS", "uid 1", "SUGGESTED_USER_IDS"},
		{"SUGGESTED_USER_IDS", strings.Join(twentyOne, ","), "SUGGESTED_USER_IDS"},
		{"FEATURE_PROFILE_EXTRAS", "bogus", "FEATURE_PROFILE_EXTRAS"},
		{"FEATURE_PROFILE_TABS", "bogus", "FEATURE_PROFILE_TABS"},
		{"FEATURE_LIKES_LIST", "bogus", "FEATURE_LIKES_LIST"},
		{"FEATURE_FOLLOW_SUGGESTIONS", "bogus", "FEATURE_FOLLOW_SUGGESTIONS"},
		{"FEATURE_LIKES_LIST_PERCENT", "101", "FEATURE_LIKES_LIST_PERCENT"},
		{"FEATURE_FOLLOW_SUGGESTIONS_PERCENT", "-1", "FEATURE_FOLLOW_SUGGESTIONS_PERCENT"},
	} {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.want)
			}
		})
	}

	t.Run("boundaries load", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("SUGGESTIONS_SAMPLE_FOLLOWEES", "30")
		t.Setenv("SUGGESTIONS_EDGE_LIMIT", "50")
		t.Setenv("SUGGESTIONS_HYDRATE_MAX", "50")
		t.Setenv("SUGGESTIONS_MAX_RESULTS", "5")
		t.Setenv("SUGGESTIONS_CACHE_TTL", "24h")
		t.Setenv("SUGGESTED_USER_IDS", strings.Join(twenty, ","))
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if len(cfg.Suggestions.UserIDs) != 20 {
			t.Errorf("UserIDs = %d, want 20", len(cfg.Suggestions.UserIDs))
		}
	})

	t.Run("dedupe happens before the count", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("SUGGESTED_USER_IDS", strings.Join(twenty, ",")+","+twenty[0])
		if _, err := Load(); err != nil {
			t.Errorf("20 distinct uids plus a repeat must load: %v", err)
		}
	})
}
