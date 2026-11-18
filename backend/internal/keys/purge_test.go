package keys

import (
	"context"
	"errors"
	"testing"
)

// fakePurger holds devices with pool sizes; a device is listed while it has a document or pool documents.
type fakePurger struct {
	order   []string
	pool    map[string]int
	hasDoc  map[string]bool
	failOn  string // "list", "pool", "device"
	queries []int  // limits seen by PurgePoolPage
}

func (f *fakePurger) FirstDeviceID(context.Context, string) (string, bool, error) {
	if f.failOn == "list" {
		return "", false, errors.New("boom")
	}
	for _, id := range f.order {
		if f.hasDoc[id] || f.pool[id] > 0 {
			return id, true, nil
		}
	}
	return "", false, nil
}

func (f *fakePurger) PurgePoolPage(_ context.Context, _, id string, limit int) (int, error) {
	if f.failOn == "pool" {
		return 0, errors.New("boom")
	}
	f.queries = append(f.queries, limit)
	n := min(f.pool[id], limit)
	f.pool[id] -= n
	return n, nil
}

func (f *fakePurger) DeleteDevice(_ context.Context, _, id string) error {
	if f.failOn == "device" {
		return errors.New("boom")
	}
	f.hasDoc[id] = false
	return nil
}

func TestEraser_PurgeUser(t *testing.T) {
	newF := func() *fakePurger {
		return &fakePurger{
			order:  []string{"a", "b", "orphan"},
			pool:   map[string]int{"a": 100, "b": 250, "orphan": 3},
			hasDoc: map[string]bool{"a": true, "b": true}, // "orphan" has pool documents but no device document
		}
	}
	t.Run("runs to completion one device per call, resuming from each checkpoint", func(t *testing.T) {
		f := newF()
		e := NewEraser(f)
		var cp Checkpoint
		calls := 0
		for {
			next, done, err := e.PurgeUser(context.Background(), "u", cp)
			if err != nil {
				t.Fatal(err)
			}
			calls++
			cp = next
			if done || calls > 10 {
				break
			}
		}
		if calls != 4 || cp.Devices != 3 || cp.LastDevice != "orphan" {
			t.Errorf("calls=%d checkpoint=%+v, want 4 calls (3 devices then an empty listing) and 3 devices, last orphan", calls, cp)
		}
		for _, id := range f.order {
			if f.hasDoc[id] || f.pool[id] != 0 {
				t.Errorf("device %s not erased", id)
			}
		}
		for _, l := range f.queries {
			if l > 100 {
				t.Errorf("a pool page asked for %d documents", l)
			}
		}
	})
	t.Run("no devices is done at once", func(t *testing.T) {
		cp, done, err := NewEraser(&fakePurger{pool: map[string]int{}, hasDoc: map[string]bool{}}).PurgeUser(context.Background(), "u", Checkpoint{})
		if err != nil || !done || cp != (Checkpoint{}) {
			t.Errorf("cp=%+v done=%v err=%v", cp, done, err)
		}
	})
	t.Run("a long pool continues on the next call", func(t *testing.T) {
		f := &fakePurger{order: []string{"a"}, pool: map[string]int{"a": (maxPagesPerRun + 2) * purgePage}, hasDoc: map[string]bool{"a": true}}
		e := NewEraser(f)
		cp, done, err := e.PurgeUser(context.Background(), "u", Checkpoint{})
		if err != nil || done || cp.Devices != 0 || !f.hasDoc["a"] {
			t.Fatalf("first call: cp=%+v done=%v err=%v hasDoc=%v", cp, done, err, f.hasDoc["a"])
		}
		cp, _, err = e.PurgeUser(context.Background(), "u", cp)
		if err != nil || cp.Devices != 1 || f.hasDoc["a"] || f.pool["a"] != 0 {
			t.Fatalf("second call: cp=%+v err=%v", cp, err)
		}
	})
	for _, where := range []string{"list", "pool", "device"} {
		t.Run("error in "+where+" keeps the checkpoint", func(t *testing.T) {
			f := newF()
			f.failOn = where
			in := Checkpoint{Devices: 1, LastDevice: "x"}
			cp, done, err := NewEraser(f).PurgeUser(context.Background(), "u", in)
			if err == nil || done || cp != in {
				t.Errorf("cp=%+v done=%v err=%v", cp, done, err)
			}
		})
	}
}
