package graph

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// fakeRepo is an in-memory Repo for service-layer unit tests (testing-strategy skill: table-driven, fakes).
type fakeRepo struct {
	snapshots map[string]Snapshot
	err       error
	calls     int
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{snapshots: map[string]Snapshot{}}
}

func (f *fakeRepo) GetSnapshot(_ context.Context, uid string) (Snapshot, error) {
	f.calls++
	if f.err != nil {
		return Snapshot{}, f.err
	}
	if s, ok := f.snapshots[uid]; ok {
		return s, nil
	}
	return Snapshot{Following: map[string]bool{}, Blocked: map[string]bool{}, Muted: map[string]bool{}, BlockedBy: map[string]bool{}, Requested: map[string]bool{}}, nil
}

// fakeFlags is a minimal FlagChecker fake.
type fakeFlags struct{ on map[string]bool }

func (f *fakeFlags) Enabled(uid, name string) bool {
	if f.on == nil {
		return false
	}
	return f.on[uid+":"+name]
}

func newTestServiceWithRepo(repo Repo, flagsOn bool) *service {
	return New(Deps{
		Repo:  repo,
		Cache: NewCache(time.Minute),
		Flags: &fakeFlags{on: map[string]bool{"uid-1:graph": flagsOn, "uid-a:graph": flagsOn, "uid-b:graph": flagsOn}},
	})
}

func assertAPIErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("error is %T, want *apierr.Error", err)
	}
	if ae.Code != code {
		t.Errorf("Code = %v, want %v", ae.Code, code)
	}
	if ae.Reason != reason {
		t.Errorf("Reason = %v, want %v", ae.Reason, reason)
	}
}

func TestSnapshot_CachesOnHit(t *testing.T) {
	repo := newFakeRepo()
	repo.snapshots["uid-1"] = Snapshot{Following: map[string]bool{"uid-2": true}}
	svc := newTestServiceWithRepo(repo, true)

	s1, err := svc.Snapshot(context.Background(), "uid-1")
	if err != nil {
		t.Fatalf("Snapshot() error = %v", err)
	}
	if !s1.isFollowing("uid-2") {
		t.Fatalf("unexpected snapshot: %+v", s1)
	}
	if repo.calls != 1 {
		t.Fatalf("calls = %d, want 1", repo.calls)
	}

	if _, err := svc.Snapshot(context.Background(), "uid-1"); err != nil {
		t.Fatalf("Snapshot() error = %v", err)
	}
	if repo.calls != 1 {
		t.Errorf("calls = %d, want 1 (cache hit)", repo.calls)
	}
}

func TestSnapshot_PropagatesRepoError(t *testing.T) {
	repo := newFakeRepo()
	repo.err = errors.New("boom")
	svc := newTestServiceWithRepo(repo, true)
	if _, err := svc.Snapshot(context.Background(), "uid-1"); err == nil {
		t.Fatal("expected an error")
	}
}

// TestIsBlockedBy_TrustsViewerBlockedBy is the common case: no overflow, 0 extra reads.
func TestIsBlockedBy_TrustsViewerBlockedBy(t *testing.T) {
	repo := newFakeRepo()
	repo.snapshots["uid-a"] = Snapshot{BlockedBy: map[string]bool{"uid-b": true}}
	svc := newTestServiceWithRepo(repo, true)

	blocked, err := svc.IsBlockedBy(context.Background(), "uid-a", "uid-b")
	if err != nil {
		t.Fatalf("IsBlockedBy() error = %v", err)
	}
	if !blocked {
		t.Error("expected blocked = true")
	}
	if repo.calls != 1 {
		t.Errorf("calls = %d, want 1 (only the viewer's own graph read)", repo.calls)
	}
}

func TestIsBlockedBy_False(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithRepo(repo, true)
	blocked, err := svc.IsBlockedBy(context.Background(), "uid-a", "uid-b")
	if err != nil {
		t.Fatalf("IsBlockedBy() error = %v", err)
	}
	if blocked {
		t.Error("expected blocked = false for an unrelated pair")
	}
}

// TestIsBlockedBy_OverflowFallback (ADR-0008 D2): when the viewer's blockedBy may be incomplete, also check
// the target's own .blocked array — the fail-closed path.
func TestIsBlockedBy_OverflowFallback(t *testing.T) {
	repo := newFakeRepo()
	repo.snapshots["uid-a"] = Snapshot{BlockedBy: map[string]bool{}, BlockedByOverflow: true}
	repo.snapshots["uid-b"] = Snapshot{Blocked: map[string]bool{"uid-a": true}}
	svc := newTestServiceWithRepo(repo, true)

	blocked, err := svc.IsBlockedBy(context.Background(), "uid-a", "uid-b")
	if err != nil {
		t.Fatalf("IsBlockedBy() error = %v", err)
	}
	if !blocked {
		t.Error("expected the overflow fallback to find uid-a in uid-b's own .blocked array")
	}
	if repo.calls != 2 {
		t.Errorf("calls = %d, want 2 (viewer graph + target graph fallback)", repo.calls)
	}
}

func TestIsBlockedBy_OverflowButNotActuallyBlocked(t *testing.T) {
	repo := newFakeRepo()
	repo.snapshots["uid-a"] = Snapshot{BlockedBy: map[string]bool{}, BlockedByOverflow: true}
	repo.snapshots["uid-b"] = Snapshot{Blocked: map[string]bool{}}
	svc := newTestServiceWithRepo(repo, true)

	blocked, err := svc.IsBlockedBy(context.Background(), "uid-a", "uid-b")
	if err != nil {
		t.Fatalf("IsBlockedBy() error = %v", err)
	}
	if blocked {
		t.Error("expected false: overflow does not mean blocked, only that the fallback must be consulted")
	}
}

// TestFlagGuard_DisabledRejectsEveryRPC (ADR-0008 T3): every GraphService RPC returns FEATURE_DISABLED
// with 0 reads when the flag is off for the caller.
func TestFlagGuard_DisabledRejectsEveryRPC(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithRepo(repo, false)
	ctx := context.Background()

	assertDisabled := func(t *testing.T, err error) {
		t.Helper()
		assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	}

	_, err := svc.Follow(ctx, "uid-1", "k", "uid-2")
	assertDisabled(t, err)
	_, err = svc.Unfollow(ctx, "uid-1", "k", "uid-2")
	assertDisabled(t, err)
	_, err = svc.Block(ctx, "uid-1", "k", "uid-2")
	assertDisabled(t, err)
	_, err = svc.Unblock(ctx, "uid-1", "k", "uid-2")
	assertDisabled(t, err)
	_, err = svc.Mute(ctx, "uid-1", "k", "uid-2")
	assertDisabled(t, err)
	_, err = svc.Unmute(ctx, "uid-1", "k", "uid-2")
	assertDisabled(t, err)
	_, err = svc.GetRelationships(ctx, "uid-1", []string{"uid-2"})
	assertDisabled(t, err)
	_, err = svc.ListFollowers(ctx, "uid-1", "uid-2", 20, "")
	assertDisabled(t, err)
	_, err = svc.ListFollowing(ctx, "uid-1", "uid-2", 20, "")
	assertDisabled(t, err)
	_, err = svc.ListBlockedUsers(ctx, "uid-1", 20, "")
	assertDisabled(t, err)
	_, err = svc.ListMutedUsers(ctx, "uid-1", 20, "")
	assertDisabled(t, err)

	if repo.calls != 0 {
		t.Errorf("repo calls = %d, want 0 (the flag guard runs before any Firestore access)", repo.calls)
	}
}

func TestFlagGuard_EnabledPassesThrough(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithRepo(repo, true)
	_, err := svc.Follow(context.Background(), "uid-1", "k", "uid-2")
	// Past the flag guard, T7 hasn't landed yet in this test file's scope; either Unimplemented (skeleton)
	// or a real result is acceptable here — this test only pins "not FEATURE_DISABLED".
	var ae *apierr.Error
	if errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Fatalf("expected the flag-enabled caller to pass the guard, got FEATURE_DISABLED")
	}
}

func TestIsNewAccount(t *testing.T) {
	svc := &service{newAccountWindow: 24 * time.Hour}
	now := time.Now()
	tests := []struct {
		name      string
		createdAt time.Time
		want      bool
	}{
		{"zero createdAt (defensive)", time.Time{}, false},
		{"1 hour old", now.Add(-time.Hour), true},
		{"48 hours old", now.Add(-48 * time.Hour), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := identity.Profile{CreatedAt: tt.createdAt}
			if got := svc.isNewAccount(p, now); got != tt.want {
				t.Errorf("isNewAccount() = %v, want %v", got, tt.want)
			}
		})
	}
}
