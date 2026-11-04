//go:build integration

package engagement

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// seedBookmarkDocs writes n bookmark docs (ids 5000+i, createdAt rising with i) and the matching userLikes set.
func (e *repoEnv) seedBookmarkDocs(t *testing.T, uid string, n int) []string {
	t.Helper()
	ctx := context.Background()
	bw := e.client.BulkWriter(ctx)
	ids := make([]string, n)
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	for i := range ids {
		ids[i] = fmt.Sprintf("%019d", 5000+i)
		if _, err := bw.Create(e.bookmarkRef(uid, ids[i]), bookmarkDoc{CreatedAt: base.Add(time.Duration(i) * time.Minute)}); err != nil {
			t.Fatal(err)
		}
	}
	bw.End()
	if _, err := e.client.Doc("userLikes/"+uid).Set(ctx, map[string]any{"bookmarks": ids, "recent": []string{"9"}}); err != nil {
		t.Fatal(err)
	}
	return ids
}

func (e *repoEnv) bookmarkRef(uid, postID string) *firestore.DocumentRef {
	return e.repo.bookmarkRef(uid, postID)
}

// The `bookmarks` step: pages of 500 (1 read + 1 delete per doc), the empty page costs 1 read, a re-run is a no-op, and
// userLikes.bookmarks is cleared field-level (the other fields survive; a deleted userLikes is not recreated).
func TestBookmarkEraser_Integration(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const uid = "bm-erase"
	e.seedBookmarkDocs(t, uid, 501)
	step := NewBookmarkEraser(e.repo)

	var cp BookmarkCheckpoint
	var done bool
	_ = runMeasured(t, "page 1", func(ctx context.Context) {
		var err error
		if cp, done, err = step.PurgeUser(ctx, uid, cp); err != nil || done {
			t.Fatalf("page 1: done %v err %v", done, err)
		}
	})
	_ = runMeasured(t, "page 2", func(ctx context.Context) {
		var err error
		if cp, done, err = step.PurgeUser(ctx, uid, cp); err != nil || !done {
			t.Fatalf("page 2: done %v err %v", done, err)
		}
	})
	if cp.Deleted != 501 {
		t.Errorf("checkpoint = %+v", cp)
	}
	if docs, _ := e.client.Collection("users").Doc(uid).Collection("bookmarks").Limit(1).Documents(ctx).GetAll(); len(docs) != 0 {
		t.Error("bookmark docs survived")
	}
	if got := e.bookmarks(t, uid); len(got) != 0 {
		t.Errorf("userLikes.bookmarks = %v, want cleared", got)
	}
	snap, err := e.client.Doc("userLikes/" + uid).Get(ctx)
	if err != nil {
		t.Fatalf("userLikes was deleted: %v", err)
	}
	if v, _ := snap.DataAt("recent"); fmt.Sprint(v) != "[9]" {
		t.Errorf("userLikes.recent = %v: the clear must be field-level", v)
	}

	// Idempotent re-run: 1 read for the empty page, no delete; the second run after userLikes is gone recreates nothing.
	_ = runMeasured(t, "re-run", func(ctx context.Context) {
		if _, done, err := step.PurgeUser(ctx, uid, BookmarkCheckpoint{}); err != nil || !done {
			t.Fatalf("re-run: done %v err %v", done, err)
		}
	})
	if _, err := e.client.Doc("userLikes/" + uid).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	_ = runMeasured(t, "re-run without userLikes", func(ctx context.Context) {
		if _, done, err := step.PurgeUser(ctx, uid, BookmarkCheckpoint{}); err != nil || !done {
			t.Fatalf("re-run: done %v err %v", done, err)
		}
	})
	if e.exists(t, "userLikes/"+uid) {
		t.Errorf("userLikes recreated: the step must not recreate a deleted userLikes")
	}

	// An account that never bookmarked: 1 read.
	_ = runMeasured(t, "empty", func(ctx context.Context) {
		if _, done, err := step.PurgeUser(ctx, "bm-erase-none", BookmarkCheckpoint{}); err != nil || !done {
			t.Fatalf("empty: done %v err %v", done, err)
		}
	})
	// Another user's bookmarks are untouched.
	e.seedBookmarkDocs(t, "bm-keep", 2)
	if _, _, err := step.PurgeUser(ctx, "bm-erase", BookmarkCheckpoint{}); err != nil {
		t.Fatal(err)
	}
	if !e.exists(t, "users/bm-keep/bookmarks/"+fmt.Sprintf("%019d", 5000)) {
		t.Error("another user's bookmark was deleted")
	}
}

func runMeasured(t *testing.T, name string, fn func(ctx context.Context)) *budget.Counter {
	t.Helper()
	return measured(t, name, fn)
}

// The export: newest first, post id and time only, pages of 500 (a cap-sized set across two pages), 1 read per doc.
func TestBookmarkExporter_Integration(t *testing.T) {
	e := newRepoEnv(t)
	const uid = "bm-export"
	ids := e.seedBookmarkDocs(t, uid, 501)
	var buf bytes.Buffer
	measured(t, "export", func(ctx context.Context) {
		if err := NewBookmarkExporter(e.repo).ExportUser(ctx, uid, &buf); err != nil {
			t.Fatal(err)
		}
	})
	var doc struct {
		Bookmarks []struct {
			PostID       string    `json:"postId"`
			BookmarkedAt time.Time `json:"bookmarkedAt"`
		} `json:"bookmarks"`
	}
	if err := json.Unmarshal(buf.Bytes(), &doc); err != nil {
		t.Fatalf("export is not valid JSON: %v", err)
	}
	if len(doc.Bookmarks) != 501 || doc.Bookmarks[0].PostID != ids[500] || doc.Bookmarks[500].PostID != ids[0] {
		t.Fatalf("rows = %d, first %v, last %v: want 501 newest first", len(doc.Bookmarks), doc.Bookmarks[0].PostID, doc.Bookmarks[len(doc.Bookmarks)-1].PostID)
	}
	buf.Reset()
	measured(t, "empty export", func(ctx context.Context) {
		if err := NewBookmarkExporter(e.repo).ExportUser(ctx, "bm-export-none", &buf); err != nil {
			t.Fatal(err)
		}
	})
	if buf.String() != "{\"bookmarks\":[]}\n" {
		t.Errorf("empty export = %q, want {\"bookmarks\":[]}", buf.String())
	}
}
