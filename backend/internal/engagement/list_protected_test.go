package engagement

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// fakeAudience mirrors posts.Audience's list decision for the table below: the real predicate is covered in
// posts/audience_test.go and, through the real chain, in apiserver/w329b_*_integration_test.go.
type fakeAudience struct {
	protected map[string]bool
	err       error
}

func (f fakeAudience) see(viewer, author string, snap graph.Snapshot) bool {
	return author == viewer || !f.protected[author] || snap.Following[author]
}

func (f fakeAudience) Decide(_ context.Context, viewer string, snap graph.Snapshot, p *posts.Post, surface posts.Surface) (posts.Decision, error) {
	if f.err != nil {
		return posts.Decision{}, f.err
	}
	if !f.see(viewer, p.AuthorID, snap) {
		return f.refuse(surface), nil
	}
	if ea := p.EmbeddedAuthor(); ea != "" && ea != viewer && !f.see(viewer, ea, snap) {
		if p.Kind == posts.KindRepost {
			return f.refuse(surface), nil
		}
		return posts.Decision{Verdict: posts.Show, Embed: postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED}, nil
	}
	return posts.Decision{Verdict: posts.Show}, nil
}

// refuse mirrors posts.Audience: Withheld on the owner list surface, Drop otherwise (W3-36 L-2).
func (fakeAudience) refuse(s posts.Surface) posts.Decision {
	if s == posts.SurfaceOwnList {
		return posts.Decision{Verdict: posts.Withheld}
	}
	return posts.Decision{Verdict: posts.Drop}
}

func (f fakeAudience) ProtectedAuthor(_ context.Context, _, author string, _ bool) bool {
	return f.protected[author]
}

func TestLists_ProtectedRows(t *testing.T) {
	following := graph.Snapshot{Following: map[string]bool{"p": true}}
	tests := []struct {
		name      string
		snap      graph.Snapshot
		post      *posts.Post
		wantKept  bool
		wantEmbed postsv1.EmbedViewerState
		wantProt  bool
		wantWith  bool // kept as an owner placeholder (W3-36 L-2)
	}{
		{"protected author, not followed: withheld placeholder", snapOf(nil, nil, nil), &posts.Post{AuthorID: "p"}, true, 0, false, true},
		{"protected author, followed: kept, marked protected", following, &posts.Post{AuthorID: "p"}, true, 0, true, false},
		{"protected author, followed someone else: withheld placeholder", graph.Snapshot{Following: map[string]bool{"x": true}}, &posts.Post{AuthorID: "p"}, true, 0, false, true},
		{"repost of a protected author's post: withheld placeholder", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a", Kind: posts.KindRepost, EmbeddedAuthorID: "p"}, true, 0, false, true},
		{"quote of a protected author's post: kept, PROTECTED embed", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a", Kind: posts.KindQuote, EmbeddedAuthorID: "p"}, true, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED, false, false},
		{"quote of a protected author's post, followed: kept, no strip", following, &posts.Post{AuthorID: "a", Kind: posts.KindQuote, EmbeddedAuthorID: "p"}, true, 0, false, false},
		{"own quote of a protected author, followed: kept, no strip", following, &posts.Post{AuthorID: caller, Kind: posts.KindQuote, EmbeddedAuthorID: "p"}, true, 0, false, false},
		{"public author: kept", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a"}, true, 0, false, false},
	}
	for _, tt := range tests {
		for _, list := range []string{"bookmarks", "likes"} {
			t.Run(list+"/"+tt.name, func(t *testing.T) {
				e := newListEnv(t, func(d *Deps) { d.Audience = fakeAudience{protected: map[string]bool{"p": true}} })
				e.gr.snap = tt.snap
				id := pid(7)
				p := *tt.post
				p.ID = id
				e.rd.docs[id] = &p
				var (
					kept int
					hint RowHint
				)
				if list == "bookmarks" {
					e.bm.rows = []ExportedBookmark{{PostID: id, BookmarkedAt: e.now}}
					page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
					if err != nil {
						t.Fatal(err)
					}
					if kept = len(page.Rows); kept == 1 {
						hint = page.Rows[0].Hint
					}
					if len(e.bm.pruneCalls) != 0 {
						t.Errorf("a protected row was pruned: %v", e.bm.pruneCalls)
					}
				} else {
					e.repo.loaded = UserLikes{Recent: []string{id}}
					page, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
					if err != nil {
						t.Fatal(err)
					}
					if kept = len(page.Posts); kept == 1 {
						hint = page.Hints[0]
					}
				}
				if (kept == 1) != tt.wantKept {
					t.Fatalf("kept = %d, want kept=%v", kept, tt.wantKept)
				}
				// No protected row is dropped any more: the unapproved ones are kept as placeholders (rows_withheld).
				if got := e.field(fieldRowsDroppedProtected); got != 0 {
					t.Errorf("rows_dropped_protected = %v, want 0", got)
				}
				wantWith := 0
				if tt.wantWith {
					wantWith = 1
				}
				if got := e.field(fieldRowsWithheld); got != wantWith {
					t.Errorf("rows_withheld = %v, want %d", got, wantWith)
				}
				if tt.wantKept && hint.Withheld != tt.wantWith {
					t.Errorf("hint.Withheld = %v, want %v", hint.Withheld, tt.wantWith)
				}
				if got := e.field(fieldRowsDroppedHidden); got != 0 {
					t.Errorf("rows_dropped_hidden = %v, want 0", got)
				}
				if tt.wantKept && (hint.Embed != tt.wantEmbed || hint.Protected != tt.wantProt) {
					t.Errorf("hint = %+v, want embed %v protected %v", hint, tt.wantEmbed, tt.wantProt)
				}
			})
		}
	}
}

func TestLists_AudienceErrorPassesThroughAsUnavailable(t *testing.T) {
	unavailable := apierr.New(connect.CodeUnavailable, 0, "temporarily busy, please retry")
	e := newListEnv(t, func(d *Deps) { d.Audience = fakeAudience{err: unavailable} })
	id := pid(7)
	e.rd.docs[id] = &posts.Post{ID: id, AuthorID: "a"}
	e.bm.rows = []ExportedBookmark{{PostID: id, BookmarkedAt: e.now}}
	_, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeUnavailable {
		t.Fatalf("bookmarks err = %v, want UNAVAILABLE", err)
	}
	e.repo.loaded = UserLikes{Recent: []string{id}}
	_, err = e.m.ListLikedPosts(e.ctx, caller, 0, "")
	if !errors.As(err, &ae) || ae.Code != connect.CodeUnavailable {
		t.Fatalf("likes err = %v, want UNAVAILABLE", err)
	}
}

func TestRowHintApply(t *testing.T) {
	v := &postsv1.PostView{Post: &postsv1.Post{Embedded: &postsv1.EmbeddedPost{PostId: "9", Text: "secret"}}}
	RowHint{Embed: postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED, Protected: true}.Apply(v)
	if v.Post.Embedded.Text != "" || v.Post.Embedded.PostId != "9" || v.Post.Visibility != postsv1.Visibility_VISIBILITY_FOLLOWERS {
		t.Fatalf("hint not applied: %+v", v.Post)
	}
}

// loaderOf is the protected-set loader behind the real posts.Audience of the next test.
type loaderOf map[string]bool

func (l loaderOf) Current(context.Context) (identity.ProtectedSet, error) { return setOf(l), nil }

type setOf map[string]bool

func (s setOf) Has(uid string) bool { return s[uid] }
func (s setOf) CanSee(viewer, author string, following bool) bool {
	return viewer == author || !s[author] || following
}

// TestLists_OwnerPlaceholderMatrix runs the REAL posts.Audience through both owner lists (W3-36 L-2): A unfollows P,
// P protects, P unprotects, P blocks A, A blocks or mutes P. The placeholder appears exactly where A is unapproved
// and neither side blocks or mutes; the full row comes back when A is approved again; the row is never pruned.
func TestLists_OwnerPlaceholderMatrix(t *testing.T) {
	const author = "p"
	tests := []struct {
		name     string
		protect  bool
		snap     graph.Snapshot
		repostBy string // "" = the liked post is by P itself; else a REPOST by this user of P's post
		want     string // "full", "withheld" or "dropped"
	}{
		{"P protects, A never followed or unfollowed", true, snapOf(nil, nil, nil), "", "withheld"},
		{"A follows P (approved)", true, graph.Snapshot{Following: map[string]bool{author: true}}, "", "full"},
		{"P unprotects", false, snapOf(nil, nil, nil), "", "full"},
		{"P blocks A", true, snapOf(nil, []string{author}, nil), "", "dropped"},
		{"A blocks P", true, snapOf([]string{author}, nil, nil), "", "dropped"},
		{"A mutes P", true, snapOf(nil, nil, []string{author}), "", "dropped"},
		{"repost by R of P's post, unapproved", true, snapOf(nil, nil, nil), "r", "withheld"},
		{"repost by R of P's post, P blocks A", true, snapOf(nil, []string{author}, nil), "r", "dropped"},
		{"repost by R of P's post, approved", true, graph.Snapshot{Following: map[string]bool{author: true}}, "r", "full"},
	}
	for _, tt := range tests {
		for _, list := range []string{"bookmarks", "likes"} {
			t.Run(list+"/"+tt.name, func(t *testing.T) {
				prot := loaderOf{}
				if tt.protect {
					prot[author] = true
				}
				e := newListEnv(t, func(d *Deps) { d.Audience = posts.NewSnapshotAudience(prot) })
				e.gr.snap = tt.snap
				id := pid(7)
				p := &posts.Post{ID: id, AuthorID: author, Kind: posts.KindPost, Visibility: posts.VisibilityPublic, Text: "secret", LikeCount: 3}
				if tt.repostBy != "" {
					p = &posts.Post{ID: id, AuthorID: tt.repostBy, Kind: posts.KindRepost, Visibility: posts.VisibilityPublic,
						EmbeddedAuthorID: author, Embedded: &posts.Embedded{PostID: pid(1), Text: "secret", Author: posts.AuthorSnapshot{UserID: author}}}
				}
				e.rd.docs[id] = p
				var hints []RowHint
				if list == "bookmarks" {
					e.bm.rows = []ExportedBookmark{{PostID: id, BookmarkedAt: e.now}}
					page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
					if err != nil {
						t.Fatal(err)
					}
					for _, r := range page.Rows {
						hints = append(hints, r.Hint)
					}
					if len(e.bm.pruneCalls) != 0 {
						t.Errorf("a row was pruned: %v", e.bm.pruneCalls)
					}
				} else {
					e.repo.loaded = UserLikes{Recent: []string{id}}
					page, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
					if err != nil {
						t.Fatal(err)
					}
					hints = page.Hints
				}
				switch tt.want {
				case "dropped":
					if len(hints) != 0 {
						t.Fatalf("want the row dropped, got %d rows", len(hints))
					}
				default:
					if len(hints) != 1 || hints[0].Withheld != (tt.want == "withheld") {
						t.Fatalf("want one %s row, got %+v", tt.want, hints)
					}
				}
				wantWith := 0
				if tt.want == "withheld" {
					wantWith = 1
				}
				if got := e.field(fieldRowsWithheld); got != wantWith {
					t.Errorf("rows_withheld = %v, want %d", got, wantWith)
				}
			})
		}
	}
}

func TestRowHintApplyWithheld(t *testing.T) {
	v := &postsv1.PostView{Post: &postsv1.Post{PostId: "9", Text: "secret", LikeCount: 4, Embedded: &postsv1.EmbeddedPost{PostId: "8"}}, LikedByViewer: true}
	RowHint{Withheld: true, Protected: true}.Apply(v)
	if !v.Withheld || v.Post.PostId != "9" || v.Post.Text != "" || v.Post.LikeCount != 0 || v.Post.Embedded != nil ||
		v.Post.Visibility != postsv1.Visibility_VISIBILITY_UNSPECIFIED || !v.LikedByViewer {
		t.Fatalf("placeholder wrong: %+v", v)
	}
}
