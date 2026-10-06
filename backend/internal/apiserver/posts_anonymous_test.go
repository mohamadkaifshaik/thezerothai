package apiserver

import (
	"os"
	"strings"
	"testing"
)

// TestPostsAllowAnonymousIsWiredFromAuthEmulator (T8, ADR-0010 D5 A10): CreatePost may accept anonymous sign-ins
// only through an option wired from cfg.AuthEmulator in Build, never from a request or a global. Build needs a
// live Firestore/Auth, so this pins the wiring in source; posts' own tests pin the default (false) and the
// option's effect.
func TestPostsAllowAnonymousIsWiredFromAuthEmulator(t *testing.T) {
	src, err := os.ReadFile("apiserver.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	if got := strings.Count(s, "posts.WithAllowAnonymous("); got != 1 {
		t.Fatalf("apiserver.go has %d posts.WithAllowAnonymous calls, want exactly 1", got)
	}
	if !strings.Contains(s, "posts.WithAllowAnonymous(cfg.AuthEmulator)") {
		t.Fatal("posts.WithAllowAnonymous must be wired from cfg.AuthEmulator")
	}
}
