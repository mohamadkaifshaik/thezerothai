//go:build integration

package integration

import (
	"context"
	"fmt"
	"testing"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/search"
)

// TestFromFollowing_RecallCapAndResumeOnFirestore (F22): over the real ByHashtag query and graph snapshot, a LATEST call with
// from_following reads at most 3 windows (the 30-post entry, then two windows of 20), keeps only followed authors, and its
// token resumes after the last queried row; the chain then reaches every followed post.
func TestFromFollowing_RecallCapAndResumeOnFirestore(t *testing.T) {
	client := newClient(t)
	tag := fmt.Sprintf("ff%d", base.UnixNano()%1_000_000)
	for n := 1; n <= 200; n++ {
		author := "stranger"
		if n%25 == 0 {
			author = "friend"
		}
		seed(t, client, n, author, tag, 0, 0)
	}
	if _, err := client.Collection("graph").Doc("viewer").Set(context.Background(), map[string]any{
		"blocked": []string{}, "following": []string{"friend"}, "muted": []string{},
	}); err != nil {
		t.Fatal(err)
	}
	svc := newInstance(t, client)
	latest := searchv1.SearchTab_SEARCH_TAB_LATEST
	req := search.PostsRequest{Query: tag, Tab: latest, PageSize: 10, FromFollowing: true}
	var all []string
	pages := 0
	for {
		resp, err := svc.PostsWith(context.Background(), "viewer", req)
		if err != nil {
			t.Fatal(err)
		}
		pages++
		all = append(all, ids(resp)...)
		if pages == 1 {
			if got := ids(resp); len(got) != 3 || got[0] != pid(200) || got[2] != pid(150) {
				t.Fatalf("page 1 = %v (3 windows: posts 200..131)", got)
			}
		}
		if resp.GetNextPageToken() == "" {
			break
		}
		if pages > 10 {
			t.Fatal("the chain does not end")
		}
		req.PageToken = resp.GetNextPageToken()
	}
	if len(all) != 8 || all[7] != pid(25) {
		t.Fatalf("chain = %v, want the 8 followed posts 200..25", all)
	}
	// An unfiltered call refuses the chain's token.
	if _, err := svc.PostsWith(context.Background(), "viewer", search.PostsRequest{Query: tag, Tab: latest, PageSize: 10, PageToken: req.PageToken}); err == nil && req.PageToken != "" {
		t.Fatal("a following token opened an unfiltered call")
	}
}
