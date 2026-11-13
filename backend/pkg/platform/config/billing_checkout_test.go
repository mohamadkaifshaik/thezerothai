package config

import (
	"strings"
	"testing"
)

func TestRealStoreCheckoutConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name, env, sales, webhooks, environment, products string
		wantError                                         bool
	}{
		{name: "default sales off", env: "dev", webhooks: "true"},
		{name: "production transactions in dev", env: "dev", webhooks: "true", sales: "true"},
		{name: "license testing in dev", env: "dev", webhooks: "true", sales: "true", environment: "SANDBOX"},
		{name: "missing webhook setup", env: "dev", sales: "true", wantError: true},
		{name: "prod rollout not authorized", env: "prod", webhooks: "true", sales: "true", wantError: true},
		{name: "sandbox forbidden in prod", env: "prod", webhooks: "true", environment: "SANDBOX", wantError: true},
		{name: "unknown receipt environment", env: "dev", webhooks: "true", environment: "test", wantError: true},
		{name: "local cannot enable real store", env: "local", webhooks: "true", sales: "true", wantError: true},
		{name: "invalid sales flag", env: "dev", sales: "on", wantError: true},
		{name: "test store cannot become real catalog", env: "dev", webhooks: "true", sales: "true", products: `{"monthly":{"Store":"test_store","Entitlement":"dzeroth_pro"}}`, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("BILLING_WEBHOOK_ENABLED", tc.webhooks)
			t.Setenv("BILLING_PURCHASES_ENABLED", tc.sales)
			t.Setenv("REVENUECAT_PURCHASE_ENVIRONMENT", tc.environment)
			t.Setenv("REVENUECAT_SECRET_API_KEY", "sk_fixture_only")
			t.Setenv("REVENUECAT_WEBHOOK_AUTHORIZATION", strings.Repeat("a", 32))
			t.Setenv("REVENUECAT_WEBHOOK_SIGNING_SECRET", strings.Repeat("b", 32))
			t.Setenv("REVENUECAT_WEBHOOK_APP_IDS", "app-play-fixture")
			products := tc.products
			if products == "" {
				products = `{"premium:monthly":{"Store":"play_store","Entitlement":"dzeroth_pro"}}`
			}
			t.Setenv("REVENUECAT_PRODUCTS_JSON", products)
			got, err := loadBillingWebhook(tc.env)
			if (err != nil) != tc.wantError {
				t.Fatalf("err=%v", err)
			}
			if err == nil && got.PurchasesEnabled != (tc.sales == "true") {
				t.Fatal("checkout gate mismatch")
			}
		})
	}
}
