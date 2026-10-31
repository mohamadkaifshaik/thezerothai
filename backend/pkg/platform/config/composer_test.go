package config

import (
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_ComposerDefaults pins every ADR-0029 default and the three flags (off, wire names polls, drafts and gif).
func TestLoad_ComposerDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	want := ComposerConfig{
		PollMaxChoices: 4, PollChoiceMaxCodepoints: 25, PollMinDuration: 5 * time.Minute, PollMaxDuration: 168 * time.Hour,
		PollVoteTTLAfterClose: 720 * time.Hour, PollViewerVotesKept: 500, GifMaxFrames: 300, GifMaxEdge: 1280, GifMaxFrameAreaSum: 50_000_000, MediaMaxScreenAttempts: 3, MediaMaxScreenRetries: 5, MediaVisionUnitsPerDay: 60, MediaVisionUnitsPerDayNewAccount: 12,
	}
	if cfg.Composer != want {
		t.Errorf("Composer = %+v, want %+v", cfg.Composer, want)
	}
	if cfg.RateLimit.MediaFinalizePerMinute != 10 {
		t.Errorf("MediaFinalizePerMinute = %d, want 10", cfg.RateLimit.MediaFinalizePerMinute)
	}
	if rl := cfg.RateLimit; rl.PollVotePerUserPerMinute != 30 || rl.PollVotesPerDay != 300 || rl.PollVotesPerDayNewAccount != 50 {
		t.Errorf("poll limits = %d/%d/%d, want 30/300/50", rl.PollVotePerUserPerMinute, rl.PollVotesPerDay, rl.PollVotesPerDayNewAccount)
	}
	for _, f := range []struct {
		spec flags.Spec
		name string
	}{{cfg.FeaturePolls, "polls"}, {cfg.FeatureDrafts, "drafts"}, {cfg.FeatureGif, "gif"}} {
		if f.spec.Name != f.name || f.spec.Mode != flags.Off {
			t.Errorf("flag = %+v, want name %s, mode off", f.spec, f.name)
		}
	}
	if got := flags.NewRegistry(cfg.FeaturePolls, cfg.FeatureDrafts, cfg.FeatureGif).EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures = %v, want none", got)
	}
}

// TestLoad_ComposerFlagModes: off, allowlist, percent and on, each reported by GetMe.enabled_features (EnabledFeatures)
// only for the callers it admits, with the kill switch (GloballyOff) true only for mode off.
func TestLoad_ComposerFlagModes(t *testing.T) {
	for _, name := range []string{"POLLS", "DRAFTS", "GIF"} {
		wire := strings.ToLower(name)
		spec := func(t *testing.T) flags.Spec {
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			return map[string]flags.Spec{"POLLS": cfg.FeaturePolls, "DRAFTS": cfg.FeatureDrafts, "GIF": cfg.FeatureGif}[name]
		}
		t.Run(name+"/off", func(t *testing.T) {
			clearEnv(t)
			r := flags.NewRegistry(spec(t))
			if r.Enabled("uid-a", wire) || !r.GloballyOff(wire) {
				t.Errorf("off: Enabled=%v GloballyOff=%v, want false/true", r.Enabled("uid-a", wire), r.GloballyOff(wire))
			}
		})
		t.Run(name+"/allowlist", func(t *testing.T) {
			clearEnv(t)
			t.Setenv("FEATURE_"+name, "allowlist")
			t.Setenv("FEATURE_"+name+"_ALLOWLIST", "uid-a,uid-b")
			r := flags.NewRegistry(spec(t))
			if !r.Enabled("uid-a", wire) || r.Enabled("uid-z", wire) || r.GloballyOff(wire) {
				t.Errorf("allowlist: a=%v z=%v globallyOff=%v, want true/false/false", r.Enabled("uid-a", wire), r.Enabled("uid-z", wire), r.GloballyOff(wire))
			}
			if got := r.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != wire {
				t.Errorf("EnabledFeatures(uid-a) = %v, want [%s]", got, wire)
			}
			if got := r.EnabledFeatures("uid-z"); len(got) != 0 {
				t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
			}
		})
		t.Run(name+"/percent", func(t *testing.T) {
			clearEnv(t)
			t.Setenv("FEATURE_"+name, "percent")
			t.Setenv("FEATURE_"+name+"_PERCENT", "0")
			r := flags.NewRegistry(spec(t))
			if r.Enabled("uid-a", wire) || r.GloballyOff(wire) { // percent 0 is a rollout, not the kill switch
				t.Errorf("percent 0: Enabled=%v GloballyOff=%v, want false/false", r.Enabled("uid-a", wire), r.GloballyOff(wire))
			}
			t.Setenv("FEATURE_"+name+"_PERCENT", "100")
			r = flags.NewRegistry(spec(t))
			if !r.Enabled("uid-a", wire) {
				t.Errorf("percent 100: not enabled")
			}
		})
		t.Run(name+"/on", func(t *testing.T) {
			clearEnv(t)
			t.Setenv("FEATURE_"+name, "on")
			r := flags.NewRegistry(spec(t))
			if !r.Enabled("uid-a", wire) || r.GloballyOff(wire) {
				t.Errorf("on: Enabled=%v GloballyOff=%v, want true/false", r.Enabled("uid-a", wire), r.GloballyOff(wire))
			}
		})
		t.Run(name+"/invalid", func(t *testing.T) {
			for _, tt := range []struct{ key, val string }{{"FEATURE_" + name, "bogus"}, {"FEATURE_" + name + "_PERCENT", "101"}} {
				clearEnv(t)
				t.Setenv(tt.key, tt.val)
				if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.key) {
					t.Errorf("%s=%s: Load() error = %v, want one naming the key", tt.key, tt.val, err)
				}
			}
		})
	}
}

// TestLoad_ComposerOverrides: every key is overridable inside its bounds.
func TestLoad_ComposerOverrides(t *testing.T) {
	clearEnv(t)
	for k, v := range map[string]string{
		"POLL_MAX_CHOICES": "3", "POLL_CHOICE_MAX_CODEPOINTS": "30", "POLL_MIN_DURATION": "10m", "POLL_MAX_DURATION": "48h",
		"POLL_VOTE_TTL_AFTER_CLOSE": "48h", "POLL_VIEWER_VOTES_KEPT": "200", "RATE_LIMIT_POLL_VOTE_PER_MIN": "7",
		"POLL_VOTES_PER_DAY": "100", "POLL_VOTES_PER_DAY_NEW_ACCOUNT": "100", "GIF_MAX_FRAMES": "100", "GIF_MAX_EDGE": "640",
		"GIF_MAX_FRAME_AREA_SUM": "1000000", "MEDIA_MAX_SCREEN_ATTEMPTS": "5", "MEDIA_MAX_SCREEN_RETRIES": "0", "MEDIA_VISION_UNITS_PER_DAY": "100", "MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT": "20", "RATE_LIMIT_MEDIA_FINALIZE_PER_MIN": "4",
	} {
		t.Setenv(k, v)
	}
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	want := ComposerConfig{
		PollMaxChoices: 3, PollChoiceMaxCodepoints: 30, PollMinDuration: 10 * time.Minute, PollMaxDuration: 48 * time.Hour,
		PollVoteTTLAfterClose: 48 * time.Hour, PollViewerVotesKept: 200, GifMaxFrames: 100, GifMaxEdge: 640, GifMaxFrameAreaSum: 1_000_000, MediaMaxScreenAttempts: 5, MediaMaxScreenRetries: 0, MediaVisionUnitsPerDay: 100, MediaVisionUnitsPerDayNewAccount: 20,
	}
	if cfg.Composer != want {
		t.Errorf("Composer = %+v, want %+v", cfg.Composer, want)
	}
	if cfg.RateLimit.MediaFinalizePerMinute != 4 {
		t.Errorf("MediaFinalizePerMinute = %d, want 4", cfg.RateLimit.MediaFinalizePerMinute)
	}
	if rl := cfg.RateLimit; rl.PollVotePerUserPerMinute != 7 || rl.PollVotesPerDay != 100 || rl.PollVotesPerDayNewAccount != 100 {
		t.Errorf("poll limits = %d/%d/%d", rl.PollVotePerUserPerMinute, rl.PollVotesPerDay, rl.PollVotesPerDayNewAccount)
	}
}

// TestLoad_ComposerBounds: a value outside its range, or unparseable, fails startup naming the key (rule 11).
func TestLoad_ComposerBounds(t *testing.T) {
	bad := []struct{ key, val string }{
		{"POLL_MAX_CHOICES", "1"}, {"POLL_MAX_CHOICES", "5"}, {"POLL_MAX_CHOICES", "x"},
		{"POLL_CHOICE_MAX_CODEPOINTS", "0"}, {"POLL_CHOICE_MAX_CODEPOINTS", "101"},
		{"POLL_MIN_DURATION", "0s"}, {"POLL_MIN_DURATION", "-5m"}, {"POLL_MIN_DURATION", "soon"}, {"POLL_MIN_DURATION", "721h"},
		{"POLL_MAX_DURATION", "30s"}, {"POLL_MAX_DURATION", "721h"},
		{"POLL_VOTE_TTL_AFTER_CLOSE", "1h"}, {"POLL_VOTE_TTL_AFTER_CLOSE", "2200h"},
		{"POLL_VIEWER_VOTES_KEPT", "0"}, {"POLL_VIEWER_VOTES_KEPT", "1001"},
		{"RATE_LIMIT_POLL_VOTE_PER_MIN", "0"}, {"RATE_LIMIT_POLL_VOTE_PER_MIN", "-1"},
		{"POLL_VOTES_PER_DAY", "0"}, {"POLL_VOTES_PER_DAY", "-1"}, {"POLL_VOTES_PER_DAY_NEW_ACCOUNT", "0"},
		{"GIF_MAX_FRAMES", "0"}, {"GIF_MAX_FRAMES", "1001"}, {"GIF_MAX_EDGE", "0"}, {"GIF_MAX_EDGE", "4097"},
		{"GIF_MAX_FRAME_AREA_SUM", "0"}, {"GIF_MAX_FRAME_AREA_SUM", "200000001"},
		{"MEDIA_MAX_SCREEN_ATTEMPTS", "0"}, {"MEDIA_MAX_SCREEN_ATTEMPTS", "11"},
		{"MEDIA_MAX_SCREEN_RETRIES", "-1"}, {"MEDIA_MAX_SCREEN_RETRIES", "11"}, {"MEDIA_VISION_UNITS_PER_DAY", "1"}, {"MEDIA_VISION_UNITS_PER_DAY", "201"},
		{"MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT", "1"}, {"MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT", "61"}, {"RATE_LIMIT_MEDIA_FINALIZE_PER_MIN", "0"},
	}
	for _, tt := range bad {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.key) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.key)
			}
		})
	}
	t.Run("min above max duration", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("POLL_MIN_DURATION", "48h")
		t.Setenv("POLL_MAX_DURATION", "24h")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "POLL_MIN_DURATION") {
			t.Errorf("Load() error = %v, want one naming POLL_MIN_DURATION", err)
		}
	})
	t.Run("new-account cap above the general cap", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("POLL_VOTES_PER_DAY", "40")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "POLL_VOTES_PER_DAY_NEW_ACCOUNT") {
			t.Errorf("Load() error = %v, want one naming POLL_VOTES_PER_DAY_NEW_ACCOUNT", err)
		}
	})
}
