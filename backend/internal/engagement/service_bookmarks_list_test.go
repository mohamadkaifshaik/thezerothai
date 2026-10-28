package engagement

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// listReader is the posts.Reader of the list tests: GetMany answers from docs (a missing id is absent, like the real
// reader) and records every call.
type listReader struct {
	*fakePosts
	getManyCalls [][]string
	getManyErr   error
}

func (l *listReader) GetMany(_ context.Context, ids []string) (map[string]*posts.Post, error) {
	l.getManyCalls = append(l.getManyCalls, append([]string(nil), ids...))
	if l.getManyErr != nil {
		return nil, l.getManyErr
	}
	out := map[string]*posts.Post{}
	for _, id := range ids {
		if p, ok := l.docs[id]; ok {
			out[id] = p
		}
	}
	return out, nil
}

// fakeGraph is the caller's graph snapshot (graph.Reader), counting reads.
type fakeGraph struct {
	snap  graph.Snapshot
	err   error
	calls int
}

func (g *fakeGraph) Snapshot(context.Context, string) (graph.Snapshot, error) {
	g.calls++
	return g.snap, g.err
}

func snapOf(blocked, blockedBy, muted []string) graph.Snapshot {
	set := func(ids []string) map[string]bool {
		m := map[string]bool{}
		for _, id := range ids {
			m[id] = true
		}
		return m
	}
	return graph.Snapshot{Blocked: set(blocked), BlockedBy: set(blockedBy), Muted: set(muted)}
}

var listKey = []byte("0123456789abcdef0123456789abcdef")

const caller = "viewer"

type listEnv struct {
	m      *Module
	s      *service
	bm     *fakeBMRepo
	rd     *listReader
	gr     *fakeGraph
	repo   *fakeRepo
	now    time.Time
	clock  *time.Time
	ctx    context.Context
	fields *logger.RequestInfo
}

type listOpt func(*Deps)

func newListEnv(t *testing.T, opts ...listOpt) *listEnv {
	t.Helper()
	e := &listEnv{
		bm: &fakeBMRepo{}, repo: &fakeRepo{}, gr: &fakeGraph{},
		rd:  &listReader{fakePosts: &fakePosts{docs: map[string]*posts.Post{}, hidden: map[string]bool{}}},
		now: time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC),
	}
	clk := e.now
	e.clock = &clk
	d := Deps{
		Repo: e.repo, Posts: e.rd.fakePosts, Reader: e.rd, Directory: fakeDir{created: e.now.Add(-48 * time.Hour)},
		NewAccountWindow: 24 * time.Hour, CacheTTL: time.Minute,
		BookmarkRepo: e.bm, BookmarksPerDay: 200, NewAccountBookmarksPerDay: 50, BookmarksMaxPerUser: 1000,
		Graph: e.gr, CursorKey: listKey, Now: func() time.Time { return *e.clock },
	}
	for _, o := range opts {
		o(&d)
	}
	m, err := New(d)
	if err != nil {
		t.Fatal(err)
	}
	e.m, e.s = m, m.s
	e.ctx, e.fields = logger.WithRequestInfo(context.Background())
	return e
}

func pid(n int) string { return fmt.Sprintf("%019d", n) }

// seed adds n bookmarks, newest first (post n is the newest), each pointing at a live visible post by "author".
func (e *listEnv) seed(n int) {
	for i := n; i >= 1; i-- {
		id := pid(i)
		e.bm.rows = append(e.bm.rows, ExportedBookmark{PostID: id, BookmarkedAt: e.now.Add(-time.Duration(n-i+1) * time.Minute)})
		e.rd.docs[id] = &posts.Post{ID: id, AuthorID: "author", Kind: posts.KindPost, Visibility: posts.VisibilityPublic}
	}
}

func (e *listEnv) field(key string) any {
	v, _ := e.fields.Get(key)
	if n, ok := v.(int64); ok { // slog stores ints as int64
		return int(n)
	}
	return v
}

func pageIDs(p BookmarkPage) []string {
	out := make([]string, 0, len(p.Rows))
	for _, r := range p.Rows {
		out = append(out, r.Post.ID)
	}
	return out
}

func TestListBookmarks_Paging(t *testing.T) {
	e := newListEnv(t)
	e.seed(25)
	p1, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p1.Rows) != 20 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %d rows, token %q; want 20 and a token", len(p1.Rows), p1.NextPageToken)
	}
	if p1.Rows[0].Post.ID != pid(25) || p1.Rows[19].Post.ID != pid(6) {
		t.Fatalf("page 1 runs %s..%s, want newest %s first", p1.Rows[0].Post.ID, p1.Rows[19].Post.ID, pid(25))
	}
	if want := e.now.Add(-time.Minute); !p1.Rows[0].BookmarkedAt.Equal(want) {
		t.Errorf("bookmarked_at = %v, want %v", p1.Rows[0].BookmarkedAt, want)
	}
	p2, err := e.m.ListBookmarks(e.ctx, caller, 0, p1.NextPageToken)
	if err != nil {
		t.Fatal(err)
	}
	if len(p2.Rows) != 5 || p2.NextPageToken != "" {
		t.Fatalf("page 2 = %d rows, token %q; want 5 and \"\"", len(p2.Rows), p2.NextPageToken)
	}
	if p2.Rows[0].Post.ID != pid(5) || p2.Rows[4].Post.ID != pid(1) {
		t.Errorf("page 2 runs %s..%s", p2.Rows[0].Post.ID, p2.Rows[4].Post.ID)
	}
	// One query and one batched GetMany per page, never one read per row.
	if len(e.bm.listCalls) != 2 || len(e.rd.getManyCalls) != 2 || len(e.rd.getManyCalls[0]) != 20 {
		t.Errorf("list calls %d, GetMany calls %d (%d ids), want 2, 2 (20 ids)", len(e.bm.listCalls), len(e.rd.getManyCalls), len(e.rd.getManyCalls[0]))
	}
	if e.bm.listCalls[1].after == nil || e.bm.listCalls[1].after.ID != pid(6) {
		t.Errorf("page 2 resumed after %+v, want the last row of page 1 (%s)", e.bm.listCalls[1].after, pid(6))
	}
	if e.gr.calls != 2 {
		t.Errorf("graph snapshots = %d, want 1 per page", e.gr.calls)
	}
}

func TestListBookmarks_PageSize(t *testing.T) {
	for _, tt := range []struct {
		name string
		in   int32
		want int
	}{{"0 is 20", 0, 20}, {"negative is 20", -3, 20}, {"1", 1, 1}, {"50", 50, 50}, {"51 is clamped", 51, 50}, {"huge is clamped", 1 << 30, 50}} {
		t.Run(tt.name, func(t *testing.T) {
			e := newListEnv(t)
			e.seed(60)
			p, err := e.m.ListBookmarks(e.ctx, caller, tt.in, "")
			if err != nil {
				t.Fatal(err)
			}
			if got := e.bm.listCalls[0].limit; got != tt.want {
				t.Errorf("query limit = %d, want %d", got, tt.want)
			}
			if len(p.Rows) != tt.want || p.NextPageToken == "" {
				t.Errorf("rows = %d token %q, want %d and a token", len(p.Rows), p.NextPageToken, tt.want)
			}
		})
	}
}

// A page that is exactly full issues a token (the next page is then empty and costs one read), like every other list.
func TestListBookmarks_ExactlyFullPage(t *testing.T) {
	e := newListEnv(t)
	e.seed(20)
	p1, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	if err != nil || len(p1.Rows) != 20 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %d rows, token %q, err %v", len(p1.Rows), p1.NextPageToken, err)
	}
	p2, err := e.m.ListBookmarks(e.ctx, caller, 0, p1.NextPageToken)
	if err != nil || len(p2.Rows) != 0 || p2.NextPageToken != "" {
		t.Fatalf("page 2 = %d rows, token %q, err %v; want empty and \"\"", len(p2.Rows), p2.NextPageToken, err)
	}
	if len(e.rd.getManyCalls) != 1 {
		t.Errorf("GetMany calls = %d: an empty page must not call it", len(e.rd.getManyCalls))
	}
}

func TestListBookmarks_Empty(t *testing.T) {
	e := newListEnv(t, func(d *Deps) { d.Flags = flags.NewRegistry(flags.Spec{Name: "engagement", Mode: flags.On}) })
	p, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	if err != nil || len(p.Rows) != 0 || p.NextPageToken != "" {
		t.Fatalf("empty list = %+v, %v", p, err)
	}
	// Nothing past the query: no GetMany, no graph, no userLikes.
	if len(e.rd.getManyCalls) != 0 || e.gr.calls != 0 || e.repo.loads != 0 {
		t.Errorf("GetMany %d, graph %d, userLikes %d reads on an empty list, want 0, 0, 0", len(e.rd.getManyCalls), e.gr.calls, e.repo.loads)
	}
	if e.field(fieldRowsReturned) != 0 || e.field(fieldRowsPruned) != 0 {
		t.Errorf("log fields returned=%v pruned=%v", e.field(fieldRowsReturned), e.field(fieldRowsPruned))
	}
}

// A foreign, tampered, expired, mis-bound or malformed token is VALIDATION page_token and reads nothing at all.
func TestListBookmarks_InvalidTokens(t *testing.T) {
	e := newListEnv(t)
	e.seed(25)
	good, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	tok := good.NextPageToken
	other := cursor.EncodeAt(listKey, bookmarksBinding("mallory"), cursor.Cursor{CreatedAt: e.now, DocID: pid(3)}, e.now)
	scheduled := cursor.EncodeAt(listKey, "scheduled|"+caller, cursor.Cursor{CreatedAt: e.now, DocID: pid(3)}, e.now)
	wrongKey := cursor.EncodeAt([]byte("another-key-another-key-another!"), bookmarksBinding(caller), cursor.Cursor{CreatedAt: e.now, DocID: pid(3)}, e.now)
	badID := cursor.EncodeAt(listKey, bookmarksBinding(caller), cursor.Cursor{CreatedAt: e.now, DocID: "not-a-post-id"}, e.now)
	zero := cursor.EncodeAt(listKey, bookmarksBinding(caller), cursor.Cursor{}, e.now)
	for name, token := range map[string]string{
		"foreign (another user's token)": other, "another list's binding": scheduled, "sealed with another key": wrongKey,
		"tampered": cursortest.Tamper(tok), "truncated": tok[:10], "garbage": "!!!not base64!!!", "not a post id": badID,
		"zero position": zero,
	} {
		t.Run(name, func(t *testing.T) {
			before := len(e.bm.listCalls) + len(e.rd.getManyCalls) + e.gr.calls + e.repo.loads
			_, err := e.m.ListBookmarks(e.ctx, caller, 0, token)
			ae := requireReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "page_token" {
				t.Errorf("metadata = %v, want field=page_token", ae.Metadata)
			}
			if after := len(e.bm.listCalls) + len(e.rd.getManyCalls) + e.gr.calls + e.repo.loads; after != before {
				t.Errorf("a refused token cost %d reads", after-before)
			}
		})
	}
	// The TTL is the cursor package's 24 h.
	*e.clock = e.now.Add(cursor.TTL + time.Minute)
	_, err = e.m.ListBookmarks(e.ctx, caller, 0, tok)
	_ = requireReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	*e.clock = e.now
	if _, err = e.m.ListBookmarks(e.ctx, caller, 0, tok); err != nil {
		t.Errorf("a fresh token was refused: %v", err)
	}
}

func TestListBookmarks_DropRules(t *testing.T) {
	quote := func(id, author, embedded string) *posts.Post {
		return &posts.Post{ID: id, AuthorID: author, Kind: posts.KindQuote, EmbeddedAuthorID: embedded}
	}
	tests := []struct {
		name string
		snap graph.Snapshot
		post *posts.Post // the single bookmarked post; nil = missing
		hide posts.Moderation
		want string // "", missing, hidden, blocked, muted
	}{
		{"plain", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a", Kind: posts.KindPost}, "", ""},
		{"missing", snapOf(nil, nil, nil), nil, "", "missing"},
		{"taken down", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a"}, posts.ModerationTakenDown, "hidden"},
		{"suspended author", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a"}, posts.ModerationSuspendedAuthor, "hidden"},
		{"author blocked by the caller", snapOf([]string{"a"}, nil, nil), &posts.Post{AuthorID: "a"}, "", "blocked"},
		{"author blocks the caller", snapOf(nil, []string{"a"}, nil), &posts.Post{AuthorID: "a"}, "", "blocked"},
		{"author muted", snapOf(nil, nil, []string{"a"}), &posts.Post{AuthorID: "a"}, "", "muted"},
		{"blocked beats muted", snapOf([]string{"a"}, nil, []string{"a"}), &posts.Post{AuthorID: "a"}, "", "blocked"},
		{"quote of a blocked author", snapOf([]string{"e"}, nil, nil), quote("", "a", "e"), "", "blocked"},
		{"quote of an author who blocks the caller", snapOf(nil, []string{"e"}, nil), quote("", "a", "e"), "", "blocked"},
		{"quote of a muted author", snapOf(nil, nil, []string{"e"}), quote("", "a", "e"), "", "muted"},
		{"quote of an unrelated author", snapOf([]string{"x"}, nil, nil), quote("", "a", "e"), "", ""},
		{"quote with a tombstone", snapOf([]string{"e"}, nil, nil), &posts.Post{AuthorID: "a", Kind: posts.KindQuote, EmbeddedAuthorID: "e", Embedded: &posts.Embedded{Unavailable: true}}, "", ""},
		{"overflow fails a foreign embedded author closed", graph.Snapshot{BlockedByOverflow: true}, quote("", "a", "e"), "", "blocked"},
		{"overflow fails a foreign direct author closed (W2-14 L-1)", graph.Snapshot{BlockedByOverflow: true}, &posts.Post{AuthorID: "a"}, "", "blocked"},
		{"overflow keeps the caller's own post", graph.Snapshot{BlockedByOverflow: true}, &posts.Post{AuthorID: caller}, "", ""},
		{"overflow keeps the caller's own quote of a foreign author", graph.Snapshot{BlockedByOverflow: true}, quote("", caller, "e"), "", ""},
		// W2-14 L-2: the same 0-read check Viewable applies. A non-public post needs the caller to follow its author.
		{"own post", snapOf([]string{"viewer"}, nil, []string{"viewer"}), &posts.Post{AuthorID: caller}, "", ""},
		{"own quote of a blocked author", snapOf([]string{"e"}, nil, nil), quote("", caller, "e"), "", ""},
		{"quote of the caller's own post", snapOf(nil, nil, nil), quote("", "a", caller), "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newListEnv(t)
			e.gr.snap = tt.snap
			id := pid(7)
			e.bm.rows = []ExportedBookmark{{PostID: id, BookmarkedAt: e.now}}
			if tt.post != nil {
				p := *tt.post
				if p.Visibility == "" {
					p.Visibility = posts.VisibilityPublic
				}
				p.ID, p.Moderation = id, tt.hide
				e.rd.docs[id] = &p
			}
			page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
			if err != nil {
				t.Fatal(err)
			}
			if got := len(page.Rows) == 1; got != (tt.want == "") {
				t.Fatalf("kept = %v, want %v", got, tt.want == "")
			}
			counts := map[string]any{"missing": e.field(fieldRowsDroppedMissing), "hidden": e.field(fieldRowsDroppedHidden),
				"blocked": e.field(fieldRowsDroppedBlocked), "muted": e.field(fieldRowsDroppedMuted)}
			for cause, got := range counts {
				want := 0
				if cause == tt.want {
					want = 1
				}
				if got != want {
					t.Errorf("rows_dropped_%s = %v, want %d", cause, got, want)
				}
			}
			wantDropped := 0
			if tt.want != "" {
				wantDropped = 1
			}
			if e.field(fieldRowsDropped) != wantDropped {
				t.Errorf("rows_dropped = %v, want %d", e.field(fieldRowsDropped), wantDropped)
			}
			// Only a missing post is pruned; hidden and blocked rows stay (a restore or an unblock brings them back).
			if wantPrune := tt.want == "missing"; (len(e.bm.pruneCalls) == 1) != wantPrune {
				t.Errorf("prune calls = %v, want prune = %v", e.bm.pruneCalls, wantPrune)
			}
		})
	}
}

// Dropped rows shorten the page but the token still resumes after the last QUERIED row, so the client never loops or
// re-reads them, and the page is not refilled server-side.
func TestListBookmarks_ShortPageKeepsCursor(t *testing.T) {
	e := newListEnv(t)
	e.seed(30)
	e.gr.snap = snapOf([]string{"bad"}, nil, nil)
	for i := 11; i <= 30; i++ { // the 20 newest are all by a blocked author
		e.rd.docs[pid(i)].AuthorID = "bad"
	}
	p1, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p1.Rows) != 0 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %d rows, token %q; want a short (empty) page that still has a token", len(p1.Rows), p1.NextPageToken)
	}
	if len(e.bm.listCalls) != 1 {
		t.Errorf("list queries = %d: the server must not refill a short page", len(e.bm.listCalls))
	}
	p2, err := e.m.ListBookmarks(e.ctx, caller, 0, p1.NextPageToken)
	if err != nil || len(p2.Rows) != 10 || p2.NextPageToken != "" {
		t.Fatalf("page 2 = %d rows, token %q, err %v; want the remaining 10", len(p2.Rows), p2.NextPageToken, err)
	}
	if got := pageIDs(p2); got[0] != pid(10) {
		t.Errorf("page 2 starts at %s, want %s", got[0], pid(10))
	}
	if e.field(fieldRowsDroppedBlocked) != 0 {
		t.Errorf("page 2 dropped %v blocked rows", e.field(fieldRowsDroppedBlocked))
	}
	if len(e.bm.pruneCalls) != 0 {
		t.Errorf("blocked rows were pruned: %v", e.bm.pruneCalls)
	}
}

func TestListBookmarks_PrunesMissingOnce(t *testing.T) {
	e := newListEnv(t)
	e.seed(5)
	delete(e.rd.docs, pid(4))
	delete(e.rd.docs, pid(2))
	// The instance's cached bookmark set knows both ids; the prune must remove them from it too.
	e.s.cache.set(caller, UserLikes{Bookmarks: []string{pid(1), pid(2), pid(3), pid(4), pid(5)}})

	page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := pageIDs(page); !slices.Equal(got, []string{pid(5), pid(3), pid(1)}) {
		t.Fatalf("rows = %v", got)
	}
	if len(e.bm.pruneCalls) != 1 || !slices.Equal(e.bm.pruneCalls[0], []string{pid(4), pid(2)}) {
		t.Fatalf("prune calls = %v, want one batch of the two missing ids", e.bm.pruneCalls)
	}
	if e.field(fieldRowsPruned) != 2 || e.field(fieldRowsDroppedMissing) != 2 {
		t.Errorf("rows_pruned %v, rows_dropped_missing %v, want 2 and 2", e.field(fieldRowsPruned), e.field(fieldRowsDroppedMissing))
	}
	st, ok := e.s.cache.get(caller)
	if !ok || slices.Contains(st.bookmarks, pid(4)) || slices.Contains(st.bookmarks, pid(2)) || len(st.bookmarks) != 3 {
		t.Errorf("cached bookmark set = %v, want the pruned ids gone", st.bookmarks)
	}

	// The next open finds nothing to prune: each row is paid for once.
	e.bm.pruneCalls = nil
	again, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	if err != nil || len(again.Rows) != 3 || len(e.bm.pruneCalls) != 0 {
		t.Fatalf("second open: %d rows, prune calls %v, err %v", len(again.Rows), e.bm.pruneCalls, err)
	}
	if e.field(fieldRowsPruned) != 0 {
		t.Errorf("rows_pruned = %v on the second open, want 0", e.field(fieldRowsPruned))
	}
}

func TestListBookmarks_PruneBestEffort(t *testing.T) {
	t.Run("a failed prune still serves the page", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(3)
		delete(e.rd.docs, pid(2))
		e.bm.pruneErr = errors.New("boom")
		page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		if err != nil || len(page.Rows) != 2 {
			t.Fatalf("rows %d, err %v; want the page served", len(page.Rows), err)
		}
		if e.field(fieldRowsPruned) != 0 || e.field(fieldRowsDroppedMissing) != 1 {
			t.Errorf("rows_pruned %v rows_dropped_missing %v, want 0 and 1", e.field(fieldRowsPruned), e.field(fieldRowsDroppedMissing))
		}
		// The next open tries again.
		e.bm.pruneErr = nil
		if _, err := e.m.ListBookmarks(e.ctx, caller, 0, ""); err != nil || len(e.bm.pruneCalls) != 2 {
			t.Errorf("retry: err %v, prune calls %d, want 2", err, len(e.bm.pruneCalls))
		}
	})
	t.Run("readonly never writes", func(t *testing.T) {
		e := newListEnv(t, func(d *Deps) { d.ReadOnly = true })
		e.seed(3)
		delete(e.rd.docs, pid(2))
		page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		if err != nil || len(page.Rows) != 2 || len(e.bm.pruneCalls) != 0 || e.field(fieldRowsPruned) != 0 {
			t.Fatalf("rows %d, prune calls %v, pruned %v, err %v", len(page.Rows), e.bm.pruneCalls, e.field(fieldRowsPruned), err)
		}
	})
	t.Run("the prune batch has a deadline", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(2)
		delete(e.rd.docs, pid(2))
		dl := &deadlineRepo{fakeBMRepo: e.bm}
		e.s.d.BookmarkRepo = dl
		if _, err := e.m.ListBookmarks(e.ctx, caller, 0, ""); err != nil || !dl.hadDeadline {
			t.Fatalf("err %v, prune ctx had a deadline = %v", err, dl.hadDeadline)
		}
	})
}

type deadlineRepo struct {
	*fakeBMRepo
	hadDeadline bool
}

func (d *deadlineRepo) Prune(ctx context.Context, uid string, ids []string) error {
	_, d.hadDeadline = ctx.Deadline()
	return d.fakeBMRepo.Prune(ctx, uid, ids)
}

func TestListBookmarks_GraphOnlyWhenNeeded(t *testing.T) {
	t.Run("only the caller's own posts", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(3)
		for _, p := range e.rd.docs {
			p.AuthorID = caller
		}
		page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		if err != nil || len(page.Rows) != 3 || e.gr.calls != 0 {
			t.Fatalf("rows %d, graph reads %d, err %v; want 3 rows and no graph read", len(page.Rows), e.gr.calls, err)
		}
	})
	t.Run("only missing and hidden rows", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(2)
		delete(e.rd.docs, pid(1))
		e.rd.docs[pid(2)].Moderation = posts.ModerationTakenDown
		if _, err := e.m.ListBookmarks(e.ctx, caller, 0, ""); err != nil || e.gr.calls != 0 {
			t.Fatalf("graph reads %d, err %v; want 0", e.gr.calls, err)
		}
	})
	t.Run("one snapshot however many rows", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(20)
		if _, err := e.m.ListBookmarks(e.ctx, caller, 0, ""); err != nil || e.gr.calls != 1 {
			t.Fatalf("graph reads %d, err %v; want 1", e.gr.calls, err)
		}
	})
}

func TestListBookmarks_ViewerHydration(t *testing.T) {
	const engOn, bmOn = "engagement", "bookmarks"
	reg := func(mode map[string]flags.Mode) posts.FlagChecker {
		var specs []flags.Spec
		for n, m := range mode {
			specs = append(specs, flags.Spec{Name: n, Mode: m})
		}
		return flags.NewRegistry(specs...)
	}
	tests := []struct {
		name      string
		fc        posts.FlagChecker
		wantLoads int
		wantLiked bool
		wantBook  bool
	}{
		{"neither flag: no read", reg(map[string]flags.Mode{engOn: flags.Off, bmOn: flags.Off}), 0, false, false},
		{"nil flags: no read", nil, 0, false, false},
		{"engagement on: full set", reg(map[string]flags.Mode{engOn: flags.On, bmOn: flags.Off}), 1, true, true},
		{"bookmarks only: bookmarks alone, no like leak", reg(map[string]flags.Mode{engOn: flags.Off, bmOn: flags.On}), 1, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newListEnv(t, func(d *Deps) { d.Flags = tt.fc })
			e.seed(2)
			e.repo.loaded = UserLikes{Recent: []string{pid(2)}, Bookmarks: []string{pid(2), pid(1)}}
			page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
			if err != nil || len(page.Rows) != 2 {
				t.Fatalf("rows %d, err %v", len(page.Rows), err)
			}
			if e.repo.loads != tt.wantLoads {
				t.Errorf("userLikes reads = %d, want %d", e.repo.loads, tt.wantLoads)
			}
			liked, _ := page.Viewer.Flags(page.Rows[0].Post)
			if liked != tt.wantLiked || page.Viewer.Bookmarked(page.Rows[0].Post) != tt.wantBook {
				t.Errorf("liked %v bookmarked %v, want %v %v", liked, page.Viewer.Bookmarked(page.Rows[0].Post), tt.wantLiked, tt.wantBook)
			}
		})
	}
	t.Run("no row left: no userLikes read", func(t *testing.T) {
		e := newListEnv(t, func(d *Deps) { d.Flags = reg(map[string]flags.Mode{engOn: flags.On}) })
		e.seed(2)
		e.gr.snap = snapOf([]string{"author"}, nil, nil)
		if _, err := e.m.ListBookmarks(e.ctx, caller, 0, ""); err != nil || e.repo.loads != 0 {
			t.Fatalf("userLikes reads %d, err %v; want 0", e.repo.loads, err)
		}
	})
}

func TestListBookmarks_Errors(t *testing.T) {
	internal := func(t *testing.T, err error) {
		t.Helper()
		var ae *apierr.Error
		if err == nil || errors.As(err, &ae) {
			t.Fatalf("err = %v, want a redacted internal error (not an apierr)", err)
		}
	}
	t.Run("no repo", func(t *testing.T) {
		e := newListEnv(t, func(d *Deps) { d.BookmarkRepo = nil })
		_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		internal(t, err)
	})
	t.Run("no cursor key", func(t *testing.T) {
		e := newListEnv(t, func(d *Deps) { d.CursorKey = nil })
		_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		internal(t, err)
	})
	t.Run("no graph", func(t *testing.T) {
		e := newListEnv(t, func(d *Deps) { d.Graph = nil })
		_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		internal(t, err)
	})
	t.Run("query fails", func(t *testing.T) {
		e := newListEnv(t)
		e.bm.listErr = errors.New("unavailable")
		_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		internal(t, err)
	})
	t.Run("GetMany fails: nothing is pruned", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(3)
		e.rd.getManyErr = errors.New("unavailable")
		_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		internal(t, err)
		if len(e.bm.pruneCalls) != 0 {
			t.Errorf("a failed GetMany pruned %v: only a confirmed-missing row may be pruned", e.bm.pruneCalls)
		}
	})
	t.Run("graph fails closed: no unfiltered page", func(t *testing.T) {
		e := newListEnv(t)
		e.seed(3)
		e.gr.err = errors.New("unavailable")
		_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
		internal(t, err)
	})
}

// The request line carries no ids, uids or text, only counts.
func TestListBookmarks_LogFields(t *testing.T) {
	e := newListEnv(t)
	e.seed(4)
	delete(e.rd.docs, pid(4))
	e.rd.docs[pid(3)].Moderation = posts.ModerationTakenDown
	e.rd.docs[pid(2)].AuthorID = "muted-author"
	e.gr.snap = snapOf(nil, nil, []string{"muted-author"})
	if _, err := e.m.ListBookmarks(e.ctx, caller, 0, ""); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		fieldOp: "list_bookmarks", fieldOutcome: outcomeDone, fieldRowsReturned: 1, fieldRowsDropped: 3,
		fieldRowsDroppedMissing: 1, fieldRowsDroppedHidden: 1, fieldRowsDroppedBlocked: 0, fieldRowsDroppedMuted: 1, fieldRowsPruned: 1,
	}
	for k, w := range want {
		if got := e.field(k); got != w {
			t.Errorf("%s = %v, want %v", k, got, w)
		}
	}
}

func TestBlockCause_NilSnapshotMapsAreSafe(t *testing.T) {
	if got := blockCause(graph.Snapshot{}, caller, &posts.Post{AuthorID: "a", EmbeddedAuthorID: "e"}); got != "" {
		t.Errorf("empty snapshot dropped a row: %q", got)
	}
}
