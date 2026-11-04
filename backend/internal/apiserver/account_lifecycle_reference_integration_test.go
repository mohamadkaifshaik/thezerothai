//go:build integration

package apiserver

// The REFERENCE ACCOUNT (P = 300 posts, O = 100 followees, I = 100 followers, B = Bb = M = 0, E = 1 export), seeded
// through the production RPCs, then exported and deleted over the real chain: the jobs finish and nothing survives.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

const refPosts, refFollowing, refFollowers = 300, 100, 100

func TestAccountLifecycle_ReferenceAccount(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds ~1,000 RPCs")
	}
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, relaxLimits)
	a := e.newUser(t)
	cohort := []string{a.uid}
	for range refFollowing {
		f := e.newUser(t)
		cohort = append(cohort, f.uid)
		e.follow(t, a, f)
	}
	for range refFollowers {
		g := e.newUser(t)
		cohort = append(cohort, g.uid)
		e.follow(t, g, a)
	}
	for i := range refPosts {
		if _, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: fmt.Sprintf("reference-post-%s-%04d", a.uid[:12], i), Text: fmt.Sprintf("reference post %d", i)})); err != nil {
			t.Fatalf("CreatePost %d: %v", i, err)
		}
	}
	e.requireInvariants(t, cohort) // the seed itself is consistent before anything is deleted

	// --- export of the reference account ---
	exp, err := e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "reference-export-key-0001"}))
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range e.pull(t) {
		if m["kind"] == "account_export" {
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("export delivery = %d", code)
			}
		}
	}
	var export map[string]any
	for _, l := range e.jobLines() {
		if l["account_job"] == "export" && l["outcome"] == "done" {
			export = l
		}
	}
	if export == nil {
		t.Fatalf("no export `done` line: %v", e.jobLines())
	}

	// --- deletion ---
	if _, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "reference-delete-key-0001"})); err != nil {
		t.Fatal(err)
	}
	e.pastGate(t, a.uid)
	deliveries := 0
	for _, m := range e.pull(t) {
		if m["kind"] != "account_delete" {
			continue
		}
		for pending := []map[string]any{m}; len(pending) > 0 && deliveries < 50; {
			deliveries++
			code := e.deliver(t, pending[0])
			pending = append(pending, e.pull(t)...)
			if code == http.StatusNoContent {
				pending = pending[1:]
			}
		}
	}
	if deliveries >= 50 {
		t.Fatalf("the delete job did not finish in %d deliveries", deliveries)
	}

	// --- end state ---
	for _, path := range []string{"users/" + a.uid, "graph/" + a.uid, "quotas/" + a.uid, "exports/" + exp.Msg.GetExportId()} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	if present, _ := e.authUser(t, a.uid); present {
		t.Error("the Firebase Auth user survived")
	}
	e.requireNoResidue(t, a.uid)
	e.requireInvariants(t, cohort)
	// Counterparts: every followee lost its one follower, every follower lost its one followee.
	for i, uid := range cohort[1 : 1+refFollowing] {
		if got := intField(t, e, "users/"+uid, "followersCount"); got != 0 {
			t.Fatalf("followee %d followersCount = %d", i, got)
		}
	}
	for i, uid := range cohort[1+refFollowing:] {
		if got := intField(t, e, "users/"+uid, "followingCount"); got != 0 {
			t.Fatalf("follower %d followingCount = %d", i, got)
		}
	}
	for _, l := range e.jobLines() {
		if strings.Contains(fmt.Sprint(l), a.uid) {
			t.Errorf("a job line carries the raw uid: %v", l)
		}
	}
}
