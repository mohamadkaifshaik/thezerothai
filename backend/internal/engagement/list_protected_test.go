package engagement

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
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

func (f fakeAudience) Decide(_ context.Context, viewer string, snap graph.Snapshot, p *posts.Post, _ posts.Surface) (posts.Decision, error) {
	if f.err != nil {
		return posts.Decision{}, f.err
	}
	if !f.see(viewer, p.AuthorID, snap) {
		return posts.Decision{Verdict: posts.Drop}, nil
	}
	if ea := p.EmbeddedAuthor(); ea != "" && ea != viewer && !f.see(viewer, ea, snap) {
		if p.Kind == posts.KindRepost {
			return posts.Decision{Verdict: posts.Drop}, nil
		}
		return posts.Decision{Verdict: posts.Show, Embed: postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED}, nil
	}
	return posts.Decision{Verdict: posts.Show}, nil
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
	}{
		{"protected author, not followed: dropped", snapOf(nil, nil, nil), &posts.Post{AuthorID: "p"}, false, 0, false},
		{"protected author, followed: kept, marked protected", following, &posts.Post{AuthorID: "p"}, true, 0, true},
		{"protected author, followed someone else: dropped", graph.Snapshot{Following: map[string]bool{"x": true}}, &posts.Post{AuthorID: "p"}, false, 0, false},
		{"repost of a protected author's post: dropped", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a", Kind: posts.KindRepost, EmbeddedAuthorID: "p"}, false, 0, false},
		{"quote of a protected author's post: kept, PROTECTED embed", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a", Kind: posts.KindQuote, EmbeddedAuthorID: "p"}, true, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED, false},
		{"quote of a protected author's post, followed: kept, no strip", following, &posts.Post{AuthorID: "a", Kind: posts.KindQuote, EmbeddedAuthorID: "p"}, true, 0, false},
		{"own quote of a protected author, followed: kept, no strip", following, &posts.Post{AuthorID: caller, Kind: posts.KindQuote, EmbeddedAuthorID: "p"}, true, 0, false},
		{"public author: kept", snapOf(nil, nil, nil), &posts.Post{AuthorID: "a"}, true, 0, false},
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
				wantDropped := 0
				if !tt.wantKept {
					wantDropped = 1
				}
				if got := e.field(fieldRowsDroppedProtected); got != wantDropped {
					t.Errorf("rows_dropped_protected = %v, want %d", got, wantDropped)
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
