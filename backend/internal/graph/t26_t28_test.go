package graph

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// T26 (ADR-0008 A1): a Mute whose target has no graph doc maps to the same NOT_FOUND as Block's, byte for
// byte (no oracle difference), and the service still sets no cache side effects.
func TestMute_NotFoundIdenticalToBlock(t *testing.T) {
	repo := newFakeRepo()
	repo.muteErr = ErrNotFoundOrBlocked
	repo.blockErr = ErrNotFoundOrBlocked
	dir := &fakeDirectory{}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})

	_, muteErr := svc.Mute(context.Background(), "uid-1", validKey, "uid-2")
	_, blockErr := svc.Block(context.Background(), "uid-1", validKey, "uid-2")
	assertAPIErr(t, muteErr, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	assertAPIErr(t, blockErr, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if muteErr.Error() != blockErr.Error() {
		t.Errorf("Mute NOT_FOUND %q differs from Block NOT_FOUND %q", muteErr, blockErr)
	}
	if dir.forgetCalled != 0 {
		t.Errorf("Forget calls = %d, want 0", dir.forgetCalled)
	}
}

// T28 (ADR-0008 A3): edgeID is the only place a follows doc id is built and refuses `_` in either uid.
func TestEdgeID(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, a, b, want string
		wantErr          bool
	}{
		{name: "plain", a: "uid-a", b: "uid-b", want: "uid-a_uid-b"},
		{name: "underscore in follower", a: "a_b", b: "c", wantErr: true},
		{name: "underscore in followee", a: "a", b: "b_c", wantErr: true},
		{name: "leading underscore", a: "_a", b: "c", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := edgeID(tt.a, tt.b)
			if (err != nil) != tt.wantErr {
				t.Fatalf("edgeID(%q,%q) err = %v, wantErr %v", tt.a, tt.b, err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("edgeID(%q,%q) = %q, want %q", tt.a, tt.b, got, tt.want)
			}
		})
	}
}
