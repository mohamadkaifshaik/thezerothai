package posts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// rollbackRunner behaves like the Firestore client's RunTransaction for the cases that matter here: the body's returned
// error rolls the transaction back and is returned (a non-Aborted error is not retried); a panic would NOT roll back.
type rollbackRunner struct{ bodies, rollbacks int }

func (r *rollbackRunner) RunTransaction(ctx context.Context, f func(context.Context, *firestore.Transaction) error, _ ...firestore.TransactionOption) error {
	r.bodies++
	if err := f(ctx, nil); err != nil {
		r.rollbacks++
		return err
	}
	return nil
}

// A panic inside the publish callback must come back as a returned error, so the client rolls back instead of leaving a
// transaction open that holds the author's users and quotas docs (review M-2). Only the panic TYPE is kept.
func TestGuardPublishPanic(t *testing.T) {
	var nilMap map[string]int
	tests := []struct {
		name      string
		body      func(context.Context, *firestore.Transaction) error
		wantPanic string // "" = no panic
		wantErr   error  // for a normal return
	}{
		{"a string panic", func(context.Context, *firestore.Transaction) error { panic("secret uid-1 draft text") }, "string", nil},
		{"a runtime error panic", func(context.Context, *firestore.Transaction) error { nilMap["x"] = 1; return nil }, "runtime.", nil},
		{"an error value panic", func(context.Context, *firestore.Transaction) error { panic(errors.New("uid-2")) }, "*errors.errorString", nil},
		{"a normal error passes through unchanged", func(context.Context, *firestore.Transaction) error { return errBoom }, "", errBoom},
		{"success passes through", func(context.Context, *firestore.Transaction) error { return nil }, "", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			runner := &rollbackRunner{}
			attempts, err := store.RunTransaction(context.Background(), runner, guardPublishPanic(tc.body))
			if tc.wantPanic == "" {
				if !errors.Is(err, tc.wantErr) && !(tc.wantErr == nil && err == nil) {
					t.Fatalf("err = %v, want %v", err, tc.wantErr)
				}
				if errors.Is(err, errPublishPanic) {
					t.Error("a non-panic became errPublishPanic")
				}
				return
			}
			if !errors.Is(err, errPublishPanic) {
				t.Fatalf("err = %v, want errPublishPanic", err)
			}
			if runner.rollbacks != 1 || attempts != 1 {
				t.Errorf("rollbacks = %d attempts = %d, want the client to roll back once and not retry", runner.rollbacks, attempts)
			}
			msg := err.Error()
			if !strings.Contains(msg, "panic of type "+tc.wantPanic) {
				t.Errorf("error = %q, want the panic type %s", msg, tc.wantPanic)
			}
			for _, secret := range []string{"secret", "uid-1", "uid-2", "draft text"} {
				if strings.Contains(msg, secret) {
					t.Errorf("the panic value leaked into the error: %q", msg)
				}
			}
		})
	}
}

func TestPublishPanicErrorIsOnlyTheSentinel(t *testing.T) {
	wrapped := fmt.Errorf("outer: %w", &publishPanicError{typ: "x"})
	if !errors.Is(wrapped, errPublishPanic) {
		t.Error("a wrapped publishPanicError must match errPublishPanic")
	}
	if errors.Is(errBoom, errPublishPanic) || errors.Is(&publishPanicError{typ: "x"}, errBoom) {
		t.Error("errPublishPanic matches unrelated errors")
	}
}

// The author block of a post is built from an identity.Profile in exactly one place, for CreatePost and for the scheduled
// publish transaction alike: the uid is the caller's (never the profile's), the avatar is the thumbnail, and the snapshot
// version travels with it.
func TestAuthorSnapshotOf(t *testing.T) {
	p := identity.Profile{
		UserID: "profile-uid", Handle: "Alice", DisplayName: "Alice A", AvatarURL: "full.jpg", AvatarThumbURL: "thumb.jpg",
		Verified: true, SnapshotVersion: 7, Bio: "not part of the snapshot",
	}
	got, version := authorSnapshotOf("uid-alice", p)
	want := AuthorSnapshot{UserID: "uid-alice", Handle: "Alice", DisplayName: "Alice A", AvatarURL: "thumb.jpg", Verified: true}
	if got != want || version != 7 {
		t.Errorf("authorSnapshotOf = %+v, %d, want %+v, 7", got, version, want)
	}
	zero, zv := authorSnapshotOf("uid-x", identity.Profile{})
	if zero != (AuthorSnapshot{UserID: "uid-x"}) || zv != 0 {
		t.Errorf("zero profile = %+v, %d, want only the uid", zero, zv)
	}
}
