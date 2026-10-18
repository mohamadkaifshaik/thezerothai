package engagement

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

type stubSvc struct {
	calls []string
	res   Result
	err   error
}

func (s *stubSvc) rec(op, uid, key, post string) (Result, error) {
	s.calls = append(s.calls, op+":"+uid+":"+key+":"+post)
	return s.res, s.err
}
func (s *stubSvc) Like(_ context.Context, u, k, p string) (Result, error) {
	return s.rec("like", u, k, p)
}
func (s *stubSvc) Unlike(_ context.Context, u, k, p string) (Result, error) {
	return s.rec("unlike", u, k, p)
}
func (s *stubSvc) Repost(_ context.Context, u, k, p string) (Result, error) {
	return s.rec("repost", u, k, p)
}
func (s *stubSvc) UndoRepost(_ context.Context, u, k, p string) (Result, error) {
	return s.rec("undo", u, k, p)
}

type stubFlags struct {
	on    bool
	asked []string
}

func (f *stubFlags) Enabled(uid, name string) bool {
	f.asked = append(f.asked, name)
	return f.on
}

func callerCtx() context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: "u1", SignInProvider: authn.SignInProviderGoogle})
}

func TestServer_Guards(t *testing.T) {
	tests := []struct {
		name   string
		ctx    context.Context
		on     bool
		code   connect.Code
		reason commonv1.ErrorReason
	}{
		{"flags off", callerCtx(), false, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED},
		{"anonymous", context.Background(), true, connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc := &stubSvc{}
			srv := NewServer(svc, &stubFlags{on: tt.on})
			_, err := srv.LikePost(tt.ctx, connect.NewRequest(&engagementv1.LikePostRequest{IdempotencyKey: keyOK, PostId: pidA}))
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != tt.code || ae.Reason != tt.reason {
				t.Fatalf("err = %#v, want %v/%v", err, tt.code, tt.reason)
			}
			if len(svc.calls) != 0 {
				t.Fatalf("service called behind a closed guard: %v", svc.calls)
			}
		})
	}
}

func TestServer_Maps(t *testing.T) {
	svc := &stubSvc{res: Result{PostID: pidA, LikeCount: 3, RepostCount: 2, LikedByViewer: true, RepostedByViewer: true, RepostPostID: pidRep}}
	srv := NewServer(svc, &stubFlags{on: true})
	ctx := callerCtx()

	like, err := srv.LikePost(ctx, connect.NewRequest(&engagementv1.LikePostRequest{IdempotencyKey: keyOK, PostId: pidA}))
	if err != nil {
		t.Fatal(err)
	}
	if g := like.Msg.GetEngagement(); g.GetPostId() != pidA || g.GetLikeCount() != 3 || g.GetRepostCount() != 2 || !g.GetLikedByViewer() || !g.GetRepostedByViewer() {
		t.Fatalf("like = %v", g)
	}
	if _, err := srv.UnlikePost(ctx, connect.NewRequest(&engagementv1.UnlikePostRequest{IdempotencyKey: keyOK, PostId: pidA})); err != nil {
		t.Fatal(err)
	}
	rp, err := srv.RepostPost(ctx, connect.NewRequest(&engagementv1.RepostPostRequest{IdempotencyKey: keyOK, PostId: pidA}))
	if err != nil || rp.Msg.GetRepostPostId() != pidRep {
		t.Fatalf("repost = %v, %v", rp, err)
	}
	if _, err := srv.UndoRepost(ctx, connect.NewRequest(&engagementv1.UndoRepostRequest{IdempotencyKey: keyOK, PostId: pidA})); err != nil {
		t.Fatal(err)
	}
	want := []string{"like", "unlike", "repost", "undo"}
	for i, op := range want {
		if got := svc.calls[i]; got != op+":u1:"+keyOK+":"+pidA {
			t.Errorf("call %d = %q", i, got)
		}
	}
	// Service errors pass through unchanged.
	svc.err = errors.New("boom")
	if _, err := srv.LikePost(ctx, connect.NewRequest(&engagementv1.LikePostRequest{})); err == nil {
		t.Fatal("service error swallowed")
	}
}
