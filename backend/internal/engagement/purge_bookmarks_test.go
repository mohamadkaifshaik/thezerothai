package engagement

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

type fakePurger struct {
	pages   []int // deleted count per call
	calls   int
	cleared int
	err     error
	clrErr  error
}

func (f *fakePurger) PurgeBookmarksPage(context.Context, string) (int, error) {
	f.calls++
	if f.err != nil {
		return 0, f.err
	}
	if f.calls > len(f.pages) {
		return 0, nil
	}
	return f.pages[f.calls-1], nil
}

func (f *fakePurger) ClearBookmarkSet(context.Context, string) error {
	f.cleared++
	return f.clrErr
}

// The step deletes a page per call and finishes (clearing userLikes.bookmarks once) on the first short page, including
// the empty page of an account without bookmarks and the re-run of a finished one.
func TestBookmarkEraser_PurgeUser(t *testing.T) {
	tests := []struct {
		name        string
		pages       []int
		wantDone    []bool
		wantDeleted int
		wantCleared int
	}{
		{"no bookmarks", nil, []bool{true}, 0, 1},
		{"one short page", []int{7}, []bool{true}, 7, 1},
		{"exactly one full page needs the empty page after it", []int{500}, []bool{false, true}, 500, 1},
		{"the cap: 500 + 500 + the empty page", []int{500, 500}, []bool{false, false, true}, 1000, 1},
		{"a full page then a short one", []int{500, 3}, []bool{false, true}, 503, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := &fakePurger{pages: tt.pages}
			e := NewBookmarkEraser(f)
			cp := BookmarkCheckpoint{}
			for i, want := range tt.wantDone {
				var done bool
				var err error
				if cp, done, err = e.PurgeUser(context.Background(), "u1", cp); err != nil {
					t.Fatal(err)
				}
				if done != want {
					t.Fatalf("call %d: done = %v, want %v", i, done, want)
				}
			}
			if cp.Deleted != tt.wantDeleted || f.cleared != tt.wantCleared || f.calls != len(tt.wantDone) {
				t.Errorf("deleted %d cleared %d calls %d, want %d/%d/%d", cp.Deleted, f.cleared, f.calls, tt.wantDeleted, tt.wantCleared, len(tt.wantDone))
			}
		})
	}

	t.Run("errors keep the checkpoint and do not finish", func(t *testing.T) {
		boom := errors.New("boom")
		cp := BookmarkCheckpoint{Deleted: 5}
		next, done, err := NewBookmarkEraser(&fakePurger{err: boom}).PurgeUser(context.Background(), "u1", cp)
		if !errors.Is(err, boom) || done || next != cp {
			t.Errorf("purge error: next %+v done %v err %v", next, done, err)
		}
		next, done, err = NewBookmarkEraser(&fakePurger{clrErr: boom}).PurgeUser(context.Background(), "u1", cp)
		if !errors.Is(err, boom) || done || next != cp {
			t.Errorf("clear error: next %+v done %v err %v", next, done, err)
		}
	})
}

type fakeBMSource struct {
	rows   []ExportedBookmark
	afters []*posts.Position
}

func (f *fakeBMSource) ExportBookmarksPage(_ context.Context, _ string, after *posts.Position, limit int) ([]ExportedBookmark, error) {
	f.afters = append(f.afters, after)
	start := 0
	if after != nil {
		for i, r := range f.rows {
			if r.PostID == after.ID {
				start = i + 1
			}
		}
	}
	end := min(start+limit, len(f.rows))
	return f.rows[start:end], nil
}

// The export streams valid JSON in pages of 500 without ever carrying post content.
func TestBookmarkExporter_ExportUser(t *testing.T) {
	for _, n := range []int{0, 1, 500, 501, 1000} {
		t.Run(fmt.Sprint(n, " bookmarks"), func(t *testing.T) {
			src := &fakeBMSource{}
			base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
			for i := range n { // newest first
				src.rows = append(src.rows, ExportedBookmark{PostID: fmt.Sprintf("%019d", 5000-i), BookmarkedAt: base.Add(time.Duration(n-i) * time.Minute)})
			}
			var buf bytes.Buffer
			if err := NewBookmarkExporter(src).ExportUser(context.Background(), "u1", &buf); err != nil {
				t.Fatal(err)
			}
			var doc struct {
				Bookmarks []map[string]any `json:"bookmarks"`
			}
			if err := json.Unmarshal(buf.Bytes(), &doc); err != nil {
				t.Fatalf("export is not valid JSON: %v\n%.200s", err, buf.String())
			}
			if len(doc.Bookmarks) != n {
				t.Fatalf("rows = %d, want %d", len(doc.Bookmarks), n)
			}
			for _, r := range doc.Bookmarks {
				if len(r) != 2 || r["postId"] == nil || r["bookmarkedAt"] == nil {
					t.Fatalf("row = %v, want exactly postId and bookmarkedAt", r)
				}
			}
			wantPages := n/bookmarkPage + 1
			if len(src.afters) != wantPages || src.afters[0] != nil {
				t.Errorf("pages = %d (first cursor %v), want %d starting from the newest", len(src.afters), src.afters[0], wantPages)
			}
		})
	}
}
