//go:build integration

package integration

// F-03 against the Firestore emulator with identity's real Directory: a public tagged post disappears from LATEST, TOP
// and MEDIA once its author is suspended through identity's own moderation write (SetAccountStatus, which changes
// users/{uid} only and never the posts), on a warm instance (the tag entry built while the author was ACTIVE) and on a
// cold one. A QUOTE of the suspended author's post stays with its embed tombstoned; a post by an author with no users doc
// and one by a DELETING author never show.

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// seedQuote writes post n of tag: a QUOTE by author of post orig by origAuthor, with one image.
func seedQuote(t *testing.T, client *firestore.Client, n int, author, tag string, orig int, origAuthor string) {
	t.Helper()
	doc := map[string]any{
		"authorId": author, "author": map[string]any{"userId": author, "handle": "h" + author},
		"kind": "QUOTE", "isReply": false, "text": "quote #" + tag, "conversationId": pid(n), "hashtags": []string{tag},
		"mentions": []map[string]any{}, "likeCount": 0, "repostCount": 0, "replyCount": 0, "quoteCount": 0,
		"visibility": "PUBLIC", "createdAt": base.Add(time.Duration(n) * time.Second), "hasMedia": true,
		"media":     []map[string]any{{"mediaId": fmt.Sprintf("m%d", n), "url": "https://x/" + pid(n), "thumbUrl": "https://x/t" + pid(n), "width": 10, "height": 10}},
		"quoteOfId": pid(orig), "embeddedAuthorId": origAuthor,
		"embedded": map[string]any{"postId": pid(orig), "author": map[string]any{"userId": origAuthor, "handle": "h" + origAuthor}, "text": "the original"},
	}
	if _, err := client.Collection("posts").Doc(pid(n)).Set(context.Background(), doc); err != nil {
		t.Fatalf("seed quote %d: %v", n, err)
	}
}

func TestSearchPosts_SuspendedAuthor(t *testing.T) {
	client := newClient(t) // a fresh emulator project: the ids below are unique to this test
	ctx := context.Background()
	graphRepo := graph.NewFirestoreRepo(client)
	idRepo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(idRepo)
	graphRepo.SetProfiles(idRepo)
	newDir := func() identity.Directory {
		return identity.New(idRepo, identity.NewCache(time.Minute), 7*24*time.Hour).(identity.Directory)
	}
	idSvc := identity.New(idRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
	dir := idSvc.(identity.Directory)

	const tag = "fzerothree"
	author, quoter, viewer, dying, ghost := "uid-f03-author", "uid-f03-quoter", "uid-f03-viewer", "uid-f03-dying", "uid-f03-ghost"
	for i, uid := range []string{author, quoter, viewer, dying} {
		if _, err := idSvc.CreateProfile(ctx, uid, "0123456789abcdef", fmt.Sprintf("ffzz%d", i), "Name"); err != nil {
			t.Fatalf("CreateProfile(%d): %v", i, err)
		}
	}
	if _, err := idRepo.UpdateProfile(ctx, dying, func(p *identity.Profile) { p.Status = identity.AccountStatusDeleting }); err != nil {
		t.Fatal(err)
	}
	dir.Forget(dying)                     // the write went around the service whose CreateProfile cached the ACTIVE profile
	seed(t, client, 1, author, tag, 1, 5) // the post that must disappear
	seedQuote(t, client, 2, quoter, tag, 1, author)
	seed(t, client, 3, ghost, tag, 1, 0) // no users doc
	seed(t, client, 4, dying, tag, 1, 0) // DELETING
	seed(t, client, 5, quoter, tag, 1, 0)
	seedBlocked(t, client, viewer, "nobody")

	tabs := []searchv1.SearchTab{searchv1.SearchTab_SEARCH_TAB_LATEST, searchv1.SearchTab_SEARCH_TAB_TOP, searchv1.SearchTab_SEARCH_TAB_MEDIA}
	// check runs every tab as the viewer and wants exactly want (sorted) and the QUOTE's embed tombstoned or not. The first
	// tab finds the tag entry warm or cold as asked; the later tabs share the entry it left, so they are always warm.
	check := func(t *testing.T, svc *instance, phase string, want []string, tombstone, warm bool) {
		t.Helper()
		for i, tab := range tabs {
			rctx, info := logger.WithRequestInfo(ctx)
			resp, err := svc.Posts(rctx, viewer, tag, tab, 0, "")
			if err != nil {
				t.Fatalf("%s %v: %v", phase, tab, err)
			}
			got := ids(resp)
			slices.Sort(got)
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Fatalf("%s %v: ids = %v, want %v", phase, tab, got, want)
			}
			if hit, _ := info.Get("cache_hit"); hit != (warm || i > 0) {
				t.Fatalf("%s %v: cache_hit = %v, want %v", phase, tab, hit, warm || i > 0)
			}
			for _, v := range resp.Posts {
				if v.GetPost().GetPostId() != pid(2) {
					continue
				}
				e := v.GetPost().GetEmbedded()
				if tombstone && (!e.GetUnavailable() || e.GetPostId() != pid(1) || e.GetText() != "" || e.GetAuthor() != nil) {
					t.Fatalf("%s %v: QUOTE embed = %v, want the tombstone", phase, tab, e)
				}
				if !tombstone && (e.GetUnavailable() || e.GetText() != "the original") {
					t.Fatalf("%s %v: QUOTE embed = %v, want the snapshot", phase, tab, e)
				}
			}
		}
	}

	warmSvc := newInstanceWith(t, client, dir)
	active := []string{pid(1), pid(2), pid(5)}
	gone := []string{pid(2), pid(5)}
	t.Run("ACTIVE: the post shows, the ghost and the DELETING author never do", func(t *testing.T) {
		check(t, warmSvc, "before (cold)", active, false, false)
		check(t, warmSvc, "before (warm)", active, false, true)
	})

	if changed, err := idRepo.SetAccountStatus(ctx, author, identity.AccountStatusActive, identity.AccountStatusSuspended, time.Now()); err != nil || !changed {
		t.Fatalf("SetAccountStatus: changed %v err %v", changed, err)
	}

	t.Run("suspended: gone from a warm tag entry", func(t *testing.T) {
		// The suspension ran outside this instance (opsctl), so the instance's identity cache holds the ACTIVE profile for up
		// to CACHE_TTL (60 s), the bound every other surface has. Forget stands in for that expiry (no sleeps in tests).
		dir.Forget(author)
		check(t, warmSvc, "after (warm)", gone, true, true)
	})

	t.Run("suspended: gone from a cold instance", func(t *testing.T) {
		cold := newInstanceWith(t, client, newDir())
		check(t, cold, "after (cold)", gone, true, false)
		check(t, cold, "after (cold, then warm)", gone, true, true)
	})
}
