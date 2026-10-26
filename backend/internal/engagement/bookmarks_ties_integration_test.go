//go:build integration

package engagement

// W2-13 (ADR-0023 D2, D6, D8): ordering and resumption of the bookmark query when createdAt values tie, for the export
// (pages of 500) and ListPage (pages of the caller's size), the eraser's re-run at the cap, and the concurrent same-post
// Add at repo level. The query is orderBy(createdAt DESC, __name__ DESC) resumed by StartAfter(createdAt, doc): a tie
// that straddles a page boundary must neither repeat nor skip a row.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// seedTied writes n docs whose createdAt comes from at(i) and returns the ids in the order the query must return them
// (createdAt DESC, id DESC).
func (e *repoEnv) seedTied(t *testing.T, uid string, n int, at func(i int) time.Time) []string {
	t.Helper()
	ctx := context.Background()
	type row struct {
		id string
		at time.Time
	}
	rows := make([]row, n)
	bw := e.client.BulkWriter(ctx)
	var jobs []*firestore.BulkWriterJob
	for i := range rows {
		rows[i] = row{fmt.Sprintf("%019d", 9_000+i), at(i)}
		j, err := bw.Create(e.bookmarkRef(uid, rows[i].id), bookmarkDoc{CreatedAt: rows[i].at})
		if err != nil {
			t.Fatal(err)
		}
		jobs = append(jobs, j)
	}
	bw.End()
	for _, j := range jobs {
		if _, err := j.Results(); err != nil {
			t.Fatal(err)
		}
	}
	slices.SortFunc(rows, func(a, b row) int {
		if c := b.at.Compare(a.at); c != 0 {
			return c
		}
		if b.id > a.id {
			return 1
		}
		return -1
	})
	out := make([]string, n)
	for i, r := range rows {
		out[i] = r.id
	}
	return out
}

// 1,000 bookmarks in three createdAt groups; the middle group of 500 straddles the 500-row page boundary of the export.
// The export must list every id exactly once, in the query order, with no duplicate and no gap.
func TestBookmarkExporter_TiesAcrossThePageBoundary(t *testing.T) {
	e := newRepoEnv(t)
	base := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	tied := base.Add(time.Hour)
	want := e.seedTied(t, "bm-ties", 1000, func(i int) time.Time {
		switch {
		case i < 250:
			return base // oldest group
		case i < 750:
			return tied // 500 docs share one createdAt: ids 9250..9749, split by the first page boundary
		default:
			return tied.Add(time.Hour)
		}
	})
	var buf bytes.Buffer
	c := measured(t, "export at the cap", budgettest.Budget{Reads: 1000 + 1}, func(ctx context.Context) {
		if err := NewBookmarkExporter(e.repo).ExportUser(ctx, "bm-ties", &buf); err != nil {
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
	got := make([]string, len(doc.Bookmarks))
	for i, b := range doc.Bookmarks {
		got[i] = b.PostID
	}
	if !slices.Equal(got, want) {
		seen := map[string]int{}
		for _, id := range got {
			seen[id]++
		}
		dups, missing := 0, 0
		for _, id := range want {
			switch seen[id] {
			case 0:
				missing++
			case 1:
			default:
				dups++
			}
		}
		t.Fatalf("export order differs from the query order: %d rows (want %d), %d duplicated, %d missing", len(got), len(want), dups, missing)
	}
	// 1,000 docs: page 1 = 500 (full), page 2 = 500 (full), page 3 = empty (1 read).
	if c.Reads() != 1001 {
		t.Errorf("export reads = %d, want 1001 (one per doc + the empty last page)", c.Reads())
	}
}

// ListPage resumed by position over ties: 45 docs with only 3 distinct createdAt values, paged at 7, must return each
// once in query order. Sub-microsecond differences (Firestore keeps microseconds) must not make a row repeat or vanish.
func TestBookmarkRepo_ListPageOverTiesAndSubMicrosecondTimes(t *testing.T) {
	e := newRepoEnv(t)
	base := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	seeded := e.seedTied(t, "bm-list-ties", 45, func(i int) time.Time {
		// three groups; inside a group the nanoseconds differ below the microsecond, which Firestore truncates away
		return base.Add(time.Duration(i/15)*time.Second + time.Duration(i%15)*37*time.Nanosecond)
	})
	ref, err := e.repo.ListPage(context.Background(), "bm-list-ties", nil, MaxListPage)
	if err != nil || len(ref) != len(seeded) {
		t.Fatalf("reference query = %d rows, %v; want %d", len(ref), err, len(seeded))
	}
	want := make([]string, len(ref))
	for i, r := range ref {
		want[i] = r.PostID
	}
	t.Logf("emulator keeps createdAt to the nanosecond: %v", ref[0].BookmarkedAt.Nanosecond()%1000 != 0 || ref[1].BookmarkedAt.Nanosecond()%1000 != 0)
	var got []string
	var after *posts.Position
	for pages := 0; pages < 20; pages++ {
		rows, err := e.repo.ListPage(context.Background(), "bm-list-ties", after, 7)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range rows {
			got = append(got, r.PostID)
		}
		if len(rows) < 7 {
			break
		}
		last := rows[len(rows)-1]
		// A cursor carries microseconds (cursor.Cursor via UnixMicro): resume exactly as the service does.
		after = &posts.Position{CreatedAt: last.BookmarkedAt.Truncate(time.Microsecond), ID: last.PostID}
	}
	if !slices.Equal(got, want) {
		t.Fatalf("paged order differs from the single-query order\n got  %v\n want %v", got, want)
	}
}

// Re-running the whole eraser after a full erase at the cap is a no-op that costs one read per invocation, and a
// checkpoint that is lost (the zero value) just starts again: the second run deletes nothing and recreates nothing.
func TestBookmarkEraser_RerunAtTheCap(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const uid = "bm-erase-cap"
	e.seedBookmarkDocs(t, uid, 1000)
	step := NewBookmarkEraser(e.repo)

	var cp BookmarkCheckpoint
	invocations := 0
	for done := false; !done; invocations++ {
		if invocations > 5 {
			t.Fatal("the eraser did not finish")
		}
		var err error
		if cp, done, err = step.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatal(err)
		}
	}
	if invocations != 3 || cp.Deleted != 1000 {
		t.Fatalf("an account at the cap took %d invocations and deleted %d, want 3 and 1000", invocations, cp.Deleted)
	}
	if docs, _ := e.client.Collection("users").Doc(uid).Collection("bookmarks").Limit(1).Documents(ctx).GetAll(); len(docs) != 0 {
		t.Fatal("documents survived")
	}
	// userLikes goes (the engagement step ran earlier); a re-run with a lost checkpoint must not bring it back.
	if _, err := e.client.Doc("userLikes/" + uid).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		c := measured(t, "re-run", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
			if _, done, err := step.PurgeUser(ctx, uid, BookmarkCheckpoint{}); err != nil || !done {
				t.Fatalf("re-run: done %v err %v", done, err)
			}
		})
		if c.Reads() != 1 || c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("re-run reads/writes/deletes = %d/%d/%d, want 1/0/0", c.Reads(), c.Writes(), c.Deletes())
		}
		if e.exists(t, "userLikes/"+uid) {
			t.Fatal("the re-run recreated userLikes")
		}
	}
}

// Ten parallel Adds of one post under ten different keys, at repo level: whatever the contention outcome, exactly one
// bookmark doc and one array entry exist and the quota is charged once.
func TestBookmarkRepo_SamePostDifferentKeysConcurrently(t *testing.T) {
	e := newRepoEnv(t)
	const uid, pid = "bm-same-post", "0000000000000000141"
	var wg sync.WaitGroup
	errs := make([]error, 10)
	for i := range errs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = e.repo.Add(context.Background(), addParams(uid, fmt.Sprintf("key-same-post-%04d", i), pid))
		}()
	}
	wg.Wait()
	if !e.bookmarkExists(t, uid, pid) {
		t.Fatalf("no bookmark after ten adds: %v", errs)
	}
	if ids := e.bookmarks(t, uid); !slices.Equal(ids, []string{pid}) {
		t.Errorf("userLikes.bookmarks = %v, want [%s]", ids, pid)
	}
	if q := e.quotaBookmarks(t, uid); q != 1 {
		t.Errorf("quotas.bookmarks = %d, want 1 (charged once)", q)
	}
}
