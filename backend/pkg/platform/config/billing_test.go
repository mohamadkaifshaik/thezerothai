package config

import (
	"fmt"
	"strings"
	"testing"
)

func TestBillingSandboxIsLocalOnlyAndRedacted(t *testing.T) {
	t.Setenv("BILLING_SANDBOX_ENABLED", "true")
	t.Setenv("REVENUECAT_SECRET_API_KEY", "sk_test_fixture_not_a_real_key")
	for _, env := range []string{"dev", "prod"} {
		if _, err := loadBillingSandbox(env); err == nil {
			t.Fatal("sandbox accepted nonlocal environment")
		}
	}
	c, err := loadBillingSandbox("local")
	if err != nil || !c.Enabled {
		t.Fatal("local sandbox configuration rejected")
	}
	if strings.Contains(fmt.Sprint(c), "sk_test") {
		t.Fatal("configuration leaked secret")
	}
	t.Setenv("REVENUECAT_SECRET_API_KEY", "test_public_sdk_key")
	if _, err := loadBillingSandbox("local"); err == nil {
		t.Fatal("public SDK key accepted for backend")
	}
}
