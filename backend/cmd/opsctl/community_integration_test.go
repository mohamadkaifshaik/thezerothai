//go:build integration

package main

import (
	"bytes"
	"context"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// End-to-end emulator test of the W5-29 levers: the real run() flag handling and output over the real communities, posts and (for the
// reports) fake report store. The cost line is the budget assertion.
func TestCommunity_Integration_CLI(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	const cid = "0000000000000005555"
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	if _, err := client.Collection("communities").Doc(cid).Set(ctx, map[string]any{
		"name": "Cats", "description": "d", "rules": []any{}, "ownerId": "u-owner", "moderatorIds": []string{},
		"memberCount": 1, "status": "ACTIVE", "visibility": "PUBLIC", "recentRemovals": []any{}, "modlog": []any{}, "modlogSeq": 0,
		"createdAt": now.Add(-time.Hour), "updatedAt": now.Add(-time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Collection("communities").Doc(cid).Collection("communityMembers").Doc("u-owner").Set(ctx, map[string]any{"uid": "u-owner", "state": "JOINED", "joinedAt": now.Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Collection("communityMemberships").Doc("u-owner").Set(ctx, map[string]any{
		"joined": []string{cid}, "owned": []string{cid}, "banned": []string{}, "modlogged": []string{}, "updatedAt": now,
	}); err != nil {
		t.Fatal(err)
	}
	crepo := communities.NewFirestoreRepo(client, nil)
	runCLI := func(args ...string) (code int, stdout, stderr string) {
		open := func(context.Context, string) (*backends, error) {
			return &backends{communities: crepo, removals: crepo, close: func() {}}, nil
		}
		var out, errOut bytes.Buffer
		code = run(ctx, args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return now })
		return code, out.String(), errOut.String()
	}
	status := func() string {
		snap, err := client.Collection("communities").Doc(cid).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		s, _ := snap.DataAt("status")
		return s.(string)
	}
	steps := []struct {
		name   string
		args   []string
		want   []string
		status string
	}{
		{"suspend", []string{"community", "suspend", cid}, []string{"suspended: community_hash=", "wrote=true", "cost: reads=1 writes=1"}, "SUSPENDED"},
		{"suspend again", []string{"community", "suspend", cid}, []string{"already suspended", "wrote=false", "cost: reads=1 writes=0"}, "SUSPENDED"},
		{"archive of a suspended one is refused", []string{"community", "archive", cid}, nil, "SUSPENDED"},
		{"dry-run restore", []string{"community", "restore", cid, "--dry-run"}, []string{"currently SUSPENDED", "cost: reads=1 writes=0"}, "SUSPENDED"},
		{"restore", []string{"community", "restore", cid}, []string{"restored: community_hash=", "status=ACTIVE", "wrote=true", "cost: reads=1 writes=1"}, "ACTIVE"},
		{"restore again", []string{"community", "restore", cid}, []string{"not suspended", "wrote=false", "cost: reads=1 writes=0"}, "ACTIVE"},
		{"archive", []string{"community", "archive", cid}, []string{"archived: community_hash=", "wrote=true", "cost: reads=3 writes=2"}, "ARCHIVED"},
		{"archive again", []string{"community", "archive", cid}, []string{"already ownerless", "wrote=false", "cost: reads=1 writes=0"}, "ARCHIVED"},
	}
	for _, s := range steps {
		_, out, errOut := runCLI(append(s.args, "--project", project)...)
		for _, w := range s.want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: output lacks %q:\nstdout=%s\nstderr=%s", s.name, w, out, errOut)
			}
		}
		if got := status(); got != s.status {
			t.Errorf("%s: status = %s, want %s", s.name, got, s.status)
		}
		nameSnap, err := client.Collection("communities").Doc(cid).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if n, _ := nameSnap.DataAt("name"); n != "Cats" {
			t.Errorf("%s: name = %v (the writes are field-level)", s.name, n)
		}
	}

	// A missing community is refused with exit 1 and nothing is created.
	code, _, errOut := runCLI("community", "suspend", "0000000000000009999", "--project", project)
	if code != 1 || !strings.Contains(errOut, "no such community") {
		t.Errorf("missing: code=%d stderr=%q", code, errOut)
	}
	if _, err := client.Collection("communities").Doc("0000000000000009999").Get(ctx); err == nil {
		t.Error("a suspend of a missing community created it")
	}
}

// takedown-post of a community post over the real posts and communities repositories: the post is TAKEN_DOWN and the community's
// recentRemovals lists it (so the next community refresh answers it in removed_ids); the append is 1 read and 1 write, and a repeat writes
// nothing. suspend-user's hide loop does the same once per community per page.
func TestTakedownAndSuspend_Integration_CommunityRemovals(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	const cidA, cidB = "0000000000000006001", "0000000000000006002"
	for _, c := range []string{cidA, cidB} {
		if _, err := client.Collection("communities").Doc(c).Set(ctx, map[string]any{
			"name": "C", "description": "", "rules": []any{}, "ownerId": "u-owner", "moderatorIds": []string{}, "memberCount": 1,
			"status": "ACTIVE", "visibility": "PUBLIC", "recentRemovals": []any{}, "modlog": []any{}, "modlogSeq": 0,
			"createdAt": now.Add(-time.Hour), "updatedAt": now.Add(-time.Hour),
		}); err != nil {
			t.Fatal(err)
		}
	}
	seed := func(id, author, cid string, ms int64) {
		d := map[string]any{"authorId": author, "kind": "POST", "text": "t", "createdAt": time.UnixMilli(ms).UTC(), "visibility": "PUBLIC"}
		if cid != "" {
			d["communityId"] = cid
		}
		if _, err := client.Collection("posts").Doc(id).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	const p1, p2, p3, p4 = "0000000000000007001", "0000000000000007002", "0000000000000007003", "0000000000000007004"
	base := int64(1_700_000_000_000)
	seed(p1, "u-bad", cidA, base+1000)
	seed(p2, "u-bad", cidA, base+2000)
	seed(p3, "u-bad", cidB, base+3000)
	seed(p4, "u-bad", "", base+4000)

	prepo := posts.NewFirestoreRepo(client)
	crepo := communities.NewFirestoreRepo(client, nil)
	runCLI := func(args ...string) (int, string, string) {
		open := func(context.Context, string) (*backends, error) {
			return &backends{moderator: prepo, removals: crepo, communities: crepo, accounts: &fakeAccounts{}, close: func() {},
				sleep: func(context.Context, time.Duration) error { return nil }}, nil
		}
		var out, errOut bytes.Buffer
		code := run(ctx, args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return now })
		return code, out.String(), errOut.String()
	}
	removals := func(cid string) []string {
		c, err := crepo.Get(ctx, cid)
		if err != nil {
			t.Fatal(err)
		}
		var ids []string
		for _, r := range c.RecentRemovals {
			ids = append(ids, r.PostID)
		}
		return ids
	}

	code, out, errOut := runCLI("takedown-post", "--post", p1, "--project", project)
	if code != 0 || !strings.Contains(out, "community removal log: communities=1 entries=1 missing=0") {
		t.Fatalf("takedown: code=%d out=%s err=%s", code, out, errOut)
	}
	// Takedown 1 read + 2 writes, the append 1 read + 1 write.
	if !strings.Contains(out, "cost: reads=2 writes=3") {
		t.Errorf("takedown cost: %s", out)
	}
	if got := removals(cidA); !slices.Equal(got, []string{p1}) {
		t.Fatalf("removals(A) = %v", got)
	}
	code, out, _ = runCLI("takedown-post", "--post", p1, "--project", project)
	if code != 0 || !strings.Contains(out, "cost: reads=2 writes=0") || strings.Contains(out, "community removal log") {
		t.Errorf("repeat: code=%d out=%s", code, out)
	}

	// suspend-user: p1 is already hidden and listed (not appended again), p2 and p3 are new, p4 is a plain post.
	code, out, errOut = runCLI("suspend-user", "--uid", "u-bad", "--project", project)
	if code != 0 {
		t.Fatalf("suspend-user: code=%d out=%s err=%s", code, out, errOut)
	}
	if !strings.Contains(out, "community removal log: communities=2 entries=2 missing=0") {
		t.Errorf("suspend-user out: %s", out)
	}
	if got := removals(cidA); !slices.Equal(got, []string{p1, p2}) {
		t.Errorf("removals(A) = %v, want [p1 p2]", got)
	}
	if got := removals(cidB); !slices.Equal(got, []string{p3}) {
		t.Errorf("removals(B) = %v, want [p3]", got)
	}

	// A re-run lists the community posts again (already hidden) but every append finds them listed: nothing written, no log line.
	code, out, _ = runCLI("suspend-user", "--uid", "u-bad", "--project", project)
	if code != 0 || strings.Contains(out, "community removal log") {
		t.Errorf("re-run: code=%d out=%s", code, out)
	}
	if got := removals(cidA); !slices.Equal(got, []string{p1, p2}) {
		t.Errorf("removals(A) after re-run = %v", got)
	}
}
