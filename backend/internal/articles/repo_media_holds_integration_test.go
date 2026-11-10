//go:build integration

package articles

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/option"
)

// TestFirestoreDraftCoverHolds: only the owner's unpublished articles (drafts and pending publications) hold a cover; a
// published article, another author's draft and an unrelated id never do; more than 30 ids are queried in chunks.
func TestFirestoreDraftCoverHolds(t *testing.T) {
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("requires Firestore emulator")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := firestore.NewClient(ctx, "demo-articles-integration", option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	n := time.Now().UnixNano()
	uid := fmt.Sprintf("holds-owner-%d", n)
	media := func(i int) string { return fmt.Sprintf("%019d", n/1000+int64(i)) }
	rows := map[string]record{
		fmt.Sprintf("holds-%d-draft", n):     {AuthorID: uid, Title: "T", Body: testBody, CoverMediaID: media(1)},
		fmt.Sprintf("holds-%d-pending", n):   {AuthorID: uid, Title: "T", Body: testBody, CoverMediaID: media(2), PendingKey: "k"},
		fmt.Sprintf("holds-%d-published", n): {AuthorID: uid, Title: "T", Body: testBody, CoverMediaID: media(3), Published: true, PostID: "1"},
		fmt.Sprintf("holds-%d-foreign", n):   {AuthorID: uid + "-other", Title: "T", Body: testBody, CoverMediaID: media(4)},
		fmt.Sprintf("holds-%d-late", n):      {AuthorID: uid, Title: "T", Body: testBody, CoverMediaID: media(40)},
	}
	for id, r := range rows {
		if _, err := client.Collection("articles").Doc(id).Set(ctx, r); err != nil {
			t.Fatal(err)
		}
		defer func(id string) { _, _ = client.Collection("articles").Doc(id).Delete(context.Background()) }(id)
	}
	// 41 ids: two IN chunks (30 + 11), the last cover in the second.
	var ids []string
	for i := 1; i <= 41; i++ {
		ids = append(ids, media(i))
	}
	got, err := NewMediaHolds(client).DraftCoverHolds(ctx, uid, ids)
	if err != nil {
		t.Fatal(err)
	}
	if want := map[string]bool{media(1): true, media(2): true, media(40): true}; !reflect.DeepEqual(got, want) {
		t.Fatalf("holds = %v, want %v", got, want)
	}
	if got, err := NewMediaHolds(client).DraftCoverHolds(ctx, uid, nil); err != nil || len(got) != 0 {
		t.Fatalf("empty request = %v, %v", got, err)
	}
}
