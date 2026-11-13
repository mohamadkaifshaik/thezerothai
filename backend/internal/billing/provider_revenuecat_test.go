package billing

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type billingTransport func(*http.Request) (*http.Response, error)

func (f billingTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestRevenueCatReadback(t *testing.T) {
	b := testBinding()
	now := b.CreatedAt.Add(time.Hour)
	expires, grace := now.Add(time.Hour), now.Add(2*time.Hour)
	yes := true
	for _, tc := range []struct {
		name    string
		edit    func(*rcCustomer)
		want    Tier
		wantErr error
	}{
		{name: "active premium", want: TierPremium},
		{name: "cancellation retains paid interval", want: TierPremium},
		{name: "refund", edit: func(c *rcCustomer) {
			s := c.Subscriptions["premium_monthly"]
			s.Refunded = &now
			c.Subscriptions["premium_monthly"] = s
		}, want: TierFree},
		{name: "production purchase in sandbox", edit: func(c *rcCustomer) {
			s := c.Subscriptions["premium_monthly"]
			no := false
			s.Sandbox = &no
			c.Subscriptions["premium_monthly"] = s
		}, want: TierFree},
		{name: "missing environment", edit: func(c *rcCustomer) {
			s := c.Subscriptions["premium_monthly"]
			s.Sandbox = nil
			c.Subscriptions["premium_monthly"] = s
		}, want: TierFree},
		{name: "foreign store", edit: func(c *rcCustomer) {
			s := c.Subscriptions["premium_monthly"]
			s.Store = "promotional"
			c.Subscriptions["premium_monthly"] = s
		}, want: TierFree},
		{name: "alias transfer", edit: func(c *rcCustomer) { c.OriginalID = "foreign" }, wantErr: ErrOwnership},
		{name: "unknown product", edit: func(c *rcCustomer) {
			e := c.Entitlements[PremiumEntitlement]
			e.Product = "foreign"
			c.Entitlements[PremiumEntitlement] = e
		}, want: TierFree},
		{name: "expired", edit: func(c *rcCustomer) {
			e := c.Entitlements[PremiumEntitlement]
			e.Expires = &now
			c.Entitlements[PremiumEntitlement] = e
		}, want: TierFree},
		{name: "grace", edit: func(c *rcCustomer) {
			e := c.Entitlements[PremiumEntitlement]
			e.Expires = &now
			e.Grace = &grace
			c.Entitlements[PremiumEntitlement] = e
		}, want: TierPremium},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := rcCustomer{OriginalID: b.CustomerID, Entitlements: map[string]rcEntitlement{PremiumEntitlement: {rcInterval: rcInterval{Expires: &expires}, Product: "premium_monthly"}}, Subscriptions: map[string]rcSubscription{"premium_monthly": {rcInterval: rcInterval{Expires: &expires, Grace: &grace}, Sandbox: &yes, Store: "play_store"}}}
			if tc.edit != nil {
				tc.edit(&c)
			}
			body, _ := json.Marshal(map[string]any{"subscriber": c})
			p, err := NewRevenueCatProvider("test-secret", map[string]Product{"premium_monthly": {Store: "play_store", Entitlement: PremiumEntitlement}}, func() time.Time { return now })
			if err != nil {
				t.Fatal(err)
			}
			p.client.Transport = billingTransport(func(r *http.Request) (*http.Response, error) {
				if r.URL.Host != "api.revenuecat.com" || r.URL.Path != "/v1/subscribers/"+b.CustomerID || r.Header.Get("Authorization") != "Bearer test-secret" {
					t.Fatal("incorrect provider request")
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
			})
			s, err := p.GetCustomer(context.Background(), b)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("error=%v", err)
			}
			if err != nil {
				return
			}
			tier, err := EffectiveTier(b, s, now)
			if err != nil || tier != tc.want {
				t.Fatalf("tier=%s error=%v", tier, err)
			}
		})
	}
}

func TestRevenueCatFailureDoesNotBecomeFree(t *testing.T) {
	for _, body := range []string{`{}`, `{"subscriber":null}`, `{`, strings.Repeat("x", 1024*1024+1)} {
		p, _ := NewRevenueCatProvider("test-secret", map[string]Product{"plus": {Store: "play_store", Entitlement: PlusEntitlement}}, nil)
		p.client.Transport = billingTransport(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})
		if _, err := p.GetCustomer(context.Background(), testBinding()); !errors.Is(err, ErrUnavailable) {
			t.Fatal("invalid response accepted")
		}
	}
}

func TestGooglePlayReadbackMatchesBasePlanInsteadOfSubscriptionAlone(t *testing.T) {
	b := testBinding()
	b.Environment = Production
	now := b.CreatedAt.Add(time.Hour)
	end := now.Add(time.Hour)
	no := false
	for _, tc := range []struct {
		name, plan, entitlementPlan string
		sandbox, refunded           bool
		want                        Tier
	}{
		{name: "reviewed monthly plan", plan: "monthly", want: TierPremium},
		{name: "entitlement also supplies plan", plan: "monthly", entitlementPlan: "monthly", want: TierPremium},
		{name: "unreviewed yearly plan", plan: "yearly", want: TierFree},
		{name: "missing plan cannot fall back", want: TierFree},
		{name: "different entitlement plan", plan: "monthly", entitlementPlan: "yearly", want: TierFree},
		{name: "license-test receipt in production", plan: "monthly", sandbox: true, want: TierFree},
		{name: "refunded monthly plan", plan: "monthly", refunded: true, want: TierFree},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := rcCustomer{OriginalID: b.CustomerID,
				Entitlements:  map[string]rcEntitlement{ProEntitlement: {Product: "premium", Plan: tc.entitlementPlan, rcInterval: rcInterval{Expires: &end}}},
				Subscriptions: map[string]rcSubscription{"premium": {Plan: tc.plan, Sandbox: &no, Store: "play_store", rcInterval: rcInterval{Expires: &end}}},
			}
			sub := c.Subscriptions["premium"]
			if tc.sandbox {
				yes := true
				sub.Sandbox = &yes
			}
			if tc.refunded {
				sub.Refunded = &now
			}
			c.Subscriptions["premium"] = sub
			body, _ := json.Marshal(map[string]any{"subscriber": c})
			provider, _ := NewRevenueCatProvider("fixture-secret", map[string]Product{"premium:monthly": {Store: "play_store", Entitlement: ProEntitlement}}, func() time.Time { return now })
			provider.client.Transport = billingTransport(func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
			})
			snapshot, err := provider.GetCustomer(context.Background(), b)
			if err != nil {
				t.Fatal(err)
			}
			tier, err := EffectiveTier(b, snapshot, now)
			if err != nil || tier != tc.want {
				t.Fatalf("tier=%s err=%v", tier, err)
			}
		})
	}
}
