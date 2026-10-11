package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_ReportsDefaults locks the ADR-0016 numbers: FEATURE_REPORTS off, 5 reports/min, 20/day (5 for new
// accounts), and that the env vars override them.
func TestLoad_ReportsDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureReports.Name != "reports" || cfg.FeatureReports.Mode != flags.Off {
		t.Errorf("FeatureReports = %+v, want name reports, mode off", cfg.FeatureReports)
	}
	if cfg.RateLimit.ReportPerMinute != 5 || cfg.Quota.ReportsPerDay != 20 || cfg.Quota.NewAccountReportsPerDay != 5 {
		t.Errorf("report limits = %d/min %d/day %d/day-new, want 5/20/5",
			cfg.RateLimit.ReportPerMinute, cfg.Quota.ReportsPerDay, cfg.Quota.NewAccountReportsPerDay)
	}

	clearEnv(t)
	t.Setenv("FEATURE_REPORTS", "on")
	t.Setenv("QUOTA_REPORTS_PER_DAY", "7")
	cfg, err = Load()
	if err != nil || cfg.FeatureReports.Mode != flags.On || cfg.Quota.ReportsPerDay != 7 {
		t.Fatalf("override: %+v %d err=%v", cfg.FeatureReports, cfg.Quota.ReportsPerDay, err)
	}

	for _, bad := range []string{"0", "-1", "abc"} {
		clearEnv(t)
		t.Setenv("RATE_LIMIT_REPORT_PER_MIN", bad)
		if _, err := Load(); err == nil {
			t.Errorf("RATE_LIMIT_REPORT_PER_MIN=%s must fail", bad)
		}
	}
}
