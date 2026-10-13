package notifications

import (
	"context"
	"errors"
	"strings"
	"testing"

	"firebase.google.com/go/v4/messaging"
)

func TestClassifySendError(t *testing.T) {
	t.Parallel()
	is := func(want error) func(error) bool { return func(err error) bool { return errors.Is(err, want) } }
	errDead, errSender, errArg, errPerm := errors.New("dead"), errors.New("sender"), errors.New("arg"), errors.New("perm")
	classes := []fcmClass{
		{"UNREGISTERED", true, is(errDead)},
		{"SENDER_ID_MISMATCH", true, is(errSender)},
		{"INVALID_ARGUMENT", false, is(errArg)},
		{"PERMISSION_DENIED", false, is(errPerm)},
	}
	tests := []struct {
		name      string
		err       error
		wantCode  string
		wantPrune bool
	}{
		{"unregistered prunes", errDead, "UNREGISTERED", true},
		{"sender id mismatch prunes", errSender, "SENDER_ID_MISMATCH", true},
		{"invalid argument keeps the device", errArg, "INVALID_ARGUMENT", false},
		{"permission denied keeps the device", errPerm, "PERMISSION_DENIED", false},
		{"unknown keeps the device", errBoom, "UNKNOWN", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			code, prune := classifySendError(tt.err, classes)
			if code != tt.wantCode || prune != tt.wantPrune {
				t.Errorf("classifySendError = %q, %v; want %q, %v", code, prune, tt.wantCode, tt.wantPrune)
			}
		})
	}
}

// TestFCMClassTableNeverPrunesInvalidArgument pins the production table: only UNREGISTERED and
// SENDER_ID_MISMATCH prune.
func TestFCMClassTableNeverPrunesInvalidArgument(t *testing.T) {
	t.Parallel()
	pruned := map[string]bool{}
	for _, c := range fcmClasses {
		if c.prune {
			pruned[c.code] = true
		}
	}
	if len(pruned) != 2 || !pruned["UNREGISTERED"] || !pruned["SENDER_ID_MISMATCH"] {
		t.Fatalf("pruning codes = %v, want exactly UNREGISTERED and SENDER_ID_MISMATCH", pruned)
	}
}

func TestPushErrorCarriesOnlyTheCode(t *testing.T) {
	t.Parallel()
	err := error(&PushError{Code: "PERMISSION_DENIED"})
	if !strings.HasSuffix(err.Error(), "PERMISSION_DENIED") || errors.Is(err, ErrTokenUnregistered) {
		t.Errorf("err = %v", err)
	}
}

// TestMessagingClientRetriesAfterAnInitError: a failed init is not cached for the life of the instance.
func TestMessagingClientRetriesAfterAnInitError(t *testing.T) {
	t.Parallel()
	calls := 0
	s := &FCMSender{newClient: func(context.Context) (*messaging.Client, error) {
		calls++
		if calls == 1 {
			return nil, errBoom
		}
		return &messaging.Client{}, nil
	}}
	if _, err := s.messagingClient(context.Background()); err == nil {
		t.Fatal("first init must fail")
	}
	c, err := s.messagingClient(context.Background())
	if err != nil || c == nil || calls != 2 {
		t.Fatalf("second init = %v, %v, calls %d; want success on retry", c, err, calls)
	}
	if _, err := s.messagingClient(context.Background()); err != nil || calls != 2 {
		t.Fatalf("a successful client must be cached (calls %d, err %v)", calls, err)
	}
}
