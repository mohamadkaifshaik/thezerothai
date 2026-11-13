package billing

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Product identifies a reviewed store product and its single paid entitlement.
type Product struct{ Store, Entitlement string }

type RevenueCatProvider struct {
	client   *http.Client
	key      string
	products map[string]Product
	now      func() time.Time
}

func NewRevenueCatProvider(key string, products map[string]Product, now func() time.Time) (*RevenueCatProvider, error) {
	if strings.TrimSpace(key) == "" || strings.ContainsAny(key, "\r\n") || len(products) == 0 {
		return nil, ErrInvalidInput
	}
	copyProducts := make(map[string]Product, len(products))
	for id, p := range products {
		if id == "" || p.Store == "" || (p.Entitlement != PlusEntitlement && p.Entitlement != PremiumEntitlement && p.Entitlement != ProEntitlement) {
			return nil, ErrInvalidInput
		}
		copyProducts[id] = p
	}
	if now == nil {
		now = time.Now
	}
	return &RevenueCatProvider{client: &http.Client{Timeout: ProviderRequestTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, key: key, products: copyProducts, now: now}, nil
}

type rcInterval struct {
	Expires *time.Time `json:"expires_date"`
	Grace   *time.Time `json:"grace_period_expires_date"`
}
type rcEntitlement struct {
	rcInterval
	Product string `json:"product_identifier"`
}
type rcSubscription struct {
	rcInterval
	Sandbox  *bool      `json:"is_sandbox"`
	Store    string     `json:"store"`
	Refunded *time.Time `json:"refunded_at"`
}
type rcCustomer struct {
	OriginalID    string                    `json:"original_app_user_id"`
	Entitlements  map[string]rcEntitlement  `json:"entitlements"`
	Subscriptions map[string]rcSubscription `json:"subscriptions"`
}

func intervalEnd(i rcInterval) time.Time {
	if i.Expires == nil {
		return time.Time{}
	} // No lifetime grants in monthly catalog.
	end := *i.Expires
	if i.Grace != nil && i.Grace.After(end) {
		end = *i.Grace
	}
	return end
}

func (p *RevenueCatProvider) GetCustomer(ctx context.Context, b Binding) (Snapshot, error) {
	if !validBinding(b) {
		return Snapshot{}, ErrInvalidInput
	}
	started := p.now().UTC()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.revenuecat.com/v1/subscribers/"+url.PathEscape(b.CustomerID), nil)
	if err != nil {
		return Snapshot{}, ErrUnavailable
	}
	req.Header.Set("Authorization", "Bearer "+p.key)
	req.Header.Set("Accept", "application/json")
	response, err := p.client.Do(req)
	if err != nil {
		return Snapshot{}, ErrUnavailable
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusCreated {
		return Snapshot{}, ErrUnavailable
	}
	const maxResponse = 1024 * 1024
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponse+1))
	if err != nil || len(body) > maxResponse {
		return Snapshot{}, ErrUnavailable
	}
	var envelope struct {
		Subscriber *rcCustomer `json:"subscriber"`
	}
	if json.Unmarshal(body, &envelope) != nil || envelope.Subscriber == nil {
		return Snapshot{}, ErrUnavailable
	}
	c := envelope.Subscriber
	// Transfers/aliases need an explicit ownership policy, never implicit adoption.
	if c.OriginalID != b.CustomerID {
		return Snapshot{}, ErrOwnership
	}
	out := Snapshot{UID: b.UID, CustomerID: b.CustomerID, Environment: b.Environment, VerifiedAt: started}
	for entitlement, e := range c.Entitlements {
		product, known := p.products[e.Product]
		if !known || product.Entitlement != entitlement {
			continue
		}
		s, ok := c.Subscriptions[e.Product]
		if !ok || s.Sandbox == nil || *s.Sandbox != (b.Environment == Sandbox) || s.Store != product.Store || s.Refunded != nil {
			continue
		}
		end, subscriptionEnd := intervalEnd(e.rcInterval), intervalEnd(s.rcInterval)
		if subscriptionEnd.Before(end) {
			end = subscriptionEnd
		}
		if !end.After(started) {
			continue
		}
		out.Grants = append(out.Grants, Grant{Entitlement: entitlement, AccessUntil: end})
	}
	return out, nil
}
