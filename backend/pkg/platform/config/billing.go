package config

import (
	"fmt"
	"os"
	"strings"
)

// BillingSandboxConfig is local-only until production billing rollout is ready.
type BillingSandboxConfig struct {
	Enabled      bool
	SecretAPIKey string
}

func (c BillingSandboxConfig) String() string {
	return fmt.Sprintf("billing sandbox enabled=%t (key redacted)", c.Enabled)
}

func loadBillingSandbox(env string) (BillingSandboxConfig, error) {
	v := os.Getenv("BILLING_SANDBOX_ENABLED")
	if v == "" || v == "false" {
		return BillingSandboxConfig{}, nil
	}
	if v != "true" || env != "local" {
		return BillingSandboxConfig{}, fmt.Errorf("config: billing sandbox requires ENV=local and BILLING_SANDBOX_ENABLED=true")
	}
	key := os.Getenv("REVENUECAT_SECRET_API_KEY")
	if !strings.HasPrefix(key, "sk_") || strings.ContainsAny(key, "\r\n") {
		return BillingSandboxConfig{}, fmt.Errorf("config: billing sandbox requires a RevenueCat secret API key")
	}
	return BillingSandboxConfig{Enabled: true, SecretAPIKey: key}, nil
}
