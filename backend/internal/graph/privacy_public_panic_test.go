package graph

import (
	"context"
	"testing"
	"time"
)

type panicEvents struct{ acceptEvents }

func (*panicEvents) FollowRequestAccepted(context.Context, string, string, time.Time) { panic("boom") }

// The emit is best effort and runs on an errgroup goroutine, outside every recover of the job's route. A panic in it loses
// that notification, as a failed emit does, and must not end the instance after the page has committed.
func TestPrivacyPublicJob_PanicInEmitDoesNotEndTheProcess(t *testing.T) {
	p := &fakePager{pages: []PendingPageResult{{Scanned: 1, Accepted: []string{"a"}}}}
	if _, err := newJob(p, &panicEvents{}).Run(context.Background(), "uid-p"); err != nil {
		t.Fatalf("Run = %v: the page committed, so the job goes on", err)
	}
}
