//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Concurrent SchedulePost calls and the per-author window cap (ADR-0021 D4, pending.md 2.16). The window cap must hold
// exactly: concurrent schedules by one user conflict on quotas/{uid}, so a retried loser sees the winner's committed
// document. A cap that only counts outside the transaction lets every concurrent first call through.

// scheduleOutcome classifies the error of one concurrent Schedule call.
type scheduleOutcome string

const (
	outcomeOK             scheduleOutcome = "ok"
	outcomeWindowRejected scheduleOutcome = "window_rejected"
	// outcomeUnknown is a transaction the client gave up on (ABORTED after its retries, the 5 s deadline, UNAVAILABLE).
	// A commit that timed out on the client can still have landed on the server, so the outcome is not known.
	outcomeUnknown scheduleOutcome = "unknown"
	outcomeOther   scheduleOutcome = "other"
)

func classifySchedule(err error) scheduleOutcome {
	if err == nil {
		return outcomeOK
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		if ae.Reason == commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED && ae.Metadata["limit"] == limitScheduledWindow {
			return outcomeWindowRejected
		}
		return outcomeOther
	}
	switch status.Code(err) {
	case codes.Aborted, codes.DeadlineExceeded, codes.Unavailable:
		return outcomeUnknown
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return outcomeUnknown
	}
	return outcomeOther
}

// TestSchedulerIT_ConcurrentWindowCap: 10 simultaneous SchedulePost calls of ONE user for the SAME minute with distinct
// idempotency keys leave at most WindowCap (3) items in that window, however the calls interleave. Losers may answer
// LIMIT_REACHED(scheduled_window) or a retryable transaction error after the client's own retries; no outcome may
// exceed the cap. Both a user with no quotas document yet (the first quota'd call of an account) and one with a
// document today are covered, because the serialisation point is quotas/{uid}.
func TestSchedulerIT_ConcurrentWindowCap(t *testing.T) {
	const (
		callers   = 10 // the CreatePost-shared bucket's burst
		windowCap = 3  // defaultScheduleLimits().WindowCap
	)
	for _, tc := range []struct {
		name      string
		seedQuota bool
	}{
		{"no quotas document yet", false},
		{"quotas document exists", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newSchedSvcIT(t)
			if got := e.svc.schedule.WindowCap; got != windowCap {
				t.Fatalf("WindowCap = %d, the test assumes %d", got, windowCap)
			}
			if tc.seedQuota {
				if _, err := e.client.Collection("quotas").Doc("alice").Set(context.Background(), quota.Record{Day: quota.Today()}); err != nil {
					t.Fatal(err)
				}
			}
			target := e.clock.Add(2 * time.Hour)

			var (
				ready, done sync.WaitGroup
				mu          sync.Mutex
				outcomes    = map[scheduleOutcome]int{}
				unknownBy   = map[string]int{} // the gRPC code of each unknown outcome, for the log
				otherErrs   []string
			)
			start := make(chan struct{}) // released together so the calls overlap
			for n := 1; n <= callers; n++ {
				ready.Add(1)
				done.Add(1)
				go func() {
					defer done.Done()
					in := e.in(n, func(i *ScheduleInput) { i.PublishAt = target })
					ctx, _ := e.ctx("alice")
					ready.Done()
					<-start
					_, err := e.svc.Schedule(ctx, "alice", in)
					out := classifySchedule(err)
					mu.Lock()
					defer mu.Unlock()
					outcomes[out]++
					switch out {
					case outcomeOther:
						otherErrs = append(otherErrs, err.Error())
					case outcomeUnknown:
						unknownBy[status.Code(err).String()]++
					}
				}()
			}
			ready.Wait()
			close(start)
			done.Wait()

			docs, err := e.client.Collection("users").Doc("alice").Collection("scheduled").Documents(context.Background()).GetAll()
			if err != nil {
				t.Fatal(err)
			}
			stored := 0
			for _, d := range docs {
				if st, _ := d.DataAt("status"); st != string(ScheduledPending) {
					t.Errorf("stored item %s has status %v", d.Ref.ID, st)
				}
				at, _ := d.DataAt("publishAt")
				if when, ok := at.(time.Time); !ok || !when.Equal(target) {
					t.Errorf("stored item %s publishAt = %v, want %v", d.Ref.ID, at, target)
				}
				stored++
			}
			dist := make([]string, 0, len(outcomes))
			for k, v := range outcomes {
				dist = append(dist, fmt.Sprintf("%s=%d", k, v))
			}
			sort.Strings(dist)
			t.Logf("%d callers: outcomes [%s] unknown by code %v; stored items %d; quotas.schedules %d", callers, strings.Join(dist, " "), unknownBy, stored, e.schedules(t, "alice"))

			if len(otherErrs) > 0 {
				t.Errorf("unexpected errors (not a window rejection or a retryable transaction error): %v", otherErrs)
			}
			if stored > windowCap {
				t.Errorf("%d items hold the same minute, the window cap is %d", stored, windowCap)
			}
			ok, unknown := outcomes[outcomeOK], outcomes[outcomeUnknown]
			if ok < 1 {
				t.Errorf("no call succeeded (%d callers): the test proves nothing", callers)
			}
			if ok > windowCap {
				t.Errorf("%d calls succeeded, the window cap is %d", ok, windowCap)
			}
			// Every success stored an item; an item beyond the successes needs a call whose outcome the client could not see.
			if stored < ok || stored > ok+unknown {
				t.Errorf("stored items = %d with %d successes and %d unknown outcomes", stored, ok, unknown)
			}
			if got := e.schedules(t, "alice"); got != int64(stored) {
				t.Errorf("quotas.schedules = %d, want %d (one charge per stored item)", got, stored)
			}
		})
	}
}
