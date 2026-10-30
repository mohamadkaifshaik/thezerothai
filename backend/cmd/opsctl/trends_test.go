package main

import (
	"bytes"
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeTrends is a search.TrendsStore for the hide commands. The embedded nil interface covers Get, Put and Load, which
// opsctl never calls (a call would panic the test, on purpose).
type fakeTrends struct {
	search.TrendsStore
	keys []string
	err  error
}

func (f *fakeTrends) Hidden(ctx context.Context) ([]string, error) {
	budget.FromContext(ctx).AddReads(1)
	return slices.Clone(f.keys), f.err
}

func (f *fakeTrends) Hide(ctx context.Context, tag string) (search.HideResult, error) {
	key, err := search.HideKey(tag)
	if err != nil {
		return search.HideResult{}, err
	}
	budget.FromContext(ctx).AddReads(1)
	if f.err != nil {
		return search.HideResult{}, f.err
	}
	if slices.Contains(f.keys, key) {
		return search.HideResult{Key: key, Count: len(f.keys)}, nil
	}
	if len(f.keys) >= 100 {
		return search.HideResult{Key: key, Count: len(f.keys)}, search.ErrHiddenFull
	}
	f.keys = append(f.keys, key)
	budget.FromContext(ctx).AddWrites(1)
	return search.HideResult{Key: key, Changed: true, Count: len(f.keys)}, nil
}

func (f *fakeTrends) Unhide(ctx context.Context, tag string) (search.HideResult, error) {
	key, err := search.HideKey(tag)
	if err != nil {
		return search.HideResult{}, err
	}
	budget.FromContext(ctx).AddReads(1)
	i := slices.Index(f.keys, key)
	if i < 0 {
		return search.HideResult{Key: key, Count: len(f.keys)}, nil
	}
	f.keys = slices.Delete(f.keys, i, i+1)
	budget.FromContext(ctx).AddWrites(1)
	return search.HideResult{Key: key, Changed: true, Count: len(f.keys)}, nil
}

func runTrends(f *fakeTrends, stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{trends: f, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestTrends_UsageAndValidation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no sub-command", []string{"trends", "--project", "dzeroth-dev"}, "trends needs a sub-command"},
		{"unknown sub-command", []string{"trends", "purge", "--project", "dzeroth-dev"}, "trends needs a sub-command"},
		{"unknown sub-command with a stray argument", []string{"trends", "purge", "x", "--project", "dzeroth-dev"}, "unexpected argument"},
		{"hide without a tag", []string{"trends", "hide", "--project", "dzeroth-dev"}, "needs the tag"},
		{"unhide without a tag", []string{"trends", "unhide", "--project", "dzeroth-dev"}, "needs the tag"},
		{"a tag that folds to nothing", []string{"trends", "hide", "_", "--project", "dzeroth-dev"}, "no letters left"},
		{"a tag longer than a hashtag", []string{"trends", "hide", strings.Repeat("a", 51), "--project", "dzeroth-dev"}, "longer than a hashtag"},
		{"list takes no tag", []string{"trends", "list", "x", "--project", "dzeroth-dev"}, "unexpected argument"},
		{"no project", []string{"trends", "hide", "x"}, "--project is required"},
		{"dry-run is not offered", []string{"trends", "hide", "x", "--project", "dzeroth-dev", "--dry-run"}, "--dry-run is not supported by trends"},
		{"a stray argument", []string{"trends", "hide", "x", "y", "--project", "dzeroth-dev"}, "unexpected argument"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := &fakeTrends{}
			code, out, errOut := runTrends(f, "", tc.args...)
			if code != 2 || !strings.Contains(errOut, tc.want) {
				t.Fatalf("code %d, stderr %q, want 2 and %q", code, errOut, tc.want)
			}
			if len(f.keys) != 0 || out != "" {
				t.Errorf("a usage error wrote %v / printed %q", f.keys, out)
			}
		})
	}
}

func TestTrends_HideUnhideList(t *testing.T) {
	t.Parallel()
	f := &fakeTrends{}

	code, out, errOut := runTrends(f, "", "trends", "hide", "#Sl_u\u200dr", "--project", "dzeroth-dev")
	if code != 0 || errOut != "" {
		t.Fatalf("hide: code %d stderr %q", code, errOut)
	}
	for _, want := range []string{`hidden: "slur" (1 on the list)`, "within 10 min", "audit: trends hide project=dzeroth-dev at=1970-01-12T13:46:40Z key=slur wrote=true count=1", "cost: reads=1 writes=1"} {
		if !strings.Contains(out, want) {
			t.Errorf("hide output lacks %q:\n%s", want, out)
		}
	}

	// A repeat writes nothing.
	code, out, _ = runTrends(f, "", "trends", "hide", "SLUR", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, "already hidden") || !strings.Contains(out, "wrote=false") || !strings.Contains(out, "cost: reads=1 writes=0") {
		t.Errorf("repeat hide: code %d\n%s", code, out)
	}

	code, out, _ = runTrends(f, "", "trends", "list", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, "1 hidden key(s)\nslur\n") || !strings.Contains(out, "cost: reads=1 writes=0") {
		t.Errorf("list: code %d\n%s", code, out)
	}

	code, out, _ = runTrends(f, "", "trends", "unhide", "slur", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, `unhidden: "slur" (0 on the list)`) || !strings.Contains(out, "audit: trends unhide") || !strings.Contains(out, "cost: reads=1 writes=1") {
		t.Errorf("unhide: code %d\n%s", code, out)
	}

	// Unhiding what is not there is success with 0 writes.
	code, out, _ = runTrends(f, "", "trends", "unhide", "slur", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, "not on the hide list") || !strings.Contains(out, "cost: reads=1 writes=0") {
		t.Errorf("unhide again: code %d\n%s", code, out)
	}
}

func TestTrends_FullListAndStoreErrors(t *testing.T) {
	t.Parallel()
	full := &fakeTrends{}
	for i := range 100 {
		full.keys = append(full.keys, strings.Repeat("k", 1)+string(rune('a'+i%26))+strings.Repeat("z", i/26))
	}
	code, _, errOut := runTrends(full, "", "trends", "hide", "onemore", "--project", "dzeroth-dev")
	if code != 1 || !strings.Contains(errOut, "hide list is full") || len(full.keys) != 100 {
		t.Errorf("full list: code %d stderr %q keys %d", code, errOut, len(full.keys))
	}
	bad := &fakeTrends{err: errors.New("unavailable")}
	if code, _, errOut = runTrends(bad, "", "trends", "list", "--project", "dzeroth-dev"); code != 1 || !strings.Contains(errOut, "unavailable") {
		t.Errorf("list error: code %d stderr %q", code, errOut)
	}
}

func TestTrends_ProdAsksForTheTypedProject(t *testing.T) {
	t.Parallel()
	f := &fakeTrends{}
	if code, _, errOut := runTrends(f, "wrong\n", "trends", "hide", "x", "--project", "dzeroth-prod"); code != 1 || !strings.Contains(errOut, "aborted") || len(f.keys) != 0 {
		t.Fatalf("wrong confirmation: code %d stderr %q keys %v", code, errOut, f.keys)
	}
	if code, _, _ := runTrends(f, "dzeroth-prod\n", "trends", "hide", "x", "--project", "dzeroth-prod"); code != 0 || !slices.Equal(f.keys, []string{"x"}) {
		t.Fatalf("right confirmation: code %d keys %v", code, f.keys)
	}
}
