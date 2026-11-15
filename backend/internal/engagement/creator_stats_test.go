package engagement

import (
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

type stagedStat struct {
	uid, day, shardKey string
	d                  identity.DailyDelta
}

type recStats struct{ calls []stagedStat }

func (r *recStats) StageDaily(_ store.Batch, uid, day, shardKey string, d identity.DailyDelta) {
	r.calls = append(r.calls, stagedStat{uid, day, shardKey, d})
}

func (r *recStats) Off() bool { return false }

// hotAt is a posts.EngagementWriter whose Hot answers known >= threshold (only Hot is called here).
type hotAt struct {
	posts.EngagementWriter
	threshold int64
}

func (h hotAt) Hot(known int64) bool { return h.threshold > 0 && known >= h.threshold }

// TestStageEngagementStat: a like or repost received stages +1 (an undo -1) on the post author's doc for today on the
// cold path only (a hot write's engagement is staged by the counter rollup), never for the author's own engagement or
// an unknown author.
func TestStageEngagementStat(t *testing.T) {
	now := time.Date(2026, 11, 15, 18, 45, 0, 0, time.UTC) // the 16th in IST
	st := &recStats{}
	r := &FirestoreRepo{now: func() time.Time { return now }, w: WriteDeps{Writer: hotAt{threshold: 100}, Stats: st}}
	r.stageEngagementStat(nil, "author", "liker", 1, 5)   // cold like
	r.stageEngagementStat(nil, "author", "liker", -1, 0)  // undo (cold)
	r.stageEngagementStat(nil, "author", "liker", 1, 100) // hot: the rollup stages it
	r.stageEngagementStat(nil, "author", "author", 1, 0)  // own like
	r.stageEngagementStat(nil, "", "liker", 1, 0)         // post not found
	want := []stagedStat{
		{"author", "20261116", "liker", identity.DailyDelta{Engagements: 1}},
		{"author", "20261116", "liker", identity.DailyDelta{Engagements: -1}},
	}
	if !reflect.DeepEqual(st.calls, want) {
		t.Fatalf("calls = %+v, want %+v", st.calls, want)
	}
	r.w.Stats = nil
	r.stageEngagementStat(nil, "author", "liker", 1, 0) // not wired: nothing, no panic
}
