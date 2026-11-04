//go:build integration

// lists_integration_test.go exercises GetRelationships and the own-list RPCs against the Firestore emulator
// (acceptance criteria).
package graph_test

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func TestGetRelationships_Integration_BlockedByInvisible(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	// b blocks a: a must see b exactly as it sees an unrelated user c.
	if _, err := w.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	rels, err := w.graph.GetRelationships(ctx, "uid-a", []string{"uid-b", "uid-c"})
	if err != nil {
		t.Fatal(err)
	}
	if rels[0].FollowState != rels[1].FollowState || rels[0].Blocking != rels[1].Blocking || rels[0].Muting != rels[1].Muting {
		t.Errorf("blocked-by user %+v distinguishable from stranger %+v", rels[0], rels[1])
	}

	// Served again from the instance cache, the answer is the same.
	again, err := w.graph.GetRelationships(context.Background(), "uid-a", []string{"uid-b", "uid-c"})
	if err != nil {
		t.Fatal(err)
	}
	if again[0] != rels[0] || again[1] != rels[1] {
		t.Errorf("repeat answer %+v differs from the first %+v", again, rels)
	}
}

func TestListBlockedUsers_Integration_Pages(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	const n = 45
	for i := 0; i < n; i++ {
		uid := fmt.Sprintf("uid-t%02d", i)
		mustCreateProfile(t, w.identity, uid, fmt.Sprintf("target%02d", i))
	}
	// Seed blocked[] directly (45 real Block calls would trip nothing but cost minutes of emulator time).
	blocked := make([]string, n)
	for i := range blocked {
		blocked[i] = fmt.Sprintf("uid-t%02d", i)
	}
	for _, b := range blocked {
		seedBlock(t, w.client, "uid-a", b) // consistent blocked[]/blockedBy[] pair, so the invariant sweep holds
	}

	var seen []string
	token := ""
	var sizes []int
	for {
		ctx := context.Background()
		page, err := w.graph.ListBlockedUsers(ctx, "uid-a", 20, token)
		if err != nil {
			t.Fatal(err)
		}
		sizes = append(sizes, len(page.Items))
		for _, it := range page.Items {
			seen = append(seen, it.User.UserID)
		}
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
	}
	if fmt.Sprint(sizes) != "[20 20 5]" {
		t.Errorf("sizes = %v, want [20 20 5]", sizes)
	}
	if len(seen) != n || seen[0] != "uid-t44" || seen[n-1] != "uid-t00" {
		t.Errorf("order wrong: first=%s last=%s len=%d", seen[0], seen[len(seen)-1], len(seen))
	}

	_, err := w.graph.ListBlockedUsers(context.Background(), "uid-a", 20, "tampered")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code.String() != "invalid_argument" {
		t.Errorf("tampered token err = %v", err)
	}
}

func TestListMutedUsers_Integration_RelationshipFilled(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	if _, err := w.graph.Mute(context.Background(), "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	page, err := w.graph.ListMutedUsers(context.Background(), "uid-a", 0, "")
	if err != nil || len(page.Items) != 1 {
		t.Fatalf("page = %+v, %v", page, err)
	}
	if got := page.Items[0].Relationship; !got.Muting || got.Blocking || got.FollowState != graph.FollowStateNone {
		t.Errorf("relationship = %+v", got)
	}
}

// A blocks B and B blocks A -> A's own ListBlockedUsers hides B (showing B would reveal that
// B blocked A, while GetProfile(B) says NOT_FOUND).
func TestListBlockedUsers_Integration_HidesUsersWhoBlockedCaller(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	ctx := context.Background()
	for _, target := range []string{"uid-b", "uid-c"} {
		if _, err := w.graph.Block(ctx, "uid-a", key1, target); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := w.graph.Block(ctx, "uid-b", key2, "uid-a"); err != nil {
		t.Fatal(err)
	}
	page, err := w.graph.ListBlockedUsers(ctx, "uid-a", 20, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.Items[0].User.UserID != "uid-c" {
		t.Errorf("rows = %+v, want only uid-c", page.Items)
	}
}
