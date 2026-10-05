package apiserver

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"connectrpc.com/connect"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/timeline"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// TestPostsAndTimeline_DegradedReadonly (T5 acceptance, timeline bodies T12/T13): with DEGRADED_MODE=readonly the mutating RPCs
// (CreatePost, DeletePost) are rejected by the platform interceptor, and the read RPCs (GetPost, both
// timelines) get through to the handler. This is mechanical: it follows each RPC's proto idempotency_level.
// The handlers are the real posts/timeline servers behind the real flag registry (on).
func TestPostsAndTimeline_DegradedReadonly(t *testing.T) {
	registry := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On})
	svc := posts.New(posts.Deps{Repo: nil, Cache: posts.NewCache(time.Minute, 0, 0)})

	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: "uid-ro", SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(setUID, degraded.Interceptor(config.DegradedReadonly, degraded.ProcedureSet{}), mw.ErrorMapping(slog.Default()))

	mux := http.NewServeMux()
	p, h := postsv1connect.NewPostServiceHandler(posts.NewServer(svc, registry), opts)
	mux.Handle(p, h)
	p, h = timelinev1connect.NewTimelineServiceHandler(timeline.NewServer(timeline.Deps{Flags: registry, Posts: emptyReader{svc}, Graph: emptyGraph{}}), opts)
	mux.Handle(p, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	postClient := postsv1connect.NewPostServiceClient(srv.Client(), srv.URL)
	tlClient := timelinev1connect.NewTimelineServiceClient(srv.Client(), srv.URL)
	ctx := context.Background()

	tests := []struct {
		name string
		call func() error
		want connect.Code
		ok   bool // the call must succeed (the handler ran)
	}{
		{"CreatePost is blocked", func() error {
			_, err := postClient.CreatePost(ctx, connect.NewRequest(&postsv1.CreatePostRequest{}))
			return err
		}, connect.CodeUnavailable, false},
		{"DeletePost is blocked", func() error {
			_, err := postClient.DeletePost(ctx, connect.NewRequest(&postsv1.DeletePostRequest{}))
			return err
		}, connect.CodeUnavailable, false},
		{"GetPost is not blocked", func() error {
			_, err := postClient.GetPost(ctx, connect.NewRequest(&postsv1.GetPostRequest{}))
			return err
		}, connect.CodeUnimplemented, false},
		{"GetHomeTimeline is not blocked", func() error {
			_, err := tlClient.GetHomeTimeline(ctx, connect.NewRequest(&timelinev1.GetHomeTimelineRequest{}))
			return err
		}, 0, true},
		{"GetUserTimeline is not blocked", func() error {
			_, err := tlClient.GetUserTimeline(ctx, connect.NewRequest(&timelinev1.GetUserTimelineRequest{}))
			return err
		}, connect.CodeInvalidArgument, false}, // the handler ran: it rejects the empty user_id before any read
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.call()
			if tt.ok {
				if err != nil {
					t.Fatalf("err = %v, want success (the read RPC reached its handler)", err)
				}
				return
			}
			if got := connect.CodeOf(err); got != tt.want {
				t.Fatalf("code = %v, want %v", got, tt.want)
			}
		})
	}
}

// emptyReader serves no posts, so the home handler can run without a Firestore repo.
type emptyReader struct{ posts.Reader }

func (emptyReader) AuthorRecent(string) (posts.Recent, bool) { return posts.Recent{}, false }
func (emptyReader) ByAuthors(context.Context, []string, posts.Window, int) ([]*posts.Post, error) {
	return nil, nil
}

// emptyGraph is a caller with no social context.
type emptyGraph struct{}

func (emptyGraph) Snapshot(context.Context, string) (graph.Snapshot, error) {
	return graph.Snapshot{}, nil
}
