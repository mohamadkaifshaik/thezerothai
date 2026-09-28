package graph

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

type mutationCall func(s *service, ctx context.Context, caller, key, target string) (Relationship, error)

var mutationCalls = map[string]mutationCall{
	"Block": func(s *service, ctx context.Context, c, k, t string) (Relationship, error) {
		return s.Block(ctx, c, k, t)
	},
	"Unblock": func(s *service, ctx context.Context, c, k, t string) (Relationship, error) {
		return s.Unblock(ctx, c, k, t)
	},
	"Mute": func(s *service, ctx context.Context, c, k, t string) (Relationship, error) {
		return s.Mute(ctx, c, k, t)
	},
	"Unmute": func(s *service, ctx context.Context, c, k, t string) (Relationship, error) {
		return s.Unmute(ctx, c, k, t)
	},
}

func TestBlockMute_Validation(t *testing.T) {
	tests := []struct {
		name   string
		key    string
		target string
		wantOK bool // self Unblock/Unmute are no-ops, not errors
		ops    []string
	}{
		{"bad key", "short", "uid-2", false, []string{"Block", "Unblock", "Mute", "Unmute"}},
		{"bad target", validKey, "bad id!", false, []string{"Block", "Unblock", "Mute", "Unmute"}},
		{"self block/mute", validKey, "uid-1", false, []string{"Block", "Mute"}},
		{"self unblock/unmute is a no-op", validKey, "uid-1", true, []string{"Unblock", "Unmute"}},
	}
	for _, tt := range tests {
		for _, op := range tt.ops {
			t.Run(tt.name+"/"+op, func(t *testing.T) {
				repo := newFakeRepo()
				svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
				_, err := mutationCalls[op](svc, context.Background(), "uid-1", tt.key, tt.target)
				if tt.wantOK {
					if err != nil {
						t.Fatalf("error = %v, want nil", err)
					}
				} else {
					assertAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
				}
				if n := repo.blockCalls + repo.unblockCalls + repo.muteCalls + repo.unmuteCalls; n != 0 {
					t.Errorf("repo calls = %d, want 0", n)
				}
			})
		}
	}
}

func TestBlock_Outcomes(t *testing.T) {
	tests := []struct {
		name       string
		result     BlockResult
		repoErr    error
		wantErr    bool
		wantCode   connect.Code
		wantReason commonv1.ErrorReason
		wantForget int
	}{
		{name: "created invalidates caches", result: BlockResult{Outcome: OutcomeCreated, Relationship: Relationship{UserID: "uid-2", Blocking: true}}, wantForget: 1},
		{name: "replay leaves caches", result: BlockResult{Outcome: OutcomeReplay, Relationship: Relationship{UserID: "uid-2", Blocking: true}}},
		{name: "overflow hit still succeeds", result: BlockResult{Outcome: OutcomeCreated, BlockedByOverflowHit: true, Relationship: Relationship{UserID: "uid-2", Blocking: true}}, wantForget: 1},
		{name: "unknown target", repoErr: ErrNotFoundOrBlocked, wantErr: true, wantCode: connect.CodeNotFound, wantReason: commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
		{name: "cap", repoErr: &LimitReachedError{Limit: "blocked"}, wantErr: true, wantCode: connect.CodeFailedPrecondition, wantReason: commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.blockResult, repo.blockErr = tt.result, tt.repoErr
			dir := &fakeDirectory{}
			svc := newTestServiceWithDirectory(repo, dir, Deps{})
			rel, err := svc.Block(context.Background(), "uid-1", validKey, "uid-2")
			if tt.wantErr {
				assertAPIErr(t, err, tt.wantCode, tt.wantReason)
				return
			}
			if err != nil {
				t.Fatalf("Block() error = %v", err)
			}
			if !rel.Blocking {
				t.Error("Blocking = false, want true")
			}
			if dir.forgetCalled != tt.wantForget {
				t.Errorf("Forget calls = %d, want %d", dir.forgetCalled, tt.wantForget)
			}
		})
	}
}

func TestBlock_GenericErrorWrapped(t *testing.T) {
	repo := newFakeRepo()
	repo.blockErr = errors.New("boom")
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	if _, err := svc.Block(context.Background(), "uid-1", validKey, "uid-2"); err == nil {
		t.Fatal("expected error")
	}
}

func TestBlock_InvalidatesBothSnapshots(t *testing.T) {
	repo := newFakeRepo()
	repo.blockResult = BlockResult{Outcome: OutcomeCreated, Relationship: Relationship{UserID: "uid-2", Blocking: true}}
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	ctx := context.Background()
	_, _ = svc.Snapshot(ctx, "uid-1")
	_, _ = svc.Snapshot(ctx, "uid-2")
	if repo.calls != 2 {
		t.Fatalf("calls = %d, want 2", repo.calls)
	}
	if _, err := svc.Block(ctx, "uid-1", validKey, "uid-2"); err != nil {
		t.Fatal(err)
	}
	_, _ = svc.Snapshot(ctx, "uid-1")
	_, _ = svc.Snapshot(ctx, "uid-2")
	if repo.calls != 4 {
		t.Errorf("calls = %d, want 4 (both caches invalidated)", repo.calls)
	}
}

func TestUnblock_ChangedVsNoop(t *testing.T) {
	tests := []struct {
		name       string
		changed    bool
		wantForget int
	}{{"changed", true, 1}, {"noop", false, 0}}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.unblockChanged = tt.changed
			repo.unblockRel = Relationship{UserID: "uid-2", FollowState: FollowStateNone}
			dir := &fakeDirectory{}
			svc := newTestServiceWithDirectory(repo, dir, Deps{})
			rel, err := svc.Unblock(context.Background(), "uid-1", validKey, "uid-2")
			if err != nil || rel.Blocking {
				t.Fatalf("Unblock() = %+v, %v", rel, err)
			}
			if dir.forgetCalled != tt.wantForget {
				t.Errorf("Forget calls = %d, want %d", dir.forgetCalled, tt.wantForget)
			}
		})
	}
}

func TestUnblock_RepoError(t *testing.T) {
	repo := newFakeRepo()
	repo.unblockErr = errors.New("boom")
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	if _, err := svc.Unblock(context.Background(), "uid-1", validKey, "uid-2"); err == nil {
		t.Fatal("expected error")
	}
}

func TestMute_Outcomes(t *testing.T) {
	tests := []struct {
		name    string
		outcome MutationOutcome
		err     error
		wantErr bool
	}{
		{"created", OutcomeCreated, nil, false},
		{"replay", OutcomeReplay, nil, false},
		{"cap", "", &LimitReachedError{Limit: "muted"}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.muteOutcome, repo.muteErr = tt.outcome, tt.err
			repo.muteResult = Relationship{UserID: "uid-2", Muting: true}
			svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
			rel, err := svc.Mute(context.Background(), "uid-1", validKey, "uid-2")
			if tt.wantErr {
				assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
				return
			}
			if err != nil || !rel.Muting {
				t.Fatalf("Mute() = %+v, %v", rel, err)
			}
		})
	}
}

func TestMute_GenericErrorWrapped(t *testing.T) {
	repo := newFakeRepo()
	repo.muteErr = errors.New("boom")
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	if _, err := svc.Mute(context.Background(), "uid-1", validKey, "uid-2"); err == nil {
		t.Fatal("expected error")
	}
}

func TestUnmute_ChangedAndError(t *testing.T) {
	repo := newFakeRepo()
	repo.unmuteChanged = true
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{}, Deps{})
	if _, err := svc.Unmute(context.Background(), "uid-1", validKey, "uid-2"); err != nil {
		t.Fatal(err)
	}
	repo.unmuteErr = errors.New("boom")
	if _, err := svc.Unmute(context.Background(), "uid-1", validKey, "uid-2"); err == nil {
		t.Fatal("expected error")
	}
}

func TestResolvedDailyLimit(t *testing.T) {
	now := time.Now()
	tests := []struct {
		name      string
		createdAt time.Time
		want      int64
	}{
		{"new account", now.Add(-time.Hour), 50},
		{"old account", now.Add(-48 * time.Hour), 200},
		{"zero createdAt", time.Time{}, 200},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := resolvedDailyLimit(tt.createdAt, now, 24*time.Hour, 200, 50); got != tt.want {
				t.Errorf("got %d, want %d", got, tt.want)
			}
		})
	}
}
