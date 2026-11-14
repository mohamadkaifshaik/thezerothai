package engagement

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// manyReader is fakePosts with a working GetMany over its docs (RecordImpressions' one read).
type manyReader struct {
	*fakePosts
	calls int
	err   error
}

func (r *manyReader) GetMany(_ context.Context, ids []string) (map[string]*posts.Post, error) {
	r.calls++
	if r.err != nil {
		return nil, r.err
	}
	out := map[string]*posts.Post{}
	for _, id := range ids {
		if p, ok := r.docs[id]; ok {
			out[id] = p
		}
	}
	return out, nil
}

// fakeImpressionRepo dedupes like the real repo: "<uid>/<postId>/<day>" keys.
type fakeImpressionRepo struct {
	mu    sync.Mutex
	seen  map[string]bool
	calls [][]string
	err   error
}

func (f *fakeImpressionRepo) RecordImpressions(_ context.Context, uid string, postIDs []string, now time.Time) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, append([]string(nil), postIDs...))
	if f.err != nil {
		return 0, f.err
	}
	if f.seen == nil {
		f.seen = map[string]bool{}
	}
	n := 0
	for _, id := range postIDs {
		k := uid + "/" + id + "/" + ImpressionDay(now)
		if !f.seen[k] {
			f.seen[k] = true
			n++
		}
	}
	return n, nil
}

const (
	pidOwn  = "0000000000000000010"
	pidHid  = "0000000000000000011"
	pidRepO = "0000000000000000012" // a REPOST by someone else of the viewer's own post
	pidGone = "0000000000000000099"
	pidB2   = "0000000000000000013"
	impKey  = "impression-key-0001"
)

func newImpressionEnv(t *testing.T) (*env, *manyReader, *fakeImpressionRepo) {
	t.Helper()
	e := newEnv(t)
	e.posts.docs[pidOwn] = &posts.Post{ID: pidOwn, AuthorID: "viewer", Kind: posts.KindPost}
	e.posts.docs[pidHid] = &posts.Post{ID: pidHid, AuthorID: "author", Kind: posts.KindPost, Moderation: posts.ModerationTakenDown}
	e.posts.docs[pidRepO] = &posts.Post{ID: pidRepO, AuthorID: "other", Kind: posts.KindRepost, RepostOfID: pidOwn}
	rd := &manyReader{fakePosts: e.posts}
	ir := &fakeImpressionRepo{}
	m, err := New(Deps{
		Repo: e.repo, Posts: e.posts, Reader: rd, Directory: fakeDir{}, Events: e.events,
		AllowAnonymous: true, ImpressionRepo: ir,
	})
	if err != nil {
		t.Fatal(err)
	}
	e.m = m
	return e, rd, ir
}

func TestImpressionIDs_Shape(t *testing.T) {
	fifty := make([]string, 51)
	for i := range fifty {
		fifty[i] = fmt.Sprintf("%019d", i+1)
	}
	tests := []struct {
		name, key string
		ids       []string
		wantField string
		want      []string
	}{
		{name: "bad key", key: "short", ids: []string{pidA}, wantField: "idempotency_key"},
		{name: "none", key: impKey, wantField: "post_ids"},
		{name: "51", key: impKey, ids: fifty, wantField: "post_ids"},
		{name: "bad id", key: impKey, ids: []string{pidA, "abc"}, wantField: "post_ids"},
		{name: "fifty ok", key: impKey, ids: fifty[:50], want: fifty[:50]},
		{name: "duplicates merged in order", key: impKey, ids: []string{pidB, pidA, pidB}, want: []string{pidB, pidA}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := impressionIDs(tt.key, tt.ids)
			if tt.wantField != "" {
				ae := requireCode(t, err, connect.CodeInvalidArgument)
				if ae.Metadata["field"] != tt.wantField {
					t.Fatalf("field = %q, want %q", ae.Metadata["field"], tt.wantField)
				}
				return
			}
			if err != nil || !slices.Equal(got, tt.want) {
				t.Fatalf("got %v, %v; want %v", got, err, tt.want)
			}
		})
	}
}

// TestRecordImpressions_Filtering: one GetMany; REPOST ids count their original; own, hidden and missing ids are dropped
// silently; the same post twice (directly and through a REPOST) is one view; the answer is nil either way.
func TestRecordImpressions_Filtering(t *testing.T) {
	e, rd, ir := newImpressionEnv(t)
	err := e.m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidA, pidRep, pidOwn, pidHid, pidGone, pidB, pidRepO})
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if len(ir.calls) != 1 || !slices.Equal(ir.calls[0], []string{pidA, pidB}) {
		t.Fatalf("repo calls = %v, want one call with [A B]", ir.calls)
	}
	if rd.calls != 1 {
		t.Errorf("GetMany calls = %d, want 1 (originals already in the page)", rd.calls)
	}
	// A replay of the same call counts nothing new (the impression docs are the record) and still succeeds.
	if err := e.m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidA, pidB}); err != nil {
		t.Fatal(err)
	}
	if len(ir.seen) != 2 {
		t.Errorf("seen = %v, want 2 impressions", ir.seen)
	}
}

func TestRecordImpressions_OriginalOutsideThePageIsFetched(t *testing.T) {
	e, rd, ir := newImpressionEnv(t)
	if err := e.m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidRep}); err != nil {
		t.Fatal(err)
	}
	if rd.calls != 2 || len(ir.calls) != 1 || !slices.Equal(ir.calls[0], []string{pidA}) {
		t.Fatalf("GetMany %d, repo %v; want 2 reads and [A]", rd.calls, ir.calls)
	}
}

// TestRecordImpressions_SelfViewsOnlyWriteNothing: the author's own views never reach the repo.
func TestRecordImpressions_SelfViewsOnlyWriteNothing(t *testing.T) {
	e, _, ir := newImpressionEnv(t)
	if err := e.m.RecordImpressions(e.ctx, "author", impKey, []string{pidA, pidRep, pidB}); err != nil {
		t.Fatal(err)
	}
	if len(ir.calls) != 0 {
		t.Fatalf("repo calls = %v, want none", ir.calls)
	}
}

func TestRecordImpressions_Errors(t *testing.T) {
	t.Run("contention is UNAVAILABLE with retry_after", func(t *testing.T) {
		e, _, ir := newImpressionEnv(t)
		ir.err = errors.Join(store.ErrContended, errors.New("aborted"))
		ae := requireCode(t, e.m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidA}), connect.CodeUnavailable)
		if ae.RetryAfter <= 0 {
			t.Error("want a retry_after")
		}
	})
	t.Run("a repo failure is an error", func(t *testing.T) {
		e, _, ir := newImpressionEnv(t)
		ir.err = errors.New("boom")
		if err := e.m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidA}); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("a read failure is an error and writes nothing", func(t *testing.T) {
		e, rd, ir := newImpressionEnv(t)
		rd.err = errors.New("read down")
		if err := e.m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidA}); err == nil || len(ir.calls) != 0 {
			t.Fatalf("err %v, calls %v", err, ir.calls)
		}
	})
	t.Run("no repo wired", func(t *testing.T) {
		e := newEnv(t)
		if err := e.m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidA}); err == nil {
			t.Fatal("want an error without an ImpressionRepo")
		}
	})
	t.Run("shape refusal reads nothing", func(t *testing.T) {
		e, rd, _ := newImpressionEnv(t)
		_ = requireCode(t, e.m.RecordImpressions(e.ctx, "viewer", "bad", []string{pidA}), connect.CodeInvalidArgument)
		if rd.calls != 0 {
			t.Fatal("a shape refusal must not read")
		}
	})
}

// TestImpressionDay_ISTBoundary: the dedupe day rolls over at IST midnight (18:30 UTC), not at UTC midnight.
func TestImpressionDay_ISTBoundary(t *testing.T) {
	for _, tc := range []struct {
		at   time.Time
		want string
	}{
		{time.Date(2026, 11, 14, 18, 29, 59, 0, time.UTC), "20261114"},
		{time.Date(2026, 11, 14, 18, 30, 0, 0, time.UTC), "20261115"},
		{time.Date(2026, 11, 14, 23, 59, 0, 0, time.UTC), "20261115"},
		{time.Date(2026, 12, 31, 18, 30, 0, 0, time.UTC), "20270101"},
	} {
		if got := ImpressionDay(tc.at); got != tc.want {
			t.Errorf("ImpressionDay(%s) = %s, want %s", tc.at, got, tc.want)
		}
	}
	if got := impressionID(pidA, "20261115"); got != pidA+"_20261115" {
		t.Errorf("impressionID = %q", got)
	}
	d := newImpressionDoc(pidA, "20261115", time.Date(2026, 11, 14, 20, 0, 0, 0, time.UTC))
	if d.ExpireAt.Sub(d.CreatedAt) != 48*time.Hour || d.PostID != pidA || d.Day != "20261115" {
		t.Errorf("impression doc = %+v, want expireAt = createdAt + 48h", d)
	}
}

// impressionFlags is a FlagChecker with post_views on or off for everyone.
type impressionFlags struct{ on bool }

func (f impressionFlags) Enabled(_, name string) bool {
	return name != ImpressionsFlagName || f.on
}

// TestRecordImpressionsHandler_Flag: with post_views off for the caller the handler answers FEATURE_DISABLED before any
// lookup; on, it answers the empty response.
func TestRecordImpressionsHandler_Flag(t *testing.T) {
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: authn.SignInProviderGoogle})
	req := connect.NewRequest(&engagementv1.RecordImpressionsRequest{IdempotencyKey: impKey, PostIds: []string{pidA}})
	for _, on := range []bool{false, true} {
		e, rd, ir := newImpressionEnv(t)
		srv := NewServer(e.m, impressionFlags{on: on})
		res, err := srv.RecordImpressions(ctx, req)
		if !on {
			ae := requireCode(t, err, connect.CodeFailedPrecondition)
			if ae.Metadata["feature"] != ImpressionsFlagName || rd.calls != 0 || len(ir.calls) != 0 {
				t.Fatalf("flag off: meta %v, reads %d, writes %v", ae.Metadata, rd.calls, ir.calls)
			}
			continue
		}
		if err != nil || res.Msg == nil || len(ir.calls) != 1 {
			t.Fatalf("flag on: %v, %v, writes %v", res, err, ir.calls)
		}
	}
	srv := NewServer(&stubSvc{}, impressionFlags{on: true})
	if _, err := srv.RecordImpressions(ctx, req); connect.CodeOf(err) != connect.CodeUnimplemented {
		t.Fatalf("unwired: %v, want Unimplemented", err)
	}
}

// TestRecordImpressions_ProtectedAndBlocked: a protected author's post counts only for a follower; an author who blocks
// the viewer is not counted; the graph snapshot is read once per call, and not at all for a page of the viewer's own posts.
func TestRecordImpressions_ProtectedAndBlocked(t *testing.T) {
	for _, tc := range []struct {
		name string
		snap graph.Snapshot
		want []string
	}{
		{"protected, not followed", graph.Snapshot{}, []string{pidB2}},
		{"protected, followed", graph.Snapshot{Following: map[string]bool{"author": true}}, []string{pidA, pidB2}},
		{"blocked by the public author", graph.Snapshot{BlockedBy: map[string]bool{"pub": true}}, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			e.posts.docs[pidB2] = &posts.Post{ID: pidB2, AuthorID: "pub", Kind: posts.KindPost}
			e.posts.docs[pidOwn] = &posts.Post{ID: pidOwn, AuthorID: "viewer", Kind: posts.KindPost}
			rd := &manyReader{fakePosts: e.posts}
			ir := &fakeImpressionRepo{}
			gr := &fakeGraph{snap: tc.snap}
			m, err := New(Deps{
				Repo: e.repo, Posts: e.posts, Reader: rd, Directory: fakeDir{}, Events: e.events,
				AllowAnonymous: true, ImpressionRepo: ir, Graph: gr,
				Audience: undoAudience{fakeAudience{protected: map[string]bool{"author": true}}},
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidA, pidB2, pidOwn}); err != nil {
				t.Fatal(err)
			}
			var got []string
			if len(ir.calls) == 1 {
				got = ir.calls[0]
			}
			if !slices.Equal(got, tc.want) || gr.calls != 1 {
				t.Fatalf("counted %v (graph reads %d), want %v and one read", got, gr.calls, tc.want)
			}
			gr.calls = 0
			if err := m.RecordImpressions(e.ctx, "viewer", impKey, []string{pidOwn}); err != nil || gr.calls != 0 {
				t.Fatalf("own page: err %v, graph reads %d, want none", err, gr.calls)
			}
		})
	}
}
