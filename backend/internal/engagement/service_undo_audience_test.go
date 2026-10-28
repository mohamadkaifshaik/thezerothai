package engagement

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// undoAudience is posts.Audience's direct-surface decision for the table below (the real predicate is covered in
// posts/audience_test.go and through the real chain in apiserver): moderation, blocked-by, protected and unfollowed.
type undoAudience struct {
	fakeAudience
}

func (a undoAudience) Decide(ctx context.Context, viewer string, snap graph.Snapshot, p *posts.Post, s posts.Surface) (posts.Decision, error) {
	if !p.Visible() || (p.AuthorID != viewer && snap.BlockedBy[p.AuthorID]) {
		return posts.Decision{Verdict: posts.NotFound}, nil
	}
	d, err := a.fakeAudience.Decide(ctx, viewer, snap, p, s)
	if d.Verdict == posts.Drop {
		d.Verdict = posts.NotFound
	}
	return d, err
}

// W3-40a (W3-36 L-1): UnlikePost and UndoRepost of a post the caller may not see answer the missing-post shape (the
// bytes a deleted post gets) and still remove the caller's like or repost.
func TestUndoAndUnlike_InvisiblePostAnswersMissingShape(t *testing.T) {
	const goneID = "0000000000000000099"
	tests := []struct {
		name   string
		mutate func(e *env)
		snap   graph.Snapshot
		call   string // post id asked for
		wantID string // the id the write must land on
	}{
		{"protected author, not followed", func(e *env) {}, graph.Snapshot{}, pidA, pidA},
		{"blocked by the author", func(e *env) {}, graph.Snapshot{BlockedBy: map[string]bool{"author": true}}, pidA, pidA},
		{"taken down", func(e *env) { e.posts.docs[pidA].Moderation = posts.ModerationTakenDown }, graph.Snapshot{Following: map[string]bool{"author": true}}, pidA, pidA},
		{"REPOST id of a protected original, not followed", func(e *env) { e.posts.docs[pidRep].AuthorID = "pub" }, graph.Snapshot{}, pidRep, pidA},
	}
	for _, tt := range tests {
		for _, op := range []string{"unlike", "undo"} {
			t.Run(op+"/"+tt.name, func(t *testing.T) {
				e := newEnv(t)
				tt.mutate(e)
				gr := &fakeGraph{snap: tt.snap}
				m, err := New(Deps{
					Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-48 * time.Hour)},
					Events: e.events, CacheTTL: time.Minute, AllowAnonymous: true, Graph: gr,
					Audience: undoAudience{fakeAudience{protected: map[string]bool{"author": true}}},
				})
				if err != nil {
					t.Fatal(err)
				}
				ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: authn.SignInProviderGoogle})
				e.repo.unlikeResult = true
				e.repo.undoRes = UndoResult{Removed: true, RepostPostID: pidRep}
				var got, want Result
				if op == "unlike" {
					got, err = m.Unlike(ctx, "viewer", keyOK, tt.call)
					if err == nil {
						want, err = m.Unlike(ctx, "viewer", keyOK, goneID)
					}
				} else {
					got, err = m.UndoRepost(ctx, "viewer", keyOK, tt.call)
					if err == nil {
						want, err = m.UndoRepost(ctx, "viewer", keyOK, goneID)
					}
				}
				if err != nil {
					t.Fatal(err)
				}
				// Byte identity with a deleted post: only the echoed id differs, and it is the one asked for.
				got.PostID, want.PostID = "", ""
				if got != want || got != (Result{}) {
					t.Fatalf("answer = %+v, deleted-post answer = %+v", got, want)
				}
				ids := e.repo.unlikeIDs
				if op == "undo" {
					ids = e.repo.undoIDs
				}
				if len(ids) == 0 || ids[0] != tt.wantID {
					t.Fatalf("write ids = %v, want the first on %s (undo is never gated)", ids, tt.wantID)
				}
			})
		}
	}
	t.Run("visible post keeps the live counts", func(t *testing.T) {
		e := newEnv(t)
		m, err := New(Deps{
			Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-48 * time.Hour)},
			Events: e.events, CacheTTL: time.Minute, AllowAnonymous: true,
			Graph:    &fakeGraph{snap: graph.Snapshot{Following: map[string]bool{"author": true}}},
			Audience: undoAudience{fakeAudience{protected: map[string]bool{"author": true}}},
		})
		if err != nil {
			t.Fatal(err)
		}
		ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: authn.SignInProviderGoogle})
		e.repo.unlikeResult = true
		r, err := m.Unlike(ctx, "viewer", keyOK, pidA)
		if err != nil || r.PostID != pidA || r.LikeCount != 3 {
			t.Fatalf("r=%+v err=%v", r, err)
		}
	})
	t.Run("a set error answers the missing shape, the write lands", func(t *testing.T) {
		e := newEnv(t)
		m, err := New(Deps{
			Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-48 * time.Hour)},
			Events: e.events, CacheTTL: time.Minute, AllowAnonymous: true, Graph: &fakeGraph{},
			Audience: fakeAudience{err: context.DeadlineExceeded},
		})
		if err != nil {
			t.Fatal(err)
		}
		ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: authn.SignInProviderGoogle})
		r, err := m.Unlike(ctx, "viewer", keyOK, pidA)
		if err != nil || r.LikeCount != 0 || len(e.repo.unlikeIDs) != 1 {
			t.Fatalf("r=%+v err=%v writes=%v", r, err, e.repo.unlikeIDs)
		}
	})
}

// W3-40b (W3-40a residual): a stranger undoing a REPOST id gets the same Result, PostID included, whether the original
// behind it is gone or hidden (protected, not followed). The id is the original's in both.
func TestUndoAndUnlike_RepostIDHiddenEqualsGone(t *testing.T) {
	for _, op := range []string{"unlike", "undo"} {
		t.Run(op, func(t *testing.T) {
			ask := func(hide bool) Result {
				e := newEnv(t)
				e.posts.docs[pidRep].AuthorID = "pub"
				if !hide {
					delete(e.posts.docs, pidA)
				}
				m, err := New(Deps{
					Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-48 * time.Hour)},
					Events: e.events, CacheTTL: time.Minute, AllowAnonymous: true, Graph: &fakeGraph{},
					Audience: undoAudience{fakeAudience{protected: map[string]bool{"author": true}}},
				})
				if err != nil {
					t.Fatal(err)
				}
				ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: authn.SignInProviderGoogle})
				e.repo.unlikeResult = true
				e.repo.undoRes = UndoResult{Removed: true, RepostPostID: pidRep}
				var r Result
				if op == "unlike" {
					r, err = m.Unlike(ctx, "viewer", keyOK, pidRep)
				} else {
					r, err = m.UndoRepost(ctx, "viewer", keyOK, pidRep)
				}
				if err != nil {
					t.Fatal(err)
				}
				return r
			}
			hidden, gone := ask(true), ask(false)
			if hidden != gone || hidden.PostID != pidA {
				t.Fatalf("hidden = %+v, gone = %+v; want identical, PostID %s", hidden, gone, pidA)
			}
		})
	}
}
