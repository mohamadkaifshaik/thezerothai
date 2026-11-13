package engagement

// F-03 (D10 reversed) on the owner-only lists: ListBookmarks and ListLikedPosts drop a row whose author is not ACTIVE
// (SUSPENDED, DELETING, no users doc) and a REPOST of such an author's post, and show a QUOTE of one with its own text
// and the embed tombstoned (posts.TombstonedQuote), before suspend-user's copy clean-up or the account purge reaches the
// row. One batched Directory read per page; a Directory failure fails the page; the rows stay in storage.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const (
	uidOK    = "uid-ok"
	uidSusp  = "uid-susp"
	uidDel   = "uid-del"
	uidGhost = "uid-ghost" // no users doc: the Directory never returns it
	pidOrig  = "0000000000000000777"
	// fieldInactive is the request-line count of the rows the rule dropped (literal, so this file compiles before the rule).
	fieldInactive = "rows_dropped_inactive"
)

// statusDir is the Directory of these tests: the status of each uid it knows (an absent uid has no users doc and is
// omitted, like the real Directory omits a missing one), an optional failure, and every GetProfiles batch it was asked.
type statusDir struct {
	fakeDir
	status map[string]identity.AccountStatus
	err    error
	calls  [][]string
}

func newStatusDir() *statusDir {
	return &statusDir{status: map[string]identity.AccountStatus{
		uidOK: identity.AccountStatusActive, uidSusp: identity.AccountStatusSuspended, uidDel: identity.AccountStatusDeleting,
	}}
}

func (d *statusDir) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	d.calls = append(d.calls, append([]string(nil), uids...))
	if d.err != nil {
		return nil, d.err
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if st, ok := d.status[u]; ok {
			out[u] = identity.Profile{UserID: u, Handle: "h_" + u, Status: st}
		}
	}
	return out, nil
}

func withDir(d *statusDir) listOpt { return func(dd *Deps) { dd.Directory = d } }

func plainBy(n int, author string) *posts.Post {
	return &posts.Post{ID: pid(n), AuthorID: author, Kind: posts.KindPost, Visibility: posts.VisibilityPublic, Text: "own text " + author}
}

// copyOf makes post n by author a REPOST or QUOTE of pidOrig by orig, with the full frozen snapshot.
func copyOf(n int, author string, kind posts.Kind, orig string) *posts.Post {
	p := plainBy(n, author)
	p.Kind, p.EmbeddedAuthorID = kind, orig
	p.Embedded = &posts.Embedded{
		PostID: pidOrig, Author: posts.AuthorSnapshot{UserID: orig, Handle: "h_" + orig}, Text: "the original",
		Media: []posts.MediaRef{{ID: "m1", URL: "https://media.example/m1"}},
	}
	if kind == posts.KindRepost {
		p.RepostOfID = pidOrig
	} else {
		p.QuoteOfID = pidOrig
	}
	return p
}

// shownRow is one row a list rendered.
type shownRow struct {
	post *posts.Post
	hint RowHint
}

// seedRows stores rows (newest first) as the caller's bookmarks or likes, and the live posts they name.
func (e *listEnv) seedRows(list string, rows ...*posts.Post) {
	recent := make([]string, 0, len(rows))
	for i, p := range rows {
		e.rd.docs[p.ID] = p
		e.bm.rows = append(e.bm.rows, ExportedBookmark{PostID: p.ID, BookmarkedAt: e.now.Add(-time.Duration(i+1) * time.Minute)})
		recent = append([]string{p.ID}, recent...) // userLikes.recent is oldest first
	}
	if list == "likes" {
		e.repo.loaded = UserLikes{Recent: recent}
	}
}

// listPage opens one page of list and returns its rows and next token.
func (e *listEnv) listPage(list string, pageSize int32, token string) ([]shownRow, string, error) {
	var out []shownRow
	if list == "bookmarks" {
		p, err := e.m.ListBookmarks(e.ctx, caller, pageSize, token)
		for _, r := range p.Rows {
			out = append(out, shownRow{r.Post, r.Hint})
		}
		return out, p.NextPageToken, err
	}
	p, err := e.m.ListLikedPosts(e.ctx, caller, pageSize, token)
	for i, x := range p.Posts {
		var h RowHint
		if i < len(p.Hints) {
			h = p.Hints[i]
		}
		out = append(out, shownRow{x, h})
	}
	return out, p.NextPageToken, err
}

var ownLists = []string{"bookmarks", "likes"}

func TestLists_AuthorStatus(t *testing.T) {
	type want struct {
		ids  []string        // shown, in order
		tomb map[string]bool // shown with the embed tombstoned
	}
	type tcase struct {
		name string
		rows []*posts.Post
		want want
	}
	cases := []tcase{
		{"ACTIVE author: unchanged", []*posts.Post{plainBy(1, uidOK)}, want{ids: []string{pid(1)}}},
		{"ACTIVE author's QUOTE of an ACTIVE author: full embed", []*posts.Post{copyOf(1, uidOK, posts.KindQuote, uidOK)}, want{ids: []string{pid(1)}}},
		{"ACTIVE author's REPOST of an ACTIVE author: shown", []*posts.Post{copyOf(1, uidOK, posts.KindRepost, uidOK)}, want{ids: []string{pid(1)}}},
		{"the caller's own QUOTE of an inactive author: tombstoned", []*posts.Post{copyOf(1, caller, posts.KindQuote, uidSusp)}, want{ids: []string{pid(1)}, tomb: map[string]bool{pid(1): true}}},
		{"the caller's own REPOST of an inactive author: dropped", []*posts.Post{copyOf(1, caller, posts.KindRepost, uidDel), plainBy(2, caller)}, want{ids: []string{pid(2)}}},
	}
	for _, gone := range []struct{ name, uid string }{{"SUSPENDED", uidSusp}, {"DELETING", uidDel}, {"missing", uidGhost}} {
		cases = append(cases,
			tcase{gone.name + " author: dropped", []*posts.Post{plainBy(1, gone.uid), plainBy(2, uidOK)}, want{ids: []string{pid(2)}}},
			tcase{"REPOST of a " + gone.name + " author: dropped", []*posts.Post{copyOf(1, uidOK, posts.KindRepost, gone.uid), plainBy(2, uidOK)}, want{ids: []string{pid(2)}}},
			tcase{"QUOTE by ACTIVE of a " + gone.name + " author: own text, embed tombstoned", []*posts.Post{copyOf(1, uidOK, posts.KindQuote, gone.uid)}, want{ids: []string{pid(1)}, tomb: map[string]bool{pid(1): true}}},
			tcase{"QUOTE by a " + gone.name + " author of an ACTIVE one: dropped", []*posts.Post{copyOf(1, gone.uid, posts.KindQuote, uidOK)}, want{ids: nil}},
		)
	}
	// Run without an Audience, and with one that treats the inactive authors as protected: the author rule runs first, so
	// an inactive protected author is dropped (never a Withheld placeholder) and a tombstone's PROTECTED embed is cleared.
	audiences := map[string]RowAudience{
		"no audience":        nil,
		"inactive protected": fakeAudience{protected: map[string]bool{uidSusp: true, uidDel: true, uidGhost: true}},
	}
	for aname, aud := range audiences {
		for _, tc := range cases {
			for _, list := range ownLists {
				t.Run(aname+"/"+list+"/"+tc.name, func(t *testing.T) {
					e := newListEnv(t, withDir(newStatusDir()), func(d *Deps) { d.Audience = aud })
					// The caller follows nobody: under "inactive protected" an inactive author is never visible by follow.
					originals := map[string]posts.Post{}
					for _, p := range tc.rows {
						originals[p.ID] = *p
					}
					e.seedRows(list, tc.rows...)
					got, _, err := e.listPage(list, 0, "")
					if err != nil {
						t.Fatal(err)
					}
					var ids []string
					for _, r := range got {
						ids = append(ids, r.post.ID)
					}
					if !slices.Equal(ids, tc.want.ids) {
						t.Fatalf("rows = %v, want %v", ids, tc.want.ids)
					}
					for _, r := range got {
						orig := originals[r.post.ID]
						if r.hint.Withheld {
							t.Errorf("row %s is a Withheld placeholder", r.post.ID)
						}
						if r.post.Text != orig.Text || r.post.AuthorID != orig.AuthorID {
							t.Errorf("row %s text/author = %q/%q, want its own %q/%q", r.post.ID, r.post.Text, r.post.AuthorID, orig.Text, orig.AuthorID)
						}
						if !tc.want.tomb[r.post.ID] {
							if orig.Embedded != nil && (r.post.Embedded == nil || r.post.Embedded.Unavailable || r.post.Embedded.Text != "the original") {
								t.Errorf("row %s embed = %+v, want the full snapshot", r.post.ID, r.post.Embedded)
							}
							continue
						}
						em := r.post.Embedded
						if em == nil || !em.Unavailable || em.PostID != pidOrig || em.Text != "" || em.Author.UserID != "" || len(em.Media) != 0 {
							t.Errorf("row %s embed = %+v, want the tombstone {%s, unavailable}", r.post.ID, em, pidOrig)
						}
						if r.post.QuoteOfID != "" || r.post.EmbeddedAuthor() != "" {
							t.Errorf("row %s quoteOfId %q embedded author %q, want both cleared", r.post.ID, r.post.QuoteOfID, r.post.EmbeddedAuthor())
						}
						if r.hint.Embed != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED {
							t.Errorf("row %s embed hint = %v, want cleared (a tombstone has no author)", r.post.ID, r.hint.Embed)
						}
						// The cached post (shared through the post cache) is never changed.
						if c := e.rd.docs[r.post.ID]; c.Embedded == nil || c.Embedded.Unavailable || c.Embedded.Text != "the original" || c.QuoteOfID != pidOrig {
							t.Errorf("the cached post %s was mutated: %+v", r.post.ID, c.Embedded)
						}
					}
					if got, want := e.field(fieldInactive), len(tc.rows)-len(tc.want.ids); got != want {
						t.Errorf("%s = %v, want %d", fieldInactive, got, want)
					}
					if e.field(fieldRowsReturned) != len(tc.want.ids) {
						t.Errorf("rows_returned = %v, want %d", e.field(fieldRowsReturned), len(tc.want.ids))
					}
					if len(e.bm.pruneCalls) != 0 {
						t.Errorf("prune calls = %v: an inactive author's row must stay in storage", e.bm.pruneCalls)
					}
				})
			}
		}
	}
}

// One batched Directory read per page, deduped, never asking the caller: 20 rows by a handful of authors make one call.
func TestLists_AuthorStatus_OneBatchedCallPerPage(t *testing.T) {
	for _, list := range ownLists {
		t.Run(list, func(t *testing.T) {
			dir := newStatusDir()
			e := newListEnv(t, withDir(dir))
			var rows []*posts.Post
			for i := 20; i >= 1; i-- {
				switch i % 4 {
				case 0:
					rows = append(rows, plainBy(i, uidOK))
				case 1:
					rows = append(rows, copyOf(i, uidOK, posts.KindQuote, uidGhost))
				case 2:
					rows = append(rows, plainBy(i, caller))
				default:
					rows = append(rows, copyOf(i, caller, posts.KindQuote, uidOK))
				}
			}
			e.seedRows(list, rows...)
			if _, _, err := e.listPage(list, 0, ""); err != nil {
				t.Fatal(err)
			}
			if len(dir.calls) != 1 {
				t.Fatalf("Directory calls = %v, want exactly one per page", dir.calls)
			}
			got := slices.Clone(dir.calls[0])
			slices.Sort(got)
			if want := []string{uidGhost, uidOK}; !slices.Equal(got, want) {
				t.Errorf("asked %v, want each foreign author once %v (never the caller)", dir.calls[0], want)
			}
		})
	}
}

// A full page of 50 rows naming 60 distinct uids makes two calls, each at most 50 uids, no uid asked twice.
func TestLists_AuthorStatus_BatchesOf50(t *testing.T) {
	for _, list := range ownLists {
		t.Run(list, func(t *testing.T) {
			dir := newStatusDir()
			e := newListEnv(t, withDir(dir))
			var rows []*posts.Post
			for i := 50; i >= 1; i-- {
				a, b := fmt.Sprintf("a%02d", i), fmt.Sprintf("b%d", i%10)
				dir.status[a], dir.status[b] = identity.AccountStatusActive, identity.AccountStatusActive
				rows = append(rows, copyOf(i, a, posts.KindQuote, b))
			}
			e.seedRows(list, rows...)
			got, _, err := e.listPage(list, 50, "")
			if err != nil || len(got) != 50 {
				t.Fatalf("rows = %d err %v, want 50 ACTIVE rows", len(got), err)
			}
			seen := map[string]bool{}
			for _, c := range dir.calls {
				if len(c) > posts.AuthorStatusBatch {
					t.Errorf("a call asked %d uids, want at most %d", len(c), posts.AuthorStatusBatch)
				}
				for _, u := range c {
					if seen[u] {
						t.Errorf("uid %s asked twice", u)
					}
					seen[u] = true
				}
			}
			if len(dir.calls) != 2 || len(seen) != 60 {
				t.Errorf("calls = %d asking %d uids, want 2 asking 60", len(dir.calls), len(seen))
			}
		})
	}
}

// The caller's own plain rows ask the Directory nothing.
func TestLists_AuthorStatus_OwnRowsAskNothing(t *testing.T) {
	for _, list := range ownLists {
		t.Run(list, func(t *testing.T) {
			dir := newStatusDir()
			e := newListEnv(t, withDir(dir))
			e.seedRows(list, plainBy(2, caller), plainBy(1, caller))
			got, _, err := e.listPage(list, 0, "")
			if err != nil || len(got) != 2 {
				t.Fatalf("rows = %d err %v, want the caller's 2", len(got), err)
			}
			if len(dir.calls) != 0 {
				t.Errorf("Directory calls = %v, want none for the caller's own rows", dir.calls)
			}
		})
	}
}

// A Directory failure fails the page closed: no rows, an internal error with no uid in it, nothing pruned. So does a
// missing Directory.
func TestLists_AuthorStatus_DirectoryErrorFailsClosed(t *testing.T) {
	for _, list := range ownLists {
		for _, mode := range []string{"error", "no directory"} {
			t.Run(list+"/"+mode, func(t *testing.T) {
				dir := newStatusDir()
				dir.err = fmt.Errorf("decode profile %s", uidSusp) // identity's errors can name a uid
				e := newListEnv(t, withDir(dir))
				if mode == "no directory" {
					e.s.d.Directory = nil
				}
				e.seedRows(list, plainBy(2, uidSusp), plainBy(1, uidOK))
				got, _, err := e.listPage(list, 0, "")
				if err == nil {
					t.Fatalf("rows = %d, want the page to fail", len(got))
				}
				if len(got) != 0 {
					t.Errorf("rows = %d on a failed page", len(got))
				}
				if errors.As(err, new(*apierr.Error)) {
					t.Errorf("err = %v, want an internal error, not a client answer", err)
				}
				for _, uid := range []string{uidSusp, uidOK, caller} {
					if strings.Contains(err.Error(), uid) {
						t.Errorf("err %q names %s", err, uid)
					}
				}
				if len(e.bm.pruneCalls) != 0 {
					t.Errorf("prune calls = %v on a failed page", e.bm.pruneCalls)
				}
			})
		}
	}
}

// A page the rule empties still advances its cursor (built from the raw page), the rows stay in storage, and a restore
// brings them back.
func TestLists_AuthorStatus_FilteredPageAdvancesAndRestores(t *testing.T) {
	for _, list := range ownLists {
		t.Run(list, func(t *testing.T) {
			dir := newStatusDir()
			e := newListEnv(t, withDir(dir))
			var rows []*posts.Post
			for i := 25; i >= 1; i-- {
				rows = append(rows, plainBy(i, uidSusp))
			}
			e.seedRows(list, rows...)
			p1, tok, err := e.listPage(list, 0, "")
			if err != nil || len(p1) != 0 || tok == "" {
				t.Fatalf("page 1 = %d rows token %q err %v; want 0 rows and a token", len(p1), tok, err)
			}
			p2, tok2, err := e.listPage(list, 0, tok)
			if err != nil || len(p2) != 0 || tok2 != "" {
				t.Fatalf("page 2 = %d rows token %q err %v; want 0 rows and no token", len(p2), tok2, err)
			}
			if last := e.rd.getManyCalls[len(e.rd.getManyCalls)-1]; !slices.Equal(last, descIDs(5, 1)) {
				t.Errorf("page 2 loaded %v, want the 5 oldest (the cursor advanced past page 1)", last)
			}
			if len(e.bm.pruneCalls) != 0 || len(e.bm.rows) != 25 {
				t.Errorf("prune calls %v, %d bookmark rows left; the rows must stay in storage", e.bm.pruneCalls, len(e.bm.rows))
			}
			dir.status[uidSusp] = identity.AccountStatusActive // restored
			back, _, err := e.listPage(list, 0, "")
			if err != nil || len(back) != 20 {
				t.Fatalf("after restore: %d rows err %v, want the first 20 back", len(back), err)
			}
		})
	}
}

// judgeAudience records every post Decide is given and drops a row whose embedded author is dropEmbedded (standing in
// for a block or blocked-by of the embedded author, which blockCause skips for the caller's own copies).
type judgeAudience struct {
	fakeAudience
	dropEmbedded string
	seen         []*posts.Post
}

func (a *judgeAudience) Decide(ctx context.Context, viewer string, snap graph.Snapshot, p *posts.Post, s posts.Surface) (posts.Decision, error) {
	a.seen = append(a.seen, p)
	if p.EmbeddedAuthor() == a.dropEmbedded {
		return posts.Decision{Verdict: posts.Drop}, nil
	}
	return a.fakeAudience.Decide(ctx, viewer, snap, p, s)
}

// The audience judges the ORIGINAL copy, and the tombstone is swapped in only after (as GetPost, GetThread's context and
// the feeds do): the caller's own QUOTE of an inactive author whose embedded author the audience refuses is dropped, not
// shown as a tombstone; one it accepts is shown tombstoned.
func TestLists_AuthorStatus_AudienceJudgesTheOriginal(t *testing.T) {
	for _, list := range ownLists {
		for _, refuse := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s/refused=%v", list, refuse), func(t *testing.T) {
				aud := &judgeAudience{}
				if refuse {
					aud.dropEmbedded = uidSusp
				}
				e := newListEnv(t, withDir(newStatusDir()), func(d *Deps) { d.Audience = aud })
				e.seedRows(list, copyOf(1, caller, posts.KindQuote, uidSusp))
				got, _, err := e.listPage(list, 0, "")
				if err != nil {
					t.Fatal(err)
				}
				if len(aud.seen) != 1 || aud.seen[0].EmbeddedAuthor() != uidSusp {
					t.Fatalf("Decide saw %v, want the original QUOTE (embedded author %s)", aud.seen, uidSusp)
				}
				if refuse {
					if len(got) != 0 {
						t.Fatalf("rows = %d, want the refused QUOTE dropped", len(got))
					}
					return
				}
				if len(got) != 1 || got[0].post.Embedded == nil || !got[0].post.Embedded.Unavailable {
					t.Fatalf("rows = %+v, want the QUOTE shown tombstoned", got)
				}
			})
		}
	}
}
