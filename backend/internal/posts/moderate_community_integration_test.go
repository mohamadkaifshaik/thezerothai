//go:build integration

package posts

import (
	"context"
	"reflect"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// setCommunity gives the seeded post a communityId (the field a platform removal appends to the community's recentRemovals).
func setCommunity(t *testing.T, repo *FirestoreRepo, id, cid string) {
	t.Helper()
	if _, err := repo.ref(id).Update(context.Background(), []firestore.Update{{Path: "communityId", Value: cid}}); err != nil {
		t.Fatal(err)
	}
}

// ADR-0031 D14: Takedown reports the post's communityId from the document it already reads (1 read, 2 writes as before), also
// on a repeat that changes nothing, and "" for a post without one.
func TestModerator_TakedownReportsTheCommunity(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedPost(t, client, pid(1), "u-a", false, 1_700_000_000_000)
	seedPost(t, client, pid(2), "u-a", false, 1_700_000_001_000)
	setCommunity(t, repo, pid(1), "0000000000000000700")
	now := time.Unix(1_800_000_000, 0)

	ctx, c := budget.WithCounter(context.Background())
	res, err := repo.Takedown(ctx, pid(1), now)
	if err != nil || res.CommunityID != "0000000000000000700" || res.After != ModerationTakenDown {
		t.Fatalf("takedown = %+v err=%v", res, err)
	}
	budgettest.Assert(t, "Takedown of a community post", c, budgettest.Budget{Reads: 1, Writes: 2})

	ctx, c = budget.WithCounter(context.Background())
	if res, err = repo.Takedown(ctx, pid(1), now); err != nil || res.CommunityID != "0000000000000000700" || res.Before != ModerationTakenDown {
		t.Fatalf("repeat = %+v err=%v", res, err)
	}
	budgettest.Assert(t, "Takedown again", c, budgettest.Budget{Reads: 1})

	if res, err = repo.Takedown(context.Background(), pid(2), now); err != nil || res.CommunityID != "" {
		t.Fatalf("plain post = %+v err=%v", res, err)
	}
}

// HideAuthor returns the community posts of the page it processed (changed or already hidden), replaced on every call, at no extra
// read or write; a post a community moderator hid has no communityId and is not listed.
func TestModerator_HideAuthorListsTheCommunityPosts(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	base := int64(1_700_000_000_000)
	for i := 1; i <= 5; i++ {
		seedPost(t, client, pid(i), "u-bad", false, base+int64(i)*1000)
	}
	setCommunity(t, repo, pid(1), "0000000000000000700")
	setCommunity(t, repo, pid(2), "0000000000000000700")
	setCommunity(t, repo, pid(3), "0000000000000000701")
	// pid(4) is a moderator-hidden community post: no communityId (the hide deleted it). pid(5) is a plain post.
	now := time.Unix(1_800_000_100, 0)

	// An already TAKEN_DOWN community post is still listed (a re-run after a crash must find it).
	if _, err := repo.Takedown(context.Background(), pid(2), now); err != nil {
		t.Fatal(err)
	}

	ctx, c := budget.WithCounter(context.Background())
	next, done, err := repo.HideAuthor(ctx, "u-bad", ModerationCheckpoint{}, now)
	if err != nil || !done || next.Changed != 4 {
		t.Fatalf("hide: next=%+v done=%v err=%v", next, done, err)
	}
	budgettest.Assert(t, "HideAuthor", c, budgettest.Budget{Reads: 5, Writes: 8})
	got := slices.Clone(next.PageCommunityPosts)
	slices.SortFunc(got, func(a, b CommunityPostRef) int {
		if a.PostID < b.PostID {
			return -1
		}
		return 1
	})
	want := []CommunityPostRef{{"0000000000000000700", pid(1)}, {"0000000000000000700", pid(2)}, {"0000000000000000701", pid(3)}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("PageCommunityPosts = %+v, want %+v", got, want)
	}

	// A re-run changes nothing but still lists them, and an input value is ignored (the field is an output).
	ctx, c = budget.WithCounter(context.Background())
	next, _, err = repo.HideAuthor(ctx, "u-bad", ModerationCheckpoint{PageCommunityPosts: []CommunityPostRef{{"x", "y"}}}, now)
	if err != nil || next.Changed != 0 || len(next.PageCommunityPosts) != 3 {
		t.Fatalf("re-run: next=%+v err=%v", next, err)
	}
	budgettest.Assert(t, "HideAuthor rerun", c, budgettest.Budget{Reads: 5})

	// An author with no posts: an empty page, nothing listed.
	next, done, err = repo.HideAuthor(context.Background(), "u-nobody", ModerationCheckpoint{PageCommunityPosts: []CommunityPostRef{{"x", "y"}}}, now)
	if err != nil || !done || len(next.PageCommunityPosts) != 0 {
		t.Fatalf("empty: next=%+v done=%v err=%v", next, done, err)
	}
}
