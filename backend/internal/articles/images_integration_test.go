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

// TestFirestoreDraftImageHolds: an unpublished article of the owner holds the inline image ids its body names (array
// field, array-contains-any); a published article, another author's draft and an unrelated id never do; ids beyond one
// chunk of 30 are queried in chunks. Cover holds keep working alongside.
func TestFirestoreDraftImageHolds(t *testing.T) {
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
	owner := fmt.Sprintf("img-hold-owner-%d", n)
	other := fmt.Sprintf("img-hold-other-%d", n)
	draft := fmt.Sprintf("img-hold-draft-%d", n)
	published := fmt.Sprintf("img-hold-published-%d", n)
	foreign := fmt.Sprintf("img-hold-foreign-%d", n)
	held := fmt.Sprintf("1%018d", n)
	heldByPublished := fmt.Sprintf("2%018d", n)
	heldByForeign := fmt.Sprintf("3%018d", n)
	unrelated := fmt.Sprintf("4%018d", n)
	cover := fmt.Sprintf("5%018d", n)

	rows := map[string]map[string]any{
		draft:     {"authorId": owner, "published": false, "imageMediaIds": []string{held}, "coverMediaId": ""},
		published: {"authorId": owner, "published": true, "imageMediaIds": []string{heldByPublished}, "postId": "9"},
		foreign:   {"authorId": other, "published": false, "imageMediaIds": []string{heldByForeign}},
		// A draft whose cover is the id: the cover hold must still see it.
		draft + "-cover": {"authorId": owner, "published": false, "coverMediaId": cover, "imageMediaIds": []string{}},
	}
	for id, data := range rows {
		if _, err := client.Collection("articles").Doc(id).Set(ctx, data); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		for id := range rows {
			_, _ = client.Collection("articles").Doc(id).Delete(context.Background())
		}
	}()

	h := &mediaHolds{client: client}
	ids := []string{held, heldByPublished, heldByForeign, unrelated, cover}
	got, err := h.DraftCoverHolds(ctx, owner, ids)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{held: true, cover: true, heldByPublished: false, heldByForeign: false, unrelated: false}
	for _, id := range ids {
		if got[id] != want[id] {
			t.Fatalf("held[%s] = %v, want %v (all %v)", id, got[id], want[id], got)
		}
	}

	// Chunking: 31 ids cross one chunk boundary; the held id sits in the second chunk.
	many := make([]string, 0, 31)
	for i := 0; i < 30; i++ {
		many = append(many, fmt.Sprintf("6%08d%010d", i, n%10000000000))
	}
	many = append(many, held)
	got, err = h.DraftCoverHolds(ctx, owner, many)
	if err != nil {
		t.Fatal(err)
	}
	if !got[held] {
		t.Fatalf("held id in the second chunk not reported: %v", got)
	}
	if reflect.DeepEqual(got, map[string]bool{}) {
		t.Fatal("empty answer")
	}
}
