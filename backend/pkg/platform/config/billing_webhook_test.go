package config

import (
	"fmt"
	"strings"
	"testing"
)

func TestProductionWebhookConfigurationFailsClosed(t *testing.T) {
	t.Setenv("BILLING_WEBHOOK_ENABLED", "true")
	t.Setenv("REVENUECAT_SECRET_API_KEY", "sk_fixture_only")
	t.Setenv("REVENUECAT_WEBHOOK_AUTHORIZATION", strings.Repeat("a", 32))
	t.Setenv("REVENUECAT_WEBHOOK_SIGNING_SECRET", strings.Repeat("b", 32))
	t.Setenv("REVENUECAT_WEBHOOK_APP_IDS", "app-production")
	t.Setenv("REVENUECAT_PRODUCTS_JSON", `{"monthly":{"Store":"app_store","Entitlement":"dzeroth_pro"}}`)
	c, err := loadBillingWebhook("prod")
	if err != nil || !c.Enabled {
		t.Fatalf("valid config: %v", err)
	}
	if strings.Contains(fmt.Sprint(c), "sk_fixture") || strings.Contains(fmt.Sprint(c), strings.Repeat("b", 32)) {
		t.Fatal("secret leaked")
	}
	if _, err = loadBillingWebhook("local"); err == nil {
		t.Fatal("production webhook accepted local")
	}
	for _, value := range []string{`{}`, `{"monthly":{"Store":"test_store","Entitlement":"dzeroth_pro"}}`, `{"monthly":{"Store":"app_store","Entitlement":"unknown"}}`} {
		t.Setenv("REVENUECAT_PRODUCTS_JSON", value)
		if _, err = loadBillingWebhook("prod"); err == nil {
			t.Fatal("invalid production catalog accepted")
		}
	}
}
