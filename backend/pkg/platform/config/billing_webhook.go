package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

type BillingWebhookProduct struct{ Store, Entitlement string }
type BillingWebhookConfig struct {
	Enabled                                    bool
	PurchasesEnabled                           bool
	Environment                                string
	SecretAPIKey, Authorization, SigningSecret string
	AppIDs                                     []string
	Products                                   map[string]BillingWebhookProduct
}

func (c BillingWebhookConfig) String() string {
	return fmt.Sprintf("billing webhook enabled=%t (secrets redacted)", c.Enabled)
}
func loadBillingWebhook(env string) (BillingWebhookConfig, error) {
	var c BillingWebhookConfig
	sales := os.Getenv("BILLING_PURCHASES_ENABLED")
	if sales != "" && sales != "false" && sales != "true" {
		return c, fmt.Errorf("config: BILLING_PURCHASES_ENABLED must be true or false")
	}
	if sales == "true" && env != "dev" {
		return c, fmt.Errorf("config: real purchase rollout is restricted to ENV=dev")
	}
	v := os.Getenv("BILLING_WEBHOOK_ENABLED")
	if v == "" || v == "false" {
		if sales == "true" {
			return c, fmt.Errorf("config: real purchases require configured production webhooks")
		}
		return c, nil
	}
	if v != "true" || (env != "dev" && env != "prod") {
		return c, fmt.Errorf("config: production billing webhooks require dev or prod")
	}
	c.Enabled = true
	c.PurchasesEnabled = sales == "true"
	c.Environment = os.Getenv("REVENUECAT_PURCHASE_ENVIRONMENT")
	if c.Environment == "" {
		c.Environment = "PRODUCTION"
	}
	if c.Environment != "PRODUCTION" && (c.Environment != "SANDBOX" || env != "dev") {
		return BillingWebhookConfig{}, fmt.Errorf("config: billing environment must be PRODUCTION, or SANDBOX in dev")
	}
	c.SecretAPIKey = os.Getenv("REVENUECAT_SECRET_API_KEY")
	c.Authorization = os.Getenv("REVENUECAT_WEBHOOK_AUTHORIZATION")
	c.SigningSecret = os.Getenv("REVENUECAT_WEBHOOK_SIGNING_SECRET")
	if !strings.HasPrefix(c.SecretAPIKey, "sk_") || len(c.Authorization) < 32 || len(c.SigningSecret) < 32 || strings.ContainsAny(c.SecretAPIKey+c.Authorization+c.SigningSecret, "\r\n") {
		return BillingWebhookConfig{}, fmt.Errorf("config: billing webhook credentials missing or invalid")
	}
	seen := map[string]bool{}
	for _, id := range strings.Split(os.Getenv("REVENUECAT_WEBHOOK_APP_IDS"), ",") {
		id = strings.TrimSpace(id)
		if id == "" || len(id) > 128 || seen[id] {
			return BillingWebhookConfig{}, fmt.Errorf("config: billing webhook app allowlist invalid")
		}
		seen[id] = true
		c.AppIDs = append(c.AppIDs, id)
	}
	if len(c.AppIDs) > 16 {
		return BillingWebhookConfig{}, fmt.Errorf("config: billing webhook app allowlist too large")
	}
	if json.Unmarshal([]byte(os.Getenv("REVENUECAT_PRODUCTS_JSON")), &c.Products) != nil || len(c.Products) == 0 || len(c.Products) > 32 {
		return BillingWebhookConfig{}, fmt.Errorf("config: billing webhook products invalid")
	}
	for id, p := range c.Products {
		if id == "" || len(id) > 256 || (p.Store != "app_store" && p.Store != "play_store") || (p.Entitlement != "dzeroth_pro" && p.Entitlement != "premium_access" && p.Entitlement != "plus_access") {
			return BillingWebhookConfig{}, fmt.Errorf("config: billing webhook production product invalid")
		}
	}
	return c, nil
}
