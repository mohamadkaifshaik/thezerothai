package search

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor/cursortest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

var testKey = []byte("0123456789abcdef0123456789abcdef")

var t0 = time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)

// fakeReader serves ByHashtag from an in-memory newest-first list per tag, honouring Window.Before and the limit, and
// counts calls and reads the way the real reader bills them (len(result), minimum 1).
type fakeReader struct {
	posts.Reader
	mu    sync.Mutex
	byTag map[string][]*posts.Post
	calls []int // the limit of each call
	reads int
	err   error
	gate  chan struct{} // when set, ByHashtag blocks until it is closed
}

func (f *fakeReader) ByHashtag(_ context.Context, tag string, w posts.Window, limit int) ([]*posts.Post, error) {
	if f.gate != nil {
		<-f.gate
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, limit)
	if f.err != nil {
		return nil, f.err
	}
	var out []*posts.Post
	for _, p := range f.byTag[tag] {
		if w.Before != nil && !p.CreatedAt.Before(w.Before.CreatedAt) && (!p.CreatedAt.Equal(w.Before.CreatedAt) || p.ID >= w.Before.ID) {
			continue
		}
		if len(out) == limit {
			break
		}
		out = append(out, p)
	}
	f.reads += max(len(out), 1)
	return out, nil
}

func (f *fakeReader) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

type fakeGraph struct {
	snap  graph.Snapshot
	err   error
	calls atomic.Int64
}

func (g *fakeGraph) Snapshot(context.Context, string) (graph.Snapshot, error) {
	g.calls.Add(1)
	return g.snap, g.err
}

func snapshot() graph.Snapshot {
	return graph.Snapshot{Following: map[string]bool{}, Blocked: map[string]bool{}, Muted: map[string]bool{}, BlockedBy: map[string]bool{}}
}

type protectedSet map[string]bool

func (s protectedSet) Has(uid string) bool { return s[uid] }
func (s protectedSet) CanSee(viewer, author string, following bool) bool {
	return viewer == author || !s[author] || following
}

type fakeProtected struct {
	set protectedSet
	err error
}

func (f fakeProtected) Current(context.Context) (identity.ProtectedSet, error) { return f.set, f.err }

type fakeViewer struct {
	set   posts.ViewerSet
	calls atomic.Int64
}

func (v *fakeViewer) Viewer(context.Context, string) posts.ViewerSet {
	v.calls.Add(1)
	return v.set
}

type flagMap map[string]bool

func (f flagMap) Enabled(_, name string) bool { return f[name] }
func (f flagMap) GloballyOff(string) bool     { return false }

// rig is one service over fakes. clock is advanced by tests.
type rig struct {
	svc    Service
	reader *fakeReader
	graph  *fakeGraph
	viewer *fakeViewer
	clock  time.Time
	mu     sync.Mutex
}

func (r *rig) now() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.clock
}

func (r *rig) advance(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.clock = r.clock.Add(d)
}

type rigOpt func(*rig, *PostsDeps, flagMap)

func newRig(byTag map[string][]*posts.Post, opts ...rigOpt) *rig {
	r := &rig{reader: &fakeReader{byTag: byTag}, graph: &fakeGraph{snap: snapshot()}, viewer: &fakeViewer{}, clock: t0}
	deps := PostsDeps{Posts: r.reader, Graph: r.graph, Viewer: r.viewer, CursorKey: testKey, Now: r.now}
	fl := flagMap{FlagSearch: true}
	for _, o := range opts {
		o(r, &deps, fl)
	}
	r.svc = New(fl, WithPosts(deps))
	return r
}

func withProtected(f fakeProtected) rigOpt {
	return func(_ *rig, d *PostsDeps, _ flagMap) { d.Audience = posts.NewSnapshotAudience(f) }
}

func withSnap(fn func(*graph.Snapshot)) rigOpt {
	return func(r *rig, _ *PostsDeps, _ flagMap) { fn(&r.graph.snap) }
}

func withFlag(name string) rigOpt {
	return func(_ *rig, _ *PostsDeps, fl flagMap) { fl[name] = true }
}

// mkPost builds the n-th post of a tag: newer for a larger n, ids fixed width so string order is numeric order.
func mkPost(n int, author string, mutate ...func(*posts.Post)) *posts.Post {
	p := &posts.Post{
		ID: fmt.Sprintf("%019d", n), AuthorID: author, Kind: posts.KindPost, Hashtags: []string{"go"},
		CreatedAt: t0.Add(-time.Hour).Add(time.Duration(n) * time.Second),
	}
	for _, m := range mutate {
		m(p)
	}
	return p
}

// newestFirst builds posts 1..n by author "a", newest first.
func newestFirst(n int, mutate ...func(int, *posts.Post)) []*posts.Post {
	out := make([]*posts.Post, 0, n)
	for i := n; i >= 1; i-- {
		p := mkPost(i, "a")
		for _, m := range mutate {
			m(i, p)
		}
		out = append(out, p)
	}
	return out
}

func ids(resp *searchv1.SearchPostsResponse) []string {
	out := make([]string, 0, len(resp.GetPosts()))
	for _, v := range resp.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func idOf(n int) string { return fmt.Sprintf("%019d", n) }

func doPosts(t *testing.T, r *rig, uid, q string, tab searchv1.SearchTab, size int32, token string) *searchv1.SearchPostsResponse {
	t.Helper()
	resp, err := r.svc.Posts(context.Background(), uid, q, tab, size, token)
	if err != nil {
		t.Fatalf("Posts(%q, %v): %v", q, tab, err)
	}
	return resp
}

func wantAPIError(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, field string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want an apierr", err)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("err = %v / %v, want %v / %v", ae.Code, ae.Reason, code, reason)
	}
	if field != "" && ae.Metadata["field"] != field {
		t.Fatalf("field = %q, want %q", ae.Metadata["field"], field)
	}
}

const (
	latest = searchv1.SearchTab_SEARCH_TAB_LATEST
	top    = searchv1.SearchTab_SEARCH_TAB_TOP
	media  = searchv1.SearchTab_SEARCH_TAB_MEDIA
)

func TestPosts_Grammar(t *testing.T) {
	t.Parallel()
	long50 := strings.Repeat("a", 50)
	tests := []struct {
		name, q   string
		wantTag   string
		unsupport bool
		invalid   bool
	}{
		{"plain word", "go", "go", false, false},
		{"hash and upper case", "#Go", "go", false, false},
		{"upper case no sigil", "GO", "go", false, false},
		{"one character", "a", "a", false, false},
		{"hash one character", "#a", "a", false, false},
		{"devanagari", "#भारत", "भारत", false, false},
		{"accent composed", "#café", "café", false, false},
		{"accent decomposed is NFC", "#café", "café", false, false},
		{"surrounding spaces", "  #go  ", "go", false, false},
		{"50 code points", long50, long50, false, false},
		{"hash plus 50 code points", "#" + long50, long50, false, false},
		{"51 code points", long50 + "a", "", false, true},
		{"hash plus 51 code points", "#" + long50 + "a", "", false, true},
		{"empty", "", "", false, true},
		{"spaces only", "   ", "", false, true},
		{"hash alone", "#", "", false, true},
		{"at alone", "@", "", false, true},
		{"tab inside", "go\tlang", "", false, true},
		{"newline inside", "go\nlang", "", false, true},
		{"trailing newline is trimmed", "go\n", "go", false, false},
		{"bidi control", "#go" + string(rune(0x202e)), "", false, true},
		{"invalid utf-8", "go\xff", "", false, true},
		{"at handle", "@alice", "", true, false},
		{"hash digits only", "#123", "", true, false},
		{"two words", "go lang", "", true, false},
		{"punctuation", "#go!", "", true, false},
		{"double hash", "##go", "", true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(map[string][]*posts.Post{})
			resp, err := r.svc.Posts(context.Background(), "u", tt.q, top, 0, "")
			if tt.invalid {
				wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "query")
			} else if err != nil {
				t.Fatalf("err = %v", err)
			} else if resp.GetUnsupportedQuery() != tt.unsupport || resp.GetNormalizedTag() != tt.wantTag {
				t.Fatalf("unsupported=%v tag=%q, want %v %q", resp.GetUnsupportedQuery(), resp.GetNormalizedTag(), tt.unsupport, tt.wantTag)
			}
			if tt.invalid || tt.unsupport {
				if r.reader.callCount() != 0 || r.graph.calls.Load() != 0 {
					t.Errorf("a rejected query must read nothing: %d queries, %d graph reads", r.reader.callCount(), r.graph.calls.Load())
				}
			}
		})
	}
}

func TestPosts_HashAndPlainWordShareATag(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(3)})
	a := doPosts(t, r, "u", "#Go", latest, 0, "")
	b := doPosts(t, r, "u", "go", latest, 0, "")
	if a.NormalizedTag != "go" || b.NormalizedTag != "go" {
		t.Fatalf("normalized tags = %q, %q", a.NormalizedTag, b.NormalizedTag)
	}
}

func TestPosts_NegativePageSizeIsValidationWithZeroReads(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(3)})
	_, err := r.svc.Posts(context.Background(), "u", "go", latest, -1, "")
	wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_size")
	if r.reader.callCount() != 0 {
		t.Fatal("must read nothing")
	}
}

// Given 45 tagged posts, pages of 20 + 20 + 5 with "" last; page 1 comes from the one 30-post entry, the others are
// queries of page_size; no post repeats and the order is newest first.
func TestLatest_PagesOf20Plus20Plus5(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(45)})
	p1 := doPosts(t, r, "u", "#go", latest, 0, "")
	if len(p1.Posts) != 20 || p1.NextPageToken == "" || ids(p1)[0] != idOf(45) || ids(p1)[19] != idOf(26) {
		t.Fatalf("page 1 = %d posts, token %q, ids %v", len(p1.Posts), p1.NextPageToken, ids(p1))
	}
	if got := r.reader.calls; len(got) != 1 || got[0] != 30 {
		t.Fatalf("page 1 must be one 30-post entry load, calls = %v", got)
	}
	p2 := doPosts(t, r, "u", "#go", latest, 0, p1.NextPageToken)
	if len(p2.Posts) != 20 || p2.NextPageToken == "" || ids(p2)[0] != idOf(25) || ids(p2)[19] != idOf(6) {
		t.Fatalf("page 2 = %d posts, token %q, ids %v", len(p2.Posts), p2.NextPageToken, ids(p2))
	}
	p3 := doPosts(t, r, "u", "#go", latest, 0, p2.NextPageToken)
	if len(p3.Posts) != 5 || p3.NextPageToken != "" || ids(p3)[4] != idOf(1) {
		t.Fatalf("page 3 = %d posts, token %q", len(p3.Posts), p3.NextPageToken)
	}
	if got := r.reader.calls; len(got) != 3 || got[1] != 20 || got[2] != 20 {
		t.Fatalf("calls = %v, want [30 20 20]", got)
	}
	if r.reader.reads != 30+20+5 {
		t.Fatalf("reads = %d, want 55", r.reader.reads)
	}
}

func TestLatest_PageSizeEdges(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		n         int
		size      int32
		wantPosts int
		wantToken bool
		wantCalls []int
	}{
		{"fewer than the page: no token", 12, 20, 12, false, []int{30}},
		{"exactly the page from a short entry: no token", 20, 20, 20, false, []int{30}},
		{"a full entry of exactly 30 and page 30: token", 30, 30, 30, true, []int{30}},
		{"entry longer than the page: token", 40, 10, 10, true, []int{30}},
		{"page 50 skips the entry", 60, 50, 50, true, []int{50}},
		{"page 31 skips the entry: a fixed 50-row window", 60, 31, 31, true, []int{50}},
		{"page above 50 is clamped", 60, 500, 50, true, []int{50}},
		{"empty tag", 0, 20, 0, false, []int{30}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(map[string][]*posts.Post{"go": newestFirst(tt.n)})
			resp := doPosts(t, r, "u", "go", latest, tt.size, "")
			if len(resp.Posts) != tt.wantPosts || (resp.NextPageToken != "") != tt.wantToken {
				t.Fatalf("posts=%d token=%v, want %d %v", len(resp.Posts), resp.NextPageToken != "", tt.wantPosts, tt.wantToken)
			}
			if fmt.Sprint(r.reader.calls) != fmt.Sprint(tt.wantCalls) {
				t.Fatalf("calls = %v, want %v", r.reader.calls, tt.wantCalls)
			}
		})
	}
}

// A tampered, foreign (another caller, tag or tab), expired or TOP-bound token is VALIDATION page_token with 0 reads.
func TestPageToken_Rejections(t *testing.T) {
	t.Parallel()
	byTag := map[string][]*posts.Post{"go": newestFirst(45), "rust": newestFirst(45)}
	r := newRig(byTag)
	good := doPosts(t, r, "u", "go", latest, 0, "").NextPageToken
	media1 := doPosts(t, r, "u", "go", media, 0, "").NextPageToken
	if good == "" || media1 == "" {
		t.Fatalf("tokens: latest %q media %q", good, media1)
	}
	tests := []struct {
		name  string
		tab   searchv1.SearchTab
		uid   string
		q     string
		token string
		later time.Duration
	}{
		{"tampered", latest, "u", "go", cursortest.Tamper(good), 0},
		{"garbage", latest, "u", "go", "not-a-token", 0},
		{"another caller", latest, "v", "go", good, 0},
		{"another tag", latest, "u", "rust", good, 0},
		{"another tab", media, "u", "go", good, 0},
		{"a media token on latest", latest, "u", "go", media1, 0},
		{"a token on TOP", top, "u", "go", good, 0},
		{"expired", latest, "u", "go", good, 25 * time.Hour},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rr := newRig(byTag)
			rr.advance(tt.later)
			_, err := rr.svc.Posts(context.Background(), tt.uid, tt.q, tt.tab, 0, tt.token)
			wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "page_token")
			if rr.reader.callCount() != 0 || rr.graph.calls.Load() != 0 {
				t.Fatalf("a bad token must read nothing: %d queries %d graph", rr.reader.callCount(), rr.graph.calls.Load())
			}
		})
	}
}

// Given the newest 20 rows are by a blocked author, then page 1 filters the whole 30-row entry first, so the 10 visible rows
// come back (not an empty page), and the token still advances past the entry (W4-27).
func TestLatest_DroppedPostStillAdvancesToken(t *testing.T) {
	t.Parallel()
	all := newestFirst(45, func(n int, p *posts.Post) {
		if n > 25 { // the newest 20 (26..45) are by "bad"
			p.AuthorID = "bad"
		}
	})
	r := newRig(map[string][]*posts.Post{"go": all}, withSnap(func(s *graph.Snapshot) { s.Blocked["bad"] = true }))
	p1 := doPosts(t, r, "u", "go", latest, 0, "")
	if len(p1.Posts) != 10 || p1.NextPageToken == "" || ids(p1)[0] != idOf(25) || ids(p1)[9] != idOf(16) {
		t.Fatalf("page 1: %d posts, token %q; want the 10 visible rows 25..16 and a token", len(p1.Posts), p1.NextPageToken)
	}
	p2 := doPosts(t, r, "u", "go", latest, 0, p1.NextPageToken)
	if len(p2.Posts) != 15 || p2.NextPageToken != "" || ids(p2)[0] != idOf(15) {
		t.Fatalf("page 2 = %d posts, token %q", len(p2.Posts), p2.NextPageToken)
	}
}

// Given a taken-down post in a warm entry, then it is dropped at serve time, and the warm call reads nothing.
func TestEntry_TakedownInWarmEntryIsDropped(t *testing.T) {
	t.Parallel()
	all := newestFirst(5)
	r := newRig(map[string][]*posts.Post{"go": all})
	first := doPosts(t, r, "u", "go", latest, 0, "")
	if len(first.Posts) != 5 {
		t.Fatalf("first = %d", len(first.Posts))
	}
	all[2].Moderation = posts.ModerationTakenDown // the same shared object, as the posts cache replaces it
	second := doPosts(t, r, "u", "go", latest, 0, "")
	if len(second.Posts) != 4 {
		t.Fatalf("second = %d, want the taken-down post dropped", len(second.Posts))
	}
	if r.reader.callCount() != 1 {
		t.Fatalf("the second call must use the warm entry, queries = %d", r.reader.callCount())
	}
}

func TestEntry_EmptyResultIsCached(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"none": nil})
	doPosts(t, r, "u", "none", latest, 0, "")
	doPosts(t, r, "u", "none", top, 0, "")
	if r.reader.callCount() != 1 {
		t.Fatalf("an empty entry must be cached for the TTL, queries = %d", r.reader.callCount())
	}
}

// Two viewers (and three tabs) share one entry load; each viewer's filter is their own.
func TestEntry_SharedAcrossViewersAndTabs(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(10)})
	doPosts(t, r, "u1", "go", top, 0, "")
	doPosts(t, r, "u2", "go", latest, 0, "")
	doPosts(t, r, "u3", "go", media, 0, "")
	if r.reader.callCount() != 1 {
		t.Fatalf("queries = %d, want 1 shared entry load", r.reader.callCount())
	}
}

func TestEntry_ConcurrentMissesShareOneLoad(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(10)})
	r.reader.gate = make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := r.svc.Posts(context.Background(), fmt.Sprintf("u%d", i), "go", latest, 0, ""); err != nil {
				t.Errorf("Posts: %v", err)
			}
		}()
	}
	time.Sleep(50 * time.Millisecond) // let the callers reach the load; the assertion below is on the count, not the timing
	close(r.reader.gate)
	wg.Wait()
	if n := r.reader.callCount(); n != 1 {
		t.Fatalf("queries = %d, want 1", n)
	}
}

func TestEntry_QueryErrorIsInternalAndNotCached(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(3)})
	r.reader.err = errors.New("boom uid=u")
	_, err := r.svc.Posts(context.Background(), "u", "go", latest, 0, "")
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want a plain internal error", err)
	}
	r.reader.err = nil
	if resp := doPosts(t, r, "u", "go", latest, 0, ""); len(resp.Posts) != 3 {
		t.Fatalf("a failed load must not poison the entry: %d posts", len(resp.Posts))
	}
}

// The D6 matrix and ADR-0025 on LATEST (the filter is shared by every tab).
func TestFilter_Matrix(t *testing.T) {
	t.Parallel()
	quoteOf := func(author string) func(*posts.Post) {
		return func(p *posts.Post) {
			p.Kind = posts.KindQuote
			p.Embedded = &posts.Embedded{PostID: "q", Author: posts.AuthorSnapshot{UserID: author}}
		}
	}
	tests := []struct {
		name      string
		post      *posts.Post
		snap      func(*graph.Snapshot)
		protected protectedSet
		wantKept  bool
		wantEmbed postsv1.EmbedViewerState
	}{
		{"plain post", mkPost(1, "x"), nil, nil, true, 0},
		{"own post", mkPost(1, "u"), func(s *graph.Snapshot) { s.Blocked["u"] = true }, nil, true, 0},
		{"author blocked", mkPost(1, "x"), func(s *graph.Snapshot) { s.Blocked["x"] = true }, nil, false, 0},
		{"author blocks the caller", mkPost(1, "x"), func(s *graph.Snapshot) { s.BlockedBy["x"] = true }, nil, false, 0},
		{"author muted", mkPost(1, "x"), func(s *graph.Snapshot) { s.Muted["x"] = true }, nil, false, 0},
		{"quote of a blocked author", mkPost(1, "x", quoteOf("y")), func(s *graph.Snapshot) { s.Blocked["y"] = true }, nil, false, 0},
		{"quote of an author who blocks the caller", mkPost(1, "x", quoteOf("y")), func(s *graph.Snapshot) { s.BlockedBy["y"] = true }, nil, false, 0},
		{"quote of a muted author", mkPost(1, "x", quoteOf("y")), func(s *graph.Snapshot) { s.Muted["y"] = true }, nil, false, 0},
		{"own quote of a blocked author is kept", mkPost(1, "u", quoteOf("y")), func(s *graph.Snapshot) { s.Blocked["y"] = true }, nil, true, 0},
		{"quote of the caller", mkPost(1, "x", quoteOf("u")), nil, nil, true, 0},
		{"taken down", mkPost(1, "x", func(p *posts.Post) { p.Moderation = posts.ModerationTakenDown }), nil, nil, false, 0},
		{"suspended author", mkPost(1, "x", func(p *posts.Post) { p.Moderation = posts.ModerationSuspendedAuthor }), nil, nil, false, 0},
		{"protected author, not followed", mkPost(1, "x"), nil, protectedSet{"x": true}, false, 0},
		{"protected author, followed", mkPost(1, "x"), func(s *graph.Snapshot) { s.Following["x"] = true }, protectedSet{"x": true}, true, 0},
		{"quote of a protected author is kept stripped", mkPost(1, "x", quoteOf("p")), nil, protectedSet{"p": true}, true, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED},
		{"overflow: stranger", mkPost(1, "x"), func(s *graph.Snapshot) { s.BlockedByOverflow = true }, nil, false, 0},
		{"overflow: followed", mkPost(1, "x"), func(s *graph.Snapshot) { s.BlockedByOverflow = true; s.Following["x"] = true }, nil, true, 0},
		{"overflow: own", mkPost(1, "u"), func(s *graph.Snapshot) { s.BlockedByOverflow = true }, nil, true, 0},
		{"overflow: followed author's quote of a foreign post", mkPost(1, "x", quoteOf("y")), func(s *graph.Snapshot) { s.BlockedByOverflow = true; s.Following["x"] = true }, nil, false, 0},
		{"overflow: followed author's quote of the caller", mkPost(1, "x", quoteOf("u")), func(s *graph.Snapshot) { s.BlockedByOverflow = true; s.Following["x"] = true }, nil, true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			opts := []rigOpt{withProtected(fakeProtected{set: tt.protected})}
			if tt.snap != nil {
				opts = append(opts, withSnap(tt.snap))
			}
			r := newRig(map[string][]*posts.Post{"go": {tt.post}}, opts...)
			resp := doPosts(t, r, "u", "go", latest, 0, "")
			if kept := len(resp.Posts) == 1; kept != tt.wantKept {
				t.Fatalf("kept = %v, want %v", kept, tt.wantKept)
			}
			if tt.wantKept {
				v := resp.Posts[0]
				if v.EmbedViewerState != tt.wantEmbed {
					t.Errorf("embed state = %v, want %v", v.EmbedViewerState, tt.wantEmbed)
				}
				if tt.wantEmbed == postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED && v.Post.Embedded.GetText() != "" {
					t.Error("a PROTECTED embed must be stripped")
				}
			}
		})
	}
}

// The wire visibility of a protected author's post the caller follows is FOLLOWERS, as on timelines.
func TestFilter_ProtectedFollowedAuthorShowsFollowersVisibility(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": {mkPost(1, "x")}},
		withProtected(fakeProtected{set: protectedSet{"x": true}}), withSnap(func(s *graph.Snapshot) { s.Following["x"] = true }))
	resp := doPosts(t, r, "u", "go", latest, 0, "")
	if len(resp.Posts) != 1 || resp.Posts[0].Post.Visibility != postsv1.Visibility_VISIBILITY_FOLLOWERS {
		t.Fatalf("visibility = %v", resp.GetPosts())
	}
}

// A protected set that cannot be trusted is UNAVAILABLE for any call that needs it, never a partial or open page.
func TestFilter_ProtectedSetUnavailableFailsClosed(t *testing.T) {
	t.Parallel()
	for _, tab := range []searchv1.SearchTab{top, latest, media} {
		t.Run(tab.String(), func(t *testing.T) {
			t.Parallel()
			r := newRig(map[string][]*posts.Post{"go": {mkPost(1, "x", func(p *posts.Post) { p.Media = []posts.MediaRef{{ID: "m"}} })}},
				withProtected(fakeProtected{err: identity.ErrProtectedSetUnavailable}))
			_, err := r.svc.Posts(context.Background(), "u", "go", tab, 0, "")
			wantAPIError(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "")
		})
	}
}

func TestFilter_GraphErrorIsInternal(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(2)})
	r.graph.err = errors.New("graph down")
	_, err := r.svc.Posts(context.Background(), "u", "go", latest, 0, "")
	var ae *apierr.Error
	if err == nil || errors.As(err, &ae) {
		t.Fatalf("err = %v, want a plain internal error", err)
	}
}

func TestViewerFlags(t *testing.T) {
	t.Parallel()
	liked := posts.NewViewerSetWithBookmarks([]string{idOf(2)}, nil, []string{idOf(1)})
	tests := []struct {
		name      string
		flags     []string
		wantCalls int
		wantLiked bool
		wantMark  bool
	}{
		{"engagement and bookmarks off: no read, no flag", nil, 0, false, false},
		{"engagement on: the full set", []string{posts.EngagementFlagName}, 1, true, true},
		{"bookmarks only: bookmarked flag only", []string{posts.BookmarksFlagName}, 1, false, true},
		{"both", []string{posts.EngagementFlagName, posts.BookmarksFlagName}, 1, true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			opts := []rigOpt{}
			for _, f := range tt.flags {
				opts = append(opts, withFlag(f))
			}
			r := newRig(map[string][]*posts.Post{"go": newestFirst(2)}, opts...)
			r.viewer.set = liked
			resp := doPosts(t, r, "u", "go", latest, 0, "")
			if r.viewer.calls.Load() != int64(tt.wantCalls) {
				t.Fatalf("userLikes reads = %d, want %d", r.viewer.calls.Load(), tt.wantCalls)
			}
			byID := map[string]*postsv1.PostView{}
			for _, v := range resp.Posts {
				byID[v.Post.PostId] = v
			}
			if byID[idOf(2)].LikedByViewer != tt.wantLiked || byID[idOf(1)].BookmarkedByViewer != tt.wantMark {
				t.Fatalf("liked=%v bookmarked=%v, want %v %v", byID[idOf(2)].LikedByViewer, byID[idOf(1)].BookmarkedByViewer, tt.wantLiked, tt.wantMark)
			}
		})
	}
	t.Run("an empty page reads no viewer state", func(t *testing.T) {
		t.Parallel()
		r := newRig(map[string][]*posts.Post{"go": nil}, withFlag(posts.EngagementFlagName))
		doPosts(t, r, "u", "go", latest, 0, "")
		if r.viewer.calls.Load() != 0 || r.graph.calls.Load() != 0 {
			t.Fatalf("viewer reads %d graph reads %d, want 0 0", r.viewer.calls.Load(), r.graph.calls.Load())
		}
	})
}

// TOP: scores 5, 2, 0 order 5, 2, 0; an 8-day-old post with 100 likes is excluded; ties go newest first; one page of at
// most 20; the token is always "".
func TestTop_RankingWindowAndCap(t *testing.T) {
	t.Parallel()
	likes := func(n int64) func(*posts.Post) { return func(p *posts.Post) { p.LikeCount = n } }
	old := func(p *posts.Post) { p.CreatedAt = t0.Add(-8 * 24 * time.Hour); p.LikeCount = 100 }
	entry := []*posts.Post{ // newest first, as ByHashtag returns them
		mkPost(30, "a", likes(0)), mkPost(29, "a", likes(5)), mkPost(28, "a", likes(2)), mkPost(27, "a", likes(2)),
		mkPost(1, "a", old),
	}
	r := newRig(map[string][]*posts.Post{"go": entry})
	resp := doPosts(t, r, "u", "go", top, 0, "")
	want := []string{idOf(29), idOf(28), idOf(27), idOf(30)}
	if fmt.Sprint(ids(resp)) != fmt.Sprint(want) || resp.NextPageToken != "" {
		t.Fatalf("ids = %v token %q, want %v and no token", ids(resp), resp.NextPageToken, want)
	}
	if resp := doPosts(t, r, "u", "go", searchv1.SearchTab_SEARCH_TAB_UNSPECIFIED, 0, ""); fmt.Sprint(ids(resp)) != fmt.Sprint(want) {
		t.Fatalf("UNSPECIFIED must be TOP, ids = %v", ids(resp))
	}
	if resp := doPosts(t, r, "u", "go", searchv1.SearchTab(99), 0, ""); fmt.Sprint(ids(resp)) != fmt.Sprint(want) {
		t.Fatalf("an unknown tab must be TOP, ids = %v", ids(resp))
	}
}

func TestTop_ScoreWeightsAndOnePageOf20(t *testing.T) {
	t.Parallel()
	if got := topScore(&posts.Post{LikeCount: 1, RepostCount: 1, QuoteCount: 1, ReplyCount: 1}); got != 6 {
		t.Fatalf("score = %d, want likes + 2 reposts + 2 quotes + replies = 6", got)
	}
	r := newRig(map[string][]*posts.Post{"go": newestFirst(30, func(n int, p *posts.Post) { p.LikeCount = int64(n) })})
	for _, size := range []int32{0, 50, 5} {
		resp := doPosts(t, r, "u", "go", top, size, "")
		wantN := 20
		if size == 5 {
			wantN = 5
		}
		if len(resp.Posts) != wantN || resp.NextPageToken != "" || ids(resp)[0] != idOf(30) {
			t.Fatalf("size %d: %d posts, token %q, first %s", size, len(resp.Posts), resp.NextPageToken, ids(resp)[0])
		}
	}
}

// The ranking is deterministic: the same entry gives the same order on every call and for every viewer, and the shared
// entry is never reordered in place.
func TestTop_Deterministic(t *testing.T) {
	t.Parallel()
	entry := newestFirst(30, func(n int, p *posts.Post) { p.LikeCount = int64(n % 4) })
	var order []string
	for _, p := range entry {
		order = append(order, p.ID)
	}
	r := newRig(map[string][]*posts.Post{"go": entry})
	first := ids(doPosts(t, r, "u", "go", top, 0, ""))
	for i := 0; i < 5; i++ {
		if got := ids(doPosts(t, r, fmt.Sprintf("v%d", i), "go", top, 0, "")); fmt.Sprint(got) != fmt.Sprint(first) {
			t.Fatalf("order changed: %v vs %v", got, first)
		}
	}
	for i, p := range entry {
		if p.ID != order[i] {
			t.Fatal("the shared entry was reordered in place")
		}
	}
}

func TestTop_FiltersBeforeRanking(t *testing.T) {
	t.Parallel()
	entry := []*posts.Post{mkPost(3, "bad", func(p *posts.Post) { p.LikeCount = 99 }), mkPost(2, "a"), mkPost(1, "a")}
	r := newRig(map[string][]*posts.Post{"go": entry}, withSnap(func(s *graph.Snapshot) { s.Muted["bad"] = true }))
	if got := ids(doPosts(t, r, "u", "go", top, 0, "")); fmt.Sprint(got) != fmt.Sprint([]string{idOf(2), idOf(1)}) {
		t.Fatalf("ids = %v", got)
	}
}

func withMedia(p *posts.Post) { p.Media = []posts.MediaRef{{ID: "m", URL: "u"}} }

// Given 3 media posts among 30, MEDIA page 1 returns 3 and (the entry being full) a token; a scan with no media is []
// plus a token; a scan that reaches the end is "". A QUOTE's embedded images do not count.
func TestMedia_EntryScanAndEnd(t *testing.T) {
	t.Parallel()
	all := newestFirst(75, func(n int, p *posts.Post) {
		if n == 70 || n == 60 || n == 50 {
			withMedia(p)
		}
		if n == 49 { // a quote whose EMBEDDED post has images: own media empty
			p.Kind = posts.KindQuote
			p.Embedded = &posts.Embedded{PostID: "q", Author: posts.AuthorSnapshot{UserID: "z"}, Media: []posts.MediaRef{{ID: "e"}}}
		}
		if n == 10 {
			withMedia(p)
		}
	})
	// The entry is posts 75..46: media 70, 60, 50.
	r := newRig(map[string][]*posts.Post{"go": all})
	p1 := doPosts(t, r, "u", "go", media, 0, "")
	if fmt.Sprint(ids(p1)) != fmt.Sprint([]string{idOf(70), idOf(60), idOf(50)}) || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %v token %q", ids(p1), p1.NextPageToken)
	}
	// Scan 1: posts 45..16, no media -> an empty page with a token.
	p2 := doPosts(t, r, "u", "go", media, 0, p1.NextPageToken)
	if len(p2.Posts) != 0 || p2.NextPageToken == "" {
		t.Fatalf("scan 1 = %v token %q, want [] and a token", ids(p2), p2.NextPageToken)
	}
	// Scan 2: posts 15..1 (15 rows < 30): the end -> media 10 and "".
	p3 := doPosts(t, r, "u", "go", media, 0, p2.NextPageToken)
	if fmt.Sprint(ids(p3)) != fmt.Sprint([]string{idOf(10)}) || p3.NextPageToken != "" {
		t.Fatalf("scan 2 = %v token %q", ids(p3), p3.NextPageToken)
	}
	if got := r.reader.calls; fmt.Sprint(got) != fmt.Sprint([]int{30, 30, 30}) {
		t.Fatalf("calls = %v, want one entry load and two 30-post scans", got)
	}
}

func TestMedia_ShortEntryHasNoToken(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(12, func(n int, p *posts.Post) {
		if n%4 == 0 {
			withMedia(p)
		}
	})})
	resp := doPosts(t, r, "u", "go", media, 0, "")
	if len(resp.Posts) != 3 || resp.NextPageToken != "" {
		t.Fatalf("%d posts, token %q", len(resp.Posts), resp.NextPageToken)
	}
}

// A page_size below the number of media rows truncates after the last row returned and the token resumes there, so no
// media post is skipped across calls (the scan re-reads what was cut).
func TestMedia_TruncationResumesAfterTheLastReturnedRow(t *testing.T) {
	t.Parallel()
	all := newestFirst(60, func(n int, p *posts.Post) {
		if n%2 == 0 {
			withMedia(p)
		}
	})
	r := newRig(map[string][]*posts.Post{"go": all})
	var got []string
	tok := ""
	for i := 0; i < 30; i++ {
		resp := doPosts(t, r, "u", "go", media, 4, tok)
		if len(resp.Posts) > 4 {
			t.Fatalf("page %d has %d posts, page_size is 4", i, len(resp.Posts))
		}
		got = append(got, ids(resp)...)
		if tok = resp.NextPageToken; tok == "" {
			break
		}
	}
	if len(got) != 30 {
		t.Fatalf("collected %d media posts, want all 30 (even n of 60)", len(got))
	}
	for i, id := range got {
		if id != idOf(60-2*i) {
			t.Fatalf("row %d = %s, want %s (newest first, none skipped, none repeated)", i, id, idOf(60-2*i))
		}
	}
}

func TestMedia_FiltersApplyToMediaRows(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": {
		mkPost(3, "bad", withMedia), mkPost(2, "a", withMedia, func(p *posts.Post) { p.Moderation = posts.ModerationTakenDown }), mkPost(1, "a", withMedia),
	}}, withSnap(func(s *graph.Snapshot) { s.BlockedBy["bad"] = true }))
	if got := ids(doPosts(t, r, "u", "go", media, 0, "")); fmt.Sprint(got) != fmt.Sprint([]string{idOf(1)}) {
		t.Fatalf("ids = %v", got)
	}
}

// The request line carries tab, counts and drop causes, never the query.
func TestRequestLine_FieldsAndNoQuery(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"secretword": {mkPost(2, "bad"), mkPost(1, "a")}},
		withSnap(func(s *graph.Snapshot) { s.Blocked["bad"] = true }))
	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := r.svc.Posts(ctx, "u", "#SecretWord", latest, 0, ""); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{fieldTab: "LATEST", fieldQueryKind: queryKindHashtag, fieldQueryLen: 10, fieldResults: 1, fieldDropped: 1, fieldDroppedBlocked: 1, fieldCacheHit: false}
	for k, v := range want {
		if got, ok := info.Get(k); !ok || fmt.Sprint(got) != fmt.Sprint(v) {
			t.Errorf("%s = %v (%v), want %v", k, got, ok, v)
		}
	}
	for _, a := range info.Fields() {
		if strings.Contains(strings.ToLower(a.Value.String()), "secretword") {
			t.Errorf("field %s leaks the query", a.Key)
		}
	}
	ctx2, info2 := logger.WithRequestInfo(context.Background())
	if _, err := r.svc.Posts(ctx2, "u", "two words", top, 0, ""); err != nil {
		t.Fatal(err)
	}
	if k, _ := info2.Get(fieldQueryKind); k != queryKindUnsupported {
		t.Errorf("query_kind = %v", k)
	}
}

func TestWithPosts_IncompleteDepsStaysUnimplemented(t *testing.T) {
	t.Parallel()
	svc := New(flagMap{FlagSearch: true}, WithPosts(PostsDeps{}))
	_, err := svc.Posts(context.Background(), "u", "go", top, 0, "")
	wantAPIError(t, err, connect.CodeUnimplemented, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "")
}

// Flag modes for SearchPosts: refused before any read unless FEATURE_SEARCH is on for the caller.
func TestPosts_FlagDisabledReadsNothing(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": newestFirst(3)})
	svc := New(flagMap{}, WithPosts(PostsDeps{Posts: r.reader, Graph: r.graph, CursorKey: testKey}))
	_, err := svc.Posts(context.Background(), "u", "go", latest, 0, "")
	wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "")
	if r.reader.callCount() != 0 || r.graph.calls.Load() != 0 {
		t.Fatal("a disabled caller must read nothing")
	}
}

// TestPosts_FlagModesWithRealRegistry: with SearchPosts built, a caller is served exactly when FEATURE_SEARCH is on for
// them (off, allowlist, percent, on); a refused caller reads nothing and gets metadata feature=search.
func TestPosts_FlagModesWithRealRegistry(t *testing.T) {
	t.Parallel()
	const in, out = "uid-in", "uid-out"
	modes := []struct {
		name            string
		spec            flags.Spec
		wantIn, wantOut bool
	}{
		{"off", flags.Spec{Name: FlagSearch, Mode: flags.Off}, false, false},
		{"allowlist", flags.Spec{Name: FlagSearch, Mode: flags.Allowlist, Allowlist: map[string]struct{}{in: {}}}, true, false},
		{"percent 0 + allowlist", flags.Spec{Name: FlagSearch, Mode: flags.Percent, Percent: 0, Allowlist: map[string]struct{}{in: {}}}, true, false},
		{"percent 100", flags.Spec{Name: FlagSearch, Mode: flags.Percent, Percent: 100}, true, true},
		{"on", flags.Spec{Name: FlagSearch, Mode: flags.On}, true, true},
	}
	for _, m := range modes {
		t.Run(m.name, func(t *testing.T) {
			t.Parallel()
			for uid, wantOn := range map[string]bool{in: m.wantIn, out: m.wantOut} {
				r := &fakeReader{byTag: map[string][]*posts.Post{"go": newestFirst(3)}}
				g := &fakeGraph{snap: snapshot()}
				svc := New(flags.NewRegistry(m.spec, flags.Spec{Name: FlagTrends, Mode: flags.On}), WithPosts(PostsDeps{Posts: r, Graph: g, CursorKey: testKey}))
				resp, err := svc.Posts(context.Background(), uid, "go", latest, 0, "")
				if wantOn {
					if err != nil || len(resp.Posts) != 3 {
						t.Errorf("%s: err %v, %d posts", uid, err, len(resp.GetPosts()))
					}
					continue
				}
				wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "")
				var ae *apierr.Error
				if errors.As(err, &ae) && ae.Metadata["feature"] != FlagSearch {
					t.Errorf("%s: feature = %q", uid, ae.Metadata["feature"])
				}
				if r.callCount() != 0 || g.calls.Load() != 0 {
					t.Errorf("%s: a refused caller must read nothing", uid)
				}
			}
		})
	}
}
