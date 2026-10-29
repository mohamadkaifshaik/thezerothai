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

// TestServer_AllSixHandlers drives each RPC over the wire in allowlist mode with a caller outside the allowlist:
// SendMessage and AcceptMessageRequest are FAILED_PRECONDITION FEATURE_DISABLED feature=messaging, the other four reach
// their own validation (the flag is not globally off). With the flag off, all six are FEATURE_DISABLED. An allowlisted
// caller gets past the gate on all six: every RPC answers its own validation of the empty request (W7-9 implemented the
// last two).
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
	}
	perCaller := map[string]bool{"SendMessage": true, "AcceptMessageRequest": true}
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
// that the proto keeps declaring the mutations as such (ADR-0027 D11).
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
	// A list still reaches the service (its own validation of the empty request).
	if _, err := c.ListMessages(ctx, connect.NewRequest(&messagingv1.ListMessagesRequest{})); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Errorf("ListMessages under readonly: code = %v (%v), want InvalidArgument", connect.CodeOf(err), err)
	}
}
