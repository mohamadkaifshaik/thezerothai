package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// W5-52: `opsctl community loghash` prints the hashes the API puts on its request lines. Not parallel: the log key is process-wide.

func TestCommunityLogHash_RoundTripAndKeyDependence(t *testing.T) {
	post := "0000000000000000611"
	run := func(key string, args ...string) (string, error) {
		var out, errOut bytes.Buffer
		err := communityLogHash(args, key, &out, &errOut)
		return out.String(), err
	}
	out, err := run("key-one", "--community", testCommunityID, "--post", post, "--user", "u1")
	if err != nil {
		t.Fatal(err)
	}
	// the same functions the service calls, under the same key
	for _, w := range []string{
		"community_hash=" + logger.HashCommunity(testCommunityID),
		"post_hash=" + logger.HashPost(post),
		"target_hash=" + logger.HashTarget("u1"),
		"uid_hash=" + logger.HashUID("u1"),
	} {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
	other, err := run("key-two", "--community", testCommunityID)
	if err != nil {
		t.Fatal(err)
	}
	if other == "community_hash="+logger.HashUID(testCommunityID)+"\n" || strings.Contains(out, strings.TrimSpace(other)) {
		t.Errorf("another key printed the same community_hash: %q vs %q", other, out)
	}
	if strings.Contains(out, testCommunityID) || strings.Contains(out, logger.HashUID(testCommunityID)) {
		t.Errorf("output carries the raw or unkeyed id:\n%s", out)
	}
}

func TestCommunityLogHash_Refusals(t *testing.T) {
	tests := []struct {
		name string
		key  string
		args []string
		want string
	}{
		{"nothing asked", "k", nil, "at least one of"},
		{"no key", "", []string{"--community", testCommunityID}, "CURSOR_HMAC_KEY"},
		{"short community", "k", []string{"--community", "12"}, "19 digits"},
		{"bad post", "k", []string{"--post", "x"}, "19 digits"},
		{"bad user", "k", []string{"--user", "a_b"}, "valid user id"},
		{"stray argument", "k", []string{"--community", testCommunityID, "extra"}, "unexpected argument"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			err := communityLogHash(tt.args, tt.key, &out, &errOut)
			if err == nil || !strings.Contains(err.Error(), tt.want) || out.Len() != 0 {
				t.Errorf("err=%v out=%q, want error containing %q and no output", err, out.String(), tt.want)
			}
		})
	}
}

func TestCommunityHashForAudit_KeyedOrMarker(t *testing.T) {
	t.Setenv(cursorKeyEnv, "")
	if got := communityHashForAudit(testCommunityID); got != "unavailable(set-CURSOR_HMAC_KEY)" {
		t.Errorf("no key: %q, want the marker", got)
	}
	t.Setenv(cursorKeyEnv, "key-one")
	if got := communityHashForAudit(testCommunityID); got != logger.HashCommunity(testCommunityID) || got == logger.HashUID(testCommunityID) {
		t.Errorf("keyed: %q", got)
	}
}

func TestCommunityLogHash_ThroughRun(t *testing.T) {
	t.Setenv(cursorKeyEnv, "key-one")
	code, out, errOut := runCommunity(newPlatform(communities.StatusActive, "owner"), &fakeOps{}, "", "community", "loghash", "--community", testCommunityID)
	if code != 0 || !strings.Contains(out, "community_hash="+logger.HashCommunity(testCommunityID)) {
		t.Errorf("code=%d out=%q err=%q", code, out, errOut)
	}
}
