package graph

import (
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

type stagedFollow struct {
	day, shardKey string
	d             identity.DailyDelta
}

type recStats struct{ calls []stagedFollow }

func (r *recStats) StageDaily(_ store.Batch, uid, day, shardKey string, d identity.DailyDelta) {
	if uid != "followee" {
		panic("unexpected uid " + uid)
	}
	r.calls = append(r.calls, stagedFollow{day, shardKey, d})
}

func (r *recStats) Off() bool { return false }

// TestStageFollowers: gained and lost reach the followee's stats on the day of the passed clock (IST), sharded by the
// actor; a zero change and an unwired repo stage nothing.
func TestStageFollowers(t *testing.T) {
	now := time.Date(2026, 11, 15, 18, 31, 0, 0, time.UTC) // the 16th in IST
	st := &recStats{}
	r := NewFirestoreRepo(nil)
	r.stageFollowers(&fakeBatch{}, "followee", "a", now, 1, 0) // not wired yet
	r.SetStats(st)
	r.stageFollowers(&fakeBatch{}, "followee", "a", now, 1, 0)        // follow / accept
	r.stageFollowers(&fakeBatch{}, "followee", "a", now, 0, 1)        // unfollow / block
	r.stageFollowers(&fakeBatch{}, "followee", "followee", now, 3, 0) // going public approves 3 requests
	r.stageFollowers(&fakeBatch{}, "followee", "b", now, 0, 0)        // a block that removed no follower
	want := []stagedFollow{
		{"20261116", "a", identity.DailyDelta{FollowersGained: 1}},
		{"20261116", "a", identity.DailyDelta{FollowersLost: 1}},
		{"20261116", "followee", identity.DailyDelta{FollowersGained: 3}},
	}
	if !reflect.DeepEqual(st.calls, want) {
		t.Fatalf("calls = %+v, want %+v", st.calls, want)
	}
}
