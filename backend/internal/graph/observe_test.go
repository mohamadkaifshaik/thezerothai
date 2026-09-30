package graph

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func obsCtx() (context.Context, *logger.RequestInfo) {
	return logger.WithRequestInfo(context.Background())
}

func field(info *logger.RequestInfo, key string) any {
	v, _ := info.Get(key)
	return v
}

func TestGraphLogFields_Mutations(t *testing.T) {
	now := time.Now()
	profiles := map[string]identity.Profile{
		"uid-1": activeProfile("uid-1", now.Add(-72*time.Hour)),
		"uid-2": activeProfile("uid-2", now.Add(-72*time.Hour)),
	}
	deps := Deps{FollowsPerDay: 200, NewAccountFollowsPerDay: 50, NewAccountWindow: time.Hour}

	follow := func(key string) func(*service, context.Context) error {
		return func(s *service, ctx context.Context) error {
			_, err := s.Follow(ctx, "uid-1", key, "uid-2")
			return err
		}
	}
	unfollow := func(s *service, ctx context.Context) error {
		_, err := s.Unfollow(ctx, "uid-1", validKey, "uid-2")
		return err
	}
	block := func(s *service, ctx context.Context) error {
		_, err := s.Block(ctx, "uid-1", validKey, "uid-2")
		return err
	}
	unblock := func(s *service, ctx context.Context) error {
		_, err := s.Unblock(ctx, "uid-1", validKey, "uid-2")
		return err
	}
	mute := func(target string) func(*service, context.Context) error {
		return func(s *service, ctx context.Context) error {
			_, err := s.Mute(ctx, "uid-1", validKey, target)
			return err
		}
	}
	unmute := func(s *service, ctx context.Context) error {
		_, err := s.Unmute(ctx, "uid-1", validKey, "uid-2")
		return err
	}

	tests := []struct {
		name        string
		setup       func(r *fakeRepo)
		call        func(s *service, ctx context.Context) error
		wantOp      string
		wantOutcome any
		wantEdges   any
	}{
		{"follow created", func(r *fakeRepo) { r.followOutcome = OutcomeCreated }, follow(validKey), "follow", "created", nil},
		{"follow replay", func(r *fakeRepo) { r.followOutcome = OutcomeReplay }, follow(validKey), "follow", "replay", nil},
		{"follow limit", func(r *fakeRepo) { r.followErr = &LimitReachedError{Limit: "following"} }, follow(validKey), "follow", "rejected:limit_reached", nil},
		{"follow target blocked", func(r *fakeRepo) { r.followErr = ErrCallerBlocksTarget }, follow(validKey), "follow", "rejected:target_blocked", nil},
		{"follow not found", func(r *fakeRepo) { r.followErr = ErrNotFoundOrBlocked }, follow(validKey), "follow", "rejected:not_found", nil},
		{"follow contention", func(r *fakeRepo) { r.followErr = ErrContention }, follow(validKey), "follow", "rejected:contention", nil},
		{"follow invalid", nil, follow("bad"), "follow", "rejected:invalid", nil},
		{"follow internal", func(r *fakeRepo) { r.followErr = context.DeadlineExceeded }, follow(validKey), "follow", "rejected:error", nil},
		{"unfollow changed", func(r *fakeRepo) { r.unfollowChanged = true }, unfollow, "unfollow", "created", nil},
		{"unfollow noop", nil, unfollow, "unfollow", "noop", nil},
		{"block with edges", func(r *fakeRepo) {
			r.blockResult = BlockResult{Outcome: OutcomeCreated, CallerWasFollowing: true, TargetWasFollowing: true}
		}, block, "block", "created", int64(2)},
		{"block replay", func(r *fakeRepo) { r.blockResult = BlockResult{Outcome: OutcomeReplay} }, block, "block", "replay", int64(0)},
		{"unblock changed", func(r *fakeRepo) { r.unblockChanged = true }, unblock, "unblock", "created", nil},
		{"mute created", func(r *fakeRepo) { r.muteOutcome = OutcomeCreated }, mute("uid-2"), "mute", "created", nil},
		{"unmute noop", nil, unmute, "unmute", "noop", nil},
		{"self mute rejected", nil, mute("uid-1"), "mute", "rejected:invalid", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepo()
			if tt.setup != nil {
				tt.setup(repo)
			}
			svc := newTestServiceWithDirectory(repo, &fakeDirectory{profiles: profiles}, deps)
			ctx, info := obsCtx()
			_ = tt.call(svc, ctx)
			if got := field(info, "graph_op"); got != tt.wantOp {
				t.Errorf("graph_op = %v, want %s", got, tt.wantOp)
			}
			if got := field(info, "outcome"); got != tt.wantOutcome {
				t.Errorf("outcome = %v, want %v", got, tt.wantOutcome)
			}
			if got := field(info, "edges_removed"); got != tt.wantEdges {
				t.Errorf("edges_removed = %v, want %v", got, tt.wantEdges)
			}
		})
	}
}

func TestGraphLogFields_FeatureDisabled(t *testing.T) {
	svc := newTestServiceWithRepo(newFakeRepo(), false)
	ctx, info := obsCtx()
	if _, err := svc.GetRelationships(ctx, "uid-1", []string{"uid-2"}); err == nil {
		t.Fatal("expected error")
	}
	if got := field(info, "outcome"); got != "rejected:feature_disabled" {
		t.Errorf("outcome = %v", got)
	}
	if got := field(info, "feature_disabled"); got != true {
		t.Errorf("feature_disabled = %v, want true", got)
	}
}

func TestGraphLogFields_ReadOpsAndCacheHit(t *testing.T) {
	repo := newFakeRepo()
	repo.snapshots["uid-1"] = Snapshot{}
	svc := newTestServiceWithDirectory(repo, &fakeDirectory{profiles: map[string]identity.Profile{}}, Deps{})

	cold, coldInfo := obsCtx()
	if _, err := svc.GetRelationships(cold, "uid-1", []string{"uid-2"}); err != nil {
		t.Fatal(err)
	}
	if got := field(coldInfo, "graph_op"); got != "get_relationships" {
		t.Errorf("graph_op = %v", got)
	}
	if got := field(coldInfo, "graph_cache_hit"); got != false {
		t.Errorf("cold graph_cache_hit = %v, want false", got)
	}
	if got := field(coldInfo, "outcome"); got != nil {
		t.Errorf("read RPC set outcome = %v", got)
	}

	warm, warmInfo := obsCtx()
	if _, err := svc.GetRelationships(warm, "uid-1", []string{"uid-2"}); err != nil {
		t.Fatal(err)
	}
	if got := field(warmInfo, "graph_cache_hit"); got != true {
		t.Errorf("warm graph_cache_hit = %v, want true", got)
	}

	// A miss anywhere in the request sticks: false means the request paid a read.
	mixed, mixedInfo := obsCtx()
	noteCacheHit(mixed, false)
	noteCacheHit(mixed, true)
	if got := field(mixedInfo, "graph_cache_hit"); got != false {
		t.Errorf("mixed graph_cache_hit = %v, want false", got)
	}

	for _, op := range []struct {
		name string
		call func(ctx context.Context)
	}{
		{"list_blocked", func(ctx context.Context) { _, _ = svc.ListBlockedUsers(ctx, "uid-1", 10, "") }},
		{"list_muted", func(ctx context.Context) { _, _ = svc.ListMutedUsers(ctx, "uid-1", 10, "") }},
		{"list_followers", func(ctx context.Context) { _, _ = svc.ListFollowers(ctx, "uid-1", "uid-2", 10, "") }},
		{"list_following", func(ctx context.Context) { _, _ = svc.ListFollowing(ctx, "uid-1", "uid-2", 10, "") }},
	} {
		ctx, info := obsCtx()
		op.call(ctx)
		if got := field(info, "graph_op"); got != op.name {
			t.Errorf("graph_op = %v, want %s", got, op.name)
		}
	}
}

func TestGraphLogFields_Purge(t *testing.T) {
	svc := newTestServiceWithRepo(newFakeRepo(), true)
	ctx, info := obsCtx()
	_, _, _ = svc.PurgeUser(ctx, "uid-1", Checkpoint{})
	if got := field(info, "graph_op"); got != "purge" {
		t.Errorf("graph_op = %v, want purge", got)
	}
}

func TestNoteTxnAttempts_WarnsAboveThreshold(t *testing.T) {
	tests := []struct {
		attempts int
		wantWarn bool
	}{{1, false}, {3, false}, {4, true}, {6, true}}
	for _, tt := range tests {
		var buf bytes.Buffer
		prev := slog.Default()
		slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
		ctx, info := obsCtx()
		noteTxnAttempts(ctx, tt.attempts)
		slog.SetDefault(prev)

		if got := field(info, "txn_attempts"); got != int64(tt.attempts) {
			t.Errorf("txn_attempts = %v, want %d", got, tt.attempts)
		}
		if warned := strings.Contains(buf.String(), `"level":"WARN"`); warned != tt.wantWarn {
			t.Errorf("attempts=%d warned=%v want %v (%s)", tt.attempts, warned, tt.wantWarn, buf.String())
		}
		if strings.Contains(buf.String(), "uid") {
			t.Errorf("WARN line must not carry uids: %s", buf.String())
		}
	}
}

func TestLogFields_NoContextInfoIsNoop(t *testing.T) {
	// Background jobs and unit tests have no RequestInfo; helpers must not panic.
	noteTxnAttempts(context.Background(), 1)
	noteCacheHit(context.Background(), true)
	setOutcome(context.Background(), OutcomeNoop)
}
