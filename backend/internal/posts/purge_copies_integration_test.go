//go:build integration

package posts

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// recordLinks records StageRelease calls (the reposts-doc deletion engagement stages in the same batch).
type recordLinks struct {
	mu    sync.Mutex
	pairs [][2]string
}

func (r *recordLinks) StageRelease(_ store.Batch, originalID, uid string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pairs = append(r.pairs, [2]string{originalID, uid})
}

const (
	cpGone    = "uid-gone"
	cpOrig    = "9000000000000000001"
	cpRepost  = "9000000000000000002"
	cpQuote   = "9000000000000000003"
	cpQuote2  = "9000000000000000005"
	cpOddball = "9000000000000000004"
)

func seedCopy(t *testing.T, client *firestore.Client, p *Post) {
	t.Helper()
	if p.CreatedAt.IsZero() {
		p.CreatedAt = time.UnixMilli(1_700_000_000_000).UTC()
	}
	if p.ConversationID == "" {
		p.ConversationID = p.ID
	}
	p.Visibility = VisibilityPublic
	if _, err := client.Collection(postsCollection).Doc(p.ID).Set(context.Background(), toDoc(p)); err != nil {
		t.Fatal(err)
	}
}

func copyOf(authorID, id string, kind Kind) *Post {
	e := &Embedded{PostID: cpOrig, Author: AuthorSnapshot{UserID: cpGone, Handle: "gone"}, Text: "secret text"}
	p := &Post{ID: id, AuthorID: authorID, Author: AuthorSnapshot{UserID: authorID, Handle: "h"}, Kind: kind,
		Embedded: e, EmbeddedAuthorID: cpGone}
	switch kind {
	case KindRepost:
		p.RepostOfID = cpOrig
	case KindQuote:
		p.QuoteOfID = cpOrig
		p.Text = "my take"
	}
	return p
}

// runCopyPhase runs PurgeUser from Phase 1 until done (bounded).
func runCopyPhase(t *testing.T, repo *FirestoreRepo, uid string) (Checkpoint, *budget.Counter) {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	cp := Checkpoint{Phase: 1}
	for i := 0; i < 5; i++ {
		var done bool
		var err error
		if cp, done, err = repo.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatalf("PurgeUser: %v", err)
		}
		if done {
			return cp, c
		}
	}
	t.Fatal("copy phase did not finish")
	return cp, c
}

// TestPurgeCopies_Integration seeds copies carrying embeddedAuthorId == the deleted user: another user's REPOST is
// removed (with its reposts-doc release and the reposter's postsCount), another user's QUOTE gets a tombstone, and
// nothing keeps embeddedAuthorId == the user.
func TestPurgeCopies_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	repo.SetWriters(WriteDeps{Counters: countersStub{client}})
	links := &recordLinks{}
	repo.SetRepostLinks(links)
	ctx := context.Background()

	seedCopy(t, client, copyOf("uid-reposter", cpRepost, KindRepost))
	seedCopy(t, client, copyOf("uid-quoter", cpQuote, KindQuote))
	seedCopy(t, client, copyOf("uid-quoter2", cpQuote2, KindQuote))
	if _, err := client.Doc("users/uid-reposter").Set(ctx, map[string]any{"postsCount": int64(4)}); err != nil {
		t.Fatal(err)
	}

	cp, c := runCopyPhase(t, repo, cpGone)
	if cp.Copies != 3 {
		t.Fatalf("copies = %d, want 3 (1 repost + 2 quotes)", cp.Copies)
	}
	if _, err := client.Doc("posts/" + cpRepost).Get(ctx); err == nil {
		t.Error("the REPOST copy survived")
	}
	links.mu.Lock()
	if len(links.pairs) != 1 || links.pairs[0] != [2]string{cpOrig, "uid-reposter"} {
		t.Errorf("reposts-doc releases = %v, want one for (orig, uid-reposter)", links.pairs)
	}
	links.mu.Unlock()
	us, _ := client.Doc("users/uid-reposter").Get(ctx)
	if v, _ := us.DataAt("postsCount"); v != int64(1) { // countersStub writes the constant 1
		t.Errorf("reposter postsCount = %v, the counter was not staged", v)
	}
	for _, id := range []string{cpQuote, cpQuote2} {
		s, err := client.Doc("posts/" + id).Get(ctx)
		if err != nil {
			t.Fatalf("the quote %s is gone: %v", id, err)
		}
		d := s.Data()
		emb, _ := d["embedded"].(map[string]any)
		if un, _ := emb["unavailable"].(bool); !un || emb["text"] != nil || emb["postId"] != cpOrig {
			t.Errorf("quote %s embed = %v, want a tombstone", id, emb)
		}
		if d["quoteOfId"] != nil || d["embeddedAuthorId"] != nil {
			t.Errorf("quote %s still carries quoteOfId/embeddedAuthorId: %v", id, d)
		}
		if d["text"] != "my take" {
			t.Errorf("the quoting user's own text changed: %v", d["text"])
		}
	}
	left, err := client.Collection(postsCollection).Where("embeddedAuthorId", "==", cpGone).Limit(5).Documents(ctx).GetAll()
	if err != nil || len(left) != 0 {
		t.Errorf("residue: %d docs with embeddedAuthorId == the user, err %v", len(left), err)
	}
	// 1 read per doc + the final empty page; the quotes share one commit (2 writes), the REPOST costs 1 write
	// (postsCount) and 1 delete.
	if c.Reads() > 3+1 || c.Writes() > 3 || c.Deletes() != 1 {
		t.Errorf("copy phase reads=%d writes=%d deletes=%d", c.Reads(), c.Writes(), c.Deletes())
	}
}

// TestPurgeCopies_StuckBranch: a full page that changes nothing (a doc with embeddedAuthorId whose kind is neither
// REPOST nor QUOTE) ends the phase at once, logs at Error, and leaves the doc for the residue sweep.
func TestPurgeCopies_StuckBranch(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	repo.SetWriters(WriteDeps{Counters: countersStub{client}})
	repo.SetRepostLinks(&recordLinks{})

	odd := copyOf("uid-odd", cpOddball, KindPost)
	seedCopy(t, client, odd)

	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(prev) })

	ctx, _ := budget.WithCounter(context.Background())
	cp, done, err := repo.PurgeUser(ctx, cpGone, Checkpoint{Phase: 1})
	if err != nil {
		t.Fatal(err)
	}
	if !done || cp.Copies != 0 {
		t.Fatalf("stuck page: done=%v copies=%d, want done with 0 copies (no endless repeat)", done, cp.Copies)
	}
	if _, err := client.Doc("posts/" + cpOddball).Get(context.Background()); err != nil {
		t.Errorf("the unrecognised doc was touched: %v", err)
	}
	var stuckLine string
	for _, l := range strings.Split(buf.String(), "\n") {
		if strings.Contains(l, "posts_purge_copies_stuck") {
			stuckLine = l
		}
	}
	if stuckLine == "" || !strings.Contains(stuckLine, `"level":"ERROR"`) {
		t.Errorf("stuck line = %q, want an ERROR line", stuckLine)
	}
	if strings.Contains(stuckLine, cpGone) {
		t.Errorf("the stuck line carries the raw uid: %q", stuckLine)
	}
}
