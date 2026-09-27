package config

import (
	"os"
	"testing"
	"time"
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
