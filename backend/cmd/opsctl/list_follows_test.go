package main

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
)

// fakeRecounter returns a fixed recount: the dry-run result, or with write the same result marked Written unless in step.
type fakeRecounter struct{ res lists.FollowRecount }

func (f fakeRecounter) RecountFollowers(_ context.Context, _ string, write bool) (lists.FollowRecount, error) {
	r := f.res
	if write && !r.InStep() {
		r.Written = true
	}
	return r, nil
}

func (fakeRecounter) MissingFollowerCount(context.Context, string, int) (lists.MissingFollowerCountPage, error) {
	return lists.MissingFollowerCountPage{}, nil
}

func TestRecountListFollows_Output(t *testing.T) {
	cases := []struct {
		name  string
		res   lists.FollowRecount
		write bool
		want  []string
	}{
		{"in step", lists.FollowRecount{Stored: 2, Counted: 2}, true, []string{"followerCount=2 markers=2", "in step: nothing to write"}},
		{"drift dry run", lists.FollowRecount{Stored: 3, Counted: 2}, false, []string{"followerCount=3 markers=2", "dry-run: would set followerCount to 2"}},
		{"missing dry run", lists.FollowRecount{Counted: 0, Missing: true}, false, []string{"followerCount=missing markers=0", "dry-run: would set followerCount to 0"}},
		{"missing write", lists.FollowRecount{Counted: 0, Missing: true}, true, []string{"followerCount=missing markers=0", "set followerCount to 0"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			b := &backends{listFollows: fakeRecounter{res: tc.res}}
			if err := recountListFollows(context.Background(), b, recountListFollowsArgs{list: testListID, write: tc.write}, &out); err != nil {
				t.Fatal(err)
			}
			for _, w := range tc.want {
				if !strings.Contains(out.String(), w) {
					t.Errorf("output %q lacks %q", out.String(), w)
				}
			}
			if strings.Contains(out.String(), "nothing to write") && tc.res.Missing {
				t.Errorf("missing field reported as in step: %q", out.String())
			}
		})
	}
}

// pagedMissing serves pages of listFollowsScanPage ids, every one missing the field, up to total ids; RecountFollowers
// writes each. It records how many repairs ran.
type pagedMissing struct {
	total    int
	repaired int
}

func (p *pagedMissing) RecountFollowers(context.Context, string, bool) (lists.FollowRecount, error) {
	p.repaired++
	return lists.FollowRecount{Missing: true, Written: true}, nil
}

func (p *pagedMissing) MissingFollowerCount(_ context.Context, after string, limit int) (lists.MissingFollowerCountPage, error) {
	start := 0
	if after != "" {
		if _, err := fmt.Sscanf(after, "%d", &start); err != nil {
			return lists.MissingFollowerCountPage{}, fmt.Errorf("fake: bad after %q: %w", after, err)
		}
	}
	var page lists.MissingFollowerCountPage
	for i := start + 1; i <= p.total && page.Scanned < limit; i++ {
		id := fmt.Sprintf("%019d", i)
		page.Scanned++
		page.Missing = append(page.Missing, id)
		page.Last = id
	}
	return page, nil
}

func TestRecountListFollows_AllMissingStopsAtTheWriteCap(t *testing.T) {
	f := &pagedMissing{total: listFollowsMaxWrites + 2*listFollowsScanPage}
	var out bytes.Buffer
	if err := recountListFollows(context.Background(), &backends{listFollows: f}, recountListFollowsArgs{allMissing: true, write: true}, &out); err != nil {
		t.Fatal(err)
	}
	if f.repaired != listFollowsMaxWrites {
		t.Fatalf("repaired %d, want exactly the cap %d", f.repaired, listFollowsMaxWrites)
	}
	checkpoint := fmt.Sprintf("%019d", listFollowsMaxWrites)
	if !strings.Contains(out.String(), "write cap of 5000 reached: rerun with --all-missing --write --after "+checkpoint) {
		t.Fatalf("output lacks the cap checkpoint %s:\n%s", checkpoint, out.String())
	}

	// Resuming from the checkpoint repairs the rest and completes.
	f.repaired = 0
	out.Reset()
	if err := recountListFollows(context.Background(), &backends{listFollows: f}, recountListFollowsArgs{allMissing: true, write: true, after: checkpoint}, &out); err != nil {
		t.Fatal(err)
	}
	if f.repaired != 2*listFollowsScanPage || !strings.Contains(out.String(), "complete:") {
		t.Fatalf("resume repaired %d, want %d; output:\n%s", f.repaired, 2*listFollowsScanPage, out.String())
	}
}

func TestRecountListFollows_AllMissingDryRunWritesNothing(t *testing.T) {
	f := &pagedMissing{total: 7}
	var out bytes.Buffer
	if err := recountListFollows(context.Background(), &backends{listFollows: f}, recountListFollowsArgs{allMissing: true}, &out); err != nil {
		t.Fatal(err)
	}
	if f.repaired != 0 || !strings.Contains(out.String(), "dry-run: scanned=7 missing=7 would_write=7") {
		t.Fatalf("dry run repaired %d; output:\n%s", f.repaired, out.String())
	}
}
