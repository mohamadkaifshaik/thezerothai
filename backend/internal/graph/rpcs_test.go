package graph

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const validKey = "0123456789abcdef"

func activeProfile(uid string, createdAt time.Time) identity.Profile {
	return identity.Profile{UserID: uid, Status: identity.AccountStatusActive, CreatedAt: createdAt}
}

func TestFollow_FeatureDisabled(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithRepo(repo, false)
	_, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2")
	assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if repo.calls+repo.followCalls != 0 {
		t.Error("expected 0 repo calls when the flag is off")
	}
}

func TestFollow_InvalidIdempotencyKey(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	_, err := svc.Follow(context.Background(), "uid-1", "too-short", "uid-2")
	assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
}

func TestFollow_SelfFollow(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	_, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-1")
	assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
}

func TestFollow_TargetMissing_NotFound(t *testing.T) {
	repo := newFakeRepo()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{"uid-1": activeProfile("uid-1", time.Now())}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})
	_, err := svc.Follow(context.Background(), "uid-1", validKey, "ghost")
	assertAPIErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if repo.followCalls != 0 {
		t.Error("expected the repo transaction to never open for a missing target")
	}
}

func TestFollow_Success(t *testing.T) {
	repo := newFakeRepo()
	repo.followResult = Relationship{UserID: "uid-2", FollowState: FollowStateFollowing}
	repo.followOutcome = OutcomeCreated
	now := time.Now()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		"uid-1": activeProfile("uid-1", now.Add(-72*time.Hour)),
		"uid-2": activeProfile("uid-2", now.Add(-72*time.Hour)),
	}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{FollowsPerDay: 200, NewAccountFollowsPerDay: 50, NewAccountWindow: 24 * time.Hour})

	rel, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2")
	if err != nil {
		t.Fatalf("Follow() error = %v", err)
	}
	if rel.FollowState != FollowStateFollowing {
		t.Errorf("FollowState = %v, want FOLLOWING", rel.FollowState)
	}
	if repo.followCalls != 1 {
		t.Fatalf("followCalls = %d, want 1", repo.followCalls)
	}
	if got := repo.lastFollowArgs[3]; got != int64(200) {
		t.Errorf("dailyLimit = %v, want 200 (not a new account)", got)
	}
	if dir.forgetCalled != 1 {
		t.Errorf("Forget calls = %d, want 1 (cache invalidation after a real write)", dir.forgetCalled)
	}
}

func TestFollow_NewAccountUsesLowerQuota(t *testing.T) {
	repo := newFakeRepo()
	repo.followOutcome = OutcomeCreated
	now := time.Now()
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		"uid-1": activeProfile("uid-1", now.Add(-1*time.Hour)), // < 24h old
		"uid-2": activeProfile("uid-2", now.Add(-72*time.Hour)),
	}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{FollowsPerDay: 200, NewAccountFollowsPerDay: 50, NewAccountWindow: 24 * time.Hour})

	if _, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2"); err != nil {
		t.Fatalf("Follow() error = %v", err)
	}
	if got := repo.lastFollowArgs[3]; got != int64(50) {
		t.Errorf("dailyLimit = %v, want 50 (new account)", got)
	}
}

func TestFollow_Replay_DoesNotForgetOrInvalidate(t *testing.T) {
	repo := newFakeRepo()
	repo.followResult = Relationship{UserID: "uid-2", FollowState: FollowStateFollowing}
	repo.followOutcome = OutcomeReplay
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		"uid-1": activeProfile("uid-1", time.Now()),
		"uid-2": activeProfile("uid-2", time.Now()),
	}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})

	rel, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2")
	if err != nil {
		t.Fatalf("Follow() error = %v", err)
	}
	if rel.FollowState != FollowStateFollowing {
		t.Errorf("FollowState = %v, want FOLLOWING", rel.FollowState)
	}
	if dir.forgetCalled != 0 {
		t.Error("expected a replay to skip cache invalidation (nothing changed)")
	}
}

func TestFollow_RepoErrors_MapToConnectErrors(t *testing.T) {
	tests := []struct {
		name       string
		repoErr    error
		wantCode   connect.Code
		wantReason commonv1.ErrorReason
	}{
		{"blocked by target", ErrNotFoundOrBlocked, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
		{"caller blocks target", ErrCallerBlocksTarget, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED},
		{"target private", ErrTargetPrivate, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED},
		{"limit reached", &LimitReachedError{Limit: "following"}, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.followErr = tt.repoErr
			dir := &fakeDirectory{profiles: map[string]identity.Profile{
				"uid-1": activeProfile("uid-1", time.Now()),
				"uid-2": activeProfile("uid-2", time.Now()),
			}}
			svc := newTestServiceWithDirectory(repo, dir, Deps{})
			_, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2")
			assertAPIErr(t, err, tt.wantCode, tt.wantReason)
		})
	}
}

func TestUnfollow_FeatureDisabled(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithRepo(repo, false)
	_, err := svc.Unfollow(context.Background(), "uid-1", validKey, "uid-2")
	assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
}

func TestUnfollow_Self_IsNoneWithoutRepoCall(t *testing.T) {
	repo := newFakeRepo()
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	rel, err := svc.Unfollow(context.Background(), "uid-1", validKey, "uid-1")
	if err != nil {
		t.Fatalf("Unfollow(self) error = %v", err)
	}
	if rel.FollowState != FollowStateNone {
		t.Errorf("FollowState = %v, want NONE", rel.FollowState)
	}
	if repo.unfollowCalls != 0 {
		t.Error("expected 0 repo calls for a self-unfollow")
	}
}

func TestUnfollow_Success_InvalidatesCacheAndForgets(t *testing.T) {
	repo := newFakeRepo()
	repo.unfollowChanged = true
	dir := &fakeDirectory{}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})

	rel, err := svc.Unfollow(context.Background(), "uid-1", validKey, "uid-2")
	if err != nil {
		t.Fatalf("Unfollow() error = %v", err)
	}
	if rel.FollowState != FollowStateNone {
		t.Errorf("FollowState = %v, want NONE", rel.FollowState)
	}
	if dir.forgetCalled != 1 {
		t.Errorf("Forget calls = %d, want 1", dir.forgetCalled)
	}
}

func TestUnfollow_Noop_SkipsForget(t *testing.T) {
	repo := newFakeRepo()
	repo.unfollowChanged = false
	dir := &fakeDirectory{}
	svc := newTestServiceWithDirectory(repo, dir, Deps{})

	if _, err := svc.Unfollow(context.Background(), "uid-1", validKey, "uid-2"); err != nil {
		t.Fatalf("Unfollow() error = %v", err)
	}
	if dir.forgetCalled != 0 {
		t.Error("expected a no-op unfollow to skip cache invalidation")
	}
}

type recordingFollowEvents struct {
	calls []struct{ follower, followee string }
}

func (r *recordingFollowEvents) Followed(_ context.Context, follower, followee string, _ time.Time) {
	r.calls = append(r.calls, struct{ follower, followee string }{follower, followee})
}

// TestFollow_EventsHook (ADR-0017 D2): a created edge reports Followed exactly once; replays and no-ops never do.
func TestFollow_EventsHook(t *testing.T) {
	tests := []struct {
		name    string
		outcome MutationOutcome
		want    int
	}{
		{"created", OutcomeCreated, 1},
		{"replay", OutcomeReplay, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.followOutcome = tt.outcome
			dir := &fakeDirectory{profiles: map[string]identity.Profile{
				"uid-1": activeProfile("uid-1", time.Now()), "uid-2": activeProfile("uid-2", time.Now()),
			}}
			ev := &recordingFollowEvents{}
			svc := newTestServiceWithDirectory(repo, dir, Deps{Events: ev})
			if _, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2"); err != nil {
				t.Fatal(err)
			}
			if len(ev.calls) != tt.want || (tt.want == 1 && ev.calls[0].follower != "uid-1" || tt.want == 1 && ev.calls[0].followee != "uid-2") {
				t.Errorf("Followed calls = %+v, want %d", ev.calls, tt.want)
			}
		})
	}
	t.Run("nil Events keeps the no-op", func(t *testing.T) {
		repo := newFakeRepo()
		repo.followOutcome = OutcomeCreated
		dir := &fakeDirectory{profiles: map[string]identity.Profile{
			"uid-1": activeProfile("uid-1", time.Now()), "uid-2": activeProfile("uid-2", time.Now()),
		}}
		svc := newTestServiceWithDirectory(repo, dir, Deps{})
		if _, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2"); err != nil {
			t.Fatal(err)
		}
	})
}
