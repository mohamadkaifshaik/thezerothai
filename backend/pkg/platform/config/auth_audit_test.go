package config

import (
	"strings"
	"testing"
)

func auditEnv(t *testing.T, v string) {
	t.Helper()
	clearEnv(t)
	t.Setenv("ENV", "local")
	t.Setenv("AUTH_IDENTITY_AUDIT", v)
}

func TestLoad_AuthIdentityAudit(t *testing.T) {
	tests := []struct {
		name, env string
		want      bool
	}{
		{"default off", "", false},
		{"true", "true", true},
		{"one", "1", true},
		{"upper case", "TRUE", true},
		{"false", "false", false},
		{"zero", "0", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			auditEnv(t, tt.env)
			cfg, err := Load()
			if err != nil {
				t.Fatal(err)
			}
			if cfg.AuthIdentityAudit != tt.want {
				t.Errorf("AuthIdentityAudit = %v, want %v", cfg.AuthIdentityAudit, tt.want)
			}
		})
	}
}

func TestLoad_AuthIdentityAuditInvalid(t *testing.T) {
	auditEnv(t, "maybe")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "AUTH_IDENTITY_AUDIT") {
		t.Fatalf("Load() error = %v, want it to name AUTH_IDENTITY_AUDIT", err)
	}
}
