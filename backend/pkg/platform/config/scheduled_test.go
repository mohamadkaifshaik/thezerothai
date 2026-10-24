package config

import (
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_ScheduledDefaults pins every ADR-0021 default: the quota keys, the SCHEDULED_* keys and the flag.
func TestLoad_ScheduledDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Quota.SchedulesPerDay != 50 || cfg.Quota.NewAccountSchedulesPerDay != 10 {
		t.Errorf("schedule quotas = %d/%d, want 50/10", cfg.Quota.SchedulesPerDay, cfg.Quota.NewAccountSchedulesPerDay)
	}
	want := ScheduledConfig{
		MaxPending: 25, Horizon: 1440 * time.Hour, MinLead: 2 * time.Minute, PerAuthorPerRun: 3, AuthorReadsWarn: 40,
		SweepLimit: 50, SweepMaxPages: 2, SweepConcurrency: 4, MaxLateness: 6 * time.Hour, MaxAttempts: 3,
		TerminalTTL: 168 * time.Hour,
	}
	if cfg.Scheduled != want {
		t.Errorf("Scheduled = %+v, want %+v", cfg.Scheduled, want)
	}
	if cfg.FeatureScheduledPosts.Name != "scheduled_posts" || cfg.FeatureScheduledPosts.Mode != flags.Off {
		t.Errorf("FeatureScheduledPosts = %+v, want name scheduled_posts, mode off", cfg.FeatureScheduledPosts)
	}
	if got := flags.NewRegistry(cfg.FeatureScheduledPosts).EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures with the flag off = %v, want none", got)
	}
}

// TestLoad_ScheduledOverridesAndValidation: every key is overridable, and a value outside its typo guard (or
// unparseable) fails startup naming the key.
func TestLoad_ScheduledOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("QUOTA_SCHEDULES_PER_DAY", "7")
		t.Setenv("QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY", "2")
		t.Setenv("SCHEDULED_MAX_PENDING", "5")
		t.Setenv("SCHEDULED_HORIZON", "24h")
		t.Setenv("SCHEDULED_MIN_LEAD", "5m")
		t.Setenv("SCHEDULED_PER_AUTHOR_PER_RUN", "2")
		t.Setenv("SCHEDULED_AUTHOR_READS_WARN", "9")
		t.Setenv("SCHEDULED_SWEEP_LIMIT", "20")
		t.Setenv("SCHEDULED_SWEEP_MAX_PAGES", "3")
		t.Setenv("SCHEDULED_SWEEP_CONCURRENCY", "2")
		t.Setenv("SCHEDULED_MAX_LATENESS", "1h")
		t.Setenv("SCHEDULED_MAX_ATTEMPTS", "5")
		t.Setenv("SCHEDULED_TERMINAL_TTL", "48h")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		want := ScheduledConfig{
			MaxPending: 5, Horizon: 24 * time.Hour, MinLead: 5 * time.Minute, PerAuthorPerRun: 2, AuthorReadsWarn: 9,
			SweepLimit: 20, SweepMaxPages: 3, SweepConcurrency: 2, MaxLateness: time.Hour, MaxAttempts: 5,
			TerminalTTL: 48 * time.Hour,
		}
		if cfg.Scheduled != want || cfg.Quota.SchedulesPerDay != 7 || cfg.Quota.NewAccountSchedulesPerDay != 2 {
			t.Errorf("override: %+v quota %d/%d", cfg.Scheduled, cfg.Quota.SchedulesPerDay, cfg.Quota.NewAccountSchedulesPerDay)
		}
	})

	t.Run("sweep limit is clamped to 50", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("SCHEDULED_SWEEP_LIMIT", "500")
		cfg, err := Load()
		if err != nil || cfg.Scheduled.SweepLimit != MaxScheduledSweepLimit {
			t.Fatalf("SweepLimit = %d err=%v, want clamp to %d", cfg.Scheduled.SweepLimit, err, MaxScheduledSweepLimit)
		}
	})

	tests := []struct{ key, val, want string }{
		{"QUOTA_SCHEDULES_PER_DAY", "0", "QUOTA_SCHEDULES_PER_DAY"},
		{"QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY", "-1", "QUOTA_NEW_ACCOUNT_SCHEDULES_PER_DAY"},
		{"QUOTA_SCHEDULES_PER_DAY", "many", "QUOTA_SCHEDULES_PER_DAY"},
		{"SCHEDULED_MAX_PENDING", "0", "SCHEDULED_MAX_PENDING"},
		{"SCHEDULED_MAX_PENDING", "51", "SCHEDULED_MAX_PENDING"},
		{"SCHEDULED_PER_AUTHOR_PER_RUN", "0", "SCHEDULED_PER_AUTHOR_PER_RUN"},
		{"SCHEDULED_AUTHOR_READS_WARN", "0", "SCHEDULED_AUTHOR_READS_WARN"},
		{"SCHEDULED_SWEEP_LIMIT", "0", "SCHEDULED_SWEEP_LIMIT"},
		{"SCHEDULED_SWEEP_MAX_PAGES", "11", "SCHEDULED_SWEEP_MAX_PAGES"},
		{"SCHEDULED_SWEEP_CONCURRENCY", "0", "SCHEDULED_SWEEP_CONCURRENCY"},
		{"SCHEDULED_SWEEP_CONCURRENCY", "5", "SCHEDULED_SWEEP_CONCURRENCY"},
		{"SCHEDULED_MAX_ATTEMPTS", "0", "SCHEDULED_MAX_ATTEMPTS"},
		{"SCHEDULED_HORIZON", "banana", "SCHEDULED_HORIZON"},
		{"SCHEDULED_HORIZON", "30m", "SCHEDULED_HORIZON"},
		{"SCHEDULED_HORIZON", "9000h", "SCHEDULED_HORIZON"},
		{"SCHEDULED_MIN_LEAD", "30s", "SCHEDULED_MIN_LEAD"},
		{"SCHEDULED_MAX_LATENESS", "0s", "SCHEDULED_MAX_LATENESS"},
		{"SCHEDULED_TERMINAL_TTL", "1m", "SCHEDULED_TERMINAL_TTL"},
		{"SCHEDULED_TERMINAL_TTL", "721h", "SCHEDULED_TERMINAL_TTL"},
	}
	for _, tt := range tests {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			_, err := Load()
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.want)
			}
		})
	}

	t.Run("min lead must be shorter than the horizon", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("SCHEDULED_HORIZON", "2h")
		t.Setenv("SCHEDULED_MIN_LEAD", "2h")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "SCHEDULED_MIN_LEAD") {
			t.Errorf("Load() error = %v, want SCHEDULED_MIN_LEAD", err)
		}
	})
}

// TestLoad_ScheduledPostsFlag: FEATURE_SCHEDULED_POSTS (ADR-0021 D4) is overridable like the other server flags and
// is listed in enabled_features only when on for the caller.
func TestLoad_ScheduledPostsFlag(t *testing.T) {
	clearEnv(t)
	t.Setenv("FEATURE_SCHEDULED_POSTS", "allowlist")
	t.Setenv("FEATURE_SCHEDULED_POSTS_ALLOWLIST", "uid-a,uid-b")
	cfg, err := Load()
	if err != nil || cfg.FeatureScheduledPosts.Mode != flags.Allowlist || len(cfg.FeatureScheduledPosts.Allowlist) != 2 {
		t.Fatalf("override: %+v err=%v", cfg.FeatureScheduledPosts, err)
	}
	reg := flags.NewRegistry(cfg.FeatureScheduledPosts)
	if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "scheduled_posts" {
		t.Errorf("EnabledFeatures(uid-a) = %v, want [scheduled_posts]", got)
	}
	if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
		t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
	}

	t.Setenv("FEATURE_SCHEDULED_POSTS", "bogus")
	if _, err := Load(); err == nil {
		t.Error("an invalid FEATURE_SCHEDULED_POSTS must fail startup")
	}
}
