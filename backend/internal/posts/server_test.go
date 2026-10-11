package posts

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

type fakeFlags struct {
	on    bool
	asked []string
}

func (f *fakeFlags) Enabled(uid, name string) bool {
	f.asked = append(f.asked, uid+"/"+name)
	return f.on
}

func callerCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

func TestGuardFeature(t *testing.T) {
	tests := []struct {
		name       string
		ctx        context.Context
		flags      FlagChecker
		wantCode   connect.Code
		wantReason commonv1.ErrorReason
		wantOK     bool
	}{
		{"flag on", callerCtx("u1"), &fakeFlags{on: true}, 0, 0, true},
		{"flag off", callerCtx("u1"), &fakeFlags{}, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, false},
		{"nil flags fail closed", callerCtx("u1"), nil, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, false},
		{"no caller", context.Background(), &fakeFlags{on: true}, connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := GuardFeature(tc.ctx, tc.flags)
			if tc.wantOK {
				if err != nil {
					t.Fatalf("err = %v, want nil", err)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != tc.wantCode || ae.Reason != tc.wantReason {
				t.Fatalf("err = %#v, want code %v reason %v", err, tc.wantCode, tc.wantReason)
			}
		})
	}
}

func TestGuardFeature_ChecksThePostsFlagForTheCaller(t *testing.T) {
	f := &fakeFlags{on: true}
	if err := GuardFeature(callerCtx("uid-7"), f); err != nil {
		t.Fatal(err)
	}
	if len(f.asked) != 1 || f.asked[0] != "uid-7/posts" {
		t.Fatalf("asked = %v, want [uid-7/posts]", f.asked)
	}
}

func TestGuardFeature_LogsTheRejection(t *testing.T) {
	ctx, info := logger.WithRequestInfo(callerCtx("u1"))
	if err := GuardFeature(ctx, &fakeFlags{}); err == nil {
		t.Fatal("want FEATURE_DISABLED")
	}
	if v, ok := info.Get("feature_disabled"); !ok || v != true {
		t.Fatalf("feature_disabled = %v, %v", v, ok)
	}
	if v, ok := info.Get("outcome"); !ok || v != "rejected:feature_disabled" {
		t.Fatalf("outcome = %v, %v", v, ok)
	}
}

// TestServer_RPCsAreBehindTheFlag: off => FEATURE_DISABLED with 0 Firestore reads; GetThread (P3) reaches the service when on.
func TestServer_RPCsAreBehindTheFlag(t *testing.T) {
	calls := map[string]func(*Server, context.Context) error{
		"CreatePost": func(s *Server, ctx context.Context) error {
			_, err := s.CreatePost(ctx, connect.NewRequest(&postsv1.CreatePostRequest{}))
			return err
		},
		"DeletePost": func(s *Server, ctx context.Context) error {
			_, err := s.DeletePost(ctx, connect.NewRequest(&postsv1.DeletePostRequest{}))
			return err
		},
		"GetPost": func(s *Server, ctx context.Context) error {
			_, err := s.GetPost(ctx, connect.NewRequest(&postsv1.GetPostRequest{}))
			return err
		},
		"GetThread": func(s *Server, ctx context.Context) error {
			_, err := s.GetThread(ctx, connect.NewRequest(&postsv1.GetThreadRequest{}))
			return err
		},
	}
	repo := newFakeRepo()
	svc := New(Deps{Repo: repo, Cache: NewCache(time.Minute, 0, 0)})

	for name, call := range calls {
		t.Run(name+" flag off", func(t *testing.T) {
			ctx, counter := budget.WithCounter(callerCtx("u1"))
			err := call(NewServer(svc, &fakeFlags{}), ctx)
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Code != connect.CodeFailedPrecondition {
				t.Fatalf("err = %#v, want FAILED_PRECONDITION + FEATURE_DISABLED", err)
			}
			if counter.Reads() != 0 || counter.Writes() != 0 || repo.getAllCalls != 0 || repo.queryCalls != 0 {
				t.Fatalf("a disabled call touched Firestore: reads=%d writes=%d", counter.Reads(), counter.Writes())
			}
		})
		if name != "GetThread" {
			continue // implemented in T8/T9; see TestServer_CreatePost, TestServer_DeleteAndGetPost
		}
		t.Run(name+" flag on", func(t *testing.T) {
			err := call(NewServer(svc, &fakeFlags{on: true}), callerCtx("u1"))
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != connect.CodeInvalidArgument { // empty post_id: past the guards, rejected by the service
				t.Fatalf("err = %v, want VALIDATION from the service", err)
			}
		})
	}
}

// TestServer_CreatePost maps a Service result onto the proto PostView and hands the flag-guarded request through.
func TestServer_CreatePost(t *testing.T) {
	e := newCreateEnv()
	srv := NewServer(e.svc, &fakeFlags{on: true})
	resp, err := srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "hi @bob #Go"}))
	if err != nil {
		t.Fatal(err)
	}
	p := resp.Msg.GetPost().GetPost()
	if p.GetPostId() == "" || p.GetConversationId() != p.GetPostId() || p.GetText() != "hi @bob #Go" ||
		p.GetKind() != postsv1.PostKind_POST_KIND_POST || p.GetVisibility() != postsv1.Visibility_VISIBILITY_PUBLIC ||
		p.GetAuthor().GetUserId() != testUID || p.GetAuthor().GetHandle() != "Alice" ||
		len(p.GetMentions()) != 1 || p.GetMentions()[0].GetUserId() != "uid-bob" || len(p.GetHashtags()) != 1 || p.GetHashtags()[0] != "go" ||
		p.GetCreatedAt() == nil || p.GetCreatedAt().AsTime().IsZero() {
		t.Fatalf("response = %v", p)
	}
	if resp.Msg.GetPost().GetLikedByViewer() || resp.Msg.GetPost().GetRepostedByViewer() {
		t.Fatal("viewer flags must be false")
	}

	_, err = srv.CreatePost(callerCtx(testUID), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: "short", Text: "hi"}))
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
		t.Fatalf("err = %v, want VALIDATION", err)
	}
}

// TestServer_DeleteAndGetPost: the handlers pass the caller and ids through and map the result.
func TestServer_DeleteAndGetPost(t *testing.T) {
	e := newDeleteEnv()
	srv := NewServer(e.svc, &fakeFlags{on: true})

	got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidOther}))
	if err != nil {
		t.Fatal(err)
	}
	if p := got.Msg.GetPost().GetPost(); p.GetPostId() != pidOther || p.GetAuthor().GetHandle() != "zed" || got.Msg.GetPost().GetLikedByViewer() {
		t.Fatalf("GetPost = %v", p)
	}
	var nf *apierr.Error
	if _, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: "0000000000000000999"})); !errors.As(err, &nf) || nf.Code != connect.CodeNotFound {
		t.Fatalf("err = %v, want NOT_FOUND", err)
	}

	if _, err := srv.DeletePost(callerCtx(testUID), connect.NewRequest(&postsv1.DeletePostRequest{IdempotencyKey: key1, PostId: pidMine})); err != nil {
		t.Fatal(err)
	}
	if _, ok := e.repo.docs[pidMine]; ok {
		t.Fatal("post not deleted")
	}
	_, err = srv.DeletePost(callerCtx(testUID), connect.NewRequest(&postsv1.DeletePostRequest{IdempotencyKey: key1, PostId: "abc"}))
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
		t.Fatalf("err = %v, want VALIDATION", err)
	}
}
