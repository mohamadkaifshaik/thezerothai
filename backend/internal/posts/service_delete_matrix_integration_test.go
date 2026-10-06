//go:build integration

package posts

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func arrUnion(path string, uid string) firestore.Update {
	return firestore.Update{Path: path, Value: firestore.ArrayUnion(uid)}
}

func setStatus(t *testing.T, client *firestore.Client, uid, status string) {
	t.Helper()
	if _, err := client.Collection("users").Doc(uid).Update(context.Background(),
		[]firestore.Update{{Path: "status", Value: status}}); err != nil {
		t.Fatal(err)
	}
}

// d6Row seeds one ADR-0010 D6 relationship of A (uid-alice, caller) to B (uid-bob, author).
type d6Row struct {
	name string
	seed func(t *testing.T, c *firestore.Client)
	// getFound: GetPost(B's post) is returned (otherwise byte-identical NOT_FOUND).
	getFound bool
}

func d6Rows() []d6Row {
	both := func(t *testing.T, c *firestore.Client) {
		setGraph(t, c, "uid-alice", []firestore.Update{arrUnion("blocked", "uid-bob"), arrUnion("blockedBy", "uid-bob")})
		setGraph(t, c, "uid-bob", []firestore.Update{arrUnion("blocked", "uid-alice"), arrUnion("blockedBy", "uid-alice")})
	}
	return []d6Row{
		{"stranger", func(*testing.T, *firestore.Client) {}, true},
		{"A follows B", func(t *testing.T, c *firestore.Client) {
			setGraph(t, c, "uid-alice", []firestore.Update{arrUnion("following", "uid-bob")})
		}, true},
		{"A blocks B", func(t *testing.T, c *firestore.Client) {
			setGraph(t, c, "uid-alice", []firestore.Update{arrUnion("blocked", "uid-bob")})
		}, true},
		{"B blocks A", func(t *testing.T, c *firestore.Client) {
			setGraph(t, c, "uid-alice", []firestore.Update{arrUnion("blockedBy", "uid-bob")})
		}, false},
		{"both block", both, false},
		{"A mutes B", func(t *testing.T, c *firestore.Client) {
			setGraph(t, c, "uid-alice", []firestore.Update{arrUnion("muted", "uid-bob")})
		}, true},
		{"B SUSPENDED", func(t *testing.T, c *firestore.Client) { setStatus(t, c, "uid-bob", "SUSPENDED") }, false},
		{"B DELETING", func(t *testing.T, c *firestore.Client) { setStatus(t, c, "uid-bob", "DELETING") }, false},
		{"B users doc missing", func(t *testing.T, c *firestore.Client) {
			if _, err := c.Collection("users").Doc("uid-bob").Delete(context.Background()); err != nil {
				t.Fatal(err)
			}
		}, false},
		{"A blockedByOverflow, B blocked A", func(t *testing.T, c *firestore.Client) {
			setGraph(t, c, "uid-alice", []firestore.Update{{Path: "blockedByOverflow", Value: true}})
			setGraph(t, c, "uid-bob", []firestore.Update{arrUnion("blocked", "uid-alice")})
		}, false},
	}
}

// d6Fixture signs up alice and bob (each on its own emulator project) and returns bob's post id.
func d6Fixture(t *testing.T) (*firestore.Client, string) {
	t.Helper()
	client := newTestClient(t)
	setup := newCreateInstance(t, client, time.Nanosecond)
	setup.signUp(t, "uid-alice", "alice")
	setup.signUp(t, "uid-bob", "bob")
	p, _, err := setup.create(t, "uid-bob", key(1), "from bob")
	if err != nil {
		t.Fatal(err)
	}
	return client, p.ID
}

// TestDeletePost_Integration_D6Matrix: with each relationship seeded, A deleting B's post is a silent success
// (<= 1 read, 0 writes, 0 deletes) and the post survives (audit item #16).
func TestDeletePost_Integration_D6Matrix(t *testing.T) {
	for _, row := range d6Rows() {
		t.Run(row.name, func(t *testing.T) {
			client, id := d6Fixture(t)
			row.seed(t, client)
			in := newCreateInstance(t, client, time.Nanosecond)
			c, err := in.del("uid-alice", id)
			if err != nil {
				t.Fatalf("DeletePost: %v, want nil", err)
			}
			budgettest.Assert(t, "DeletePost "+row.name, c, budgettest.Budget{Reads: 1})
			if c.Writes() != 0 || c.Deletes() != 0 {
				t.Fatalf("writes=%d deletes=%d, want 0/0", c.Writes(), c.Deletes())
			}
			if !postExists(t, client, id) {
				t.Fatal("B's post was deleted by A")
			}
		})
	}
}

// TestGetPost_Integration_D6Matrix: the GetPost column of D6 per row, including own, A follows B, both-block and
// DELETING, with the NOT_FOUND budget (<= 3, overflow <= 4) and byte-identity with a missing post
// (audit items #15 and the GetPost part of #10).
func TestGetPost_Integration_D6Matrix(t *testing.T) {
	for _, row := range d6Rows() {
		t.Run(row.name, func(t *testing.T) {
			client, id := d6Fixture(t)
			row.seed(t, client)
			in := newCreateInstance(t, client, time.Nanosecond)
			c, p, err := in.get("uid-alice", id)
			ceiling := int64(3)
			if row.name == "A blockedByOverflow, B blocked A" {
				ceiling = 4
			}
			budgettest.Assert(t, "GetPost "+row.name, c, budgettest.Budget{Reads: ceiling})
			if c.Writes() != 0 || c.Deletes() != 0 {
				t.Fatalf("writes=%d deletes=%d, want 0/0", c.Writes(), c.Deletes())
			}
			if row.getFound {
				if err != nil || p == nil || p.ID != id {
					t.Fatalf("want the post returned, got %v %v", p, err)
				}
				return
			}
			wantPostNotFound(t, err)
			_, _, missing := in.get("uid-alice", pid(777))
			wantPostNotFound(t, missing)
			if err.Error() != missing.Error() {
				t.Fatalf("not byte-identical to a missing post: %q vs %q", err, missing)
			}
		})
	}
}

// TestGetPost_Integration_Own: A == B returns the post (own post skips the graph).
func TestGetPost_Integration_Own(t *testing.T) {
	client, id := d6Fixture(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	c, p, err := in.get("uid-bob", id)
	if err != nil || p == nil || p.ID != id {
		t.Fatalf("own post: %v %v", p, err)
	}
	budgettest.Assert(t, "GetPost own", c, budgettest.Budget{Reads: 3})
}

// TestPurge_Integration_RestartFromEmptyCheckpoint: the checkpoint is lost after batch 1; PurgeUser restarted from
// Checkpoint{} still deletes everything, and batch 1 removed the newest 500 (audit item #22).
func TestPurge_Integration_RestartFromEmptyCheckpoint(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	const uid = "uid-u"
	seedMany(t, client, uid, 1203, 1) // pid(1) oldest .. pid(1203) newest
	seedMany(t, client, "uid-keep", 7, 5000)

	ctx1, c1 := budget.WithCounter(context.Background())
	cp, done, err := repo.PurgeUser(ctx1, uid, Checkpoint{})
	if err != nil || done || cp.Deleted != 500 {
		t.Fatalf("batch 1: cp=%+v done=%v err=%v", cp, done, err)
	}
	// Newest 500 (pid 704..1203) are gone; the oldest 703 remain.
	for _, n := range []int{704, 900, 1203} {
		if postExists(t, client, pid(n)) {
			t.Fatalf("post %d (among the newest 500) survived batch 1", n)
		}
	}
	for _, n := range []int{1, 350, 703} {
		if !postExists(t, client, pid(n)) {
			t.Fatalf("post %d (not among the newest 500) was deleted by batch 1", n)
		}
	}
	if got := countByAuthor(t, client, uid); got != 703 {
		t.Fatalf("%d remain after batch 1, want 703", got)
	}

	// Crash: the saved checkpoint is lost. Restart from zero.
	ctx2, c2 := budget.WithCounter(context.Background())
	cp = Checkpoint{}
	done = false
	for calls := 0; !done; calls++ {
		if calls >= 10 {
			t.Fatal("restarted purge did not finish")
		}
		if cp, done, err = repo.PurgeUser(ctx2, uid, cp); err != nil {
			t.Fatal(err)
		}
	}
	if cp.Deleted != 703 {
		t.Fatalf("restart deleted %d, want the remaining 703", cp.Deleted)
	}
	if total := c1.Deletes() + c2.Deletes(); total != 1203 {
		t.Fatalf("total deletes = %d, want 1203", total)
	}
	if got := countByAuthor(t, client, uid); got != 0 {
		t.Fatalf("%d posts remain", got)
	}
	if got := countByAuthor(t, client, "uid-keep"); got != 7 {
		t.Fatalf("another user's posts: %d, want 7", got)
	}
}
