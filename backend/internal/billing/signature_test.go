package billing

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSignedWebhookRejectsTamperingAndReplay(t *testing.T) {
	now := time.Unix(1800000000, 0)
	const secret = "test-signing-secret-01234567890123456789"
	const auth = "test-authorization-01234567890123456789"
	const body = `{"event":{"id":"one","app_id":"app","environment":"SANDBOX","type":"TEST"}}`
	sign := func(at time.Time, payload string) string {
		ts := strconv.FormatInt(at.Unix(), 10)
		mac := hmac.New(sha256.New, []byte(secret))
		mac.Write([]byte(ts + "." + payload))
		return "t=" + ts + ",v1=" + hex.EncodeToString(mac.Sum(nil))
	}
	for _, tc := range []struct {
		name, header, payload, authorization string
		want                                 int
	}{
		{"valid", sign(now, body), body, auth, 200},
		{"tampered", sign(now, body), body + " ", auth, 401},
		{"stale", sign(now.Add(-301*time.Second), body), body, auth, 401},
		{"future", sign(now.Add(301*time.Second), body), body, auth, 401},
		{"missing", "", body, auth, 401},
		{"duplicate", sign(now, body) + ",t=1800000000", body, auth, 401},
		{"missing authorization", sign(now, body), body, "", 401},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			h, err := NewSignedWebhookHandler(inboxFunc(func(context.Context, InboxEvent) error { calls++; return nil }), auth, secret, Sandbox, []string{"app"}, func() time.Time { return now })
			if err != nil {
				t.Fatal(err)
			}
			r := httptest.NewRequest("POST", "/webhook", strings.NewReader(tc.payload))
			r.Header.Set("Authorization", tc.authorization)
			r.Header.Set("X-RevenueCat-Webhook-Signature", tc.header)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Fatalf("status %d, want %d", w.Code, tc.want)
			}
			if tc.want != 200 && calls != 0 {
				t.Fatal("unauthenticated event reached storage")
			}
			if tc.want == 200 && calls != 1 {
				t.Fatal("event not committed")
			}
		})
	}
}
