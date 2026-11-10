package search

// F-03: SearchPosts drops rows whose author is not ACTIVE (missing, SUSPENDED, DELETING), on every tab and after the shared
// tag entry, through identity.Directory.GetProfiles (the rule GetPost, GetThread's context and GetUserTimeline apply). A
// copy of a post whose author is not ACTIVE ends as the suspend-user and account-purge clean-up leaves it in storage: a
// REPOST is gone and a QUOTE keeps its own text with the embed tombstoned ({post_id, unavailable}).

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// statusDir is identity.Directory.GetProfiles over in-memory statuses: every uid is an ACTIVE account unless marked, and
// like the real Directory it omits missing, SUSPENDED and DELETING accounts alike. It records every batch. Safe for
// concurrent calls (the singleflight tests share one rig).
type statusDir struct {
	mu      sync.Mutex
	status  map[string]identity.AccountStatus
	missing map[string]bool
	batches [][]string
	err     error
}

func newStatusDir() *statusDir {
	return &statusDir{status: map[string]identity.AccountStatus{}, missing: map[string]bool{}}
}

func (d *statusDir) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.batches = append(d.batches, slices.Clone(uids))
	if d.err != nil {
		return nil, d.err
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		st, ok := d.status[u]
		if !ok {
			st = identity.AccountStatusActive
		}
		if d.missing[u] || st != identity.AccountStatusActive {
			continue
		}
		out[u] = identity.Profile{UserID: u, Status: st}
	}
	return out, nil
}

func (d *statusDir) calls() [][]string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return slices.Clone(d.batches)
}

// inactive marks uid by kind: "suspended", "deleting" or "missing".
func (d *statusDir) inactive(uid, kind string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch kind {
	case "suspended":
		d.status[uid] = identity.AccountStatusSuspended
	case "deleting":
		d.status[uid] = identity.AccountStatusDeleting
	case "missing":
		d.missing[uid] = true
	}
}

func withAuthorStatus(uid, kind string) rigOpt {
	return func(r *rig, _ *PostsDeps, _ flagMap) { r.authors.inactive(uid, kind) }
}

var inactiveKinds = []string{"suspended", "deleting", "missing"}

// A non-ACTIVE author's rows are gone on LATEST, TOP and MEDIA; an ACTIVE author's rows are unchanged.
func TestPosts_AuthorStatus_Tabs(t *testing.T) {
	t.Parallel()
	for _, kind := range append([]string{"active"}, inactiveKinds...) {
		for _, tab := range []searchv1.SearchTab{latest, top, media} {
			t.Run(kind+"/"+tab.String(), func(t *testing.T) {
				t.Parallel()
				// Posts 1..6 with images; even posts by "bad", odd by "good".
				var ps []*posts.Post
				for n := 6; n >= 1; n-- {
					author := "good"
					if n%2 == 0 {
						author = "bad"
					}
					ps = append(ps, mkPost(n, author, withMedia))
				}
				r := newRig(map[string][]*posts.Post{"go": ps}, withAuthorStatus("bad", kind))
				got := ids(doPosts(t, r, "u", "go", tab, 0, ""))
				slices.Sort(got) // TOP ranks by score; the set is what matters here
				want := []string{idOf(1), idOf(3), idOf(5)}
				if kind == "active" {
					want = []string{idOf(1), idOf(2), idOf(3), idOf(4), idOf(5), idOf(6)}
				}
				if fmt.Sprint(got) != fmt.Sprint(want) {
					t.Fatalf("ids = %v, want %v", got, want)
				}
			})
		}
	}
}

// The filter runs after the shared tag entry: a page served warm from the entry built while the author was ACTIVE drops
// the author's rows once the Directory reports the new status.
func TestPosts_AuthorStatus_WarmEntry(t *testing.T) {
	t.Parallel()
	for _, tab := range []searchv1.SearchTab{latest, top, media} {
		t.Run(tab.String(), func(t *testing.T) {
			t.Parallel()
			r := newRig(map[string][]*posts.Post{"go": {mkPost(2, "bad", withMedia), mkPost(1, "good", withMedia)}})
			if got := ids(doPosts(t, r, "u", "go", tab, 0, "")); len(got) != 2 {
				t.Fatalf("cold: ids = %v, want both rows", got)
			}
			r.authors.inactive("bad", "suspended")
			if got := ids(doPosts(t, r, "u", "go", tab, 0, "")); fmt.Sprint(got) != fmt.Sprint([]string{idOf(1)}) {
				t.Fatalf("warm: ids = %v, want only the ACTIVE author's row", got)
			}
			if n := r.reader.callCount(); n != 1 {
				t.Fatalf("tag queries = %d, want 1 (the warm page is served from the entry)", n)
			}
		})
	}
}

// quoteOf makes post n by author a QUOTE of post orig by embAuthor; repostOf makes it a REPOST.
func quoteOf(orig, embAuthor string) func(*posts.Post) {
	return func(p *posts.Post) {
		p.Kind, p.QuoteOfID, p.EmbeddedAuthorID = posts.KindQuote, orig, embAuthor
		p.Embedded = &posts.Embedded{PostID: orig, Author: posts.AuthorSnapshot{UserID: embAuthor, Handle: "h" + embAuthor}, Text: "secret embed"}
	}
}

func repostOf(orig, embAuthor string) func(*posts.Post) {
	return func(p *posts.Post) {
		p.Kind, p.RepostOfID, p.EmbeddedAuthorID = posts.KindRepost, orig, embAuthor
		p.Embedded = &posts.Embedded{PostID: orig, Author: posts.AuthorSnapshot{UserID: embAuthor, Handle: "h" + embAuthor}, Text: "secret embed"}
	}
}

const origID = "0000000000000009999"

// An embedded author who is not ACTIVE: the QUOTE stays with its embed tombstoned, the REPOST is dropped (the end state
// of suspend-user's copy clean-up and of the account purge). The caller's own copies follow the same rule. An ACTIVE
// embedded author leaves both unchanged.
func TestPosts_AuthorStatus_Embeds(t *testing.T) {
	t.Parallel()
	for _, kind := range append([]string{"active"}, inactiveKinds...) {
		for _, quoter := range []string{"good", "u"} {
			t.Run(kind+"/by "+quoter, func(t *testing.T) {
				t.Parallel()
				r := newRig(map[string][]*posts.Post{"go": {
					mkPost(3, quoter, quoteOf(origID, "bad")),
					mkPost(2, quoter, repostOf(origID, "bad")),
					mkPost(1, "good"),
				}}, withAuthorStatus("bad", kind))
				for _, tab := range []searchv1.SearchTab{latest, top} {
					resp := doPosts(t, r, "u", "go", tab, 0, "")
					got := ids(resp)
					slices.Sort(got)
					if kind == "active" {
						if fmt.Sprint(got) != fmt.Sprint([]string{idOf(1), idOf(2), idOf(3)}) {
							t.Fatalf("%v: ids = %v, want all three", tab, got)
						}
						for _, v := range resp.Posts {
							if e := v.GetPost().GetEmbedded(); e != nil && (e.GetUnavailable() || e.GetText() != "secret embed") {
								t.Fatalf("%v: an ACTIVE embedded author's embed changed: %v", tab, e)
							}
						}
						continue
					}
					if fmt.Sprint(got) != fmt.Sprint([]string{idOf(1), idOf(3)}) {
						t.Fatalf("%v: ids = %v, want the QUOTE and the plain post (the REPOST dropped)", tab, got)
					}
					for _, v := range resp.Posts {
						if v.GetPost().GetPostId() != idOf(3) {
							continue
						}
						e := v.GetPost().GetEmbedded()
						if e == nil || !e.GetUnavailable() || e.GetPostId() != origID || e.GetText() != "" || e.GetAuthor() != nil {
							t.Fatalf("%v: QUOTE embed = %v, want the tombstone {post_id, unavailable}", tab, e)
						}
						if v.GetPost().GetKind() != postsv1.PostKind_POST_KIND_QUOTE {
							t.Fatalf("%v: kind = %v", tab, v.GetPost().GetKind())
						}
					}
				}
			})
		}
	}
}

// The tombstone is rendered on a copy: the shared entry keeps the snapshot, so a later ACTIVE answer shows it again.
func TestPosts_AuthorStatus_TombstoneDoesNotMutateEntry(t *testing.T) {
	t.Parallel()
	q := mkPost(1, "good", quoteOf(origID, "bad"))
	r := newRig(map[string][]*posts.Post{"go": {q}}, withAuthorStatus("bad", "suspended"))
	if e := doPosts(t, r, "u", "go", latest, 0, "").Posts[0].GetPost().GetEmbedded(); !e.GetUnavailable() {
		t.Fatalf("embed = %v, want the tombstone", e)
	}
	if q.Embedded.Unavailable || q.EmbeddedAuthor() != "bad" || q.QuoteOfID != origID {
		t.Fatal("the shared entry's post was mutated")
	}
	r.authors.mu.Lock()
	delete(r.authors.status, "bad")
	r.authors.mu.Unlock()
	if e := doPosts(t, r, "u", "go", latest, 0, "").Posts[0].GetPost().GetEmbedded(); e.GetUnavailable() || e.GetText() != "secret embed" {
		t.Fatalf("embed after unsuspend = %v, want the snapshot", e)
	}
}

// A page whose raw rows are all by non-ACTIVE authors still issues a token positioned at the last QUERIED row, so the
// next page reads strictly older rows (no loop): LATEST page 1 from the entry, a LATEST older window and a MEDIA scan.
func TestPosts_AuthorStatus_AllFilteredPageAdvances(t *testing.T) {
	t.Parallel()
	for _, tab := range []searchv1.SearchTab{latest, media} {
		t.Run(tab.String(), func(t *testing.T) {
			t.Parallel()
			// 90 posts with images: 90..31 by "bad" (two full windows), 30..1 by "good".
			var ps []*posts.Post
			for n := 90; n >= 1; n-- {
				author := "good"
				if n > 30 {
					author = "bad"
				}
				ps = append(ps, mkPost(n, author, withMedia))
			}
			r := newRig(map[string][]*posts.Post{"go": ps}, withAuthorStatus("bad", "suspended"))
			p1 := doPosts(t, r, "u", "go", tab, 20, "")
			if len(p1.Posts) != 0 || p1.NextPageToken == "" {
				t.Fatalf("page 1: %d rows, token %q; want an empty page that still moves on", len(p1.Posts), p1.NextPageToken)
			}
			seen := map[string]bool{p1.NextPageToken: true}
			tok := p1.NextPageToken
			var got []string
			for i := 0; i < 10 && tok != ""; i++ {
				p := doPosts(t, r, "u", "go", tab, 20, tok)
				got = append(got, ids(p)...)
				if p.NextPageToken != "" && seen[p.NextPageToken] {
					t.Fatalf("page %d repeated a token: the cursor did not advance", i+2)
				}
				seen[p.NextPageToken] = true
				tok = p.NextPageToken
			}
			if tok != "" {
				t.Fatal("the walk did not end")
			}
			if len(got) != 30 || got[0] != idOf(30) || got[29] != idOf(1) {
				t.Fatalf("rows after the filtered windows = %d (%v...), want the 30 ACTIVE rows 30..1", len(got), got[:min(3, len(got))])
			}
		})
	}
}

// Cost: one GetProfiles per page with rows, each author asked once and the caller never; none for a request that reads no
// rows. More than 50 distinct uids (a 50-row window of QUOTEs) is split into batches of at most 50.
func TestPosts_AuthorStatus_ReadCost(t *testing.T) {
	t.Parallel()
	t.Run("one batch, deduplicated, caller skipped", func(t *testing.T) {
		t.Parallel()
		r := newRig(map[string][]*posts.Post{"go": {
			mkPost(4, "a", quoteOf(origID, "b")), mkPost(3, "a"), mkPost(2, "u", quoteOf(origID, "u")), mkPost(1, "b"),
		}})
		doPosts(t, r, "u", "go", latest, 0, "")
		calls := r.authors.calls()
		if len(calls) != 1 {
			t.Fatalf("GetProfiles calls = %d, want 1", len(calls))
		}
		got := slices.Sorted(slices.Values(calls[0]))
		if fmt.Sprint(got) != fmt.Sprint([]string{"a", "b"}) {
			t.Fatalf("asked %v, want [a b] once each and never the caller", got)
		}
	})
	t.Run("no rows, no read", func(t *testing.T) {
		t.Parallel()
		r := newRig(map[string][]*posts.Post{"go": {mkPost(1, "a")}})
		doPosts(t, r, "u", "empty", latest, 0, "")
		doPosts(t, r, "u", "two words", latest, 0, "")
		if _, err := r.svc.Posts(context.Background(), "u", "go", latest, 0, "garbage"); err == nil {
			t.Fatal("a garbage token must fail")
		}
		if n := len(r.authors.calls()); n != 0 {
			t.Fatalf("GetProfiles calls = %d, want 0", n)
		}
	})
	t.Run("only the caller's own rows, no read", func(t *testing.T) {
		t.Parallel()
		r := newRig(map[string][]*posts.Post{"go": {mkPost(1, "u")}})
		if got := ids(doPosts(t, r, "u", "go", latest, 0, "")); len(got) != 1 {
			t.Fatalf("ids = %v", got)
		}
		if n := len(r.authors.calls()); n != 0 {
			t.Fatalf("GetProfiles calls = %d, want 0", n)
		}
	})
	t.Run("100 distinct uids in batches of at most 50", func(t *testing.T) {
		t.Parallel()
		var ps []*posts.Post
		for n := 50; n >= 1; n-- {
			ps = append(ps, mkPost(n, fmt.Sprintf("a%02d", n), quoteOf(origID, fmt.Sprintf("e%02d", n))))
		}
		r := newRig(map[string][]*posts.Post{"go": ps})
		if got := ids(doPosts(t, r, "u", "go", latest, 50, "")); len(got) != 50 {
			t.Fatalf("rows = %d, want 50", len(got))
		}
		calls := r.authors.calls()
		asked := map[string]bool{}
		for _, b := range calls {
			if len(b) > authorBatch {
				t.Fatalf("a batch of %d uids, want at most %d", len(b), authorBatch)
			}
			for _, u := range b {
				asked[u] = true
			}
		}
		if len(calls) != 2 || len(asked) != 100 {
			t.Fatalf("%d calls asking %d uids, want 2 calls covering 100", len(calls), len(asked))
		}
	})
}

// A Directory failure fails the request: author status is never assumed (fail closed).
func TestPosts_AuthorStatus_DirectoryErrorFailsClosed(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": {mkPost(1, "a")}})
	r.authors.err = errors.New("unavailable")
	if resp, err := r.svc.Posts(context.Background(), "u", "go", latest, 0, ""); err == nil {
		t.Fatalf("err = nil with %d rows, want a failure", len(resp.GetPosts()))
	}
}

// Without the Directory SearchPosts is not built: an enabled caller gets Unimplemented, never unfiltered rows.
func TestWithPosts_NoAuthorDirectoryStaysUnimplemented(t *testing.T) {
	t.Parallel()
	r := newRig(nil)
	svc := New(flagMap{FlagSearch: true}, WithPosts(PostsDeps{Posts: r.reader, Graph: r.graph, CursorKey: testKey}))
	_, err := svc.Posts(context.Background(), "u", "go", top, 0, "")
	wantAPIError(t, err, connect.CodeUnimplemented, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "")
	if r.reader.callCount() != 0 {
		t.Fatal("an unbuilt SearchPosts must read nothing")
	}
}

// The request line counts the rows dropped for author status (a count, never a uid).
func TestPosts_AuthorStatus_RequestLine(t *testing.T) {
	t.Parallel()
	r := newRig(map[string][]*posts.Post{"go": {mkPost(2, "bad"), mkPost(1, "a")}}, withAuthorStatus("bad", "deleting"))
	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := r.svc.Posts(ctx, "u", "go", latest, 0, ""); err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]any{fieldResults: 1, fieldDropped: 1, fieldDroppedInactive: 1} {
		if got, ok := info.Get(k); !ok || fmt.Sprint(got) != fmt.Sprint(v) {
			t.Errorf("%s = %v (%v), want %v", k, got, ok, v)
		}
	}
}

// Security review (low): a Directory error can name an author (identity's "decode profile <uid>"). The error SearchPosts
// returns, and the cause chain mw.reportError logs, carries no raw uid of the batch or of the caller.
func TestPosts_AuthorStatus_DirectoryErrorRedactsTheBatch(t *testing.T) {
	t.Parallel()
	const author, quoted, caller = "uid-author-secret", "uid-quoted-secret", "uid-caller-secret"
	r := newRig(map[string][]*posts.Post{"go": {mkPost(2, author, quoteOf(origID, quoted)), mkPost(1, author)}})
	r.authors.err = fmt.Errorf("identity: decode profile %s: bad field; and %s; caller %s", author, quoted, caller)
	_, err := r.svc.Posts(context.Background(), caller, "go", latest, 0, "")
	if err == nil {
		t.Fatal("err = nil, want a failure")
	}
	for _, msg := range []string{err.Error(), logger.CauseChain(err)} {
		for _, id := range []string{author, quoted, caller} {
			if strings.Contains(msg, id) {
				t.Errorf("error text %q leaks %s", msg, id)
			}
		}
	}
	if !strings.Contains(logger.CauseChain(err), logger.HashUID(author)) {
		t.Errorf("error text %q lacks the author's hash", logger.CauseChain(err))
	}
}
