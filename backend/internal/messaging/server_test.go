package messaging_test

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// newClient serves the handler behind an interceptor that sets the caller from X-Test-Uid (no header = no identity).
func newClient(t *testing.T, reg *flags.Registry) messagingv1connect.MessagingServiceClient {
	t.Helper()
	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if uid := req.Header().Get("X-Test-Uid"); uid != "" {
				ctx = authn.WithClaims(ctx, authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
			}
			return next(ctx, req)
		}
	})
	mux := http.NewServeMux()
	mux.Handle(messagingv1connect.NewMessagingServiceHandler(messaging.NewServer(messaging.New(reg, messaging.Deps{})), connect.WithInterceptors(uidOf, mw.ErrorMapping(slog.New(slog.NewTextHandler(io.Discard, nil))))))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return messagingv1connect.NewMessagingServiceClient(srv.Client(), srv.URL)
}

func withUID[T any](msg *T, uid string) *connect.Request[T] {
	r := connect.NewRequest(msg)
	if uid != "" {
		r.Header().Set("X-Test-Uid", uid)
	}
	return r
}

func reasonOf(t *testing.T, err error) (commonv1.ErrorReason, map[string]string) {
	t.Helper()
	var ce *connect.Error
	if !asConnect(err, &ce) {
		t.Fatalf("err = %v, want a connect error", err)
	}
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				return ed.GetReason(), ed.GetMetadata()
			}
		}
	}
	return commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil
}

func asConnect(err error, target **connect.Error) bool {
	ce, ok := err.(*connect.Error) //nolint:errorlint // the Connect client returns the concrete type
	if ok {
		*target = ce
	}
	return ok
}

// TestServer_AllSixHandlers (now eleven: the six originals and the five encrypted-conversation RPCs) drives each RPC over
// the wire in allowlist mode with a caller outside the allowlist: SendMessage, AcceptMessageRequest and CommitConversation
// are FAILED_PRECONDITION FEATURE_DISABLED feature=messaging, the others reach their own validation (the flag is not
// globally off). With the flag off, all are FEATURE_DISABLED. An allowlisted caller gets past the gate on all: every RPC
// answers its own validation of the empty request. Without an identity every RPC is UNAUTHENTICATED.
func TestServer_AllSixHandlers(t *testing.T) {
	ctx := context.Background()
	calls := map[string]func(c messagingv1connect.MessagingServiceClient, uid string) error{
		"SendMessage": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.SendMessage(ctx, withUID(&messagingv1.SendMessageRequest{}, uid))
			return err
		},
		"AcceptMessageRequest": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.AcceptMessageRequest(ctx, withUID(&messagingv1.AcceptMessageRequestRequest{}, uid))
			return err
		},
		"ListConversations": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.ListConversations(ctx, withUID(&messagingv1.ListConversationsRequest{}, uid))
			return err
		},
		"ListMessages": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.ListMessages(ctx, withUID(&messagingv1.ListMessagesRequest{}, uid))
			return err
		},
		"MarkConversationRead": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.MarkConversationRead(ctx, withUID(&messagingv1.MarkConversationReadRequest{}, uid))
			return err
		},
		"DeleteConversation": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.DeleteConversation(ctx, withUID(&messagingv1.DeleteConversationRequest{}, uid))
			return err
		},
		// The encrypted-conversation RPCs (E2EE plan 3): CommitConversation per caller (as SendMessage); the three sync
		// lists and AckWelcomes not globally off. None needs e2ee_dm (the registry here does not even define it).
		"CommitConversation": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.CommitConversation(ctx, withUID(&messagingv1.CommitConversationRequest{}, uid))
			return err
		},
		"ListConversationCommits": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.ListConversationCommits(ctx, withUID(&messagingv1.ListConversationCommitsRequest{}, uid))
			return err
		},
		"ListEpochMessages": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.ListEpochMessages(ctx, withUID(&messagingv1.ListEpochMessagesRequest{}, uid))
			return err
		},
		"ListWelcomes": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.ListWelcomes(ctx, withUID(&messagingv1.ListWelcomesRequest{}, uid))
			return err
		},
		"AckWelcomes": func(c messagingv1connect.MessagingServiceClient, uid string) error {
			_, err := c.AckWelcomes(ctx, withUID(&messagingv1.AckWelcomesRequest{}, uid))
			return err
		},
	}
	perCaller := map[string]bool{"SendMessage": true, "AcceptMessageRequest": true, "CommitConversation": true}
	// open is the code a caller past the gate gets from this RPC: the validation of the empty request.
	open := func(string) connect.Code { return connect.CodeInvalidArgument }

	allow := newClient(t, registry(flags.Allowlist, 0))
	off := newClient(t, registry(flags.Off, 0))
	for name, call := range calls {
		t.Run(name, func(t *testing.T) {
			// Outside the allowlist.
			err := call(allow, outList)
			if perCaller[name] {
				wantDisabled(t, err)
			} else if connect.CodeOf(err) != open(name) {
				t.Errorf("outside the allowlist: code = %v (%v), want %v", connect.CodeOf(err), err, open(name))
			}
			// Inside the allowlist.
			if err := call(allow, inList); connect.CodeOf(err) != open(name) {
				t.Errorf("allowlisted: code = %v (%v), want %v", connect.CodeOf(err), err, open(name))
			}
			// Globally off: everything is FEATURE_DISABLED, even for a listed uid.
			wantDisabled(t, call(off, inList))
			// No identity: UNAUTHENTICATED, never a flag answer.
			if err := call(allow, ""); connect.CodeOf(err) != connect.CodeUnauthenticated {
				t.Errorf("no caller: code = %v, want Unauthenticated", connect.CodeOf(err))
			}
		})
	}
}

// TestServer_CheckPostShare drives CheckPostShare over the wire: no identity is UNAUTHENTICATED; "messaging" off for the
// caller is FEATURE_DISABLED messaging; "messaging" on with dm_share_check off is FEATURE_DISABLED dm_share_check; with
// both on (and posts, dm_post_share) an empty post id reaches the service's VALIDATION "post_id". Under
// DEGRADED_MODE=readonly it still reaches the service (NO_SIDE_EFFECTS), never DEGRADED_MODE.
func TestServer_CheckPostShare(t *testing.T) {
	ctx := context.Background()
	all := flags.NewRegistry(
		flags.Spec{Name: messaging.FlagName, Mode: flags.On}, flags.Spec{Name: messaging.ShareCheckFlagName, Mode: flags.On},
		flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: messaging.PostShareFlagName, Mode: flags.On},
	)
	check := func(c messagingv1connect.MessagingServiceClient, uid string) error {
		_, err := c.CheckPostShare(ctx, withUID(&messagingv1.CheckPostShareRequest{}, uid))
		return err
	}
	tests := []struct {
		name    string
		reg     *flags.Registry
		uid     string
		code    connect.Code
		reason  commonv1.ErrorReason
		feature string
	}{
		{"no identity", all, "", connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, ""},
		{"messaging outside the allowlist", registry(flags.Allowlist, 0), outList, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "messaging"},
		{"dm_share_check off", registry(flags.On, 0), inList, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, messaging.ShareCheckFlagName},
		{"every flag on reaches the id check", all, inList, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := check(newClient(t, tt.reg), tt.uid)
			if connect.CodeOf(err) != tt.code {
				t.Fatalf("code = %v (%v), want %v", connect.CodeOf(err), err, tt.code)
			}
			if tt.code == connect.CodeUnauthenticated {
				return
			}
			reason, meta := reasonOf(t, err)
			if reason != tt.reason || meta["feature"] != tt.feature {
				t.Fatalf("reason = %v meta = %v, want %v feature=%q", reason, meta, tt.reason, tt.feature)
			}
			if tt.reason == commonv1.ErrorReason_ERROR_REASON_VALIDATION && meta["field"] != "post_id" {
				t.Fatalf("field = %q, want post_id", meta["field"])
			}
		})
	}

	t.Run("answers under readonly", func(t *testing.T) {
		uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
				return next(authn.WithClaims(ctx, authn.Claims{UID: inList, SignInProvider: authn.SignInProviderGoogle}), req)
			}
		})
		mux := http.NewServeMux()
		mux.Handle(messagingv1connect.NewMessagingServiceHandler(messaging.NewServer(messaging.New(all, messaging.Deps{})),
			connect.WithInterceptors(degraded.Interceptor(config.DegradedReadonly, nil), uidOf, mw.ErrorMapping(slog.New(slog.NewTextHandler(io.Discard, nil))))))
		srv := httptest.NewServer(mux)
		t.Cleanup(srv.Close)
		err := check(messagingv1connect.NewMessagingServiceClient(srv.Client(), srv.URL), "")
		if connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatalf("CheckPostShare under readonly: code = %v (%v), want the service's InvalidArgument", connect.CodeOf(err), err)
		}
	})
}

func wantDisabled(t *testing.T, err error) {
	t.Helper()
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("code = %v (%v), want FailedPrecondition", connect.CodeOf(err), err)
	}
	reason, meta := reasonOf(t, err)
	if reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != "messaging" {
		t.Fatalf("reason = %v meta = %v, want FEATURE_DISABLED feature=messaging", reason, meta)
	}
}

// TestServer_ReadonlyRefusesTheMutations: DEGRADED_MODE=readonly refuses SendMessage, MarkConversationRead,
// AcceptMessageRequest and DeleteConversation through the existing interceptor, which reads each RPC's declared
// idempotency level (the two lists are NO_SIDE_EFFECTS and still answer). Nothing in the module is needed for it; this pins
// that the proto keeps declaring the mutations as such.
func TestServer_ReadonlyRefusesTheMutations(t *testing.T) {
	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: inList, SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	mux := http.NewServeMux()
	mux.Handle(messagingv1connect.NewMessagingServiceHandler(messaging.NewServer(messaging.New(registry(flags.On, 0), messaging.Deps{})),
		connect.WithInterceptors(degraded.Interceptor(config.DegradedReadonly, nil), uidOf, mw.ErrorMapping(slog.New(slog.NewTextHandler(io.Discard, nil))))))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	c := messagingv1connect.NewMessagingServiceClient(srv.Client(), srv.URL)
	ctx := context.Background()
	const id = "0123456789abcdef0123456789abcdef"
	for name, call := range map[string]func() error{
		"SendMessage": func() error {
			_, err := c.SendMessage(ctx, connect.NewRequest(&messagingv1.SendMessageRequest{}))
			return err
		},
		"MarkConversationRead": func() error {
			_, err := c.MarkConversationRead(ctx, connect.NewRequest(&messagingv1.MarkConversationReadRequest{ConversationId: id}))
			return err
		},
		"AcceptMessageRequest": func() error {
			_, err := c.AcceptMessageRequest(ctx, connect.NewRequest(&messagingv1.AcceptMessageRequestRequest{ConversationId: id}))
			return err
		},
		"DeleteConversation": func() error {
			_, err := c.DeleteConversation(ctx, connect.NewRequest(&messagingv1.DeleteConversationRequest{ConversationId: id}))
			return err
		},
		"CommitConversation": func() error {
			_, err := c.CommitConversation(ctx, connect.NewRequest(&messagingv1.CommitConversationRequest{ConversationId: id}))
			return err
		},
		"AckWelcomes": func() error {
			_, err := c.AckWelcomes(ctx, connect.NewRequest(&messagingv1.AckWelcomesRequest{Ids: []string{id}}))
			return err
		},
	} {
		err := call()
		if connect.CodeOf(err) != connect.CodeUnavailable {
			t.Errorf("%s: code = %v (%v), want Unavailable", name, connect.CodeOf(err), err)
			continue
		}
		if reason, _ := reasonOf(t, err); reason != commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE {
			t.Errorf("%s: reason = %v, want DEGRADED_MODE", name, reason)
		}
	}
	// A list still reaches the service (its own validation of the empty request), the three sync lists included.
	for name, call := range map[string]func() error{
		"ListMessages": func() error {
			_, err := c.ListMessages(ctx, connect.NewRequest(&messagingv1.ListMessagesRequest{}))
			return err
		},
		"ListConversationCommits": func() error {
			_, err := c.ListConversationCommits(ctx, connect.NewRequest(&messagingv1.ListConversationCommitsRequest{}))
			return err
		},
		"ListEpochMessages": func() error {
			_, err := c.ListEpochMessages(ctx, connect.NewRequest(&messagingv1.ListEpochMessagesRequest{}))
			return err
		},
		"ListWelcomes": func() error {
			_, err := c.ListWelcomes(ctx, connect.NewRequest(&messagingv1.ListWelcomesRequest{}))
			return err
		},
	} {
		if err := call(); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Errorf("%s under readonly: code = %v (%v), want InvalidArgument", name, connect.CodeOf(err), err)
		}
	}
}
