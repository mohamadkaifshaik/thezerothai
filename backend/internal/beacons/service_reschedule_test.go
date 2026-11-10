package beacons

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// F28: UpdateBeacon edits start_at, duration_minutes and cost before the beacon starts.

func TestNormalizeSchedule(t *testing.T) {
	now := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	at := func(d time.Duration) *time.Time { v := now.Add(d); return &v }
	n := func(v int) *int { return &v }
	c := func(v Cost) *Cost { return &v }
	for _, tc := range []struct {
		name  string
		in    UpdateInput
		field string
	}{
		{"nothing set", UpdateInput{}, ""},
		{"start 5 min ahead", UpdateInput{StartAt: at(MinStartLead)}, ""},
		{"start too soon", UpdateInput{StartAt: at(MinStartLead - time.Second)}, "start_at"},
		{"start in the past", UpdateInput{StartAt: at(-time.Hour)}, "start_at"},
		{"start 30 d ahead", UpdateInput{StartAt: at(MaxStartLead)}, ""},
		{"start too late", UpdateInput{StartAt: at(MaxStartLead + time.Second)}, "start_at"},
		{"duration 15", UpdateInput{DurationMin: n(15)}, ""},
		{"duration 14", UpdateInput{DurationMin: n(14)}, "duration_minutes"},
		{"duration 241", UpdateInput{DurationMin: n(241)}, "duration_minutes"},
		{"cost set", UpdateInput{Cost: c(CostFree)}, ""},
		{"cost empty", UpdateInput{Cost: c("")}, "cost"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, err := normalizeSchedule(tc.in, now)
			if tc.field != "" {
				assertValidation(t, err, tc.field)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if s.set() != (tc.in.StartAt != nil || tc.in.DurationMin != nil || tc.in.Cost != nil) {
				t.Fatalf("set() = %v", s.set())
			}
		})
	}
	t.Run("start is UTC at the stored precision", func(t *testing.T) {
		in := now.Add(time.Hour + 1500*time.Nanosecond).In(time.FixedZone("IST", 19800))
		s, err := normalizeSchedule(UpdateInput{StartAt: &in}, now)
		if err != nil || s.start.Location() != time.UTC || s.start.Nanosecond()%1000 != 0 || !s.start.Equal(in.Truncate(time.Microsecond)) {
			t.Fatalf("start = %v, %v", s.start, err)
		}
	})
}

// TestUpdateHash_UnchangedWithoutSchedule: a retry in flight across the deploy must hash as before F28.
func TestUpdateHash_UnchangedWithoutSchedule(t *testing.T) {
	title := "T"
	legacy := idempotency.HashRequest(`beacon_id=b|title="T"|details=unset|venue=unset|open_spots=unset`)
	if got := updateHash("b", &title, nil, nil, nil, schedule{}); got != legacy {
		t.Fatalf("hash without schedule = %s, want the pre-F28 %s", got, legacy)
	}
	start := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	d, c := 30, CostFree
	seen := map[string]bool{legacy: true}
	for _, s := range []schedule{{start: &start}, {duration: &d}, {cost: &c}, {start: &start, duration: &d, cost: &c}} {
		h := updateHash("b", &title, nil, nil, nil, s)
		if seen[h] {
			t.Fatalf("schedule %+v hashes like another request", s)
		}
		seen[h] = true
	}
}

func TestUpdateBeacon_ScheduleReachesTheRepo(t *testing.T) {
	e := newEnv()
	e.repo.docs[testBeaconID] = e.openBeacon()
	e.repo.update = UpdateResult{Outcome: Written, Beacon: e.openBeacon()}
	start, dur, cost := e.now.Add(3*time.Hour), 45, CostSplitEvenly
	if _, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, StartAt: &start, DurationMin: &dur, Cost: &cost}); err != nil {
		t.Fatal(err)
	}
	p := e.repo.updatedBy[0]
	if p.StartAt == nil || !p.StartAt.Equal(start) || p.DurationMin == nil || *p.DurationMin != 45 || p.Cost == nil || *p.Cost != CostSplitEvenly ||
		p.MaxEditRows != MaxEditRows || !p.Now.Equal(e.now) {
		t.Fatalf("params = %+v", p)
	}
	if p.RequestHash != updateHash(testBeaconID, nil, nil, nil, nil, schedule{start: &start, duration: &dur, cost: &cost}) {
		t.Fatal("request hash does not cover the schedule")
	}
}

func TestUpdateBeacon_InvalidScheduleStopsBeforeAnyLookup(t *testing.T) {
	e := newEnv()
	e.repo.docs[testBeaconID] = e.openBeacon()
	past := e.now.Add(-time.Minute)
	_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, StartAt: &past})
	assertValidation(t, err, "start_at")
	if e.repo.calls() != 0 {
		t.Fatal("repository called for an invalid start")
	}
}

func TestUpdateBeacon_NotifiesAcceptedOnReschedule(t *testing.T) {
	updated := func() Beacon {
		b := newEnv().openBeacon()
		b.UpdatedAt = time.Date(2026, 11, 9, 13, 0, 0, 0, time.UTC)
		return b
	}
	for _, tc := range []struct {
		name      string
		res       UpdateResult
		eventsErr error
		want      int
	}{
		{"rescheduled with accepted people", UpdateResult{Outcome: Written, Beacon: updated(), Rescheduled: true, Accepted: []string{"p1", "p2"}}, nil, 1},
		{"rescheduled, nobody accepted", UpdateResult{Outcome: Written, Beacon: updated(), Rescheduled: true}, nil, 0},
		{"title only", UpdateResult{Outcome: Written, Beacon: updated(), Accepted: []string{"p1"}}, nil, 0},
		{"replay", UpdateResult{Outcome: Replayed, Beacon: updated(), Rescheduled: true, Accepted: []string{"p1"}}, nil, 0},
		{"unchanged", UpdateResult{Outcome: Unchanged, Beacon: updated(), Rescheduled: true, Accepted: []string{"p1"}}, nil, 0},
		{"hand-off fails: the update still succeeds", UpdateResult{Outcome: Written, Beacon: updated(), Rescheduled: true, Accepted: []string{"p1"}}, errors.New("pubsub down"), 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv()
			e.repo.docs[testBeaconID] = e.openBeacon()
			e.repo.update = tc.res
			e.events.updateErr = tc.eventsErr
			cost := CostFree
			if _, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, Cost: &cost}); err != nil {
				t.Fatalf("UpdateBeacon: %v", err)
			}
			if len(e.events.updated) != tc.want {
				t.Fatalf("Updated events = %d, want %d", len(e.events.updated), tc.want)
			}
			if tc.want == 1 {
				ev := e.events.updated[0]
				if ev.BeaconID != testBeaconID || ev.OrganiserUID != testOrganiser || len(ev.ParticipantUIDs) != len(tc.res.Accepted) || !ev.At.Equal(tc.res.Beacon.UpdatedAt) {
					t.Fatalf("event = %+v", ev)
				}
			}
		})
	}
}

func TestUpdateBeacon_RepoRefusalsMap(t *testing.T) {
	t.Run("started", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.repo.err = ErrStarted
		d := 30
		_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, DurationMin: &d})
		assertPrecondition(t, err, "started")
	})
	t.Run("too many rows", func(t *testing.T) {
		e := newEnv()
		e.repo.docs[testBeaconID] = e.openBeacon()
		e.repo.err = ErrEditRows
		start := e.now.Add(2 * time.Hour)
		_, err := e.svc.UpdateBeacon(context.Background(), testOrganiser, UpdateInput{Key: testKey, BeaconID: testBeaconID, StartAt: &start})
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED || ae.Metadata["limit"] != "beacon_edit_rows" {
			t.Fatalf("err = %v, want LIMIT_REACHED beacon_edit_rows", err)
		}
	})
}

func TestUpdateInputFromProto(t *testing.T) {
	start := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	dur := int32(60)
	cost := beaconsv1.BeaconCost_BEACON_COST_FREE
	unspecified := beaconsv1.BeaconCost_BEACON_COST_UNSPECIFIED
	in, err := updateInputFromProto(&beaconsv1.UpdateBeaconRequest{IdempotencyKey: testKey, BeaconId: testBeaconID, StartAt: timestamppb.New(start), DurationMinutes: &dur, Cost: &cost})
	if err != nil || in.StartAt == nil || !in.StartAt.Equal(start) || in.DurationMin == nil || *in.DurationMin != 60 || in.Cost == nil || *in.Cost != CostFree {
		t.Fatalf("in = %+v, %v", in, err)
	}
	in, err = updateInputFromProto(&beaconsv1.UpdateBeaconRequest{IdempotencyKey: testKey, BeaconId: testBeaconID})
	if err != nil || in.StartAt != nil || in.DurationMin != nil || in.Cost != nil {
		t.Fatalf("unset fields = %+v, %v; want nil", in, err)
	}
	_, err = updateInputFromProto(&beaconsv1.UpdateBeaconRequest{Cost: &unspecified})
	assertValidation(t, err, "cost")
}
