package outbox

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestSweep_CarriesScrubbedCauses(t *testing.T) {
	ctx := context.Background()
	o, _, c := newTestOutbox(t)
	const key = "0000000000000000101"
	// The handler's error names the uid, the key and a document path: none may reach the log text.
	_ = o.Handle("post_delete", func(_ context.Context, it Item) error {
		return fmt.Errorf("publish for %s of %s at projects/p/databases/(default)/documents/users/%s: down", it.UID, it.Key, it.UID)
	})
	_ = o.Stage(nil, entry(key))
	_ = o.Stage(nil, entry("0000000000000000102"))
	_ = o.Stage(nil, Entry{Kind: "beacon_cancelled", Key: "0000000000000000103", UID: uidA})
	c.advance(DefaultInitialDelay)
	res, err := o.Sweep(ctx)
	if err != nil || res.Failed != 2 || res.UnknownKind != 1 {
		t.Fatalf("res %+v err %v", res, err)
	}
	if len(res.Errors) != 2 {
		t.Fatalf("errors = %+v, want one per (kind, outcome)", res.Errors)
	}
	byOutcome := map[string]ItemError{}
	for _, e := range res.Errors {
		byOutcome[e.Outcome] = e
	}
	f := byOutcome["failed"]
	if f.Kind != "post_delete" || f.Count != 2 || !strings.Contains(f.Cause, "down") {
		t.Fatalf("failed entry = %+v", f)
	}
	for _, leak := range []string{uidA, key, "0000000000000000102", "documents/users"} {
		if strings.Contains(f.Cause, leak) {
			t.Fatalf("cause %q leaks %q", f.Cause, leak)
		}
	}
	if u := byOutcome["unknown_kind"]; u.Kind != "beacon_cancelled" || u.Count != 1 || u.Cause == "" {
		t.Fatalf("unknown entry = %+v", u)
	}
}

func TestSweep_WriteFailureCauseIsCarried(t *testing.T) {
	o, b, c := newTestOutbox(t)
	_ = o.Handle("post_delete", func(context.Context, Item) error { return nil })
	_ = o.Stage(nil, entry("1"))
	c.advance(DefaultInitialDelay)
	b.removeErr = errors.New("unavailable")
	res, _ := o.Sweep(context.Background())
	if res.WriteFailed != 1 || len(res.Errors) != 1 || res.Errors[0].Outcome != "write_failed" || !strings.Contains(res.Errors[0].Cause, "unavailable") {
		t.Fatalf("res %+v", res)
	}
}

func TestSweep_ErrorsAreCapped(t *testing.T) {
	o, _, c := newTestOutbox(t)
	for i := range MaxResultErrors + 5 {
		_ = o.Stage(nil, Entry{Kind: fmt.Sprintf("kind_%d", i), Key: "k", UID: uidA})
	}
	c.advance(DefaultInitialDelay)
	res, _ := o.Sweep(context.Background())
	if res.UnknownKind != MaxResultErrors+5 || len(res.Errors) != MaxResultErrors {
		t.Fatalf("unknown %d, errors %d (cap %d)", res.UnknownKind, len(res.Errors), MaxResultErrors)
	}
}

func TestSweep_UndecodableAndPushBackFailuresAreCounted(t *testing.T) {
	o, b, _ := newTestOutbox(t)
	b.dueStats = dueStats{undecodable: 2, decodeCause: "decode outbox item: bad", pushBackFailed: 1, pushBackCause: "unavailable"}
	res, err := o.Sweep(context.Background())
	if err != nil || res.Undecodable != 2 || res.WriteFailed != 1 {
		t.Fatalf("res %+v err %v", res, err)
	}
	if len(res.Errors) != 2 || res.Errors[0].Outcome != "undecodable" || res.Errors[1].Outcome != "write_failed" || res.Errors[1].Cause != "unavailable" {
		t.Fatalf("errors = %+v", res.Errors)
	}
	if !strings.Contains(fmt.Sprint(res.LogAttrs()), "undecodable 2") {
		t.Fatalf("attrs %v", res.LogAttrs())
	}
}

func TestStuck_ReportedOnTheRunNowPathThroughOnStuck(t *testing.T) {
	ctx := context.Background()
	b := newFakeBackend()
	c := &testClock{t: time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)}
	var got []StuckItem
	o := newOutbox(b, Config{Now: c.now, OnStuck: func(_ context.Context, s StuckItem) { got = append(got, s) }})
	_ = o.Handle("post_delete", func(context.Context, Item) error { return errors.New("down") })
	e := entry("0000000000000000101")
	_ = o.Stage(nil, e)
	// Bring it to StuckAfter-1 attempts; RunNow then fails the crossing attempt.
	s := b.docs[e.ID()]
	s.doc.Attempts = DefaultStuckAfter - 1
	b.docs[e.ID()] = s
	if _, err := o.RunNow(ctx, e); err == nil {
		t.Fatal("want the handler error")
	}
	if len(got) != 1 || got[0].Kind != "post_delete" || got[0].UIDHash == "" || !strings.Contains(got[0].Cause, "down") {
		t.Fatalf("OnStuck calls = %+v", got)
	}
	// Past the threshold it is not reported again, on either path.
	if _, err := o.RunNow(ctx, e); err == nil {
		t.Fatal("want the handler error")
	}
	c.advance(DefaultMaxBackoff)
	if res, _ := o.Sweep(ctx); res.Failed != 1 || res.Stuck != 0 {
		t.Fatalf("sweep past the threshold = %+v", res)
	}
	if len(got) != 1 {
		t.Fatalf("OnStuck calls = %d, want 1", len(got))
	}
}

func TestStuck_SweepCallsOnStuckAndCarriesTheCause(t *testing.T) {
	b := newFakeBackend()
	c := &testClock{t: time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)}
	calls := 0
	o := newOutbox(b, Config{Now: c.now, OnStuck: func(context.Context, StuckItem) { calls++ }})
	_ = o.Handle("post_delete", func(context.Context, Item) error { return errors.New("down") })
	e := entry("1")
	_ = o.Stage(nil, e)
	s := b.docs[e.ID()]
	s.doc.Attempts = DefaultStuckAfter - 1
	b.docs[e.ID()] = s
	c.advance(DefaultInitialDelay)
	res, _ := o.Sweep(context.Background())
	if res.Stuck != 1 || calls != 1 || len(res.StuckItems) != 1 || !strings.Contains(res.StuckItems[0].Cause, "down") {
		t.Fatalf("res %+v calls %d", res, calls)
	}
}

// An item already past the threshold when it is first seen (say StuckAfter was lowered) is not reported: only the crossing is.
func TestStuck_CrossingOnly(t *testing.T) {
	o, b, c := newTestOutbox(t)
	_ = o.Handle("post_delete", func(context.Context, Item) error { return errors.New("down") })
	e := entry("1")
	_ = o.Stage(nil, e)
	s := b.docs[e.ID()]
	s.doc.Attempts = DefaultStuckAfter + 3
	b.docs[e.ID()] = s
	c.advance(DefaultInitialDelay)
	if res, _ := o.Sweep(context.Background()); res.Stuck != 0 || res.Failed != 1 {
		t.Fatalf("res %+v", res)
	}
}
