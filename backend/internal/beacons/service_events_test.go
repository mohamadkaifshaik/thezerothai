package beacons

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// captureLogs routes slog's default logger into a buffer for the test (restored on cleanup).
func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	buf := &bytes.Buffer{}
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return buf
}

// TestEvents_FireOnlyOnWritten (R23): a request, an acceptance and a cancellation reach the Events seam exactly when
// the transaction wrote (Outcome Written); replays, no-ops and a decline fire nothing.
func TestEvents_FireOnlyOnWritten(t *testing.T) {
	type call struct {
		name    string
		outcome Outcome
		run     func(e *env) error
		want    func(ev *fakeEvents) bool
	}
	request := func(e *env) error {
		_, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, "")
		return err
	}
	respond := func(accept bool) func(e *env) error {
		return func(e *env) error {
			_, err := e.svc.RespondToJoinRequest(context.Background(), testOrganiser, testKey, testBeaconID, testViewer, accept)
			return err
		}
	}
	cancel := func(e *env) error {
		return e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID)
	}
	none := func(ev *fakeEvents) bool { return len(ev.requested)+len(ev.accepted)+len(ev.cancelled) == 0 }
	tests := []call{
		{"request written", Written, request, func(ev *fakeEvents) bool {
			return len(ev.requested) == 1 && len(ev.accepted) == 0 && len(ev.cancelled) == 0 &&
				ev.requested[0] == ParticipationEvent{BeaconID: testBeaconID, OrganiserUID: testOrganiser, ParticipantUID: testViewer, At: testNow}
		}},
		{"request replayed", Replayed, request, none},
		{"accept written", Written, respond(true), func(ev *fakeEvents) bool {
			return len(ev.accepted) == 1 && len(ev.requested) == 0 && len(ev.cancelled) == 0 &&
				ev.accepted[0] == ParticipationEvent{BeaconID: testBeaconID, OrganiserUID: testOrganiser, ParticipantUID: testViewer, At: testNow}
		}},
		{"accept replayed", Replayed, respond(true), none},
		{"decline written", Written, respond(false), none},
		{"cancel written", Written, cancel, func(ev *fakeEvents) bool {
			if len(ev.cancelled) != 1 || len(ev.requested)+len(ev.accepted) != 0 {
				return false
			}
			c := ev.cancelled[0]
			return c.BeaconID == testBeaconID && c.OrganiserUID == testOrganiser && c.At.Equal(testNow) &&
				len(c.ParticipantUIDs) == 2 && c.ParticipantUIDs[0] == "bob" && c.ParticipantUIDs[1] == "carol"
		}},
		{"cancel unchanged", Unchanged, cancel, none},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv()
			b := e.openBeacon()
			b.AcceptedCount = 2
			e.repo.docs[testBeaconID] = b
			e.repo.presult = ParticipantResult{Outcome: tt.outcome, Beacon: b, Participant: Participant{BeaconID: testBeaconID, UID: testViewer, State: PStateAccepted}}
			e.repo.cancel = CancelResult{Outcome: tt.outcome, Beacon: b}
			e.repo.plist = []Participant{{BeaconID: testBeaconID, UID: "bob", State: PStateAccepted}, {BeaconID: testBeaconID, UID: "carol", State: PStateAccepted}}
			if err := tt.run(e); err != nil {
				t.Fatalf("rpc: %v", err)
			}
			if !tt.want(e.events) {
				t.Errorf("events = requested %+v accepted %+v cancelled %+v", e.events.requested, e.events.accepted, e.events.cancelled)
			}
		})
	}
}

// TestCancel_SkipsParticipantReadWhenNobodyAccepted: the accepted list is read once, only when the cancel wrote and
// someone was accepted, bounded by MaxOpenSpots.
func TestCancel_SkipsParticipantReadWhenNobodyAccepted(t *testing.T) {
	e := newEnv()
	b := e.openBeacon()
	e.repo.docs[testBeaconID] = b
	e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
	if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Fatal(err)
	}
	if len(e.repo.pqueries) != 0 || len(e.events.cancelled) != 0 {
		t.Fatalf("nobody accepted: queries=%+v events=%+v, want none", e.repo.pqueries, e.events.cancelled)
	}
	b.AcceptedCount = 2
	e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
	e.repo.plist = []Participant{{UID: "bob", State: PStateAccepted}}
	if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Fatal(err)
	}
	if len(e.repo.pqueries) != 1 || e.repo.pqueries[0] != (ParticipantQuery{BeaconID: testBeaconID, State: PStateAccepted, Limit: 20}) {
		t.Errorf("queries = %+v, want one accepted query bounded by MaxOpenSpots", e.repo.pqueries)
	}
	if len(e.events.cancelled) != 1 || len(e.events.cancelled[0].ParticipantUIDs) != 1 || e.events.cancelled[0].ParticipantUIDs[0] != "bob" {
		t.Errorf("cancelled = %+v", e.events.cancelled)
	}
}

// TestCancel_ParticipantReadErrorKeepsTheCancel: the cancel already committed; a failed accepted-list read is logged
// (hash only) and the event skipped, and the RPC still succeeds.
func TestCancel_ParticipantReadErrorKeepsTheCancel(t *testing.T) {
	logs := captureLogs(t)
	e := newEnv()
	b := e.openBeacon()
	b.AcceptedCount = 1
	e.repo.docs[testBeaconID] = b
	e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
	e.repo.plistErr = errors.New("boom")
	if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Fatalf("CancelBeacon: %v", err)
	}
	if len(e.events.cancelled) != 0 {
		t.Errorf("cancelled = %+v, want none", e.events.cancelled)
	}
	if len(e.repo.pqueries) != cancelReadAttempts {
		t.Errorf("participant reads = %d, want %d (bounded retry)", len(e.repo.pqueries), cancelReadAttempts)
	}
	if !strings.Contains(logs.String(), "beacon_cancel_participants_failed") || strings.Contains(logs.String(), testBeaconID) {
		t.Errorf("logs = %s", logs.String())
	}
}

// TestCancel_ParticipantReadRetries (B07): a transient accepted-list failure is retried a bounded number of times, so
// the notice still reaches the accepted participants once a later read succeeds; a cancelled ctx stops the retries.
func TestCancel_ParticipantReadRetries(t *testing.T) {
	for _, tt := range []struct {
		name      string
		fails     int
		cancelCtx bool
		wantReads int
		wantEvent bool
	}{
		{name: "first read fails then succeeds", fails: 1, wantReads: 2, wantEvent: true},
		{name: "all but the last read fail", fails: cancelReadAttempts - 1, wantReads: cancelReadAttempts, wantEvent: true},
		{name: "every read fails", fails: cancelReadAttempts, wantReads: cancelReadAttempts},
		{name: "cancelled ctx stops after one read", fails: cancelReadAttempts, cancelCtx: true, wantReads: 1},
	} {
		t.Run(tt.name, func(t *testing.T) {
			captureLogs(t)
			e := newEnv()
			b := e.openBeacon()
			b.AcceptedCount = 1
			e.repo.docs[testBeaconID] = b
			e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
			e.repo.plist = []Participant{{UID: "bob", State: PStateAccepted}}
			e.repo.plistErr, e.repo.plistFails = errors.New("unavailable"), tt.fails
			ctx := context.Background()
			if tt.cancelCtx {
				c, cancel := context.WithCancel(ctx)
				cancel()
				ctx = c
			}
			if err := e.svc.CancelBeacon(ctx, testOrganiser, testKey, testBeaconID); err != nil {
				t.Fatalf("CancelBeacon: %v", err)
			}
			if len(e.repo.pqueries) != tt.wantReads {
				t.Errorf("participant reads = %d, want %d", len(e.repo.pqueries), tt.wantReads)
			}
			got := len(e.events.cancelled) == 1 && len(e.events.cancelled[0].ParticipantUIDs) == 1 && e.events.cancelled[0].ParticipantUIDs[0] == "bob"
			if got != tt.wantEvent || (!tt.wantEvent && len(e.events.cancelled) != 0) {
				t.Errorf("cancelled = %+v, want event %v", e.events.cancelled, tt.wantEvent)
			}
		})
	}
}

// TestEvents_NilSeamIsSafe: a nil Events drops every event and the three RPCs still succeed.
func TestEvents_NilSeamIsSafe(t *testing.T) {
	e := newEnv()
	b := e.openBeacon()
	b.AcceptedCount = 1
	e.repo.docs[testBeaconID] = b
	e.repo.presult = ParticipantResult{Outcome: Written, Beacon: b, Participant: Participant{BeaconID: testBeaconID, UID: testViewer, State: PStateAccepted}}
	e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
	e.repo.plist = []Participant{{UID: "bob", State: PStateAccepted}}
	e.svc = New(Deps{
		Repo: e.repo, Directory: e.dir, Graph: e.graph, Communities: e.comm, CommunityFlags: e.flags, IDs: fakeIDs{},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Limits: Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20},
		Now: func() time.Time { return e.now },
	})
	if _, err := e.svc.RequestToJoin(context.Background(), testViewer, testKey, testBeaconID, ""); err != nil {
		t.Errorf("request: %v", err)
	}
	if _, err := e.svc.RespondToJoinRequest(context.Background(), testOrganiser, testKey, testBeaconID, testViewer, true); err != nil {
		t.Errorf("respond: %v", err)
	}
	if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Errorf("cancel: %v", err)
	}
}
