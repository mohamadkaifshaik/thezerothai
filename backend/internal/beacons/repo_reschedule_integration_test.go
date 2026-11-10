//go:build integration

package beacons

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// rescheduleEnv is one beacon organised by org with p1 and p2 ACCEPTED, r1 REQUESTED and d1 DECLINED.
type rescheduleEnv struct {
	*repoEnv
	b Beacon
}

func newRescheduleEnv(t *testing.T, org string) *rescheduleEnv {
	t.Helper()
	e := newRepoEnv(t)
	b := e.create(t, org, itKeyA, e.beaconAt(org, itCommunity, e.now.Add(2*time.Hour))).Beacon
	for _, u := range []string{"p1", "p2", "r1", "d1"} {
		e.mustRequest(t, u, "integration-key-rq-"+u, b.ID)
	}
	for _, u := range []string{"p1", "p2"} {
		if _, err := e.respond(org, "integration-key-ac-"+u, b.ID, u, true, e.now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.respond(org, "integration-key-dc-d1", b.ID, "d1", false, e.now); err != nil {
		t.Fatal(err)
	}
	return &rescheduleEnv{repoEnv: e, b: b}
}

func (e *rescheduleEnv) update(org, key string, p UpdateParams) (UpdateResult, error) {
	p.UID, p.BeaconID = org, e.b.ID
	p.IdemKey, p.RequestHash = idempotency.Key(org, rpcUpdateBeacon, key), idempotency.HashRequest(key)
	if p.Now.IsZero() {
		p.Now = e.now
	}
	return e.repo.Update(context.Background(), p)
}

func (e *rescheduleEnv) docTime(t *testing.T, path, field string) time.Time {
	t.Helper()
	s, err := e.client.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	v, err := s.DataAt(field)
	if err != nil {
		return time.Time{}
	}
	tm, _ := v.(time.Time)
	return tm
}

// TestRepo_RescheduleMovesEveryRow (F28): a new start rewrites the beacon's startAt, endAt and expireAt, every
// participant row's expireAt (every state), and every membership row's startAt and endAt, plus pendingUntil on the live
// request only; the accepted list comes back for the notice; a replay writes nothing more.
func TestRepo_RescheduleMovesEveryRow(t *testing.T) {
	e := newRescheduleEnv(t, "org-r1")
	newStart := e.now.Add(26 * time.Hour)
	dur := 90
	res, err := e.update("org-r1", "integration-key-rs01", UpdateParams{StartAt: &newStart, DurationMin: &dur, MaxEditRows: MaxEditRows})
	if err != nil || res.Outcome != Written || !res.Rescheduled {
		t.Fatalf("reschedule = %+v, %v", res, err)
	}
	accepted := append([]string(nil), res.Accepted...)
	sort.Strings(accepted)
	if fmt.Sprint(accepted) != "[p1 p2]" {
		t.Fatalf("accepted = %v, want [p1 p2]", accepted)
	}
	end := newStart.Add(90 * time.Minute)
	expire := newStart.Add(ExpireAfterStart)
	b, err := e.repo.Get(context.Background(), e.b.ID)
	if err != nil || !b.StartAt.Equal(newStart) || !b.EndAt.Equal(end) || !b.ExpireAt.Equal(expire) || b.DurationMin != 90 || b.AcceptedCount != 2 {
		t.Fatalf("beacon = %+v, %v", b, err)
	}
	for _, u := range []string{"p1", "p2", "r1", "d1"} {
		if got := e.docTime(t, "beacons/"+e.b.ID+"/beaconParticipants/"+u, "expireAt"); !got.Equal(expire) {
			t.Errorf("participant %s expireAt = %v, want %v", u, got, expire)
		}
	}
	for _, u := range []string{"org-r1", "p1", "p2", "r1", "d1"} {
		path := "users/" + u + "/beaconMemberships/" + e.b.ID
		if s, en := e.docTime(t, path, "startAt"), e.docTime(t, path, "endAt"); !s.Equal(newStart) || !en.Equal(end) {
			t.Errorf("membership %s window = %v..%v, want %v..%v", u, s, en, newStart, end)
		}
	}
	if got := e.docTime(t, "users/r1/beaconMemberships/"+e.b.ID, "pendingUntil"); !got.Equal(end) {
		t.Errorf("requester pendingUntil = %v, want the new end %v", got, end)
	}
	for _, u := range []string{"p1", "d1"} {
		if got := e.docTime(t, "users/"+u+"/beaconMemberships/"+e.b.ID, "pendingUntil"); !got.IsZero() {
			t.Errorf("%s pendingUntil = %v, want none (not a live request)", u, got)
		}
	}
	again, err := e.update("org-r1", "integration-key-rs01", UpdateParams{StartAt: &newStart, DurationMin: &dur, MaxEditRows: MaxEditRows})
	if err != nil || again.Outcome != Replayed || again.Rescheduled {
		t.Fatalf("replay = %+v, %v, want Replayed and no notice", again, err)
	}
	same, err := e.update("org-r1", "integration-key-rs02", UpdateParams{StartAt: &newStart, DurationMin: &dur, MaxEditRows: MaxEditRows})
	if err != nil || same.Outcome != Unchanged || same.Rescheduled {
		t.Fatalf("resend of the stored values = %+v, %v, want Unchanged", same, err)
	}
}

// TestRepo_RescheduleKeepsErasedMembershipsGone: a membership row an erasure removed is never recreated by a move.
func TestRepo_RescheduleKeepsErasedMembershipsGone(t *testing.T) {
	e := newRescheduleEnv(t, "org-r2")
	if _, err := e.client.Doc("users/d1/beaconMemberships/" + e.b.ID).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	newStart := e.now.Add(5 * time.Hour)
	if _, err := e.update("org-r2", "integration-key-rs11", UpdateParams{StartAt: &newStart, MaxEditRows: MaxEditRows}); err != nil {
		t.Fatal(err)
	}
	if fsExists(t, e.repoEnv, "users/d1/beaconMemberships/"+e.b.ID) {
		t.Fatal("the reschedule recreated an erased membership row")
	}
}

// TestRepo_RescheduleRules: cost alone moves no row but still reports the accepted list; once the stored start passed
// any change of start, duration or cost is ErrStarted (title still allowed until the end); more participant rows than
// MaxEditRows is ErrEditRows and nothing is written.
func TestRepo_RescheduleRules(t *testing.T) {
	e := newRescheduleEnv(t, "org-r3")
	t.Run("cost only", func(t *testing.T) {
		cost := CostSplitEvenly
		res, err := e.update("org-r3", "integration-key-rs21", UpdateParams{Cost: &cost, MaxEditRows: MaxEditRows})
		if err != nil || !res.Rescheduled || res.Beacon.Cost != CostSplitEvenly || len(res.Accepted) != 2 {
			t.Fatalf("cost = %+v, %v", res, err)
		}
		if got := e.docTime(t, "beacons/"+e.b.ID+"/beaconParticipants/p1", "expireAt"); !got.Equal(e.b.ExpireAt) {
			t.Fatalf("cost-only change moved a participant TTL: %v", got)
		}
	})
	t.Run("too many rows", func(t *testing.T) {
		later := e.now.Add(3 * time.Hour)
		_, err := e.update("org-r3", "integration-key-rs22", UpdateParams{StartAt: &later, MaxEditRows: 3})
		if !errors.Is(err, ErrEditRows) {
			t.Fatalf("err = %v, want ErrEditRows (4 rows, max 3)", err)
		}
		if b, _ := e.repo.Get(context.Background(), e.b.ID); !b.StartAt.Equal(e.b.StartAt) {
			t.Fatalf("start moved to %v despite the refusal", b.StartAt)
		}
	})
	t.Run("started", func(t *testing.T) {
		started := e.b.StartAt.Add(time.Minute)
		later := e.now.Add(6 * time.Hour)
		dur := 60
		cost := CostFree
		for i, p := range []UpdateParams{{StartAt: &later}, {DurationMin: &dur}, {Cost: &cost}} {
			p.Now, p.MaxEditRows = started, MaxEditRows
			if _, err := e.update("org-r3", fmt.Sprintf("integration-key-rs3%d", i), p); !errors.Is(err, ErrStarted) {
				t.Fatalf("change %d after start: err = %v, want ErrStarted", i, err)
			}
		}
		title := "Still editable"
		if res, err := e.update("org-r3", "integration-key-rs39", UpdateParams{Title: &title, Now: started}); err != nil || res.Rescheduled {
			t.Fatalf("title after start = %+v, %v", res, err)
		}
	})
}

func fsExists(t *testing.T, e *repoEnv, path string) bool {
	t.Helper()
	s, err := e.client.Doc(path).Get(context.Background())
	if err != nil && s == nil {
		return false
	}
	return s.Exists()
}
