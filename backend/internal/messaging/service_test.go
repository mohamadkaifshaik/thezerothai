package messaging_test

import (
	"context"
	"errors"
	"testing"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	inList  = "uid-in"
	outList = "uid-out"
)

// registry builds the flag registry the way config.Load does for FEATURE_MESSAGING.
func registry(mode flags.Mode, percent int) *flags.Registry {
	return flags.NewRegistry(flags.Spec{
		Name:      messaging.FlagName,
		Mode:      mode,
		Allowlist: map[string]struct{}{inList: {}},
		Percent:   percent,
	})
}

// rpcs lists the six service methods with the flag class each belongs to (ADR-0027 D6).
var rpcs = []struct {
	name      string
	perCaller bool // needs the flag on for the caller; else only "not globally off"
	call      func(ctx context.Context, s messaging.Service, uid string) error
}{
	{"SendMessage", true, func(ctx context.Context, s messaging.Service, uid string) error {
		_, err := s.Send(ctx, uid, &messagingv1.SendMessageRequest{})
		return err
	}},
	{"AcceptMessageRequest", true, func(ctx context.Context, s messaging.Service, uid string) error {
		_, err := s.Accept(ctx, uid, &messagingv1.AcceptMessageRequestRequest{})
		return err
	}},
	{"ListConversations", false, func(ctx context.Context, s messaging.Service, uid string) error {
		_, err := s.ListConversations(ctx, uid, &messagingv1.ListConversationsRequest{})
		return err
	}},
	{"ListMessages", false, func(ctx context.Context, s messaging.Service, uid string) error {
		_, err := s.ListMessages(ctx, uid, &messagingv1.ListMessagesRequest{})
		return err
	}},
	{"MarkConversationRead", false, func(ctx context.Context, s messaging.Service, uid string) error {
		_, err := s.MarkRead(ctx, uid, &messagingv1.MarkConversationReadRequest{})
		return err
	}},
	{"DeleteConversation", false, func(ctx context.Context, s messaging.Service, uid string) error {
		_, err := s.Delete(ctx, uid, &messagingv1.DeleteConversationRequest{})
		return err
	}},
}

// TestService_FlagModes: off / allowlist / percent / on x the two RPC classes x callers inside and outside the cohort.
// Per-caller RPCs are FEATURE_DISABLED unless the flag is on for the caller; the others reach the skeleton's
// ErrNotImplemented unless the flag is globally off. A disabled answer carries metadata feature=messaging.
func TestService_FlagModes(t *testing.T) {
	tests := []struct {
		name string
		reg  *flags.Registry
		uid  string
		// wantOn: flag enabled for this caller; wantNotOff: flag not globally off.
		wantOn, wantNotOff bool
	}{
		{"off, listed uid", registry(flags.Off, 0), inList, false, false},
		{"off, other uid", registry(flags.Off, 0), outList, false, false},
		{"allowlist, listed uid", registry(flags.Allowlist, 0), inList, true, true},
		{"allowlist, other uid", registry(flags.Allowlist, 0), outList, false, true},
		{"percent 0, listed uid", registry(flags.Percent, 0), inList, true, true},
		{"percent 0, other uid", registry(flags.Percent, 0), outList, false, true},
		{"percent 100, other uid", registry(flags.Percent, 100), outList, true, true},
		{"on, other uid", registry(flags.On, 0), outList, true, true},
	}
	for _, tt := range tests {
		for _, rpc := range rpcs {
			t.Run(tt.name+"/"+rpc.name, func(t *testing.T) {
				t.Parallel()
				err := rpc.call(context.Background(), messaging.New(tt.reg), tt.uid)
				open := tt.wantNotOff
				if rpc.perCaller {
					open = tt.wantOn
				}
				if open {
					if !errors.Is(err, messaging.ErrNotImplemented) {
						t.Fatalf("err = %v, want ErrNotImplemented", err)
					}
					return
				}
				var ae *apierr.Error
				if !errors.As(err, &ae) {
					t.Fatalf("err = %v, want an apierr.Error", err)
				}
				if ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != "messaging" {
					t.Fatalf("err = %+v, want FEATURE_DISABLED feature=messaging", ae)
				}
			})
		}
	}
}

// TestService_NilFlagsIsOff: a Service built without a checker is off for everyone, on every RPC.
func TestService_NilFlagsIsOff(t *testing.T) {
	for _, rpc := range rpcs {
		t.Run(rpc.name, func(t *testing.T) {
			var ae *apierr.Error
			if err := rpc.call(context.Background(), messaging.New(nil), inList); !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
				t.Fatalf("err = %v, want FEATURE_DISABLED", err)
			}
		})
	}
}

// TestEnabledFeatures: GetMe.enabled_features lists messaging for the allowlisted uid only.
func TestEnabledFeatures(t *testing.T) {
	reg := registry(flags.Allowlist, 0)
	if got := reg.EnabledFeatures(inList); len(got) != 1 || got[0] != "messaging" {
		t.Errorf("EnabledFeatures(%s) = %v, want [messaging]", inList, got)
	}
	if got := reg.EnabledFeatures(outList); len(got) != 0 {
		t.Errorf("EnabledFeatures(%s) = %v, want none", outList, got)
	}
}
