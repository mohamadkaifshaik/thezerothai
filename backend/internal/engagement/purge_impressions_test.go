package engagement

import (
	"context"
	"errors"
	"testing"
)

type fakeImpressionPurger struct {
	pages []int
	err   error
	calls int
}

func (f *fakeImpressionPurger) PurgeImpressionsPage(context.Context, string) (int, error) {
	f.calls++
	if f.err != nil {
		return 0, f.err
	}
	n := f.pages[0]
	f.pages = f.pages[1:]
	return n, nil
}

// TestImpressionEraser_PagesUntilShort: a full page is not done, a short (or empty) page is, the count accumulates,
// and an error keeps the checkpoint.
func TestImpressionEraser_PagesUntilShort(t *testing.T) {
	f := &fakeImpressionPurger{pages: []int{impressionPage, 7}}
	e := NewImpressionEraser(f)
	cp, done, err := e.PurgeUser(context.Background(), "u", ImpressionCheckpoint{})
	if err != nil || done || cp.Deleted != impressionPage {
		t.Fatalf("full page: %+v %v %v", cp, done, err)
	}
	cp, done, err = e.PurgeUser(context.Background(), "u", cp)
	if err != nil || !done || cp.Deleted != impressionPage+7 {
		t.Fatalf("short page: %+v %v %v", cp, done, err)
	}
	empty := NewImpressionEraser(&fakeImpressionPurger{pages: []int{0}})
	if _, done, err := empty.PurgeUser(context.Background(), "u", ImpressionCheckpoint{}); err != nil || !done {
		t.Fatalf("empty: %v %v", done, err)
	}
	boom := errors.New("boom")
	failing := NewImpressionEraser(&fakeImpressionPurger{err: boom})
	if cp, _, err := failing.PurgeUser(context.Background(), "u", ImpressionCheckpoint{Deleted: 3}); !errors.Is(err, boom) || cp.Deleted != 3 {
		t.Fatalf("error: %+v %v", cp, err)
	}
}
