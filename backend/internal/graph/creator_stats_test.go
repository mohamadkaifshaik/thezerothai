package graph

import (
	"reflect"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

type recStats struct{ calls []identity.DailyDelta }

func (r *recStats) StageDaily(_ store.Batch, uid, day string, d identity.DailyDelta) {
	if uid != "followee" || len(day) != 8 {
		panic("unexpected uid or day " + uid + " " + day)
	}
	r.calls = append(r.calls, d)
}

// TestStageFollowers: gained and lost reach the followee's stats; a zero change and an unwired repo stage nothing.
func TestStageFollowers(t *testing.T) {
	st := &recStats{}
	r := NewFirestoreRepo(nil)
	r.stageFollowers(&fakeBatch{}, "followee", 1, 0) // not wired yet
	r.SetStats(st)
	r.stageFollowers(&fakeBatch{}, "followee", 1, 0) // follow / accept
	r.stageFollowers(&fakeBatch{}, "followee", 0, 1) // unfollow / block
	r.stageFollowers(&fakeBatch{}, "followee", 3, 0) // going public approves 3 requests
	r.stageFollowers(&fakeBatch{}, "followee", 0, 0) // a block that removed no follower
	want := []identity.DailyDelta{{FollowersGained: 1}, {FollowersLost: 1}, {FollowersGained: 3}}
	if !reflect.DeepEqual(st.calls, want) {
		t.Fatalf("calls = %+v, want %+v", st.calls, want)
	}
}
