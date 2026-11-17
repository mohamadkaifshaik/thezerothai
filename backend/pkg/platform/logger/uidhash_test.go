package logger

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// plainHash is the old, unkeyed uid_hash (hex(SHA-256(s))[:16 hex]): anyone holding a uid could recompute it. Tests use it to
// prove that no log pseudonym is that guessable value.
func plainHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}

// HashUID is keyed: the same key gives the same 16-hex pseudonym, another key another one, and it is never the plain SHA-256 a
// log reader could recompute from a public uid, nor the target pseudonym of the same uid (domain separation).
func TestHashUID_Keyed(t *testing.T) {
	// Not parallel: the key is process-wide.
	const uid = "AbCdEfGhIjKlMnOpQrStUvWxYz12"
	tests := []struct {
		name   string
		secret string
	}{
		{"key one", "secret-one"},
		{"key two", "secret-two"},
	}
	seen := map[string]string{}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := SetConversationKey([]byte(tt.secret)); err != nil {
				t.Fatal(err)
			}
			h := HashUID(uid)
			if len(h) != 16 {
				t.Fatalf("HashUID = %q: want 16 hex characters", h)
			}
			if _, err := hex.DecodeString(h); err != nil {
				t.Fatalf("HashUID = %q is not hex: %v", h, err)
			}
			if h == plainHash(uid) {
				t.Fatalf("HashUID = %q is the unkeyed SHA-256 of the uid", h)
			}
			if h == HashTarget(uid) || h == HashConversation(uid) || h == HashPost(uid) || h == HashCommunity(uid) {
				t.Fatalf("HashUID = %q collides with another keyed domain", h)
			}
			if again := HashUID(uid); again != h {
				t.Fatalf("not stable for one key: %q then %q", h, again)
			}
			if HashUID("") != "" {
				t.Fatal("empty uid must stay empty")
			}
			for name, prev := range seen {
				if prev == h {
					t.Fatalf("%s and %s gave the same hash %q", name, tt.name, h)
				}
			}
			seen[tt.name] = h
		})
	}
	// The derivation is pinned: re-installing a key reproduces the hashes logged under it (opsctl relies on this).
	if err := SetConversationKey([]byte("secret-one")); err != nil {
		t.Fatal(err)
	}
	if got := HashUID(uid); got != seen["key one"] {
		t.Errorf("re-derived key one: %q, want %q", got, seen["key one"])
	}
}

// Before SetConversationKey a process (a test binary, a tool that never loads CURSOR_HMAC_KEY) hashes with a random per-process
// key: stable inside the process, reported as not set, and never the plain SHA-256. Installing the real key replaces it.
func TestHashUID_BeforeKeyInstall(t *testing.T) {
	// Not parallel: it clears the process-wide key and restores it afterwards.
	oldKey, oldRandom := convHashKey.Load(), randomConvKey.Load()
	t.Cleanup(func() {
		convHashKey.Store(oldKey)
		randomConvKey.Store(oldRandom)
	})
	convHashKey.Store(nil)
	randomConvKey.Store(false)

	const uid = "AbCdEfGhIjKlMnOpQrStUvWxYz12"
	before := HashUID(uid)
	if before == "" || before == plainHash(uid) || before == uid {
		t.Fatalf("HashUID before key install = %q: want a keyed, non-plain hash", before)
	}
	if ConversationKeySet() {
		t.Fatal("a random fallback key must not be reported as the real key")
	}
	if again := HashUID(uid); again != before {
		t.Fatalf("random fallback key not stable within the process: %q then %q", before, again)
	}

	if err := SetConversationKey([]byte("secret-one")); err != nil {
		t.Fatal(err)
	}
	if !ConversationKeySet() {
		t.Fatal("real key not reported as set")
	}
	after := HashUID(uid)
	if after == before {
		t.Error("installing the real key must replace the random fallback")
	}
	if after == plainHash(uid) {
		t.Error("keyed hash equals the plain hash")
	}
}
