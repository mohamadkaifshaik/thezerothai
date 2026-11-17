//go:build integration

package integration

import (
	"context"
	"reflect"
	"testing"

	"cloud.google.com/go/firestore"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
)

func feedIDs(r *searchv1.ExplorePostsResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func update(t *testing.T, client *firestore.Client, n int, fields map[string]any) {
	t.Helper()
	var ups []firestore.Update
	for k, v := range fields {
		ups = append(ups, firestore.Update{Path: k, Value: v})
	}
	if _, err := client.Collection("posts").Doc(pid(n)).Update(context.Background(), ups); err != nil {
		t.Fatalf("update %d: %v", n, err)
	}
}

// TestExplorePosts_Pages runs ExplorePosts over real documents with the real posts and graph services: the newest root
// posts of every author, newest first, with replies, REPOSTs, taken-down posts and authors blocked either way dropped,
// and the token chain visiting every kept post exactly once (one fresh emulator project, so no other test's posts).
func TestExplorePosts_Pages(t *testing.T) {
	client := newClient(t)
	// Posts 1..30 by "a" (every 4th with an image); 31 is a reply, 32 a REPOST, 33 taken down, 34 by a blocked author,
	// 35 by an author who blocks the caller, 36 the caller's own post.
	for n := 1; n <= 30; n++ {
		img := 0
		if n%4 == 0 {
			img = 1
		}
		seed(t, client, n, "a", "any", img, 0)
	}
	seed(t, client, 31, "a", "any", 0, 0)
	update(t, client, 31, map[string]any{"kind": "REPLY", "isReply": true, "parentId": pid(1)})
	seed(t, client, 32, "a", "any", 0, 0)
	update(t, client, 32, map[string]any{"kind": "REPOST", "hashtags": []string{}})
	seed(t, client, 33, "a", "any", 0, 0)
	update(t, client, 33, map[string]any{"moderation": "TAKEN_DOWN"})
	seed(t, client, 34, "bad", "any", 0, 0)
	seed(t, client, 35, "meanie", "any", 0, 0)
	seed(t, client, 36, "u", "any", 0, 0)
	if _, err := client.Collection("graph").Doc("u").Set(context.Background(), map[string]any{
		"blocked": []string{"bad"}, "blockedBy": []string{"meanie"}, "following": []string{}, "muted": []string{},
	}); err != nil {
		t.Fatal(err)
	}

	want := []string{pid(36)}
	for n := 30; n >= 1; n-- {
		want = append(want, pid(n))
	}

	svc := newInstance(t, client)
	var got []string
	token, pages := "", 0
	for {
		resp, err := svc.ExplorePosts(context.Background(), "u", 7, token)
		if err != nil {
			t.Fatalf("page %d: %v", pages+1, err)
		}
		pages++
		if len(resp.GetPosts()) > 7 {
			t.Fatalf("page %d: %d posts, want at most 7", pages, len(resp.GetPosts()))
		}
		got = append(got, feedIDs(resp)...)
		token = resp.GetNextPageToken()
		if token == "" || pages > 20 {
			break
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("drained = %v\nwant %v", got, want)
	}
	if svc.viewerCalls() == 0 {
		t.Fatal("pages with rows read no viewer state; want the standard post-card hydration")
	}

	// Another caller cannot replay this caller's token.
	first, err := svc.ExplorePosts(context.Background(), "u", 1, "")
	if err != nil || first.GetNextPageToken() == "" {
		t.Fatalf("first page: err %v token %q", err, first.GetNextPageToken())
	}
	if _, err := svc.ExplorePosts(context.Background(), "someone-else", 1, first.GetNextPageToken()); err == nil {
		t.Fatal("a foreign token was accepted")
	}
}
