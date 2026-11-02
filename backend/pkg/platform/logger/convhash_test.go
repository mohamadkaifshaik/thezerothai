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

func TestHashPost(t *testing.T) {
	if err := SetConversationKey([]byte("k-one")); err != nil {
		t.Fatal(err)
	}
	id := "1234567890123456789"
	h := HashPost(id)
	if len(h) != 16 || h == HashUID(id) || h == HashConversation(id) || HashPost("") != "" {
		t.Errorf("HashPost = %q: want 16 hex, not the plain or conversation hash", h)
	}
	if err := SetConversationKey([]byte("k-two")); err != nil {
		t.Fatal(err)
	}
	if HashPost(id) == h {
		t.Error("hash does not depend on the key")
	}
}

// W6-56: composite <postId>_<uid> document ids render as HashPost(postId)_HashUID(uid); no plain id, no unkeyed post hash.
func TestRedactErrPostDocs(t *testing.T) {
	t.Parallel()
	const uid = "uidAbc123"
	cases := []struct {
		name string
		docs []string
	}{
		{"one", []string{"7300000000000000001_" + uid}},
		{"two", []string{"7300000000000000001_" + uid, "7300000000000000002_" + uid}},
		{"id without separator is skipped", []string{"nounderscore"}},
		{"empty", []string{""}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var named string
			for _, d := range tc.docs {
				named += " documents/likes/" + d
			}
			msg := RedactErrPostDocs(errors.New("rpc error:"+named), uid, tc.docs...).Error()
			if strings.Contains(msg, uid) {
				t.Fatalf("plain uid in %q", msg)
			}
			for _, d := range tc.docs {
				i := strings.LastIndex(d, "_")
				if i <= 0 {
					continue
				}
				p := d[:i]
				if strings.Contains(msg, p) || strings.Contains(msg, HashUID(p)) {
					t.Fatalf("plain or unkeyed post id in %q", msg)
				}
				if !strings.Contains(msg, HashPost(p)+"_"+HashUID(uid)) {
					t.Fatalf("want HashPost_HashUID in %q", msg)
				}
			}
			if RedactErrPostDocs(nil, uid, tc.docs...) != nil {
				t.Fatal("nil in, nil out")
			}
		})
	}
}

// W5-52: community and target hashes are keyed, domain-separated and 16 hex.
func TestHashCommunityAndTarget(t *testing.T) {
	if err := SetConversationKey([]byte("k-one")); err != nil {
		t.Fatal(err)
	}
	id := "0000000000000000501"
	c, tg := HashCommunity(id), HashTarget(id)
	if len(c) != 16 || len(tg) != 16 || c == tg || c == HashUID(id) || tg == HashUID(id) || c == HashPost(id) || c == HashConversation(id) {
		t.Errorf("community %q target %q: want 16 hex, distinct from each other and from the plain and other keyed hashes", c, tg)
	}
	if HashCommunity("") != "" || HashTarget("") != "" {
		t.Error("empty in, empty out")
	}
	if err := SetConversationKey([]byte("k-two")); err != nil {
		t.Fatal(err)
	}
	if HashCommunity(id) == c || HashTarget(id) == tg {
		t.Error("hash does not depend on the key")
	}
}
