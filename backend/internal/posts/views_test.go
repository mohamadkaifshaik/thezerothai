package posts

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// withViewRule installs r for one test and restores the previous rule.
func withViewRule(t *testing.T, r *ViewCountRule) {
	t.Helper()
	prev := viewRule.Load()
	if r == nil {
		viewRule.Store(nil)
	} else {
		SetViewCountRule(*r)
	}
	t.Cleanup(func() { viewRule.Store(prev) })
}

// TestViewCountVisibility is the hybrid rule table (owner decision 2026-11-14): the author always; anyone else from the
// threshold on and only for an author known not to be protected (an unknown protected state, a set outage, fails
// closed); never on a REPOST row or a withheld row; nowhere while the flag is globally off or before the rule is installed.
func TestViewCountVisibility(t *testing.T) {
	off := func() bool { return true }
	on := &ViewCountRule{Threshold: 1000}
	tests := []struct {
		name      string
		rule      *ViewCountRule
		viewer    string
		count     int64
		kind      Kind
		protected bool
		unknown   bool // the protected set could not be read (known = false)
		withheld  bool
		want      *int64
	}{
		{name: "author below threshold", rule: on, viewer: "author", count: 3, want: ptr(3)},
		{name: "author zero views", rule: on, viewer: "author", count: 0, want: ptr(0)},
		{name: "author, protected", rule: on, viewer: "author", count: 5, protected: true, want: ptr(5)},
		{name: "other below threshold", rule: on, viewer: "other", count: 999},
		{name: "other at threshold", rule: on, viewer: "other", count: 1000, want: ptr(1000)},
		{name: "other above threshold", rule: on, viewer: "other", count: 5000, want: ptr(5000)},
		{name: "other above threshold, protected", rule: on, viewer: "other", count: 5000, protected: true},
		{name: "author, protected state unknown", rule: on, viewer: "author", count: 5, unknown: true, want: ptr(5)},
		{name: "other above threshold, protected state unknown", rule: on, viewer: "other", count: 5000, unknown: true},
		{name: "other above threshold, protected and unknown", rule: on, viewer: "other", count: 5000, protected: true, unknown: true},
		{name: "signed-out viewer above threshold, protected state unknown", rule: on, viewer: "", count: 5000, unknown: true},
		{name: "signed-out viewer above threshold", rule: on, viewer: "", count: 5000, want: ptr(5000)},
		{name: "REPOST row, author", rule: on, viewer: "author", count: 5000, kind: KindRepost},
		{name: "REPOST row, other", rule: on, viewer: "other", count: 5000, kind: KindRepost},
		{name: "withheld row", rule: on, viewer: "other", count: 5000, withheld: true},
		{name: "flag globally off, author", rule: &ViewCountRule{Threshold: 1, Off: off}, viewer: "author", count: 5},
		{name: "flag globally off, other", rule: &ViewCountRule{Threshold: 1, Off: off}, viewer: "other", count: 5},
		{name: "no rule installed", viewer: "author", count: 5},
		{name: "bad threshold means no public count", rule: &ViewCountRule{Threshold: 0}, viewer: "other", count: 5},
		{name: "custom threshold", rule: &ViewCountRule{Threshold: 10}, viewer: "other", count: 10, want: ptr(10)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			withViewRule(t, tt.rule)
			kind := tt.kind
			if kind == "" {
				kind = KindPost
			}
			p := &Post{ID: "0000000000000000001", AuthorID: "author", Kind: kind, ViewCount: tt.count}
			v := ToView(p, ViewerSet{}, tt.viewer)
			if tt.withheld {
				ApplyWithheld(v)
			}
			ApplyPublicViews(v, p, tt.protected, !tt.unknown)
			got := v.GetPost().ViewCount
			switch {
			case tt.want == nil && got != nil:
				t.Fatalf("view_count = %d, want unset", *got)
			case tt.want != nil && (got == nil || *got != *tt.want):
				t.Fatalf("view_count = %v, want %d", got, *tt.want)
			}
		})
	}
}

func ptr(n int64) *int64 { return &n }

// TestApplyWithheldDropsViewCount: a withheld placeholder never carries a count, even the author's.
func TestApplyWithheldDropsViewCount(t *testing.T) {
	withViewRule(t, &ViewCountRule{Threshold: 1})
	v := ToView(&Post{ID: "0000000000000000001", AuthorID: "a", Kind: KindPost, ViewCount: 9}, ViewerSet{}, "a")
	ApplyWithheld(v)
	if v.Post.ViewCount != nil {
		t.Fatal("a withheld row kept view_count")
	}
	ApplyPublicViews(nil, nil, false, true) // nil-safe
	ApplyPublicViews(&postsv1.PostView{}, &Post{}, false, true)
}

// liveRepo is a Repo whose only working method is LiveViewCount.
type liveRepo struct {
	Repo
	n   int64
	err error
}

func (r liveRepo) LiveViewCount(context.Context, string) (int64, error) { return r.n, r.err }

func TestServiceLiveViewCount(t *testing.T) {
	p := &Post{ID: "0000000000000000001", AuthorID: "a", Kind: KindPost}
	withViewRule(t, &ViewCountRule{Threshold: 1000})
	if n, ok := (&service{repo: liveRepo{n: 42}}).LiveViewCount(context.Background(), p); !ok || n != 42 {
		t.Fatalf("live = %d, %v", n, ok)
	}
	if _, ok := (&service{repo: liveRepo{err: errors.New("down")}}).LiveViewCount(context.Background(), p); ok {
		t.Fatal("a failed read must fall back (ok false)")
	}
	if _, ok := (&service{repo: liveRepo{n: 1}}).LiveViewCount(context.Background(), &Post{Kind: KindRepost}); ok {
		t.Fatal("a REPOST has no count of its own")
	}
	if _, ok := (&service{}).LiveViewCount(context.Background(), p); ok {
		t.Fatal("a repo without ViewCounter cannot count")
	}
	withViewRule(t, &ViewCountRule{Threshold: 1, Off: func() bool { return true }})
	if _, ok := (&service{repo: liveRepo{n: 1}}).LiveViewCount(context.Background(), p); ok {
		t.Fatal("globally off: no live count")
	}
}

// liveSvc is a Service whose LiveViewCount answers n.
type liveSvc struct {
	Service
	n  int64
	ok bool
}

func (s liveSvc) LiveViewCount(context.Context, *Post) (int64, bool) { return s.n, s.ok }

type viewsFlags struct{ on bool }

func (f viewsFlags) Enabled(_, name string) bool { return name != ViewsFlagName || f.on }

// TestApplyAuthorLiveViews: GetPost's author gets the live sum (never below the rolled-up count) only with the flag on
// for them; anyone else, or a failed read, keeps what ToView and ApplyPublicViews decided.
func TestApplyAuthorLiveViews(t *testing.T) {
	withViewRule(t, &ViewCountRule{Threshold: 1000})
	p := &Post{ID: "0000000000000000001", AuthorID: "a", Kind: KindPost, ViewCount: 10}
	for _, tc := range []struct {
		name   string
		viewer string
		flagOn bool
		svc    liveSvc
		want   *int64
	}{
		{"author, live higher", "a", true, liveSvc{n: 14, ok: true}, ptr(14)},
		{"author, live lagging", "a", true, liveSvc{n: 7, ok: true}, ptr(10)},
		{"author, read failed", "a", true, liveSvc{}, ptr(10)},
		{"author, flag off for them", "a", false, liveSvc{n: 14, ok: true}, ptr(10)},
		{"other viewer", "b", true, liveSvc{n: 14, ok: true}, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &Server{svc: tc.svc, flags: viewsFlags{on: tc.flagOn}}
			v := ToView(p, ViewerSet{}, tc.viewer)
			s.applyAuthorLiveViews(context.Background(), v, tc.viewer, p)
			got := v.Post.ViewCount
			if (tc.want == nil) != (got == nil) || (got != nil && *got != *tc.want) {
				t.Fatalf("view_count = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestGetPostViewCountFailsClosedOnSetOutage: a follower reads an author's post while the protected set is unknown
// (Decide never asks the set for a followed author, so the read succeeds). The author's protected state is unknown, so
// the count over the threshold is not shown; with the set known and the author public it is.
func TestGetPostViewCountFailsClosedOnSetOutage(t *testing.T) {
	withViewRule(t, &ViewCountRule{Threshold: 1000})
	for _, tc := range []struct {
		name   string
		setErr error
		want   bool
	}{
		{"set unavailable", identity.ErrProtectedSetUnavailable, false},
		{"set known, author public", nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := restrictedEnv("")
			f := e.protect() // nobody protected
			f.err = tc.setErr
			e.graph.snap = following(uZed)
			e.repo.docs[rRoot].ViewCount = 5000
			srv := NewServer(e.svc, replyAudienceRegistry(flags.Spec{Mode: flags.Off}))
			got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: rRoot}))
			if err != nil {
				t.Fatal(err)
			}
			if vc := got.Msg.GetPost().GetPost().ViewCount; (vc != nil) != tc.want {
				t.Fatalf("view_count = %v, want shown=%v", vc, tc.want)
			}
		})
	}
}

// TestPurgeChunkFitsABatch: a purge batch (posts plus their view shards) stays within Firestore's 500 writes.
func TestPurgeChunkFitsABatch(t *testing.T) {
	if purgeChunk < 1 || purgeChunk*(1+viewShardWrites) > 500 {
		t.Fatalf("purgeChunk %d x %d writes exceeds 500", purgeChunk, 1+viewShardWrites)
	}
}
