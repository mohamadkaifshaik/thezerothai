package outbox

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fakeBackend is an in-memory model of the outbox collection. Every write bumps a doc's update time, so the claim and
// remove preconditions behave as Firestore's LastUpdateTime does.
type fakeBackend struct {
	docs  map[string]stored
	clock time.Time // update times are clock + n ns, strictly increasing
	ticks int64

	dueErr, claimErr, removeErr, getErr, purgeErr error
	dueCalls                                      int
	lastDueLimit                                  int
	lastDueAt                                     time.Time
	staged                                        []string
	// beforeClaim runs once before the next claim (a concurrent writer).
	beforeClaim func(id string)
}

type stored struct {
	doc itemDoc
	ut  time.Time
}

func newFakeBackend() *fakeBackend {
	return &fakeBackend{docs: map[string]stored{}, clock: time.Unix(1_800_000_000, 0)}
}

func (f *fakeBackend) tick() time.Time {
	f.ticks++
	return f.clock.Add(time.Duration(f.ticks))
}

func (f *fakeBackend) stage(_ store.Batch, id string, d itemDoc) {
	f.staged = append(f.staged, id)
	f.docs[id] = stored{doc: d, ut: f.tick()}
}

func (f *fakeBackend) get(_ context.Context, id string) (Item, bool, error) {
	if f.getErr != nil {
		return Item{}, false, f.getErr
	}
	s, ok := f.docs[id]
	if !ok {
		return Item{}, false, nil
	}
	return s.doc.item(id, s.ut), true, nil
}

func (f *fakeBackend) due(_ context.Context, now time.Time, limit int) ([]Item, error) {
	f.dueCalls++
	f.lastDueLimit, f.lastDueAt = limit, now
	if f.dueErr != nil {
		return nil, f.dueErr
	}
	var out []Item
	for id, s := range f.docs {
		if !s.doc.NextAttemptAt.After(now) {
			out = append(out, s.doc.item(id, s.ut))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].NextAttemptAt.Equal(out[j].NextAttemptAt) {
			return out[i].NextAttemptAt.Before(out[j].NextAttemptAt)
		}
		return out[i].id < out[j].id
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *fakeBackend) claim(_ context.Context, it Item, attempts int, next time.Time) (time.Time, bool, error) {
	if f.beforeClaim != nil {
		h := f.beforeClaim
		f.beforeClaim = nil
		h(it.id)
	}
	if f.claimErr != nil {
		return time.Time{}, false, f.claimErr
	}
	s, ok := f.docs[it.id]
	if !ok || !s.ut.Equal(it.updateTime) {
		return time.Time{}, false, nil
	}
	s.doc.Attempts, s.doc.NextAttemptAt = attempts, next
	s.ut = f.tick()
	f.docs[it.id] = s
	return s.ut, true, nil
}

func (f *fakeBackend) remove(_ context.Context, id string, ifUpdated *time.Time) error {
	if f.removeErr != nil {
		return f.removeErr
	}
	s, ok := f.docs[id]
	if !ok || (ifUpdated != nil && !s.ut.Equal(*ifUpdated)) {
		return nil
	}
	delete(f.docs, id)
	return nil
}

func (f *fakeBackend) purgeUID(_ context.Context, uid string, limit int) (int, error) {
	if f.purgeErr != nil {
		return 0, f.purgeErr
	}
	var ids []string
	for id, s := range f.docs {
		if s.doc.UID == uid {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) > limit {
		ids = ids[:limit]
	}
	for _, id := range ids {
		delete(f.docs, id)
	}
	return len(ids), nil
}

// testClock is a settable clock.
type testClock struct{ t time.Time }

func (c *testClock) now() time.Time          { return c.t }
func (c *testClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestOutbox(t *testing.T) (*Outbox, *fakeBackend, *testClock) {
	t.Helper()
	b := newFakeBackend()
	c := &testClock{t: time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)}
	return newOutbox(b, Config{Now: c.now}), b, c
}

const uidA = "uidAAAAAAAAAAAAAAAAAAAAAAAA1"

func entry(key string) Entry {
	return Entry{Kind: "post_delete", Key: key, UID: uidA, Payload: []byte(`{"k":"` + key + `"}`)}
}

func TestEntryValidate(t *testing.T) {
	long := strings.Repeat("a", 129)
	tests := []struct {
		name string
		e    Entry
		ok   bool
	}{
		{"valid", entry("0000000000000000101"), true},
		{"empty kind", Entry{Key: "k", UID: uidA}, false},
		{"kind with upper case", Entry{Kind: "Post", Key: "k", UID: uidA}, false},
		{"kind too long", Entry{Kind: strings.Repeat("k", 33), Key: "k", UID: uidA}, false},
		{"kind starts with a digit", Entry{Kind: "1x", Key: "k", UID: uidA}, false},
		{"empty key", Entry{Kind: "post_delete", UID: uidA}, false},
		{"key with slash", Entry{Kind: "post_delete", Key: "a/b", UID: uidA}, false},
		{"key with colon", Entry{Kind: "post_delete", Key: "a:b", UID: uidA}, false},
		{"key too long", Entry{Kind: "post_delete", Key: long, UID: uidA}, false},
		{"no uid", Entry{Kind: "post_delete", Key: "k"}, false},
		{"payload too large", Entry{Kind: "post_delete", Key: "k", UID: uidA, Payload: make([]byte, MaxPayloadBytes+1)}, false},
		{"payload at the bound", Entry{Kind: "post_delete", Key: "k", UID: uidA, Payload: make([]byte, MaxPayloadBytes)}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.e.Validate()
			if (err == nil) != tt.ok {
				t.Fatalf("Validate = %v, want ok=%v", err, tt.ok)
			}
			if err != nil && !errors.Is(err, ErrInvalidEntry) {
				t.Fatalf("err = %v, want ErrInvalidEntry", err)
			}
		})
	}
}

func TestEntryID_IsDeterministicAndUnambiguous(t *testing.T) {
	if got := entry("123").ID(); got != "post_delete:123" {
		t.Fatalf("ID = %q", got)
	}
	// The separator is not allowed in a kind or a key, so (kind, key) pairs never collide.
	a := Entry{Kind: "a_b", Key: "c"}.ID()
	b := Entry{Kind: "a", Key: "b_c"}.ID()
	if a == b {
		t.Fatalf("ids collide: %q", a)
	}
}

func TestStage_WritesTheItemWithDelayAndTTL(t *testing.T) {
	o, b, c := newTestOutbox(t)
	e := entry("0000000000000000101")
	if err := o.Stage(nil, e); err != nil {
		t.Fatal(err)
	}
	s, ok := b.docs[e.ID()]
	if !ok {
		t.Fatalf("not staged: %v", b.docs)
	}
	d := s.doc
	if d.Kind != e.Kind || d.Key != e.Key || d.UID != e.UID || string(d.Payload) != string(e.Payload) || d.Attempts != 0 {
		t.Fatalf("doc = %+v", d)
	}
	if !d.CreatedAt.Equal(c.t) || !d.NextAttemptAt.Equal(c.t.Add(DefaultInitialDelay)) || !d.ExpireAt.Equal(c.t.Add(DefaultTTL)) {
		t.Fatalf("times = created %v next %v expire %v", d.CreatedAt, d.NextAttemptAt, d.ExpireAt)
	}
	if err := o.Stage(nil, Entry{Kind: "post_delete"}); !errors.Is(err, ErrInvalidEntry) {
		t.Fatalf("invalid entry staged: %v", err)
	}
	if len(b.staged) != 1 {
		t.Fatalf("staged = %v, want only the valid entry", b.staged)
	}
}

func TestDone_RemovesTheItemAndToleratesAMissingOne(t *testing.T) {
	o, b, _ := newTestOutbox(t)
	e := entry("0000000000000000101")
	_ = o.Stage(nil, e)
	if err := o.Done(context.Background(), e); err != nil {
		t.Fatal(err)
	}
	if _, ok := b.docs[e.ID()]; ok {
		t.Fatal("Done left the item")
	}
	if err := o.Done(context.Background(), e); err != nil {
		t.Fatalf("second Done = %v, want nil", err)
	}
	b.removeErr = errors.New("unavailable")
	if err := o.Done(context.Background(), e); err == nil {
		t.Fatal("a backend failure was swallowed")
	}
	if err := o.Done(context.Background(), Entry{}); !errors.Is(err, ErrInvalidEntry) {
		t.Fatalf("Done(invalid) = %v", err)
	}
}

func TestHandle_RejectsDuplicatesAndBadKinds(t *testing.T) {
	o, _, _ := newTestOutbox(t)
	h := func(context.Context, Item) error { return nil }
	if err := o.Handle("post_delete", h); err != nil {
		t.Fatal(err)
	}
	if err := o.Handle("post_delete", h); err == nil {
		t.Fatal("a second handler for one kind was accepted")
	}
	if err := o.Handle("Bad Kind", h); err == nil {
		t.Fatal("an invalid kind was accepted")
	}
	if err := o.Handle("other", nil); err == nil {
		t.Fatal("a nil handler was accepted")
	}
}

func TestBackoff(t *testing.T) {
	o, _, _ := newTestOutbox(t)
	tests := []struct {
		attempts int
		want     time.Duration
	}{
		{0, time.Minute}, {1, time.Minute}, {2, 2 * time.Minute}, {3, 4 * time.Minute}, {8, 128 * time.Minute},
		{9, 256 * time.Minute}, {10, 6 * time.Hour}, {40, 6 * time.Hour}, {1000, 6 * time.Hour},
	}
	for _, tt := range tests {
		if got := o.backoff(tt.attempts); got != tt.want {
			t.Errorf("backoff(%d) = %v, want %v", tt.attempts, got, tt.want)
		}
	}
}

// recorder is a handler that records the items it ran and fails while err is set.
type recorder struct {
	ran []string
	err error
}

func (r *recorder) handle(_ context.Context, it Item) error {
	r.ran = append(r.ran, it.Key)
	return r.err
}

func TestSweep_PublisherFailureKeepsTheItem_SuccessRemovesIt(t *testing.T) {
	ctx := context.Background()
	o, b, c := newTestOutbox(t)
	rec := &recorder{err: errors.New("pubsub down")}
	if err := o.Handle("post_delete", rec.handle); err != nil {
		t.Fatal(err)
	}
	e := entry("0000000000000000101")
	_ = o.Stage(nil, e)

	// Not due yet: the inline publish owns the first InitialDelay.
	res, err := o.Sweep(ctx)
	if err != nil || res.Due != 0 || len(rec.ran) != 0 {
		t.Fatalf("early sweep = %+v, %v, ran %v", res, err, rec.ran)
	}

	c.advance(DefaultInitialDelay)
	res, err = o.Sweep(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if res.Due != 1 || res.Failed != 1 || res.Done != 0 || len(rec.ran) != 1 {
		t.Fatalf("failing sweep = %+v, ran %v", res, rec.ran)
	}
	s := b.docs[e.ID()]
	if s.doc.Attempts != 1 || !s.doc.NextAttemptAt.Equal(c.t.Add(time.Minute)) {
		t.Fatalf("after failure: attempts %d next %v", s.doc.Attempts, s.doc.NextAttemptAt)
	}

	// Backed off: an immediate re-run does nothing.
	if res, _ := o.Sweep(ctx); res.Due != 0 {
		t.Fatalf("re-run inside the backoff = %+v", res)
	}

	c.advance(time.Minute)
	rec.err = nil
	res, err = o.Sweep(ctx)
	if err != nil || res.Done != 1 || res.Failed != 0 {
		t.Fatalf("succeeding sweep = %+v, %v", res, err)
	}
	if _, ok := b.docs[e.ID()]; ok {
		t.Fatal("a delivered item was not removed")
	}
	if len(rec.ran) != 2 {
		t.Fatalf("ran = %v", rec.ran)
	}
	// Idempotent double sweep: nothing left, nothing re-run.
	c.advance(time.Hour)
	if res, _ := o.Sweep(ctx); res.Due != 0 || len(rec.ran) != 2 {
		t.Fatalf("second sweep after delivery = %+v, ran %v", res, rec.ran)
	}
}

func TestSweep_ExponentialBackoffAndStuckReportedOnce(t *testing.T) {
	ctx := context.Background()
	o, b, c := newTestOutbox(t)
	rec := &recorder{err: errors.New("down")}
	_ = o.Handle("post_delete", rec.handle)
	e := entry("0000000000000000101")
	_ = o.Stage(nil, e)
	c.advance(DefaultInitialDelay)

	var stuck []int
	for attempt := 1; attempt <= DefaultStuckAfter+2; attempt++ {
		res, err := o.Sweep(ctx)
		if err != nil || res.Due != 1 || res.Failed != 1 {
			t.Fatalf("attempt %d: %+v, %v", attempt, res, err)
		}
		if res.Stuck > 0 {
			stuck = append(stuck, attempt)
			if len(res.StuckItems) != 1 || res.StuckItems[0].Kind != "post_delete" || res.StuckItems[0].UIDHash == "" || res.StuckItems[0].UIDHash == uidA {
				t.Fatalf("stuck items = %+v, want the kind and a hashed uid", res.StuckItems)
			}
		}
		d := b.docs[e.ID()].doc
		if want := o.backoff(attempt); !d.NextAttemptAt.Equal(c.t.Add(want)) || d.Attempts != attempt {
			t.Fatalf("attempt %d: next %v (want +%v), attempts %d", attempt, d.NextAttemptAt.Sub(c.t), want, d.Attempts)
		}
		c.advance(o.backoff(attempt))
	}
	if len(stuck) != 1 || stuck[0] != DefaultStuckAfter {
		t.Fatalf("stuck reported on attempts %v, want only [%d]", stuck, DefaultStuckAfter)
	}
}

// An item that succeeds exactly on the StuckAfter-th attempt was never stuck.
func TestSweep_SuccessAtTheThresholdIsNotStuck(t *testing.T) {
	ctx := context.Background()
	o, b, c := newTestOutbox(t)
	rec := &recorder{err: errors.New("down")}
	_ = o.Handle("post_delete", rec.handle)
	e := entry("1")
	_ = o.Stage(nil, e)
	c.advance(DefaultInitialDelay)
	for attempt := 1; attempt < DefaultStuckAfter; attempt++ {
		if res, _ := o.Sweep(ctx); res.Failed != 1 || res.Stuck != 0 {
			t.Fatalf("attempt %d: %+v", attempt, res)
		}
		c.advance(o.backoff(attempt))
	}
	rec.err = nil
	res, err := o.Sweep(ctx)
	if err != nil || res.Done != 1 || res.Stuck != 0 || len(res.StuckItems) != 0 {
		t.Fatalf("success at attempt %d = %+v, %v; want done and not stuck", DefaultStuckAfter, res, err)
	}
	if _, ok := b.docs[e.ID()]; ok {
		t.Fatal("item left")
	}
}

func TestSweep_BatchBound(t *testing.T) {
	ctx := context.Background()
	o, b, c := newTestOutbox(t)
	rec := &recorder{}
	_ = o.Handle("post_delete", rec.handle)
	for i := range DefaultBatchSize + 7 {
		_ = o.Stage(nil, entry(fmt.Sprintf("%019d", i)))
	}
	c.advance(DefaultInitialDelay)
	res, err := o.Sweep(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if b.lastDueLimit != DefaultBatchSize || res.Due != DefaultBatchSize || res.Done != DefaultBatchSize || len(rec.ran) != DefaultBatchSize {
		t.Fatalf("limit %d, res %+v, ran %d", b.lastDueLimit, res, len(rec.ran))
	}
	if len(b.docs) != 7 {
		t.Fatalf("left = %d, want 7 for the next run", len(b.docs))
	}
	res, _ = o.Sweep(ctx)
	if res.Done != 7 || len(b.docs) != 0 {
		t.Fatalf("second run = %+v, left %d", res, len(b.docs))
	}
}

func TestSweep_DueQueryFailureIsTheRunsError(t *testing.T) {
	o, b, _ := newTestOutbox(t)
	b.dueErr = errors.New("unavailable")
	res, err := o.Sweep(context.Background())
	if err == nil || res.Due != 0 {
		t.Fatalf("res %+v err %v", res, err)
	}
}

func TestSweep_UnknownKindIsBackedOffNotDropped(t *testing.T) {
	ctx := context.Background()
	o, b, c := newTestOutbox(t)
	e := Entry{Kind: "beacon_cancelled", Key: "123", UID: uidA}
	_ = o.Stage(nil, e)
	c.advance(DefaultInitialDelay)
	res, err := o.Sweep(ctx)
	if err != nil || res.UnknownKind != 1 || res.Done != 0 {
		t.Fatalf("res %+v err %v", res, err)
	}
	d, ok := b.docs[e.ID()]
	if !ok || d.doc.Attempts != 1 || !d.doc.NextAttemptAt.After(c.t) {
		t.Fatalf("unknown-kind item = %+v, %v (kept and backed off: a newer revision may own the kind)", d, ok)
	}
}

func TestSweep_LostClaimSkipsTheItem(t *testing.T) {
	ctx := context.Background()
	o, b, c := newTestOutbox(t)
	rec := &recorder{}
	_ = o.Handle("post_delete", rec.handle)
	e := entry("0000000000000000101")
	_ = o.Stage(nil, e)
	c.advance(DefaultInitialDelay)
	// Another sweep claims it between our query and our claim.
	b.beforeClaim = func(id string) {
		s := b.docs[id]
		s.ut = b.tick()
		b.docs[id] = s
	}
	res, err := o.Sweep(ctx)
	if err != nil || res.Contended != 1 || len(rec.ran) != 0 {
		t.Fatalf("res %+v err %v ran %v", res, err, rec.ran)
	}
}

func TestSweep_ClaimAndRemoveErrorsAreCounted(t *testing.T) {
	ctx := context.Background()
	t.Run("claim error", func(t *testing.T) {
		o, b, c := newTestOutbox(t)
		rec := &recorder{}
		_ = o.Handle("post_delete", rec.handle)
		_ = o.Stage(nil, entry("1"))
		c.advance(DefaultInitialDelay)
		b.claimErr = errors.New("unavailable")
		res, err := o.Sweep(ctx)
		if err != nil || res.WriteFailed != 1 || len(rec.ran) != 0 {
			t.Fatalf("res %+v err %v ran %v (no claim, no run)", res, err, rec.ran)
		}
	})
	t.Run("remove error", func(t *testing.T) {
		o, b, c := newTestOutbox(t)
		rec := &recorder{}
		_ = o.Handle("post_delete", rec.handle)
		_ = o.Stage(nil, entry("1"))
		c.advance(DefaultInitialDelay)
		b.removeErr = errors.New("unavailable")
		res, err := o.Sweep(ctx)
		if err != nil || res.WriteFailed != 1 || res.Done != 0 || len(rec.ran) != 1 {
			t.Fatalf("res %+v err %v ran %v", res, err, rec.ran)
		}
		if b.docs[entry("1").ID()].doc.Attempts != 1 {
			t.Fatal("the claim was not kept, so the item would be re-run at once")
		}
	})
}

func TestSweep_RestagedDuringRunIsNotRemoved(t *testing.T) {
	ctx := context.Background()
	o, b, c := newTestOutbox(t)
	e := entry("1")
	_ = o.Stage(nil, e)
	c.advance(DefaultInitialDelay)
	// The handler runs, and meanwhile the producer stages the item again (a replay): the stale remove must not wipe it.
	_ = o.Handle("post_delete", func(context.Context, Item) error {
		_ = o.Stage(nil, e)
		return nil
	})
	res, err := o.Sweep(ctx)
	if err != nil || res.Done != 1 {
		t.Fatalf("res %+v err %v", res, err)
	}
	if _, ok := b.docs[e.ID()]; !ok {
		t.Fatal("a re-staged item was removed by the earlier run's stale delete")
	}
}

func TestSweep_StopsAtTheDeadline(t *testing.T) {
	o, _, c := newTestOutbox(t)
	ctx, cancel := context.WithCancel(context.Background())
	n := 0
	_ = o.Handle("post_delete", func(context.Context, Item) error {
		n++
		cancel()
		return nil
	})
	for i := range 5 {
		_ = o.Stage(nil, entry(fmt.Sprint(i)))
	}
	c.advance(DefaultInitialDelay)
	res, err := o.Sweep(ctx)
	if err != nil || n != 1 || res.Done != 1 || res.Deferred != 4 {
		t.Fatalf("res %+v err %v ran %d", res, err, n)
	}
}

func TestSweep_PanicInAHandlerIsAFailure(t *testing.T) {
	o, b, c := newTestOutbox(t)
	_ = o.Handle("post_delete", func(context.Context, Item) error { panic("boom") })
	e := entry("1")
	_ = o.Stage(nil, e)
	c.advance(DefaultInitialDelay)
	res, err := o.Sweep(context.Background())
	if err != nil || res.Failed != 1 {
		t.Fatalf("res %+v err %v", res, err)
	}
	if _, ok := b.docs[e.ID()]; !ok {
		t.Fatal("a panicking item was dropped")
	}
}

func TestRunNow(t *testing.T) {
	ctx := context.Background()
	o, b, _ := newTestOutbox(t)
	rec := &recorder{}
	_ = o.Handle("post_delete", rec.handle)
	e := entry("1")

	found, err := o.RunNow(ctx, e)
	if err != nil || found || len(rec.ran) != 0 {
		t.Fatalf("absent: found %v err %v ran %v", found, err, rec.ran)
	}
	_ = o.Stage(nil, e)
	// Not due yet, but RunNow runs it anyway (a replay retrigger).
	found, err = o.RunNow(ctx, e)
	if err != nil || !found || len(rec.ran) != 1 {
		t.Fatalf("present: found %v err %v ran %v", found, err, rec.ran)
	}
	if _, ok := b.docs[e.ID()]; ok {
		t.Fatal("RunNow left a delivered item")
	}

	_ = o.Stage(nil, e)
	rec.err = errors.New("down")
	found, err = o.RunNow(ctx, e)
	if err == nil || !found {
		t.Fatalf("failing: found %v err %v", found, err)
	}
	if d := b.docs[e.ID()].doc; d.Attempts != 1 {
		t.Fatalf("failing RunNow attempts = %d, want the claim kept", d.Attempts)
	}

	b.getErr = errors.New("unavailable")
	if _, err := o.RunNow(ctx, e); err == nil {
		t.Fatal("a read failure was swallowed")
	}
	b.getErr = nil
	if _, err := o.RunNow(ctx, Entry{Kind: "unknown_kind", Key: "1", UID: uidA}); err == nil {
		t.Fatal("RunNow of a kind with no handler must fail")
	}
	if _, err := o.RunNow(ctx, Entry{}); !errors.Is(err, ErrInvalidEntry) {
		t.Fatalf("RunNow(invalid) = %v", err)
	}
}

func TestPurgeUser(t *testing.T) {
	ctx := context.Background()
	o, b, _ := newTestOutbox(t)
	other := "uidBBBBBBBBBBBBBBBBBBBBBBBB2"
	for i := range purgePage + 3 {
		_ = o.Stage(nil, entry(fmt.Sprint(i)))
	}
	_ = o.Stage(nil, Entry{Kind: "post_delete", Key: "theirs", UID: other})

	cp, done, err := o.PurgeUser(ctx, uidA, Checkpoint{})
	if err != nil || done || cp.Deleted != purgePage {
		t.Fatalf("page 1: cp %+v done %v err %v", cp, done, err)
	}
	cp, done, err = o.PurgeUser(ctx, uidA, cp)
	if err != nil || !done || cp.Deleted != purgePage+3 {
		t.Fatalf("page 2: cp %+v done %v err %v", cp, done, err)
	}
	if len(b.docs) != 1 {
		t.Fatalf("left %d docs, want only the other user's", len(b.docs))
	}
	b.purgeErr = errors.New("unavailable")
	if _, _, err := o.PurgeUser(ctx, other, Checkpoint{}); err == nil {
		t.Fatal("a purge failure was swallowed")
	}
}

func TestResultLogAttrs(t *testing.T) {
	r := Result{Due: 3, Done: 1, Failed: 1, UnknownKind: 1}
	attrs := r.LogAttrs()
	got := fmt.Sprint(attrs)
	for _, want := range []string{"due 3", "done 1", "failed 1", "unknown_kind 1", "stuck 0"} {
		if !strings.Contains(got, want) {
			t.Errorf("attrs %v lack %q", got, want)
		}
	}
}

// The Firestore adapter is exercised by the integration test; this only pins that New builds one without I/O.
func TestNew_NoIO(t *testing.T) {
	o := New(&firestore.Client{}, Config{})
	if o == nil || o.cfg.BatchSize != DefaultBatchSize || o.cfg.Now == nil {
		t.Fatalf("New = %+v", o)
	}
}
