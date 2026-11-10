package posts

// F-03 in posts: the shared rule (ResolveActiveAuthors, Verdict, TombstonedQuote), GetPost on a copy of an inactive
// author's post (security review Low 1: a REPOST is NOT_FOUND, a QUOTE renders its embed tombstoned) and GetThread's
// reply rows (dropped per row, one batch, a Directory failure fails the page).

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	pidCopied = "0000000000000000777" // the post the copies below embed
	goneUID   = "uid-gone"
)

// statusCopy turns p into a REPOST or QUOTE of pidCopied by orig.
func statusCopy(p *Post, kind Kind, orig string) *Post {
	p.Kind, p.EmbeddedAuthorID = kind, orig
	p.Embedded = &Embedded{PostID: pidCopied, Author: AuthorSnapshot{UserID: orig, Handle: "h"}, Text: "the original"}
	if kind == KindRepost {
		p.RepostOfID = pidCopied
	} else {
		p.QuoteOfID = pidCopied
	}
	return p
}

func TestResolveActiveAuthors(t *testing.T) {
	t.Parallel()
	active := func(uid string) identity.Profile {
		return identity.Profile{UserID: uid, Status: identity.AccountStatusActive}
	}
	t.Run("caller and known are never asked; no uid, no call", func(t *testing.T) {
		t.Parallel()
		d := &fakeDirectory{profiles: map[string]identity.Profile{}}
		rows := []*Post{post("1", "me"), statusCopy(post("2", "t"), KindQuote, "me")}
		a, err := ResolveActiveAuthors(context.Background(), d, "me", rows, "t")
		if err != nil || len(d.calls) != 0 || !a.Active("me") || !a.Active("t") {
			t.Fatalf("err=%v calls=%v", err, d.calls)
		}
		if _, err := ResolveActiveAuthors(context.Background(), nil, "me", rows, "t"); err != nil {
			t.Fatalf("no uid to ask needs no directory: %v", err)
		}
	})
	t.Run("verdicts", func(t *testing.T) {
		t.Parallel()
		d := &fakeDirectory{profiles: map[string]identity.Profile{
			"ok": active("ok"), "susp": {UserID: "susp", Status: identity.AccountStatusSuspended},
			"del": {UserID: "del", Status: identity.AccountStatusDeleting},
		}}
		rows := []*Post{
			post("1", "ok"), post("2", "susp"), post("3", "del"), post("4", "ghost"),
			statusCopy(post("5", "ok"), KindRepost, "susp"), statusCopy(post("6", "ok"), KindQuote, "del"),
			statusCopy(post("7", "ok"), KindQuote, "ok"), statusCopy(post("8", "susp"), KindQuote, "ok"),
			statusCopy(post("9", "ok"), KindRepost, "me"),
		}
		a, err := ResolveActiveAuthors(context.Background(), d, "me", rows)
		if err != nil {
			t.Fatal(err)
		}
		want := []AuthorVerdict{AuthorShow, AuthorDrop, AuthorDrop, AuthorDrop, AuthorDrop, AuthorTombstone, AuthorShow, AuthorDrop, AuthorShow}
		for i, p := range rows {
			if got := a.Verdict(p); got != want[i] {
				t.Errorf("row %s: verdict %v, want %v", p.ID, got, want[i])
			}
		}
		if len(d.calls) != 1 || slices.Contains(d.calls[0], "me") {
			t.Fatalf("calls = %v, want one without the caller", d.calls)
		}
	})
	t.Run("two batches past 50 uids", func(t *testing.T) {
		t.Parallel()
		d := &fakeDirectory{profiles: map[string]identity.Profile{}}
		var rows []*Post
		for i := range 50 {
			rows = append(rows, statusCopy(post(fmt.Sprint(i), fmt.Sprintf("a%d", i)), KindQuote, fmt.Sprintf("o%d", i)))
		}
		if _, err := ResolveActiveAuthors(context.Background(), d, "me", rows); err != nil {
			t.Fatal(err)
		}
		if len(d.calls) != 2 || len(d.calls[0]) != AuthorStatusBatch || len(d.calls[1]) != AuthorStatusBatch {
			t.Fatalf("batches = %d, want 2 of %d", len(d.calls), AuthorStatusBatch)
		}
	})
	t.Run("a failure is an error, redacted", func(t *testing.T) {
		t.Parallel()
		d := &fakeDirectory{profileErr: errors.New("decode profile uid-secret and caller uid-me-secret")}
		_, err := ResolveActiveAuthors(context.Background(), d, "uid-me-secret", []*Post{post("1", "uid-secret")})
		if err == nil {
			t.Fatal("err = nil")
		}
		for _, id := range []string{"uid-secret", "uid-me-secret"} {
			if strings.Contains(logger.CauseChain(err), id) {
				t.Errorf("%q leaks %s", logger.CauseChain(err), id)
			}
		}
		if _, err := ResolveActiveAuthors(context.Background(), nil, "me", []*Post{post("1", "x")}); err == nil {
			t.Fatal("a nil directory with a uid to ask must fail closed")
		}
	})
}

func TestTombstonedQuote_CopiesAndNeverMutates(t *testing.T) {
	t.Parallel()
	q := statusCopy(post("1", "a"), KindQuote, "b")
	c := TombstonedQuote(q)
	if c == q || c.Embedded == nil || !c.Embedded.Unavailable || c.Embedded.PostID != pidCopied || c.Embedded.Text != "" ||
		c.QuoteOfID != "" || c.EmbeddedAuthorID != "" || c.EmbeddedAuthor() != "" || c.Text != q.Text || c.ID != q.ID {
		t.Fatalf("tombstone = %+v", c)
	}
	if q.Embedded.Unavailable || q.QuoteOfID != pidCopied || q.EmbeddedAuthorID != "b" {
		t.Fatalf("the original changed: %+v", q)
	}
}

// Security review Low 1: GetPost on an ACTIVE user's copy of a post whose author is not ACTIVE.
func TestGetForViewer_EmbeddedAuthorStatus(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		kind      Kind
		copier    string
		status    func(e *createEnv)
		wantFound bool
		wantTomb  bool
	}{
		{"REPOST of an ACTIVE author", KindRepost, otherUID, func(e *createEnv) {
			e.dir.profiles[goneUID] = identity.Profile{UserID: goneUID, Status: identity.AccountStatusActive}
		}, true, false},
		{"QUOTE of an ACTIVE author", KindQuote, otherUID, func(e *createEnv) {
			e.dir.profiles[goneUID] = identity.Profile{UserID: goneUID, Status: identity.AccountStatusActive}
		}, true, false},
		{"REPOST of a SUSPENDED author", KindRepost, otherUID, func(e *createEnv) {
			e.dir.profiles[goneUID] = identity.Profile{UserID: goneUID, Status: identity.AccountStatusSuspended}
		}, false, false},
		{"REPOST of a missing author", KindRepost, otherUID, func(*createEnv) {}, false, false},
		{"the caller's own REPOST of a gone author", KindRepost, testUID, func(*createEnv) {}, false, false},
		{"QUOTE of a SUSPENDED author", KindQuote, otherUID, func(e *createEnv) {
			e.dir.profiles[goneUID] = identity.Profile{UserID: goneUID, Status: identity.AccountStatusSuspended}
		}, true, true},
		{"QUOTE of a DELETING author", KindQuote, otherUID, func(e *createEnv) {
			e.dir.profiles[goneUID] = identity.Profile{UserID: goneUID, Status: identity.AccountStatusDeleting}
		}, true, true},
		{"the caller's own QUOTE of a gone author", KindQuote, testUID, func(*createEnv) {}, true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newDeleteEnv()
			stored := statusCopy(e.repo.docs[pidOther], tt.kind, goneUID)
			stored.AuthorID = tt.copier
			tt.status(e)
			p, err := e.get(pidOther)
			if !tt.wantFound {
				wantPostNotFound(t, err)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got := p.Embedded.Unavailable; got != tt.wantTomb {
				t.Fatalf("embed unavailable = %v, want %v (%+v)", got, tt.wantTomb, p.Embedded)
			}
			if tt.wantTomb && (p.Embedded.Text != "" || p.EmbeddedAuthor() != "" || p.Text != stored.Text) {
				t.Fatalf("tombstoned QUOTE = %+v", p)
			}
			if stored.Embedded.Unavailable || stored.EmbeddedAuthorID != goneUID {
				t.Fatal("the stored QUOTE was mutated")
			}
			// One Directory call covers the author and the embedded author.
			if len(e.dir.calls) != 1 {
				t.Fatalf("GetProfiles calls = %v, want 1", e.dir.calls)
			}
		})
	}
	// The block rule still sees the original copy, as the feeds (embedAllowed) and search (blockCause) do: a QUOTE whose
	// copied author is SUSPENDED and blocks the caller is NOT_FOUND, not a tombstone.
	e := newDeleteEnv()
	statusCopy(e.repo.docs[pidOther], KindQuote, goneUID)
	e.dir.profiles[goneUID] = identity.Profile{UserID: goneUID, Status: identity.AccountStatusSuspended}
	e.graph.snaps = map[string]graph.Snapshot{testUID: {BlockedBy: map[string]bool{goneUID: true}}}
	_, err := e.get(pidOther)
	wantPostNotFound(t, err)

	e = newDeleteEnv()
	statusCopy(e.repo.docs[pidOther], KindQuote, goneUID)
	e.dir.profileErr = errors.New("down")
	if _, err := e.get(pidOther); err == nil {
		t.Fatal("a Directory failure must fail GetPost")
	}
}

// GetThread reply rows: a reply by a SUSPENDED, DELETING or missing author is dropped; the caller's own reply is kept
// without asking; one batch; a Directory failure fails the page; a full page still gets its token.
func TestGetThread_ReplyAuthorStatus(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name string
		set  func(e *createEnv)
	}{
		{"SUSPENDED", func(e *createEnv) {
			e.dir.profiles[uDave] = identity.Profile{UserID: uDave, Status: identity.AccountStatusSuspended}
		}},
		{"DELETING", func(e *createEnv) {
			e.dir.profiles[uDave] = identity.Profile{UserID: uDave, Status: identity.AccountStatusDeleting}
		}},
		{"no users doc", func(e *createEnv) { delete(e.dir.profiles, uDave) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			e := newThreadEnv()
			tc.set(e)
			e.dir.calls = nil
			ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), testUID))
			th, err := e.svc.GetThread(ctx, testUID, ThreadInput{PostID: rRoot})
			if err != nil {
				t.Fatal(err)
			}
			if got, want := idsOf(th.Replies), []string{rReply1, rReply4}; !slices.Equal(got, want) {
				t.Fatalf("replies = %v, want %v (dave's two dropped)", got, want)
			}
			var batch []string
			for _, c := range e.dir.calls {
				if slices.Contains(c, uDave) {
					if batch != nil {
						t.Fatalf("reply authors asked twice: %v", e.dir.calls)
					}
					batch = c
				}
			}
			if batch == nil || slices.Contains(batch, testUID) {
				t.Fatalf("reply batch = %v, want one batch without the caller", batch)
			}
			if got, _ := info.Get("audience_dropped_inactive"); fmt.Sprint(got) != "2" {
				t.Fatalf("audience_dropped_inactive = %v, want 2", got)
			}
		})
	}
	t.Run("Directory failure fails the page", func(t *testing.T) {
		t.Parallel()
		e := newThreadEnv()
		if _, err := e.thread(ThreadInput{PostID: rRoot}); err != nil {
			t.Fatal(err)
		}
		e.dir.profileErr = errors.New("down")
		if _, err := e.thread(ThreadInput{PostID: rRoot}); err == nil {
			t.Fatal("a Directory failure must fail GetThread")
		}
	})
	t.Run("a fully dropped full page still advances", func(t *testing.T) {
		t.Parallel()
		e := newThreadEnv()
		delete(e.dir.profiles, uCarol)
		th, err := e.thread(ThreadInput{PostID: rRoot, PageSize: 1}) // the first row is carol's
		if err != nil {
			t.Fatal(err)
		}
		if len(th.Replies) != 0 || th.NextPageToken == "" {
			t.Fatalf("replies = %v next=%q, want none and a token", idsOf(th.Replies), th.NextPageToken)
		}
	})
}
