package engagement

import (
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// seedLikes stores n likes as userLikes.recent (post 1 liked first, post n newest, so the array is oldest first like
// the real one) and a live visible post by "author" for each. The newest-first order is pid(n)..pid(1).
func (e *listEnv) seedLikes(n int) []string {
	recent := make([]string, 0, n)
	for i := 1; i <= n; i++ {
		recent = append(recent, pid(i))
		e.rd.docs[pid(i)] = &posts.Post{ID: pid(i), AuthorID: "author", Kind: posts.KindPost, Visibility: posts.VisibilityPublic}
	}
	e.repo.loaded = UserLikes{Recent: recent}
	return recent
}

func likedIDs(p LikesPage) []string {
	out := make([]string, 0, len(p.Posts))
	for _, x := range p.Posts {
		out = append(out, x.ID)
	}
	return out
}

// descIDs lists pid(from), pid(from-1) .. pid(to): newest first when from > to.
func descIDs(from, to int) []string {
	var out []string
	for i := from; i >= to; i-- {
		out = append(out, pid(i))
	}
	return out
}

// 25 likes: the first call returns the 20 most recently liked posts and a token, the second the remaining 5 and "".
// One userLikes read serves both pages (the instance cache), one batched GetMany per page.
func TestListLikedPosts_Paging(t *testing.T) {
	e := newListEnv(t)
	e.seedLikes(25)
	p1, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := likedIDs(p1); !slices.Equal(got, descIDs(25, 6)) || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %v token %q; want the newest 20 (%s..%s) and a token", got, p1.NextPageToken, pid(25), pid(6))
	}
	p2, err := e.m.ListLikedPosts(e.ctx, caller, 0, p1.NextPageToken)
	if err != nil {
		t.Fatal(err)
	}
	if got := likedIDs(p2); !slices.Equal(got, descIDs(5, 1)) || p2.NextPageToken != "" {
		t.Fatalf("page 2 = %v token %q; want the last 5 and \"\"", got, p2.NextPageToken)
	}
	if e.repo.loads != 1 {
		t.Errorf("userLikes loads = %d, want 1 (cached for the second page)", e.repo.loads)
	}
	if len(e.rd.getManyCalls) != 2 || len(e.rd.getManyCalls[0]) != 20 || len(e.rd.getManyCalls[1]) != 5 {
		t.Errorf("GetMany calls = %v, want one batched call per page (20 then 5 ids)", e.rd.getManyCalls)
	}
	if e.gr.calls != 2 {
		t.Errorf("graph snapshots = %d, want 1 per page", e.gr.calls)
	}
	if len(e.bm.listCalls) != 0 || len(e.bm.pruneCalls) != 0 {
		t.Errorf("the bookmark repo was touched: %d list, %d prune", len(e.bm.listCalls), len(e.bm.pruneCalls))
	}
}

// A page that ends exactly at the oldest like has no token: the array is in hand, so no empty trailing page is needed.
func TestListLikedPosts_ExactFitHasNoToken(t *testing.T) {
	e := newListEnv(t)
	e.seedLikes(20)
	p, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil || len(p.Posts) != 20 || p.NextPageToken != "" {
		t.Fatalf("page = %d rows token %q err %v; want 20 and \"\"", len(p.Posts), p.NextPageToken, err)
	}
	e = newListEnv(t)
	e.seedLikes(21)
	p, err = e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil || len(p.Posts) != 20 || p.NextPageToken == "" {
		t.Fatalf("21 likes: page = %d rows token %q err %v; want 20 and a token", len(p.Posts), p.NextPageToken, err)
	}
	p, err = e.m.ListLikedPosts(e.ctx, caller, 0, p.NextPageToken)
	if err != nil || !slices.Equal(likedIDs(p), []string{pid(1)}) || p.NextPageToken != "" {
		t.Fatalf("last page = %v token %q err %v", likedIDs(p), p.NextPageToken, err)
	}
}

func TestListLikedPosts_PageSize(t *testing.T) {
	for _, tt := range []struct {
		name string
		in   int32
		want int
	}{{"0 is 20", 0, 20}, {"negative is 20", -3, 20}, {"1", 1, 1}, {"50", 50, 50}, {"51 is clamped", 51, 50}, {"huge is clamped", 1 << 30, 50}} {
		t.Run(tt.name, func(t *testing.T) {
			e := newListEnv(t)
			e.seedLikes(60)
			p, err := e.m.ListLikedPosts(e.ctx, caller, tt.in, "")
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Posts) != tt.want || p.NextPageToken == "" || len(e.rd.getManyCalls[0]) != tt.want {
				t.Errorf("rows = %d (GetMany %d ids) token %q, want %d and a token", len(p.Posts), len(e.rd.getManyCalls[0]), p.NextPageToken, tt.want)
			}
		})
	}
}

// An empty array costs the userLikes read and nothing else: no GetMany, no graph snapshot. So does a user with no doc.
func TestListLikedPosts_EmptyArray(t *testing.T) {
	e := newListEnv(t)
	p, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil || len(p.Posts) != 0 || p.NextPageToken != "" {
		t.Fatalf("empty list: %d rows token %q err %v", len(p.Posts), p.NextPageToken, err)
	}
	if len(e.rd.getManyCalls) != 0 || e.gr.calls != 0 || e.repo.loads != 1 {
		t.Errorf("GetMany %d, graph %d, userLikes %d reads on an empty array, want 0, 0, 1", len(e.rd.getManyCalls), e.gr.calls, e.repo.loads)
	}
	if e.field(fieldRowsReturned) != 0 || e.field(fieldRowsDropped) != 0 {
		t.Errorf("log fields returned=%v dropped=%v", e.field(fieldRowsReturned), e.field(fieldRowsDropped))
	}
}

// A foreign, tampered, expired, mis-bound or malformed token is VALIDATION page_token and reads nothing at all.
func TestListLikedPosts_InvalidTokens(t *testing.T) {
	e := newListEnv(t)
	e.seedLikes(25)
	good, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	tok := good.NextPageToken
	seal := func(key []byte, binding, payload string) string {
		return cursor.EncodeAt(key, binding, cursor.Cursor{CreatedAt: e.now, DocID: payload}, e.now)
	}
	payload := "v1:" + pid(5) + ":" + pid(6) + ":20"
	mine := likesBinding(caller)
	zero := cursor.EncodeAt(listKey, mine, cursor.Cursor{}, e.now)
	for name, token := range map[string]string{
		"foreign (another user's token)": seal(listKey, likesBinding("mallory"), payload),
		"the bookmarks list's token":     seal(listKey, bookmarksBinding(caller), payload),
		"sealed with another key":        seal([]byte("another-key-another-key-another!"), mine, payload),
		"tampered":                       tok[:len(tok)-2] + "AA",
		"truncated":                      tok[:10],
		"garbage":                        "!!!not base64!!!",
		"zero position":                  zero,
		"a bookmarks-style payload":      seal(listKey, mine, pid(3)),
		"another payload version":        seal(listKey, mine, "v2:"+pid(5)+":"+pid(6)+":20"),
		"missing the index":              seal(listKey, mine, "v1:"+pid(5)+":"+pid(6)),
		"extra field":                    seal(listKey, mine, payload+":1"),
		"next is not a post id":          seal(listKey, mine, "v1:nope:"+pid(6)+":20"),
		"last is not a post id":          seal(listKey, mine, "v1:"+pid(5)+":nope:20"),
		"negative index":                 seal(listKey, mine, "v1:"+pid(5)+":"+pid(6)+":-1"),
		"index is not a number":          seal(listKey, mine, "v1:"+pid(5)+":"+pid(6)+":x"),
		"empty anchors":                  seal(listKey, mine, "v1:::"),
		"issued in the far future":       cursor.EncodeAt(listKey, mine, cursor.Cursor{CreatedAt: e.now, DocID: payload}, e.now.Add(48*time.Hour)),
		"issued longer than 24 h ago":    cursor.EncodeAt(listKey, mine, cursor.Cursor{CreatedAt: e.now, DocID: payload}, e.now.Add(-cursor.TTL-time.Minute)),
	} {
		t.Run(name, func(t *testing.T) {
			before := len(e.rd.getManyCalls) + e.gr.calls + e.repo.loads
			_, err := e.m.ListLikedPosts(e.ctx, caller, 0, token)
			ae := requireReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "page_token" {
				t.Errorf("metadata = %v, want field=page_token", ae.Metadata)
			}
			if after := len(e.rd.getManyCalls) + e.gr.calls + e.repo.loads; after != before {
				t.Errorf("a refused token cost %d reads", after-before)
			}
		})
	}
	// The TTL is the cursor package's 24 h.
	*e.clock = e.now.Add(cursor.TTL + time.Minute)
	_, err = e.m.ListLikedPosts(e.ctx, caller, 0, tok)
	_ = requireReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	*e.clock = e.now
	if _, err = e.m.ListLikedPosts(e.ctx, caller, 0, tok); err != nil {
		t.Errorf("a fresh token was refused: %v", err)
	}
}

// likesResume is the ADR-0024 D6 rule, table-driven over the changes that can happen to the array between two pages.
// The base list is liked 1..10 (10 newest); page 1 of size 3 scanned 10, 9, 8, so Next = 7, Last = 8, NextIndex = 3.
func TestLikesResume(t *testing.T) {
	anchor := likesAnchor{Next: pid(7), Last: pid(8), NextIndex: 3}
	ids := func(ns ...int) []string { // oldest first, like the stored array
		out := make([]string, len(ns))
		for i, n := range ns {
			out[i] = pid(n)
		}
		return out
	}
	tests := []struct {
		name   string
		recent []string
		anchor likesAnchor
		want   string // the first id of the next page, or "" when the list has ended
	}{
		{"nothing changed", ids(1, 2, 3, 4, 5, 6, 7, 8, 9, 10), anchor, pid(7)},
		{"unlike of Next: resume just older than Last, which is where Next stood", ids(1, 2, 3, 4, 5, 6, 8, 9, 10), anchor, pid(6)},
		{"re-like of Next: it is now newer than Last, so it is not shown twice", ids(1, 2, 3, 4, 5, 6, 8, 9, 10, 7), anchor, pid(6)},
		{"unlike of Last: resume at Next", ids(1, 2, 3, 4, 5, 6, 7, 9, 10), anchor, pid(7)},
		{"Last re-liked above the page: resume at Next", ids(1, 2, 3, 4, 5, 6, 7, 9, 10, 8), anchor, pid(7)},
		{"both anchors unliked: the offset from the newest end (rule 3)", ids(1, 2, 3, 4, 5, 6, 9, 10), anchor, pid(5)},
		{"an unlike of older rows leaves the anchors alone", ids(1, 3, 5, 6, 7, 8, 9, 10), anchor, pid(7)},
		{"an unlike of an already shown row shifts nothing relative to the anchors", ids(1, 2, 3, 4, 5, 6, 7, 8, 10), anchor, pid(7)},
		{"new likes at the newest end", ids(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12), anchor, pid(7)},
		{"a trim of the oldest rows", ids(4, 5, 6, 7, 8, 9, 10), anchor, pid(7)},
		{"a trim that reaches Next ends the list", ids(8, 9, 10), anchor, ""},
		{"a trim that took Next and Last, offset past the end, ends the list", ids(9, 10), anchor, ""},
		{"everything unliked", nil, anchor, ""},
		{"both anchors gone, offset inside the list", ids(1, 2, 3, 4, 5, 6), likesAnchor{Next: pid(70), Last: pid(80), NextIndex: 2}, pid(4)},
		{"both anchors gone, offset at the end", ids(1, 2), likesAnchor{Next: pid(70), Last: pid(80), NextIndex: 2}, ""},
		{"both anchors gone, offset far past the end", ids(1, 2), likesAnchor{Next: pid(70), Last: pid(80), NextIndex: 900}, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			start := likesResume(tt.recent, tt.anchor)
			n := len(tt.recent)
			got := ""
			if start >= 0 && start < n {
				got = tt.recent[n-1-start]
			}
			if got != tt.want {
				t.Errorf("resume at position %d = %q, want %q", start, got, tt.want)
			}
		})
	}
}

// The same cases through the service and a real token: page 1 of 3, the array changes, page 2 resumes correctly.
func TestListLikedPosts_ResumeAfterChanges(t *testing.T) {
	tests := []struct {
		name   string
		change func(recent []string) []string
		want   []string // page 2 (size 3)
	}{
		{"nothing changed", func(r []string) []string { return r }, descIDs(7, 5)},
		{"Next unliked", func(r []string) []string { return withoutID(r, pid(7)) }, descIDs(6, 4)},
		{"Next unliked and re-liked", func(r []string) []string { return append(withoutID(r, pid(7)), pid(7)) }, descIDs(6, 4)},
		{"Last unliked", func(r []string) []string { return withoutID(r, pid(8)) }, descIDs(7, 5)},
		{"a row already shown unliked", func(r []string) []string { return withoutID(r, pid(10)) }, descIDs(7, 5)},
		{"a new like", func(r []string) []string { return append(r, pid(11)) }, descIDs(7, 5)},
		{"the oldest trimmed", func(r []string) []string { return r[3:] }, descIDs(7, 5)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newListEnv(t)
			recent := e.seedLikes(10)
			e.rd.docs[pid(11)] = &posts.Post{ID: pid(11), AuthorID: "author", Visibility: posts.VisibilityPublic}
			p1, err := e.m.ListLikedPosts(e.ctx, caller, 3, "")
			if err != nil || !slices.Equal(likedIDs(p1), descIDs(10, 8)) || p1.NextPageToken == "" {
				t.Fatalf("page 1 = %v token %q err %v", likedIDs(p1), p1.NextPageToken, err)
			}
			e.s.cache.set(caller, UserLikes{Recent: tt.change(slices.Clone(recent))})
			p2, err := e.m.ListLikedPosts(e.ctx, caller, 3, p1.NextPageToken)
			if err != nil {
				t.Fatal(err)
			}
			if got := likedIDs(p2); !slices.Equal(got, tt.want) {
				t.Errorf("page 2 = %v, want %v", got, tt.want)
			}
		})
	}
}

// The ADR-0023 D2 / ADR-0010 D6 drop rules apply to a liked post exactly as to a bookmark: the same shared code.
func TestListLikedPosts_DropRules(t *testing.T) {
	quote := func(author, embedded string) *posts.Post {
		return &posts.Post{AuthorID: author, Kind: posts.KindQuote, EmbeddedAuthorID: embedded}
	}
	tests := []struct {
		name string
		snap graph.Snapshot
		post *posts.Post // the single liked post; nil = missing
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
		{"quote of a blocked author", snapOf([]string{"e"}, nil, nil), quote("a", "e"), "", "blocked"},
		{"quote of an author who blocks the caller", snapOf(nil, []string{"e"}, nil), quote("a", "e"), "", "blocked"},
		{"quote of a muted author", snapOf(nil, nil, []string{"e"}), quote("a", "e"), "", "muted"},
		{"quote of an unrelated author", snapOf([]string{"x"}, nil, nil), quote("a", "e"), "", ""},
		{"overflow fails a foreign author closed", graph.Snapshot{BlockedByOverflow: true}, &posts.Post{AuthorID: "a"}, "", "blocked"},
		{"overflow keeps the caller's own post", graph.Snapshot{BlockedByOverflow: true}, &posts.Post{AuthorID: caller}, "", ""},
		{"own post", snapOf([]string{"viewer"}, nil, []string{"viewer"}), &posts.Post{AuthorID: caller}, "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newListEnv(t)
			e.gr.snap = tt.snap
			id := pid(7)
			e.repo.loaded = UserLikes{Recent: []string{id}}
			if tt.post != nil {
				p := *tt.post
				if p.Visibility == "" {
					p.Visibility = posts.VisibilityPublic
				}
				p.ID, p.Moderation = id, tt.hide
				e.rd.docs[id] = &p
			}
			page, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
			if err != nil {
				t.Fatal(err)
			}
			if got := len(page.Posts) == 1; got != (tt.want == "") {
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
		})
	}
}

// No pruning: the like path owns the array. A missing post is dropped from the page and nothing else changes: no write,
// the cached array keeps the id, and the next open drops it again.
func TestListLikedPosts_NoPruning(t *testing.T) {
	e := newListEnv(t)
	recent := e.seedLikes(5)
	delete(e.rd.docs, pid(4))
	page, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := likedIDs(page); !slices.Equal(got, []string{pid(5), pid(3), pid(2), pid(1)}) {
		t.Fatalf("rows = %v", got)
	}
	if len(e.bm.pruneCalls) != 0 || len(e.repo.trims) != 0 {
		t.Errorf("a likes list wrote: prune %v, trims %v", e.bm.pruneCalls, e.repo.trims)
	}
	if st, ok := e.s.cache.get(caller); !ok || !slices.Equal(st.recent, recent) {
		t.Errorf("cached array = %v, want it untouched %v", st.recent, recent)
	}
	if e.field(fieldRowsDroppedMissing) != 1 || e.field(fieldRowsPruned) != nil {
		t.Errorf("rows_dropped_missing = %v rows_pruned = %v, want 1 and unset", e.field(fieldRowsDroppedMissing), e.field(fieldRowsPruned))
	}
	// Read-only mode changes nothing for a list that never writes.
	e = newListEnv(t, func(d *Deps) { d.ReadOnly = true })
	e.seedLikes(3)
	if p, err := e.m.ListLikedPosts(e.ctx, caller, 0, ""); err != nil || len(p.Posts) != 3 {
		t.Errorf("readonly: %d rows, %v", len(p.Posts), err)
	}
}

// Dropped rows shorten the page but the token still resumes after the last SCANNED row, so the client never loops or
// re-reads them, and the page is not refilled server-side.
func TestListLikedPosts_ShortPageKeepsCursor(t *testing.T) {
	e := newListEnv(t)
	e.seedLikes(30)
	e.gr.snap = snapOf([]string{"bad"}, nil, nil)
	for i := 11; i <= 30; i++ { // the 20 newest likes are all by a blocked author
		e.rd.docs[pid(i)].AuthorID = "bad"
	}
	p1, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p1.Posts) != 0 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %d rows, token %q; want a short (empty) page that still has a token", len(p1.Posts), p1.NextPageToken)
	}
	if len(e.rd.getManyCalls) != 1 {
		t.Errorf("GetMany calls = %d: the server must not refill a short page", len(e.rd.getManyCalls))
	}
	p2, err := e.m.ListLikedPosts(e.ctx, caller, 0, p1.NextPageToken)
	if err != nil || !slices.Equal(likedIDs(p2), descIDs(10, 1)) || p2.NextPageToken != "" {
		t.Fatalf("page 2 = %v token %q err %v; want the remaining 10", likedIDs(p2), p2.NextPageToken, err)
	}
}

// A page of the caller's own posts needs no graph snapshot; the viewer state of the rows is the engagement flag's rule
// (posts.HydrateViewer) over the same userLikes state, with no second read.
func TestListLikedPosts_ViewerAndGraphReads(t *testing.T) {
	reg := flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On})
	e := newListEnv(t, func(d *Deps) { d.Flags = reg })
	e.seedLikes(3)
	p, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if err != nil || len(p.Posts) != 3 {
		t.Fatalf("%d rows, %v", len(p.Posts), err)
	}
	for _, x := range p.Posts {
		if liked, reposted := p.Viewer.Flags(x); !liked || reposted {
			t.Errorf("%s: liked=%v reposted=%v, want liked and not reposted", x.ID, liked, reposted)
		}
	}
	if e.repo.loads != 1 {
		t.Errorf("userLikes loads = %d, want 1: the viewer state reuses the list's read", e.repo.loads)
	}
	if e.gr.calls != 1 {
		t.Errorf("graph snapshots = %d, want 1", e.gr.calls)
	}

	// Own posts only: the snapshot is never read.
	e = newListEnv(t, func(d *Deps) { d.Flags = reg })
	e.seedLikes(3)
	for _, d := range e.rd.docs {
		d.AuthorID = caller
	}
	if p, err = e.m.ListLikedPosts(e.ctx, caller, 0, ""); err != nil || len(p.Posts) != 3 || e.gr.calls != 0 {
		t.Errorf("own posts: %d rows, %d graph reads, %v; want 3 rows and 0 graph reads", len(p.Posts), e.gr.calls, err)
	}

	// engagement off for the caller: the list still works, the rows carry no viewer flags.
	e = newListEnv(t, func(d *Deps) { d.Flags = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off}) })
	e.seedLikes(3)
	if p, err = e.m.ListLikedPosts(e.ctx, caller, 0, ""); err != nil || len(p.Posts) != 3 {
		t.Fatalf("engagement off: %d rows, %v", len(p.Posts), err)
	}
	if liked, _ := p.Viewer.Flags(p.Posts[0]); liked {
		t.Error("engagement off: the viewer set still reports a like")
	}
}

func TestListLikedPosts_Failures(t *testing.T) {
	internal := func(t *testing.T, err error) {
		t.Helper()
		var ae *apierr.Error
		if err == nil || errors.As(err, &ae) {
			t.Fatalf("err = %v, want a redacted internal error (not an apierr)", err)
		}
		if strings.Contains(err.Error(), caller) || strings.Contains(err.Error(), pid(1)) {
			t.Errorf("error leaks an id: %v", err)
		}
	}
	t.Run("no cursor key", func(t *testing.T) {
		e := newListEnv(t, func(d *Deps) { d.CursorKey = nil })
		_, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
		internal(t, err)
	})
	t.Run("no graph", func(t *testing.T) {
		e := newListEnv(t, func(d *Deps) { d.Graph = nil })
		_, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
		internal(t, err)
	})
	t.Run("userLikes read fails", func(t *testing.T) {
		e := newListEnv(t)
		e.repo.loadErr = errors.New("unavailable")
		_, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
		internal(t, err)
		if len(e.rd.getManyCalls) != 0 {
			t.Error("GetMany ran without a list")
		}
	})
	t.Run("GetMany fails", func(t *testing.T) {
		e := newListEnv(t)
		e.seedLikes(3)
		e.rd.getManyErr = errors.New("unavailable")
		_, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
		internal(t, err)
	})
	t.Run("graph fails closed: no unfiltered page", func(t *testing.T) {
		e := newListEnv(t)
		e.seedLikes(3)
		e.gr.err = errors.New("unavailable")
		_, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
		internal(t, err)
	})
}

// The request line carries no ids, uids or text, only counts, and no rows_pruned (nothing is ever pruned).
func TestListLikedPosts_LogFields(t *testing.T) {
	e := newListEnv(t)
	e.seedLikes(4)
	delete(e.rd.docs, pid(4))
	e.rd.docs[pid(3)].Moderation = posts.ModerationTakenDown
	e.rd.docs[pid(2)].AuthorID = "muted-author"
	e.gr.snap = snapOf(nil, nil, []string{"muted-author"})
	if _, err := e.m.ListLikedPosts(e.ctx, caller, 0, ""); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		fieldOp: "list_liked_posts", fieldOutcome: outcomeDone, fieldRowsReturned: 1, fieldRowsDropped: 3,
		fieldRowsDroppedMissing: 1, fieldRowsDroppedHidden: 1, fieldRowsDroppedBlocked: 0, fieldRowsDroppedMuted: 1,
	}
	for k, w := range want {
		if got := e.field(k); got != w {
			t.Errorf("%s = %v, want %v", k, got, w)
		}
	}
	if got := e.field(fieldRowsPruned); got != nil {
		t.Errorf("rows_pruned = %v, want it unset", got)
	}
}

// A rejected token is noted on the request line like any other rejected call.
func TestListLikedPosts_RejectedTokenIsNoted(t *testing.T) {
	e := newListEnv(t)
	if _, err := e.m.ListLikedPosts(e.ctx, caller, 0, "garbage"); err == nil {
		t.Fatal("garbage token accepted")
	}
	if got := e.field(fieldOutcome); got == nil || got == outcomeDone {
		t.Errorf("outcome = %v, want a rejected outcome", got)
	}
	if e.field(fieldOp) != "list_liked_posts" {
		t.Errorf("op = %v", e.field(fieldOp))
	}
}
