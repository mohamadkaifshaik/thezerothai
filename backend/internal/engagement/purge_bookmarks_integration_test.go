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

// The `bookmarks` step: pages of 500, a re-run is a no-op, and
// userLikes.bookmarks is cleared field-level (the other fields survive; a deleted userLikes is not recreated).
func TestBookmarkEraser_Integration(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const uid = "bm-erase"
	e.seedBookmarkDocs(t, uid, 501)
	step := NewBookmarkEraser(e.repo)
	left := func() int {
		docs, err := e.client.Collection("users").Doc(uid).Collection("bookmarks").Limit(10).Documents(ctx).GetAll()
		if err != nil {
			t.Fatal(err)
		}
		return len(docs)
	}

	// A page deletes at most 500 documents (Firestore's batch limit): after page 1 one document is left.
	cp, done, err := step.PurgeUser(ctx, uid, BookmarkCheckpoint{})
	if err != nil || done {
		t.Fatalf("page 1: done %v err %v", done, err)
	}
	if cp.Deleted != 500 || left() != 1 {
		t.Fatalf("after page 1: checkpoint %+v, %d documents left, want 500 deleted and 1 left", cp, left())
	}
	cp, done, err = step.PurgeUser(ctx, uid, cp)
	if err != nil || !done {
		t.Fatalf("page 2: done %v err %v", done, err)
	}
	if cp.Deleted != 501 {
		t.Errorf("checkpoint = %+v", cp)
	}
	if left() != 0 {
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

	// Idempotent re-run: nothing left to delete, so the step finishes at once and reports no deletions; the second run after userLikes is gone recreates nothing.
	rerun, done, err := step.PurgeUser(ctx, uid, BookmarkCheckpoint{})
	if err != nil || !done || rerun.Deleted != 0 {
		t.Fatalf("re-run: done %v checkpoint %+v err %v", done, rerun, err)
	}
	if _, err := e.client.Doc("userLikes/" + uid).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	if _, done, err := step.PurgeUser(ctx, uid, BookmarkCheckpoint{}); err != nil || !done {
		t.Fatalf("re-run: done %v err %v", done, err)
	}
	if e.exists(t, "userLikes/"+uid) {
		t.Errorf("userLikes recreated: the step must not recreate a deleted userLikes")
	}

	// An account that never bookmarked finishes at once with nothing deleted.
	if none, done, err := step.PurgeUser(ctx, "bm-erase-none", BookmarkCheckpoint{}); err != nil || !done || none.Deleted != 0 {
		t.Fatalf("empty: done %v checkpoint %+v err %v", done, none, err)
	}
	// Another user's bookmarks are untouched.
	e.seedBookmarkDocs(t, "bm-keep", 2)
	if _, _, err := step.PurgeUser(ctx, "bm-erase", BookmarkCheckpoint{}); err != nil {
		t.Fatal(err)
	}
	if !e.exists(t, "users/bm-keep/bookmarks/"+fmt.Sprintf("%019d", 5000)) {
		t.Error("another user's bookmark was deleted")
	}
}

// The export: newest first, post id and time only, pages of 500 (a cap-sized set across two pages).
func TestBookmarkExporter_Integration(t *testing.T) {
	e := newRepoEnv(t)
	const uid = "bm-export"
	ids := e.seedBookmarkDocs(t, uid, 501)
	var buf bytes.Buffer
	if err := NewBookmarkExporter(e.repo).ExportUser(context.Background(), uid, &buf); err != nil {
		t.Fatal(err)
	}
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
	if err := NewBookmarkExporter(e.repo).ExportUser(context.Background(), "bm-export-none", &buf); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "{\"bookmarks\":[]}\n" {
		t.Errorf("empty export = %q, want {\"bookmarks\":[]}", buf.String())
	}
}
