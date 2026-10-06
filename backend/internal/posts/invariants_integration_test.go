//go:build integration

// invariants_integration_test.go is the reusable posts invariant checker (ADR-0010 D12 / T19, modelled on graph's
// invariants_integration_test.go). The pure checker (postsInvariantViolations) has negative self-tests proving it can
// fail; the Firestore loader backs assertPostsInvariants, which newCreateInstance registers as a t.Cleanup so every
// create/delete emulator scenario ends with a full sweep.
package posts

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"
)

// postsState is a snapshot of the posts module's collections in one Firestore project.
type postsState struct {
	// Users maps uid -> users/{uid}.postsCount (0 when the field is absent). Only uids with a users doc appear.
	Users map[string]int64
	// Posts maps posts doc ID -> its authorId and author.userId snapshot.
	Posts map[string]storedPost
}

type storedPost struct{ AuthorID, SnapshotUserID string }

// postsInvariantViolations implements the posts invariants and returns sorted, human-readable violations; empty
// means consistent.
//
//	P1  users/{u}.postsCount == #posts where authorId == u
//	P2  posts/{id}.author.userId == authorId (the denormalised snapshot belongs to the author)
//
// Posts whose author has no users doc are not flagged: posts tests seed such posts directly, and an account purge
// legitimately leaves counters to the account lifecycle job.
func postsInvariantViolations(st postsState) []string {
	var v []string
	byAuthor := map[string]int64{}
	for id, p := range st.Posts {
		byAuthor[p.AuthorID]++
		if p.SnapshotUserID != p.AuthorID {
			v = append(v, fmt.Sprintf("P2: posts/%s has authorId=%q but author.userId=%q", id, p.AuthorID, p.SnapshotUserID))
		}
	}
	for uid, n := range st.Users {
		if got := byAuthor[uid]; n != got {
			v = append(v, fmt.Sprintf("P1: users/%s.postsCount = %d but %d posts have authorId=%s", uid, n, got, uid))
		}
	}
	sort.Strings(v)
	return v
}

func loadPostsState(ctx context.Context, client *firestore.Client) (postsState, error) {
	st := postsState{Users: map[string]int64{}, Posts: map[string]storedPost{}}
	it := client.Collection("users").Documents(ctx)
	for {
		snap, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return st, err
		}
		n, _ := snap.Data()["postsCount"].(int64)
		st.Users[snap.Ref.ID] = n
	}
	it = client.Collection(postsCollection).Documents(ctx)
	for {
		snap, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return st, err
		}
		d := snap.Data()
		author, _ := d["authorId"].(string)
		var snapshot string
		if a, ok := d["author"].(map[string]interface{}); ok {
			snapshot, _ = a["userId"].(string)
		}
		st.Posts[snap.Ref.ID] = storedPost{AuthorID: author, SnapshotUserID: snapshot}
	}
	return st, nil
}

// assertPostsInvariants fails t when the emulator project behind client violates any posts invariant. Call it
// directly mid-test (races) or rely on newCreateInstance's t.Cleanup.
func assertPostsInvariants(t testing.TB, client *firestore.Client) {
	t.Helper()
	st, err := loadPostsState(context.Background(), client)
	if err != nil {
		t.Errorf("posts invariants: load state: %v", err)
		return
	}
	if v := postsInvariantViolations(st); len(v) > 0 {
		t.Errorf("posts invariants violated:\n  %s", strings.Join(v, "\n  "))
	}
}

func TestPostsInvariants_CleanStatePasses(t *testing.T) {
	st := postsState{
		Users: map[string]int64{"a": 2, "b": 0},
		Posts: map[string]storedPost{"1": {"a", "a"}, "2": {"a", "a"}, "3": {"orphan", "orphan"}},
	}
	if v := postsInvariantViolations(st); len(v) != 0 {
		t.Fatalf("violations on a consistent state: %v", v)
	}
}

// TestPostsInvariants_NegativeSelfTests proves the checker can fail: each mutation of a consistent state must be
// reported under the right invariant, so a vacuous checker cannot pass the suites.
func TestPostsInvariants_NegativeSelfTests(t *testing.T) {
	base := func() postsState {
		return postsState{
			Users: map[string]int64{"a": 2, "b": 1},
			Posts: map[string]storedPost{"1": {"a", "a"}, "2": {"a", "a"}, "3": {"b", "b"}},
		}
	}
	tests := []struct {
		name   string
		mutate func(*postsState)
		want   string
	}{
		{"counter too high", func(s *postsState) { s.Users["a"] = 3 }, "P1: users/a.postsCount = 3 but 2"},
		{"counter too low", func(s *postsState) { s.Users["b"] = 0 }, "P1: users/b.postsCount = 0 but 1"},
		{"negative counter", func(s *postsState) { s.Users["b"] = -1 }, "P1: users/b.postsCount = -1"},
		{"post without counter bump", func(s *postsState) { s.Posts["9"] = storedPost{"a", "a"} }, "P1: users/a.postsCount = 2 but 3"},
		{"post deleted without decrement", func(s *postsState) { delete(s.Posts, "3") }, "P1: users/b.postsCount = 1 but 0"},
		{"author snapshot of another user", func(s *postsState) { s.Posts["1"] = storedPost{"a", "b"} }, "P2: posts/1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			st := base()
			tt.mutate(&st)
			v := postsInvariantViolations(st)
			if len(v) == 0 || !strings.Contains(strings.Join(v, "\n"), tt.want) {
				t.Fatalf("violations = %v, want one containing %q", v, tt.want)
			}
		})
	}
}

// TestPostsInvariants_LoaderSeesTamperedEmulatorState: the Firestore loader (not just the pure checker) reports a
// counter that was bumped behind the service's back.
func TestPostsInvariants_LoaderSeesTamperedEmulatorState(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, 1)
	in.skipInvariantSweep("tampers postsCount on purpose")
	in.signUp(t, "uid-alice", "alice")
	if _, _, err := in.create(t, "uid-alice", key(1), "one"); err != nil {
		t.Fatal(err)
	}
	st, err := loadPostsState(context.Background(), client)
	if err != nil {
		t.Fatal(err)
	}
	if v := postsInvariantViolations(st); len(v) != 0 {
		t.Fatalf("consistent after a create: %v", v)
	}
	if _, err := client.Doc("users/uid-alice").Update(context.Background(), []firestore.Update{{Path: "postsCount", Value: 7}}); err != nil {
		t.Fatal(err)
	}
	st, err = loadPostsState(context.Background(), client)
	if err != nil {
		t.Fatal(err)
	}
	if v := postsInvariantViolations(st); len(v) != 1 || !strings.Contains(v[0], "P1: users/uid-alice.postsCount = 7 but 1") {
		t.Fatalf("violations = %v, want the tampered counter", v)
	}
}
