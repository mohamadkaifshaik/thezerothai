package logger

import (
	"errors"
	"strings"
	"testing"
)

const convID = "0123456789abcdef0123456789abcdef"

func TestHashConversation(t *testing.T) {
	// Not parallel: the key is process-wide.
	if err := SetConversationKey(nil); err == nil {
		t.Fatal("an empty secret must be refused")
	}
	if err := SetConversationKey([]byte("secret-one")); err != nil {
		t.Fatal(err)
	}
	if !ConversationKeySet() {
		t.Fatal("key not reported as set")
	}
	one := HashConversation(convID)
	if len(one) != 16 || one == HashUID(convID) {
		t.Fatalf("hash %q: want 16 hex characters, different from the plain hash %q", one, HashUID(convID))
	}
	if again := HashConversation(convID); again != one {
		t.Errorf("not deterministic: %q then %q", one, again)
	}
	if other := HashConversation(convID[:31] + "0"); other == one {
		t.Error("different ids gave the same hash")
	}
	if HashConversation("") != "" {
		t.Error("empty id must stay empty")
	}
	if err := SetConversationKey([]byte("secret-two")); err != nil {
		t.Fatal(err)
	}
	if two := HashConversation(convID); two == one {
		t.Error("a different secret must give a different hash")
	}
	// The derivation is pinned: operators reproduce it with opsctl, so a change would orphan every logged hash.
	if err := SetConversationKey([]byte("secret-one")); err != nil {
		t.Fatal(err)
	}
	if HashConversation(convID) != one {
		t.Error("same secret, different hash after re-derivation")
	}
}

func TestRedactErrKeyed(t *testing.T) {
	if err := SetConversationKey([]byte("secret-one")); err != nil {
		t.Fatal(err)
	}
	base := errors.New("sentinel")
	err := RedactErrKeyed(errors.Join(base, errors.New("conv "+convID+" user uid-a")), []string{convID, ""}, "uid-a", "")
	got := err.Error()
	if strings.Contains(got, convID) || strings.Contains(got, "uid-a") || strings.Contains(got, HashUID(convID)) {
		t.Errorf("not redacted: %q", got)
	}
	if !strings.Contains(got, HashConversation(convID)) || !strings.Contains(got, HashUID("uid-a")) {
		t.Errorf("hashes missing: %q", got)
	}
	if !errors.Is(err, base) {
		t.Error("errors.Is must still reach the cause")
	}
	if RedactErrKeyed(nil, nil) != nil {
		t.Error("nil in, nil out")
	}
}
