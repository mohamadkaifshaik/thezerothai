package beacons

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fakeCancelOutbox is an in-memory CancelOutbox: Stage records the item (as if the batch committed), Done removes it,
// RunNow and sweep run handler over the present items and remove the ones that succeeded (outbox.Outbox semantics).
type fakeCancelOutbox struct {
	items   map[string]outbox.Entry
	staged  []outbox.Entry
	done    []string
	runNow  []string
	handler outbox.Handler
	doneErr error
}

func newFakeCancelOutbox() *fakeCancelOutbox {
	return &fakeCancelOutbox{items: map[string]outbox.Entry{}}
}

func (f *fakeCancelOutbox) Stage(_ store.Batch, e outbox.Entry) error {
	if err := e.Validate(); err != nil {
		return err
	}
	f.staged = append(f.staged, e)
	f.items[e.ID()] = e
	return nil
}

func (f *fakeCancelOutbox) Done(_ context.Context, e outbox.Entry) error {
	f.done = append(f.done, e.ID())
	if f.doneErr != nil {
		return f.doneErr
	}
	delete(f.items, e.ID())
	return nil
}

func (f *fakeCancelOutbox) run(ctx context.Context, id string) error {
	if err := f.handler(ctx, outbox.Item{Entry: f.items[id]}); err != nil {
		return err
	}
	delete(f.items, id)
	return nil
}

func (f *fakeCancelOutbox) RunNow(ctx context.Context, e outbox.Entry) (bool, error) {
	f.runNow = append(f.runNow, e.ID())
	if _, ok := f.items[e.ID()]; !ok {
		return false, nil
	}
	return true, f.run(ctx, e.ID())
}

// sweep runs every present item once, like one outbox.Sweep of due items.
func (f *fakeCancelOutbox) sweep(ctx context.Context) {
	for id := range f.items {
		_ = f.run(ctx, id)
	}
}

// withOutbox rebuilds e's service with a fake outbox whose handler is the production NewCancelOutboxHandler over the
// same repo and events.
func (e *env) withOutbox() *fakeCancelOutbox {
	ob := newFakeCancelOutbox()
	limits := Limits{MaxOpenPerUser: 5, MaxPendingRequests: 10, MaxOpenSpots: 20}
	ob.handler = NewCancelOutboxHandler(e.repo, e.events, limits.MaxOpenSpots)
	e.svc = New(Deps{
		Repo: e.repo, Directory: e.dir, Graph: e.graph, Communities: e.comm, CommunityFlags: e.flags, IDs: fakeIDs{},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Limits: limits,
		Events: e.events, Outbox: ob, Now: func() time.Time { return e.now },
	})
	return ob
}

func accepted(n int) []Participant {
	out := make([]Participant, n)
	for i := range out {
		out[i] = Participant{BeaconID: testBeaconID, UID: fmt.Sprintf("p%02d", i), State: PStateAccepted}
	}
	return out
}

// handedOff counts, per participant, the Cancelled calls that succeeded (the fake fails the first cancelFails).
func handedOff(ev *fakeEvents) map[string]int {
	got := map[string]int{}
	for i, c := range ev.cancelled {
		if ev.cancelErr != nil && (ev.cancelFails == 0 || i < ev.cancelFails) {
			continue
		}
		for _, uid := range c.ParticipantUIDs {
			got[uid]++
		}
	}
	return got
}

var cancelItemID = CancelOutboxKind + ":" + testBeaconID

// TestCancelOutbox_InlineSuccessRemovesItem: a cancel with accepted participants stages one item in its transaction
// (organiser uid, beacon key, no participant uid in the payload) and removes it once every notice was handed off; nobody
// accepted stages nothing.
func TestCancelOutbox_InlineSuccessRemovesItem(t *testing.T) {
	for _, n := range []int{0, 1, 10, 11, 20} {
		t.Run(fmt.Sprintf("%d accepted", n), func(t *testing.T) {
			e := newEnv()
			ob := e.withOutbox()
			b := e.openBeacon()
			b.AcceptedCount = n
			e.repo.docs[testBeaconID] = b
			e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
			e.repo.plist = accepted(n)
			if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
				t.Fatal(err)
			}
			if n == 0 {
				if len(ob.staged) != 0 || len(e.events.cancelled) != 0 || len(e.repo.pqueries) != 0 {
					t.Fatalf("nobody accepted: staged %v events %v reads %d", ob.staged, e.events.cancelled, len(e.repo.pqueries))
				}
				return
			}
			if len(ob.staged) != 1 {
				t.Fatalf("staged = %v, want one item", ob.staged)
			}
			it := ob.staged[0]
			if it.ID() != cancelItemID || it.UID != testOrganiser {
				t.Errorf("item = %+v", it)
			}
			for _, p := range e.repo.plist {
				if strings.Contains(string(it.Payload), p.UID) {
					t.Errorf("payload %s carries participant %s", it.Payload, p.UID)
				}
			}
			got := handedOff(e.events)
			if len(got) != n {
				t.Errorf("handed off to %d participants, want %d", len(got), n)
			}
			if len(ob.items) != 0 || len(ob.done) != 1 {
				t.Errorf("items left %v done %v, want removed", ob.items, ob.done)
			}
		})
	}
}

// TestCancelOutbox_LostHandOffIsSweptExactlyOnce: the inline hand-off fails after the commit (or the accepted-list read
// does), the item stays, and the sweep hands each accepted participant's notice off exactly once; later sweeps and a
// replayed cancel do nothing more.
func TestCancelOutbox_LostHandOffIsSweptExactlyOnce(t *testing.T) {
	for _, failRead := range []bool{false, true} {
		for _, n := range []int{1, 10, 11, 20} {
			t.Run(fmt.Sprintf("%d accepted, read fails %v", n, failRead), func(t *testing.T) {
				captureLogs(t)
				ctx := context.Background()
				e := newEnv()
				ob := e.withOutbox()
				b := e.openBeacon()
				b.AcceptedCount = n
				e.repo.docs[testBeaconID] = b
				e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
				e.repo.plist = accepted(n)
				if failRead {
					e.repo.plistErr, e.repo.plistFails = errors.New("unavailable"), cancelReadAttempts
				} else {
					e.events.cancelErr, e.events.cancelFails = errors.New("pubsub down"), 1
				}
				if err := e.svc.CancelBeacon(ctx, testOrganiser, testKey, testBeaconID); err != nil {
					t.Fatalf("CancelBeacon: %v (a lost notice must never fail the cancel)", err)
				}
				if _, ok := ob.items[cancelItemID]; !ok || len(ob.done) != 0 {
					t.Fatalf("after a lost hand-off: items %v done %v, want the item kept", ob.items, ob.done)
				}
				if got := handedOff(e.events); len(got) != 0 {
					t.Fatalf("handed off inline %v, want none", got)
				}

				ob.sweep(ctx)
				if len(ob.items) != 0 {
					t.Fatalf("items after the sweep = %v", ob.items)
				}
				ob.sweep(ctx)
				e.repo.cancel = CancelResult{Outcome: Replayed, Beacon: b}
				if err := e.svc.CancelBeacon(ctx, testOrganiser, testKey, testBeaconID); err != nil {
					t.Fatal(err)
				}
				got := handedOff(e.events)
				if len(got) != n {
					t.Fatalf("handed off to %d participants, want %d", len(got), n)
				}
				for uid, c := range got {
					if c != 1 {
						t.Errorf("%s handed off %d times, want exactly once", uid, c)
					}
				}
			})
		}
	}
}

// TestCancelOutbox_ReplayRetriggers: a replayed (or already-cancelled) cancel runs a still-present item at once, and
// does nothing (one RunNow lookup) when the item is gone.
func TestCancelOutbox_ReplayRetriggers(t *testing.T) {
	for _, outcome := range []Outcome{Replayed, Unchanged} {
		t.Run(fmt.Sprint(outcome), func(t *testing.T) {
			captureLogs(t)
			ctx := context.Background()
			e := newEnv()
			ob := e.withOutbox()
			b := e.openBeacon()
			b.AcceptedCount = 2
			e.repo.docs[testBeaconID] = b
			e.repo.plist = accepted(2)

			// No item: the replay looks once and hands nothing off.
			e.repo.cancel = CancelResult{Outcome: outcome, Beacon: b}
			if err := e.svc.CancelBeacon(ctx, testOrganiser, testKey, testBeaconID); err != nil {
				t.Fatal(err)
			}
			if len(ob.runNow) != 1 || ob.runNow[0] != cancelItemID || len(e.events.cancelled) != 0 {
				t.Fatalf("absent: runNow %v events %v", ob.runNow, e.events.cancelled)
			}

			// A lost inline hand-off leaves the item; the replay delivers it now.
			e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
			e.events.cancelErr, e.events.cancelFails = errors.New("pubsub down"), 1
			if err := e.svc.CancelBeacon(ctx, testOrganiser, testKey, testBeaconID); err != nil {
				t.Fatal(err)
			}
			e.repo.cancel = CancelResult{Outcome: outcome, Beacon: b}
			if err := e.svc.CancelBeacon(ctx, testOrganiser, testKey, testBeaconID); err != nil {
				t.Fatal(err)
			}
			if len(ob.items) != 0 {
				t.Fatalf("the replay left the item: %v", ob.items)
			}
			if got := handedOff(e.events); len(got) != 2 || got["p00"] != 1 || got["p01"] != 1 {
				t.Fatalf("handed off %v, want each participant once", got)
			}
		})
	}
}

// TestCancelOutbox_NotDurableWithoutSeams: no outbox (or no Events) stages nothing and keeps the best-effort notice; a
// Done failure after a full hand-off is logged and never fails the cancel.
func TestCancelOutbox_NotDurableWithoutSeams(t *testing.T) {
	e := newEnv()
	b := e.openBeacon()
	b.AcceptedCount = 1
	e.repo.docs[testBeaconID] = b
	e.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
	e.repo.plist = accepted(1)
	if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Fatal(err)
	}
	if e.repo.cancelledBy[0].Stage != nil || len(e.events.cancelled) != 1 {
		t.Fatalf("no outbox: stage set %v, events %v", e.repo.cancelledBy[0].Stage != nil, e.events.cancelled)
	}

	ob := newFakeCancelOutbox()
	e.svc = New(Deps{Repo: e.repo, Directory: e.dir, Graph: e.graph, Communities: e.comm, CommunityFlags: e.flags, IDs: fakeIDs{},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"), Limits: Limits{MaxOpenSpots: 20}, Outbox: ob,
		Now: func() time.Time { return e.now }})
	if err := e.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Fatal(err)
	}
	if len(ob.staged) != 0 {
		t.Fatalf("no Events: staged %v", ob.staged)
	}

	logs := captureLogs(t)
	e2 := newEnv()
	ob2 := e2.withOutbox()
	ob2.doneErr = errors.New("unavailable")
	e2.repo.docs[testBeaconID] = b
	e2.repo.cancel = CancelResult{Outcome: Written, Beacon: b}
	e2.repo.plist = accepted(1)
	if err := e2.svc.CancelBeacon(context.Background(), testOrganiser, testKey, testBeaconID); err != nil {
		t.Fatalf("a failed Done must not fail the cancel: %v", err)
	}
	if !strings.Contains(logs.String(), "beacon_cancel_outbox_done_failed") || strings.Contains(logs.String(), testBeaconID) {
		t.Errorf("logs = %s", logs.String())
	}
}

func TestCancelEntryRoundTrip(t *testing.T) {
	at := time.Date(2026, 11, 9, 10, 0, 0, 0, time.UTC)
	e, err := CancelEntry(testBeaconID, testOrganiser, at)
	if err != nil {
		t.Fatal(err)
	}
	if e.Kind != CancelOutboxKind || e.Key != testBeaconID || e.UID != testOrganiser {
		t.Fatalf("entry = %+v", e)
	}
	w, err := DecodeCancelWork(e.Payload)
	if err != nil || w != (CancelWork{BeaconID: testBeaconID, OrganiserUID: testOrganiser, AtMillis: at.UnixMilli()}) {
		t.Fatalf("decode = %+v, %v", w, err)
	}
	for _, bad := range []struct{ beacon, uid string }{{"42", testOrganiser}, {testBeaconID, ""}, {testBeaconID, "a/b"}} {
		if _, err := CancelEntry(bad.beacon, bad.uid, at); err == nil {
			t.Errorf("CancelEntry(%q, %q) accepted", bad.beacon, bad.uid)
		}
	}
	if _, err := DecodeCancelWork([]byte("{")); err == nil {
		t.Error("malformed payload decoded")
	}
}

// TestCancelOutboxHandler_DropsMalformed: a payload no retry can fix is answered with nil (removed), never retried.
func TestCancelOutboxHandler_DropsMalformed(t *testing.T) {
	logs := captureLogs(t)
	e := newEnv()
	h := NewCancelOutboxHandler(e.repo, e.events, 20)
	if err := h(context.Background(), outbox.Item{Entry: outbox.Entry{Kind: CancelOutboxKind, Key: testBeaconID, UID: testOrganiser, Payload: []byte("{")}}); err != nil {
		t.Fatalf("malformed = %v, want dropped", err)
	}
	if len(e.repo.pqueries) != 0 || !strings.Contains(logs.String(), "outbox_item_dropped") {
		t.Fatalf("reads %d logs %s", len(e.repo.pqueries), logs.String())
	}
}
