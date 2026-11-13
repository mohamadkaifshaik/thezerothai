package billing

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type inboxFunc func(context.Context, InboxEvent) error

func (f inboxFunc) AcceptEvent(c context.Context, e InboxEvent) error { return f(c, e) }

func TestWebhookRequiresAuthenticationAndDurableCommit(t *testing.T) {
	const auth = "test-only-authorization-value-0123456789"
	const body = `{"event":{"id":"event-1","app_id":"app-test","app_user_id":"private-customer","environment":"SANDBOX","type":"INITIAL_PURCHASE"}}`
	for _, tc := range []struct {
		name, auth, body string
		fail             bool
		code, calls      int
	}{
		{"valid", auth, body, false, 200, 1},
		{"forged", "wrong", body, false, 401, 0},
		{"invalid json", auth, "{", false, 400, 0},
		{"wrong environment", auth, strings.Replace(body, "SANDBOX", "PRODUCTION", 1), false, 400, 0},
		{"wrong app", auth, strings.Replace(body, "app-test", "foreign", 1), false, 400, 0},
		{"commit failed", auth, body, true, 503, 1},
		{"oversized", auth, strings.Repeat("x", 256*1024+1), false, 413, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			h, err := NewWebhookHandler(inboxFunc(func(_ context.Context, e InboxEvent) error {
				calls++
				if len(e.BodyHash) != 64 {
					t.Fatal("missing payload hash")
				}
				if tc.fail {
					return errors.New("storage failure")
				}
				return nil
			}), auth, Sandbox, []string{"app-test"})
			if err != nil {
				t.Fatal(err)
			}
			r := httptest.NewRequest(http.MethodPost, "/webhooks/revenuecat", strings.NewReader(tc.body))
			r.Header.Set("Authorization", tc.auth)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.code || calls != tc.calls {
				t.Fatalf("status=%d calls=%d", w.Code, calls)
			}
		})
	}
}
