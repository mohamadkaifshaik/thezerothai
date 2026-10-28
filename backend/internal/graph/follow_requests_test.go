package graph

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func requestsTestService(repo *fakeRepo, ev FollowEvents) (*service, *fakeDirectory) {
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		"uid-1": activeProfile("uid-1", time.Now().Add(-72*time.Hour)),
		"uid-2": activeProfile("uid-2", time.Now().Add(-72*time.Hour)),
	}}
	return newTestServiceWithDirectory(repo, dir, Deps{Events: ev, FollowsPerDay: 200, NewAccountFollowsPerDay: 50, NewAccountWindow: time.Hour}), dir
}

// A created request reports FollowRequested and never Followed, and does not move any counter (no directory Forget).
func TestFollow_Request_EventsAndCaches(t *testing.T) {
	tests := []struct {
		name         string
		outcome      MutationOutcome
		state        FollowState
		wantFollowed int
		wantRequests int
		wantForget   int
		wantOutcome  string
	}{
		{"request created", OutcomeCreated, FollowStateRequested, 0, 1, 0, "requested"},
		{"request replay", OutcomeReplay, FollowStateRequested, 0, 0, 0, "replay"},
		{"edge created", OutcomeCreated, FollowStateFollowing, 1, 0, 1, "edge"},
		{"edge replay", OutcomeReplay, FollowStateFollowing, 0, 0, 0, "replay"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.followOutcome = tt.outcome
			repo.followResult = Relationship{UserID: "uid-2", FollowState: tt.state}
			ev := &recordingFollowEvents{}
			svc, dir := requestsTestService(repo, ev)
			ctx, info := obsCtx()
			rel, err := svc.Follow(ctx, "uid-1", validKey, "uid-2")
			if err != nil {
				t.Fatal(err)
			}
			if rel.FollowState != tt.state {
				t.Errorf("FollowState = %v, want %v", rel.FollowState, tt.state)
			}
			if len(ev.calls) != tt.wantFollowed || len(ev.requests) != tt.wantRequests {
				t.Errorf("Followed=%d FollowRequested=%d, want %d and %d", len(ev.calls), len(ev.requests), tt.wantFollowed, tt.wantRequests)
			}
			if tt.wantRequests == 1 && (ev.requests[0].requester != "uid-1" || ev.requests[0].target != "uid-2") {
				t.Errorf("FollowRequested = %+v, want uid-1 -> uid-2", ev.requests[0])
			}
			if dir.forgetCalled != tt.wantForget {
				t.Errorf("Forget calls = %d, want %d", dir.forgetCalled, tt.wantForget)
			}
			if got := field(info, "follow_outcome"); got != tt.wantOutcome {
				t.Errorf("follow_outcome = %v, want %q", got, tt.wantOutcome)
			}
			if field(info, "target_uid_hash") == nil {
				t.Error("target_uid_hash (the D6 contention signal) was not logged")
			}
		})
	}
}

// Follow reads only the caller through the Directory: the target's existence and protection come from the transaction.
func TestFollow_ReadsOnlyCallerFromDirectory(t *testing.T) {
	repo := newFakeRepo()
	repo.followOutcome = OutcomeCreated
	dir := &askedDirectory{fakeDirectory: fakeDirectory{profiles: map[string]identity.Profile{
		"uid-1": activeProfile("uid-1", time.Now().Add(-72*time.Hour)),
	}}}
	svc := newTestServiceWithDirectory(repo, dir, Deps{FollowsPerDay: 200, NewAccountWindow: time.Hour})
	if _, err := svc.Follow(context.Background(), "uid-1", validKey, "ghost-target"); err != nil {
		t.Fatal(err)
	}
	if len(dir.asked) != 1 || len(dir.asked[0]) != 1 || dir.asked[0][0] != "uid-1" {
		t.Errorf("Directory.GetProfiles asked %v, want exactly [[uid-1]]", dir.asked)
	}
}

type askedDirectory struct {
	fakeDirectory
	asked [][]string
}

func (c *askedDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	c.asked = append(c.asked, append([]string(nil), uids...))
	return c.fakeDirectory.GetProfiles(ctx, uids)
}

func TestFollow_RequestedCapIsLimitReached(t *testing.T) {
	repo := newFakeRepo()
	repo.followErr = &LimitReachedError{Limit: "follow_requests"}
	svc, _ := requestsTestService(repo, nil)
	_, err := svc.Follow(context.Background(), "uid-1", validKey, "uid-2")
	assertAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
}

// Withdraw (ADR-0025 D7): the second batch runs only when the edge batch found nothing, and undo is never gated beyond
// the module flag.
func TestUnfollow_Withdraw(t *testing.T) {
	tests := []struct {
		name         string
		edge         bool
		withdrawn    bool
		wantWithdraw int
		wantForget   int
		wantLog      any
		wantOutcome  string
	}{
		{"edge removed, no second batch", true, false, 0, 1, nil, "created"},
		{"request withdrawn", false, true, 1, 0, "request", "created"},
		{"nothing to withdraw", false, false, 1, 0, "none", "noop"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.unfollowChanged = tt.edge
			repo.withdrawChanged = tt.withdrawn
			svc, dir := requestsTestService(repo, nil)
			svc.cache.Set("uid-1", Snapshot{Requested: map[string]bool{"uid-2": true}})
			ctx, info := obsCtx()
			rel, err := svc.Unfollow(ctx, "uid-1", validKey, "uid-2")
			if err != nil {
				t.Fatal(err)
			}
			if rel.FollowState != FollowStateNone {
				t.Errorf("FollowState = %v, want NONE", rel.FollowState)
			}
			if repo.withdrawCalls != tt.wantWithdraw {
				t.Errorf("withdrawCalls = %d, want %d", repo.withdrawCalls, tt.wantWithdraw)
			}
			if dir.forgetCalled != tt.wantForget {
				t.Errorf("Forget calls = %d, want %d (a withdraw moves no counter)", dir.forgetCalled, tt.wantForget)
			}
			if got := field(info, "withdraw"); got != tt.wantLog {
				t.Errorf("withdraw log = %v, want %v", got, tt.wantLog)
			}
			if got := field(info, "outcome"); got != tt.wantOutcome {
				t.Errorf("outcome = %v, want %q", got, tt.wantOutcome)
			}
			_, cached := svc.cache.Get("uid-1")
			if wantDropped := tt.edge || tt.withdrawn; cached == wantDropped {
				t.Errorf("caller snapshot still cached = %v, want dropped = %v", cached, wantDropped)
			}
		})
	}
}

func TestUnfollow_WithdrawErrorsMap(t *testing.T) {
	repo := newFakeRepo()
	repo.withdrawErr = ErrContention
	svc, _ := requestsTestService(repo, nil)
	_, err := svc.Unfollow(context.Background(), "uid-1", validKey, "uid-2")
	assertAPIErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)

	repo.withdrawErr = errors.New("boom")
	_, err = svc.Unfollow(context.Background(), "uid-1", validKey, "uid-2")
	if err == nil {
		t.Fatal("want an error")
	}
}

// REQUESTED comes from the caller's own Snapshot at 0 reads, and an edge always wins (I-X).
func TestRelationshipFor_Requested(t *testing.T) {
	tests := []struct {
		name string
		snap Snapshot
		want FollowState
	}{
		{"requested", Snapshot{Requested: map[string]bool{"t": true}}, FollowStateRequested},
		{"following wins over a drifted request", Snapshot{Following: map[string]bool{"t": true}, Requested: map[string]bool{"t": true}}, FollowStateFollowing},
		{"neither", Snapshot{}, FollowStateNone},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := relationshipFor(tt.snap, "t").FollowState; got != tt.want {
				t.Errorf("FollowState = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestFollowStateOf_Requested(t *testing.T) {
	if got := followStateOf(doc{Requested: []string{"t"}}, "t"); got != FollowStateRequested {
		t.Errorf("followStateOf = %v, want REQUESTED", got)
	}
	if got := followStateOf(doc{Following: []string{"t"}, Requested: []string{"t"}}, "t"); got != FollowStateFollowing {
		t.Errorf("followStateOf = %v, want FOLLOWING", got)
	}
}

func TestFirestoreRepo_FollowWithoutTxProfilesErrors(t *testing.T) {
	r := &FirestoreRepo{}
	if _, _, err := r.Follow(context.Background(), "a", "b", 10, time.Now()); err == nil {
		t.Fatal("Follow without TxProfiles wired must return an error, not panic")
	}
}
