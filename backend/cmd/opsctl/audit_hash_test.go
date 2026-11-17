package main

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// plainHash is the old, unkeyed uid_hash (hex of the first 8 bytes of SHA-256): what anyone could recompute from an id. No
// opsctl output may print it.
func plainHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}

// testAuditKey is the CURSOR_HMAC_KEY the audit-line tests put in the environment.
const testAuditKey = "test-cursor-hmac-key"

// keyedAuditUIDHash sets CURSOR_HMAC_KEY for the test, installs the same key and returns the uid_hash-style pseudonym of id that
// the API logs under that key: what opsctl's audit lines must print. Callers cannot be parallel (t.Setenv).
func keyedAuditUIDHash(t *testing.T, id string) string {
	t.Helper()
	t.Setenv(cursorKeyEnv, testAuditKey)
	if err := logger.SetConversationKey([]byte(testAuditKey)); err != nil {
		t.Fatal(err)
	}
	return logger.HashUID(id)
}

// The beacon_hash, list_hash and message_hash of the audit lines are the keyed HashUID the API logs for the same id, so an
// operator can find the lines; without CURSOR_HMAC_KEY they are a marker, never a hash under opsctl's random fallback key (which
// matches nothing in the logs). Not parallel: it sets the environment and the logger's process-wide key.
func TestUIDHashForAudit_KeyedOrMarker(t *testing.T) {
	const id = "7300000000000000001"
	tests := []struct {
		name string
		key  string
		want func() string
	}{
		{"no key", "", func() string { return "unavailable(set-CURSOR_HMAC_KEY)" }},
		{"key one", "key-one", func() string { _ = logger.SetConversationKey([]byte("key-one")); return logger.HashUID(id) }},
		{"key two", "key-two", func() string { _ = logger.SetConversationKey([]byte("key-two")); return logger.HashUID(id) }},
	}
	seen := map[string]bool{}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(cursorKeyEnv, tt.key)
			got := uidHashForAudit(id)
			if want := tt.want(); got != want {
				t.Errorf("uidHashForAudit = %q, want %q", got, want)
			}
			if seen[got] {
				t.Errorf("%q printed for two different keys", got)
			}
			seen[got] = true
		})
	}
}

// opsctl installs the API's log key at start when CURSOR_HMAC_KEY is set, so lines its commands log through the modules (a
// purge's uid_hash, the hashes inside redacted errors) match the API's; without it nothing is installed and those lines keep
// the random per-process key. Not parallel: it sets the environment and the logger's process-wide key.
func TestInstallLogKeyFromEnv(t *testing.T) {
	const uid = "AbCdEfGhIjKlMnOpQrStUvWxYz12"
	t.Setenv(cursorKeyEnv, "")
	if installLogKeyFromEnv() {
		t.Fatal("no key in the environment, yet one was installed")
	}
	if err := logger.SetConversationKey([]byte("another-key")); err != nil {
		t.Fatal(err)
	}
	other := logger.HashUID(uid)
	t.Setenv(cursorKeyEnv, testAuditKey)
	if !installLogKeyFromEnv() || !logger.ConversationKeySet() {
		t.Fatal("key from the environment not installed")
	}
	got := logger.HashUID(uid)
	if err := logger.SetConversationKey([]byte(testAuditKey)); err != nil {
		t.Fatal(err)
	}
	if want := logger.HashUID(uid); got != want || got == other || got == plainHash(uid) {
		t.Errorf("HashUID after install = %q, want the API's %q (not %q, not the plain hash)", got, want, other)
	}
}
