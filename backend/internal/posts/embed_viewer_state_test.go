package posts

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// Issue #152: GetPost and GetThread tell the client when the viewer blocks or mutes the author of the original a
// REPOST or QUOTE embeds, from the viewer's own lists only.

func TestEmbedViewerState(t *testing.T) {
	unspec, blocked, muted := postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_BLOCKED, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_MUTED
	tests := []struct {
		name      string
		snap      graph.Snapshot
		graphErr  error
		post      func(e *createEnv) *Post
		want      postsv1.EmbedViewerState
		wantReads int64
	}{
		{"plain post: no graph read", graph.Snapshot{Blocked: map[string]bool{uZed: true}},
			nil, func(e *createEnv) *Post { return e.repo.docs[rRoot] }, unspec, 0},
		{"blocked embedded author", graph.Snapshot{Blocked: map[string]bool{uZed: true}},
			nil, func(e *createEnv) *Post { return e.repo.docs[rPolRepost] }, blocked, 1},
		{"muted embedded author", graph.Snapshot{Muted: map[string]bool{uZed: true}},
			nil, func(e *createEnv) *Post { return e.repo.docs[rPolRepost] }, muted, 1},
		{"blocked wins over muted", graph.Snapshot{Blocked: map[string]bool{uZed: true}, Muted: map[string]bool{uZed: true}},
			nil, func(e *createEnv) *Post { return e.repo.docs[rPolRepost] }, blocked, 1},
		{"an author who blocks the viewer is not reported (no block oracle)", graph.Snapshot{BlockedBy: map[string]bool{uZed: true}},
			nil, func(e *createEnv) *Post { return e.repo.docs[rPolRepost] }, unspec, 1},
		{"unrelated block", graph.Snapshot{Blocked: map[string]bool{"uid-other": true}},
			nil, func(e *createEnv) *Post { return e.repo.docs[rPolRepost] }, unspec, 1},
		{"graph error: unspecified, the client falls back", graph.Snapshot{},
			errors.New("firestore down"), func(e *createEnv) *Post { return e.repo.docs[rPolRepost] }, unspec, 1},
		{"the viewer's own repost", graph.Snapshot{Blocked: map[string]bool{uZed: true}},
			nil, func(e *createEnv) *Post {
				p := *e.repo.docs[rPolRepost]
				p.AuthorID = testUID
				return &p
			}, unspec, 0},
		{"a tombstone has no author", graph.Snapshot{Blocked: map[string]bool{uZed: true}},
			nil, func(e *createEnv) *Post {
				p := *e.repo.docs[rPolRepost]
				p.Embedded = &Embedded{PostID: rRoot, Unavailable: true}
				p.EmbeddedAuthorID = ""
				return &p
			}, unspec, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := restrictedEnv("")
			e.graph.snap = tt.snap
			if tt.graphErr != nil {
				e.graph.errs = map[string]error{testUID: tt.graphErr}
			}
			ctx, c := budget.WithCounter(context.Background())
			if got := e.svc.EmbedViewerState(ctx, testUID, tt.post(e)); got != tt.want {
				t.Fatalf("state = %v, want %v", got, tt.want)
			}
			if c.Reads() != tt.wantReads {
				t.Errorf("reads = %d, want %d", c.Reads(), tt.wantReads)
			}
		})
	}
}

func TestServer_GetPost_EmbedViewerState(t *testing.T) {
	e := restrictedEnv("")
	e.graph.snap = graph.Snapshot{Muted: map[string]bool{uZed: true}}
	srv := NewServer(e.svc, replyAudienceRegistry(flags.Spec{Mode: flags.Off}))
	got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: rPolRepost}))
	if err != nil {
		t.Fatal(err)
	}
	if s := got.Msg.GetPost().GetEmbedViewerState(); s != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_MUTED {
		t.Fatalf("GetPost state = %v, want MUTED", s)
	}
	// A post with no embed is never flagged, even when its author is muted.
	e.graph.snap = graph.Snapshot{Muted: map[string]bool{uZed: true}}
	got, err = srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: rRoot}))
	if err == nil && got.Msg.GetPost().GetEmbedViewerState() != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED {
		t.Fatalf("a plain post got state %v", got.Msg.GetPost().GetEmbedViewerState())
	}
}
