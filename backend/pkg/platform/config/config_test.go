package config

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func clearEnv(t *testing.T) {
	t.Helper()
	keys := []string{
		"PORT", "FIREBASE_PROJECT_ID", "GOOGLE_CLOUD_PROJECT", "GCP_PROJECT_ID", "GCP_PROJECT", "ENV", "DEGRADED_MODE",
		"APP_CHECK_MODE", "CURSOR_HMAC_KEY", "SHUTDOWN_TIMEOUT", "CACHE_TTL", "HANDLE_CHANGE_COOLDOWN",
		"QUOTA_NEW_ACCOUNT_WINDOW", "RATE_LIMIT_PER_USER_PER_MIN", "RATE_LIMIT_TIMELINE_PER_MIN",
		"RATE_LIMIT_CHECK_HANDLE_PER_MIN", "RATE_LIMIT_LIKES_PER_MIN", "RATE_LIMIT_PER_IP_PER_MIN", "RATE_LIMIT_PRE_AUTH_IP_PER_MIN",
		"QUOTA_POSTS_PER_DAY", "QUOTA_FOLLOWS_PER_DAY", "QUOTA_MEDIA_PER_DAY", "QUOTA_EXPORTS_PER_DAY",
		"QUOTA_NEW_ACCOUNT_POSTS_PER_DAY", "QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY", "QUOTA_NEW_ACCOUNT_MEDIA_PER_DAY",
		"INTERNAL_OIDC_AUDIENCE", "INTERNAL_OIDC_ALLOWED_EMAILS", "CORS_ALLOWED_ORIGINS", "TRUSTED_PROXY_HOPS",
		"FEATURE_GRAPH", "FEATURE_GRAPH_ALLOWLIST", "FEATURE_GRAPH_PERCENT",
		"FEATURE_POSTS", "FEATURE_POSTS_ALLOWLIST", "FEATURE_POSTS_PERCENT",
		"CACHE_POSTS_ENTRIES", "CACHE_AUTHOR_RECENT_ENTRIES",
		"RATE_LIMIT_USER_TIMELINE_PER_MIN", "RATE_LIMIT_POST_CREATE_PER_MIN", "RATE_LIMIT_POST_DELETE_PER_MIN",
		"QUOTA_BLOCKS_PER_DAY", "QUOTA_NEW_ACCOUNT_BLOCKS_PER_DAY",
		"RATE_LIMIT_GRAPH_FOLLOW_PER_MIN", "RATE_LIMIT_GRAPH_BLOCK_PER_MIN", "RATE_LIMIT_GRAPH_LIST_PER_MIN",
		"LIST_CALLS_PER_DAY", "GRAPH_MUTATIONS_PER_DAY",
		"READ_BUDGET_PER_UID_PER_DAY", "READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY", "CHECK_HANDLE_CALLS_PER_DAY",
		"ACCOUNT_OPS_CALLS_PER_DAY", "FIREBASE_AUTH_EMULATOR_HOST", "TIMELINE_TOKEN_TTL",
	}
	for _, k := range keys {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
}

func TestLoad_LocalDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Env != "local" {
		t.Errorf("Env = %q, want local", cfg.Env)
	}
	if cfg.ProjectID != "demo-dzeroth-local" {
		t.Errorf("ProjectID = %q, want demo-dzeroth-local", cfg.ProjectID)
	}
	if cfg.Degraded != DegradedOff {
		t.Errorf("Degraded = %q, want off", cfg.Degraded)
	}
	if cfg.AppCheck != AppCheckMonitor {
		t.Errorf("AppCheck = %q, want monitor (local default)", cfg.AppCheck)
	}
	if cfg.Port != "8081" {
		t.Errorf("Port = %q, want 8081 (M10: never collide with the Firestore emulator's fixed port 8080)", cfg.Port)
	}
	if len(cfg.CursorHMACKey) == 0 {
		t.Error("CursorHMACKey should have a local dev default")
	}
	if cfg.Quota.PostsPerDay != 100 || cfg.Quota.NewAccountPostsPerDay != 20 {
		t.Errorf("unexpected quota defaults: %+v", cfg.Quota)
	}
	if cfg.RateLimit.PerUserPerMinute != 60 {
		t.Errorf("RateLimit.PerUserPerMinute = %d, want 60", cfg.RateLimit.PerUserPerMinute)
	}
	if cfg.RateLimit.PreAuthIPPerMinute != 120 {
		t.Errorf("RateLimit.PreAuthIPPerMinute = %d, want 120 (M1 default)", cfg.RateLimit.PreAuthIPPerMinute)
	}
	if len(cfg.CORSAllowedOrigins) == 0 {
		t.Error("expected CORS to default on for local dev origins")
	}
	if cfg.TrustedProxyHops != 1 {
		t.Errorf("TrustedProxyHops = %d, want 1 (default: current/original rightmost-entry behavior)", cfg.TrustedProxyHops)
	}
}

func TestLoad_TrustedProxyHopsOverride(t *testing.T) {
	clearEnv(t)
	t.Setenv("TRUSTED_PROXY_HOPS", "2")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.TrustedProxyHops != 2 {
		t.Errorf("TrustedProxyHops = %d, want 2", cfg.TrustedProxyHops)
	}
}

func TestLoad_InvalidTrustedProxyHops(t *testing.T) {
	clearEnv(t)
	t.Setenv("TRUSTED_PROXY_HOPS", "not-an-int")
	if _, err := Load(); err == nil {
		t.Fatal("expected error for invalid TRUSTED_PROXY_HOPS")
	}
}

func TestLoad_PreAuthIPPerMinuteOverride(t *testing.T) {
	clearEnv(t)
	t.Setenv("RATE_LIMIT_PRE_AUTH_IP_PER_MIN", "42")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.RateLimit.PreAuthIPPerMinute != 42 {
		t.Errorf("RateLimit.PreAuthIPPerMinute = %d, want 42", cfg.RateLimit.PreAuthIPPerMinute)
	}
}

func TestLoad_ProjectIDFallbacks(t *testing.T) {
	tests := []struct {
		name string
		env  string
		val  string
	}{
		{"GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT", "dzeroth-dev"},
		{"GCP_PROJECT_ID", "GCP_PROJECT_ID", "dzeroth-dev"},
		{"GCP_PROJECT", "GCP_PROJECT", "dzeroth-dev"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.env, tt.val)
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if cfg.ProjectID != tt.val {
				t.Errorf("ProjectID = %q, want %q", cfg.ProjectID, tt.val)
			}
		})
	}
}

func TestLoad_ProdRequiresInternalOIDC(t *testing.T) {
	base := func(t *testing.T) {
		t.Helper()
		clearEnv(t)
		t.Setenv("ENV", "prod")
		t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-prod")
		t.Setenv("CURSOR_HMAC_KEY", "prod-secret")
	}

	t.Run("both unset", func(t *testing.T) {
		base(t)
		if _, err := Load(); err == nil {
			t.Fatal("expected error when INTERNAL_OIDC_AUDIENCE/INTERNAL_OIDC_ALLOWED_EMAILS are unset in prod")
		}
	})
	t.Run("audience unset", func(t *testing.T) {
		base(t)
		t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "sa@x.iam.gserviceaccount.com")
		if _, err := Load(); err == nil {
			t.Fatal("expected error when INTERNAL_OIDC_AUDIENCE is unset in prod")
		}
	})
	t.Run("allowed emails unset", func(t *testing.T) {
		base(t)
		t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
		if _, err := Load(); err == nil {
			t.Fatal("expected error when INTERNAL_OIDC_ALLOWED_EMAILS is unset in prod")
		}
	})
	t.Run("both set", func(t *testing.T) {
		base(t)
		t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
		t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "sa@x.iam.gserviceaccount.com")
		if _, err := Load(); err != nil {
			t.Fatalf("Load() error = %v, want nil once both are set", err)
		}
	})
}

func TestLoad_CORSOffByDefaultOutsideLocal(t *testing.T) {
	clearEnv(t)
	t.Setenv("ENV", "dev")
	t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-dev")
	t.Setenv("CURSOR_HMAC_KEY", "dev-secret")
	t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
	t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "sa@x.iam.gserviceaccount.com")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if len(cfg.CORSAllowedOrigins) != 0 {
		t.Errorf("CORSAllowedOrigins = %v, want empty (off) outside local with no CORS_ALLOWED_ORIGINS set", cfg.CORSAllowedOrigins)
	}
	if cfg.Port != "8080" {
		t.Errorf("Port = %q, want 8080 outside local", cfg.Port)
	}

	t.Setenv("CORS_ALLOWED_ORIGINS", "https://app.example.com, https://admin.example.com")
	cfg2, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if len(cfg2.CORSAllowedOrigins) != 2 {
		t.Fatalf("CORSAllowedOrigins = %v, want 2 entries", cfg2.CORSAllowedOrigins)
	}
}

func TestLoad_ProdRequiresProjectID(t *testing.T) {
	clearEnv(t)
	t.Setenv("ENV", "prod")
	if _, err := Load(); err == nil {
		t.Fatal("expected error when FIREBASE_PROJECT_ID is unset in prod")
	}
}

func TestLoad_ProdRequiresCursorKey(t *testing.T) {
	clearEnv(t)
	t.Setenv("ENV", "prod")
	t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-prod")
	if _, err := Load(); err == nil {
		t.Fatal("expected error when CURSOR_HMAC_KEY is unset in prod")
	}
}

func TestLoad_InvalidDegradedMode(t *testing.T) {
	clearEnv(t)
	t.Setenv("DEGRADED_MODE", "bogus")
	if _, err := Load(); err == nil {
		t.Fatal("expected error for invalid DEGRADED_MODE")
	}
}

func TestLoad_InvalidAppCheckMode(t *testing.T) {
	clearEnv(t)
	t.Setenv("APP_CHECK_MODE", "bogus")
	if _, err := Load(); err == nil {
		t.Fatal("expected error for invalid APP_CHECK_MODE")
	}
}

func TestLoad_InvalidDuration(t *testing.T) {
	clearEnv(t)
	t.Setenv("SHUTDOWN_TIMEOUT", "not-a-duration")
	if _, err := Load(); err == nil {
		t.Fatal("expected error for invalid duration")
	}
}

func TestLoad_InvalidInt(t *testing.T) {
	clearEnv(t)
	t.Setenv("QUOTA_POSTS_PER_DAY", "not-an-int")
	if _, err := Load(); err == nil {
		t.Fatal("expected error for invalid int")
	}
}

func TestLoad_Overrides(t *testing.T) {
	clearEnv(t)
	t.Setenv("ENV", "dev")
	t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-dev")
	t.Setenv("CURSOR_HMAC_KEY", "dev-secret")
	t.Setenv("PORT", "9090")
	t.Setenv("DEGRADED_MODE", "readonly")
	t.Setenv("APP_CHECK_MODE", "enforce")
	t.Setenv("CACHE_TTL", "30s")
	t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
	t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "a@x.iam.gserviceaccount.com, b@x.iam.gserviceaccount.com")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.ProjectID != "dzeroth-dev" {
		t.Errorf("ProjectID = %q", cfg.ProjectID)
	}
	if cfg.Port != "9090" {
		t.Errorf("Port = %q", cfg.Port)
	}
	if cfg.Degraded != DegradedReadonly {
		t.Errorf("Degraded = %q", cfg.Degraded)
	}
	if cfg.AppCheck != AppCheckEnforce {
		t.Errorf("AppCheck = %q", cfg.AppCheck)
	}
	if cfg.CacheTTL != 30*time.Second {
		t.Errorf("CacheTTL = %v", cfg.CacheTTL)
	}
	if len(cfg.InternalOIDCAllowedEmails) != 2 {
		t.Fatalf("InternalOIDCAllowedEmails = %v", cfg.InternalOIDCAllowedEmails)
	}
}

// TestLoad_CacheTTLGuard (ADR-0009 T33): CACHE_TTL must stay <= 60 s, below the 120 s deletion start gate.
func TestLoad_CacheTTLGuard(t *testing.T) {
	tests := []struct {
		name    string
		ttl     string // "" = unset (default)
		wantErr bool
	}{
		{"default", "", false},
		{"boundary 60s ok", "60s", false},
		{"61s rejected", "61s", true},
		{"120s rejected", "120s", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			clearEnv(t)
			if tc.ttl != "" {
				t.Setenv("CACHE_TTL", tc.ttl)
			}
			cfg, err := Load()
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				for _, want := range []string{"CACHE_TTL", "60s", "120s"} {
					if !strings.Contains(err.Error(), want) {
						t.Errorf("error %q does not mention %q", err, want)
					}
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if cfg.CacheTTL > MaxCacheTTL {
				t.Errorf("CacheTTL = %v", cfg.CacheTTL)
			}
		})
	}
}

// TestLoad_FeatureGraphDefaults (ADR-0008 D6 rollout plan): off in prod, on in dev and local by default.
func TestLoad_FeatureGraphDefaults(t *testing.T) {
	tests := []struct {
		name string
		env  string
		want flags.Mode
	}{
		{"local", "local", flags.On},
		{"dev", "dev", flags.On},
		{"prod", "prod", flags.Off},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("ENV", tt.env)
			if tt.env != "local" {
				t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-x")
				t.Setenv("CURSOR_HMAC_KEY", "x-secret")
				t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
				t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "sa@x.iam.gserviceaccount.com")
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if cfg.FeatureGraph.Mode != tt.want {
				t.Errorf("FeatureGraph.Mode = %q, want %q", cfg.FeatureGraph.Mode, tt.want)
			}
			if cfg.FeatureGraph.Name != "graph" {
				t.Errorf("FeatureGraph.Name = %q, want graph", cfg.FeatureGraph.Name)
			}
		})
	}
}

func TestLoad_FeatureGraphInvalidModeFailsFast(t *testing.T) {
	clearEnv(t)
	t.Setenv("FEATURE_GRAPH", "maybe")
	if _, err := Load(); err == nil {
		t.Fatal("expected an error for an invalid FEATURE_GRAPH value")
	}
}

func TestLoad_FeatureGraphOverride(t *testing.T) {
	clearEnv(t)
	t.Setenv("FEATURE_GRAPH", "allowlist")
	t.Setenv("FEATURE_GRAPH_ALLOWLIST", "uid-a,uid-b")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureGraph.Mode != flags.Allowlist {
		t.Errorf("FeatureGraph.Mode = %q, want allowlist", cfg.FeatureGraph.Mode)
	}
	if _, ok := cfg.FeatureGraph.Allowlist["uid-a"]; !ok {
		t.Error("expected uid-a in FeatureGraph.Allowlist")
	}
}

// TestLoad_GraphQuotaAndRateLimitDefaults locks in the ADR-0008 D7 numbers.
func TestLoad_GraphQuotaAndRateLimitDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Quota.BlocksPerDay != 200 {
		t.Errorf("Quota.BlocksPerDay = %d, want 200", cfg.Quota.BlocksPerDay)
	}
	if cfg.Quota.NewAccountBlocksPerDay != 50 {
		t.Errorf("Quota.NewAccountBlocksPerDay = %d, want 50", cfg.Quota.NewAccountBlocksPerDay)
	}
	if cfg.RateLimit.GraphFollowPerMinute != 30 {
		t.Errorf("RateLimit.GraphFollowPerMinute = %d, want 30", cfg.RateLimit.GraphFollowPerMinute)
	}
	if cfg.RateLimit.GraphBlockPerMinute != 20 {
		t.Errorf("RateLimit.GraphBlockPerMinute = %d, want 20", cfg.RateLimit.GraphBlockPerMinute)
	}
	if cfg.RateLimit.GraphListPerMinute != 20 {
		t.Errorf("RateLimit.GraphListPerMinute = %d, want 20", cfg.RateLimit.GraphListPerMinute)
	}
	if cfg.RateLimit.GraphListCallsPerDay != 100 {
		t.Errorf("RateLimit.GraphListCallsPerDay = %d, want 100", cfg.RateLimit.GraphListCallsPerDay)
	}
	if cfg.RateLimit.GraphMutationsPerDay != 500 {
		t.Errorf("RateLimit.GraphMutationsPerDay = %d, want 500", cfg.RateLimit.GraphMutationsPerDay)
	}
	if cfg.RateLimit.ReadBudgetPerUIDPerDay != 2000 || cfg.RateLimit.ReadBudgetPerIPNoProfilePerDay != 500 || cfg.RateLimit.CheckHandleCallsPerDay != 100 {
		t.Errorf("read budget defaults = %d/%d/%d, want 2000/500/100",
			cfg.RateLimit.ReadBudgetPerUIDPerDay, cfg.RateLimit.ReadBudgetPerIPNoProfilePerDay, cfg.RateLimit.CheckHandleCallsPerDay)
	}
	if cfg.RateLimit.AccountOpsCallsPerDay != 20 {
		t.Errorf("RateLimit.AccountOpsCallsPerDay = %d, want 20 (ADR-0010 D5 A6)", cfg.RateLimit.AccountOpsCallsPerDay)
	}
	// R-N8: CheckHandleAvailability raised from 10 to 20/min.
	if cfg.RateLimit.CheckHandlePerUserPerMinute != 20 {
		t.Errorf("RateLimit.CheckHandlePerUserPerMinute = %d, want 20", cfg.RateLimit.CheckHandlePerUserPerMinute)
	}
}

func TestMustLoad_PanicsOnError(t *testing.T) {
	clearEnv(t)
	t.Setenv("ENV", "prod")
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected MustLoad to panic")
		}
	}()
	MustLoad()
}

// m3: a zero or negative read-budget / check-handle cap would lock every uid out after one call, so Load
// rejects it instead of treating it as "disabled".
func TestLoad_RejectsNonPositiveReadBudgetCaps(t *testing.T) {
	for _, key := range []string{"READ_BUDGET_PER_UID_PER_DAY", "READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY", "CHECK_HANDLE_CALLS_PER_DAY",
		"ACCOUNT_OPS_CALLS_PER_DAY"} {
		for _, val := range []string{"0", "-5"} {
			t.Run(key+"="+val, func(t *testing.T) {
				clearEnv(t)
				t.Setenv(key, val)
				_, err := Load()
				if err == nil || !strings.Contains(err.Error(), key) {
					t.Fatalf("Load() error = %v, want an error naming %s", err, key)
				}
			})
		}
	}
	clearEnv(t)
	t.Setenv("READ_BUDGET_PER_UID_PER_DAY", "1")
	if _, err := Load(); err != nil {
		t.Fatalf("a positive cap must load: %v", err)
	}
}

// TestLoad_AuthEmulator (ADR-0010 D5 A10): AuthEmulator mirrors FIREBASE_AUTH_EMULATOR_HOST, and Load refuses the
// variable in dev and prod, where the Admin SDK would accept unsigned emulator tokens.
func TestLoad_AuthEmulator(t *testing.T) {
	tests := []struct {
		name        string
		env         string
		host        string
		wantErr     bool
		wantEmulate bool
	}{
		{"local, unset", "local", "", false, false},
		{"local, set", "local", "127.0.0.1:9099", false, true},
		{"dev, unset", "dev", "", false, false},
		{"dev, set", "dev", "127.0.0.1:9099", true, false},
		{"prod, unset", "prod", "", false, false},
		{"prod, set", "prod", "127.0.0.1:9099", true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("ENV", tt.env)
			if tt.env != "local" {
				t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-"+tt.env)
				t.Setenv("CURSOR_HMAC_KEY", "secret")
				t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
				t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "sa@x.iam.gserviceaccount.com")
			}
			if tt.host != "" {
				t.Setenv("FIREBASE_AUTH_EMULATOR_HOST", tt.host)
			}
			cfg, err := Load()
			if (err != nil) != tt.wantErr {
				t.Fatalf("Load() error = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && cfg.AuthEmulator != tt.wantEmulate {
				t.Errorf("AuthEmulator = %v, want %v", cfg.AuthEmulator, tt.wantEmulate)
			}
		})
	}
}
