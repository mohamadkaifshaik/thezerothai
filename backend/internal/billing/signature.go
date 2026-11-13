package billing

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// NewSignedWebhookHandler authenticates the exact wire bytes before parsing.
// Durable event IDs remain necessary: timestamp validation alone cannot dedupe
// legitimate retries within the acceptance window.
func NewSignedWebhookHandler(inbox EventInbox, authorization, secret string, env Environment, appIDs []string, now func() time.Time) (http.Handler, error) {
	if len(secret) < 32 {
		return nil, ErrInvalidInput
	}
	next, err := NewWebhookHandler(inbox, authorization, env, appIDs)
	if err != nil {
		return nil, err
	}
	if now == nil {
		now = time.Now
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 256*1024))
		if err != nil {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
			return
		}
		if !validSignature(r.Header.Values("X-RevenueCat-Webhook-Signature"), body, secret, now()) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		next.ServeHTTP(w, r)
	}), nil
}

func validSignature(headers []string, body []byte, secret string, now time.Time) bool {
	if len(headers) != 1 {
		return false
	}
	fields := strings.Split(headers[0], ",")
	if len(fields) != 2 {
		return false
	}
	values := make(map[string]string, 2)
	for _, field := range fields {
		key, value, ok := strings.Cut(strings.TrimSpace(field), "=")
		if !ok || (key != "t" && key != "v1") || values[key] != "" || value == "" {
			return false
		}
		values[key] = value
	}
	ts, err := strconv.ParseInt(values["t"], 10, 64)
	if err != nil || ts <= 0 || ts < now.Add(-5*time.Minute).Unix() || ts > now.Add(5*time.Minute).Unix() {
		return false
	}
	sig, err := hex.DecodeString(values["v1"])
	if err != nil || len(sig) != sha256.Size {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(values["t"] + "."))
	mac.Write(body)
	return hmac.Equal(sig, mac.Sum(nil))
}
