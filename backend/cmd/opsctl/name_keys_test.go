package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// fakeNameKeys pages over n documents with ids 1..n, every third stale; with write the stale ones become written except the
// ids in skip (a rename raced the backfill).
type fakeNameKeys struct {
	n      int
	skip   map[int]bool
	fail   int // fail on this page (1-based), 0 = never
	calls  int
	writes []bool
}

func (f *fakeNameKeys) BackfillNameKeys(_ context.Context, after string, limit int, write bool) (namekey.BackfillPage, error) {
	f.calls++
	f.writes = append(f.writes, write)
	if f.fail == f.calls {
		return namekey.BackfillPage{}, errors.New("firestore down")
	}
	start := 1
	if after != "" {
		n, err := strconv.Atoi(after)
		if err != nil {
			return namekey.BackfillPage{}, err
		}
		start = n + 1
	}
	var p namekey.BackfillPage
	for i := start; i <= f.n && p.Scanned < limit; i++ {
		p.Scanned++
		p.Last = fmt.Sprintf("%019d", i)
		if i%3 == 0 {
			p.Stale++
			if write && f.skip[i] {
				p.Skipped++
			} else if write {
				p.Written++
			}
		}
	}
	p.Done = p.Scanned < limit
	return p, nil
}

func runNameKeys(lists, comm *fakeNameKeys, args ...string) (int, string, string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{listNameKeys: lists, communityNameKeys: comm, close: func() {}}, nil
	}
	code := run(context.Background(), args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return time.Unix(1_000_000, 0) })
	return code, out.String(), errOut.String()
}

func TestBackfillNameKeys_Usage(t *testing.T) {
	t.Parallel()
	for name, args := range map[string][]string{
		"no sub":               {"search", "--project", "demo-x"},
		"unknown sub":          {"search", "reindex", "--project", "demo-x"},
		"bad collection":       {"search", "backfill-name-keys", "--project", "demo-x", "--collection", "posts"},
		"no collection":        {"search", "backfill-name-keys", "--project", "demo-x"},
		"bad after":            {"search", "backfill-name-keys", "--project", "demo-x", "--collection", "lists", "--after", "x"},
		"bad max pages":        {"search", "backfill-name-keys", "--project", "demo-x", "--collection", "lists", "--max-pages", "-1"},
		"too many pages":       {"search", "backfill-name-keys", "--project", "demo-x", "--collection", "lists", "--max-pages", "501"},
		"missing project":      {"search", "backfill-name-keys", "--collection", "lists"},
		"collection elsewhere": {"recount-list-follows", "--project", "demo-x", "--list", "1234567890123456789", "--collection", "lists"},
	} {
		t.Run(name, func(t *testing.T) {
			l := &fakeNameKeys{n: 10}
			if code, _, _ := runNameKeys(l, &fakeNameKeys{}, args...); code != 2 {
				t.Fatalf("exit = %d, want 2", code)
			}
		})
	}
}

func TestBackfillNameKeys_DryRunWriteAndResume(t *testing.T) {
	t.Parallel()
	// Dry run by default: nothing written, the stale count printed.
	l := &fakeNameKeys{n: 450}
	code, out, errOut := runNameKeys(l, &fakeNameKeys{}, "search", "backfill-name-keys", "--project", "demo-x", "--collection", "lists")
	if code != 0 || !strings.Contains(out, "lists (dry-run): scanned=450 stale=150 written=0 skipped=0") || !strings.Contains(out, "re-run with --write") {
		t.Fatalf("exit %d out %q err %q", code, out, errOut)
	}
	for _, w := range l.writes {
		if w {
			t.Fatal("a dry run asked for writes")
		}
	}
	if l.calls != 3 {
		t.Fatalf("pages = %d, want 3 (200, 200, 50)", l.calls)
	}

	// --write on communities, a raced rename skipped, capped at one page with the resume id printed.
	c := &fakeNameKeys{n: 450, skip: map[int]bool{3: true}}
	code, out, _ = runNameKeys(&fakeNameKeys{}, c, "search", "backfill-name-keys", "--project", "demo-x", "--collection", "communities", "--write", "--max-pages", "1")
	if code != 0 || !strings.Contains(out, "communities (write): scanned=200 stale=66 written=65 skipped=1") ||
		!strings.Contains(out, "resume with --after 0000000000000000200") {
		t.Fatalf("exit %d out %q", code, out)
	}
	code, out, _ = runNameKeys(&fakeNameKeys{}, c, "search", "backfill-name-keys", "--project", "demo-x", "--collection", "communities", "--write", "--after", "0000000000000000200")
	if code != 0 || !strings.Contains(out, "scanned=250") || !strings.Contains(out, "done") {
		t.Fatalf("resume: exit %d out %q", code, out)
	}
}

func TestBackfillNameKeys_FailurePrintsResumePoint(t *testing.T) {
	t.Parallel()
	l := &fakeNameKeys{n: 900, fail: 2}
	code, out, errOut := runNameKeys(l, &fakeNameKeys{}, "search", "backfill-name-keys", "--project", "demo-x", "--collection", "lists", "--write")
	if code != 1 || !strings.Contains(out, "resume with --after 0000000000000000200") || !strings.Contains(errOut, "firestore down") {
		t.Fatalf("exit %d out %q err %q", code, out, errOut)
	}
}
