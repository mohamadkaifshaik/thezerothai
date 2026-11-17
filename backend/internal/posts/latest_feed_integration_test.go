//go:build integration

package posts

import (
	"context"
	"reflect"
	"testing"
)

// Emulator test: ByLatestFeed (the Trending newest-posts feed). The query has no filter, only ORDER BY createdAt DESC,
// __name__ DESC, which the automatic single-field index of createdAt serves (the emulator does not enforce indexes; the
// same shape as Recent runs on dzeroth-dev), so there is no firestore.indexes.json change. It proves the order, the
// window (StartAfter on createdAt + doc id, equal timestamps included), the Limit and that nothing is filtered.
func TestRepo_Integration_ByLatestFeed(t *testing.T) {
	client := newTestClient(t)
	svc, _ := integrationSvc(client)
	ctx := context.Background()

	// Posts 1..8 at createdAt 1000*n; 9 and 10 share createdAt 9000 (the id breaks the tie, descending); 4 is a reply,
	// 6 a REPOST, 7 has images, 3 is taken down: the reader returns every one of them, unfiltered.
	for n := 1; n <= 8; n++ {
		kind := KindPost
		switch n {
		case 4:
			kind = KindReply
		case 6:
			kind = KindRepost
		}
		images := 0
		if n == 7 {
			images = 1
		}
		seedTabPost(t, client, pid(n), "a", kind, int64(n)*1000, images)
	}
	seedTabPost(t, client, pid(9), "b", KindPost, 9000, 0)
	seedTabPost(t, client, pid(10), "b", KindPost, 9000, 0)
	takeDown(t, client, pid(3))

	want := []string{pid(10), pid(9), pid(8), pid(7), pid(6), pid(5), pid(4), pid(3), pid(2), pid(1)}
	all, err := svc.ByLatestFeed(ctx, Window{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	if got := idList(all); !reflect.DeepEqual(got, want) {
		t.Fatalf("order = %v, want %v", got, want)
	}
	if all[2].Hidden() == all[7].Hidden() || !all[7].Hidden() {
		t.Fatalf("hidden flags: post 8 %v, post 3 %v; want only post 3 hidden (unfiltered reader)", all[2].Hidden(), all[7].Hidden())
	}

	// Pages of 3 resuming after the last row of each page: every post once, in order, the equal-timestamp pair split cleanly.
	var paged []string
	var w Window
	for i := 0; i < 10; i++ {
		page, err := svc.ByLatestFeed(ctx, w, 3)
		if err != nil {
			t.Fatal(err)
		}
		if len(page) > 3 {
			t.Fatalf("page %d: %d rows, want at most the limit 3", i+1, len(page))
		}
		paged = append(paged, idList(page)...)
		if len(page) < 3 {
			break
		}
		last := page[len(page)-1]
		w = Window{Before: &Position{CreatedAt: last.CreatedAt, ID: last.ID}}
	}
	if !reflect.DeepEqual(paged, want) {
		t.Fatalf("paged = %v, want %v", paged, want)
	}

	// Resuming between the two posts that share createdAt 9000 returns the other one first.
	after10, err := svc.ByLatestFeed(ctx, Window{Before: &Position{CreatedAt: all[0].CreatedAt, ID: pid(10)}}, 2)
	if err != nil {
		t.Fatal(err)
	}
	if got := idList(after10); !reflect.DeepEqual(got, []string{pid(9), pid(8)}) {
		t.Fatalf("after post 10 = %v, want [9 8]", got)
	}
}
