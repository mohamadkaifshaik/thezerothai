package apiserver

// W6-17: the pollVotes TTL is the only thing that removes the vote docs of a deleted poll post (ADR-0029 D8), and the code stamps
// expireAt on them. This guard keeps the Terraform `ttl_fields` entry and the code's field name in step, so a rename on either side
// fails here rather than leaving vote docs for ever. (It reads the module's default; applying it is W6-22.)

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestW617_PollVotesTTLFieldIsInTerraform(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "infra", "terraform", "modules", "firestore", "variables.tf"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)poll_votes_expire_at\s*=\s*\{\s*collection\s*=\s*"([^"]+)"\s*field\s*=\s*"([^"]+)"\s*\}`).FindSubmatch(raw)
	if m == nil {
		t.Fatal("variables.tf has no poll_votes_expire_at entry in ttl_fields (ADR-0029 D9)")
	}
	if string(m[1]) != "pollVotes" || string(m[2]) != "expireAt" {
		t.Errorf("ttl entry = %s.%s, want pollVotes.expireAt", m[1], m[2])
	}
	repo, err := os.ReadFile(filepath.Join("..", "engagement", "repo_polls.go"))
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`firestore:"expireAt"`).Match(repo) || !regexp.MustCompile(`"pollVotes"`).Match(repo) {
		t.Error("engagement/repo_polls.go no longer writes pollVotes.expireAt")
	}
}
