package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
)

func TestParseHiddenArgs(t *testing.T) {
	t.Parallel()
	const cid = "0000000000000007001"
	cases := []struct {
		name string
		sub  string
		cid  string
		a    modArgs
		ok   bool
	}{
		{"hidden", "hidden", cid, modArgs{}, true},
		{"hidden with token", "hidden", cid, modArgs{pageToken: "h1.0000000000000007101"}, true},
		{"restore-hidden full", "restore-hidden", cid, modArgs{since: "2026-11-02T09:30:00Z", dryRun: true}, true},
		{"no id", "hidden", "", modArgs{}, false},
		{"short id", "restore-hidden", "12", modArgs{}, false},
		{"hidden is read-only", "hidden", cid, modArgs{dryRun: true}, false},
		{"hidden has no since", "hidden", cid, modArgs{since: "2026-11-02T09:30:00Z"}, false},
		{"bad since", "restore-hidden", cid, modArgs{since: "yesterday"}, false},
		{"bad token", "restore-hidden", cid, modArgs{pageToken: "0000000000000007101"}, false},
		{"token with junk", "hidden", cid, modArgs{pageToken: "h1.12x"}, false},
		{"limit is not for this", "hidden", cid, modArgs{limit: 10}, false},
		{"report is not for this", "restore-hidden", cid, modArgs{report: strings.Repeat("a", 32)}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			err := parseHiddenArgs(tc.sub, tc.cid, tc.a)
			if (err == nil) != tc.ok {
				t.Errorf("err = %v, want ok=%v", err, tc.ok)
			}
		})
	}
}

// fakeHidden is a communities.HiddenRecovery whose pages are all full; it fails on page failAt (1-based; 0 = never) or reports a missing community.
type fakeHidden struct {
	pages, failAt int
	missing       bool
}

func (f *fakeHidden) ListHidden(context.Context, string, string, int) ([]communities.HiddenRow, string, error) {
	return nil, "", nil
}

func (f *fakeHidden) RestoreHidden(_ context.Context, p communities.RestoreHiddenParams) (communities.RestoreHiddenResult, error) {
	if f.missing {
		return communities.RestoreHiddenResult{}, communities.ErrNotFound
	}
	f.pages++
	if f.pages == f.failAt {
		return communities.RestoreHiddenResult{}, errors.New("boom")
	}
	return communities.RestoreHiddenResult{Listed: p.Limit, Restored: p.Limit, Last: fmt.Sprintf("%019d", f.pages), EntryWritten: p.WriteEntry}, nil
}

func runRestoreHidden(t *testing.T, f *fakeHidden) (code int, out string) {
	t.Helper()
	open := func(context.Context, string) (*backends, error) { return &backends{hidden: f, close: func() {}}, nil }
	var o, e bytes.Buffer
	code = run(context.Background(), []string{"community", "restore-hidden", "0000000000000007001", "--project", "demo-x"}, strings.NewReader(""), &o, &e, open, time.Now)
	return code, o.String() + e.String()
}

// M-1: an error on page 2 is reported as an error with the resume token of the failed page, not as the page cap; a missing community prints no
// summary and no audit line; the cap message appears only when page 100 itself was full.
func TestRestoreHidden_EndOfRunOutput(t *testing.T) {
	old := hiddenPageSize
	hiddenPageSize = 2
	t.Cleanup(func() { hiddenPageSize = old })

	code, out := runRestoreHidden(t, &fakeHidden{failAt: 2})
	if code != 1 {
		t.Errorf("mid-run error: code = %d", code)
	}
	for _, w := range []string{"listed=2 restored=2", "error after 1 pages; resume with --page-token h1.0000000000000000001", "outcome=error", "boom"} {
		if !strings.Contains(out, w) {
			t.Errorf("mid-run error: output lacks %q:\n%s", w, out)
		}
	}
	if strings.Contains(out, "page cap") {
		t.Errorf("mid-run error printed the cap message:\n%s", out)
	}

	code, out = runRestoreHidden(t, &fakeHidden{missing: true})
	if code != 1 || !strings.Contains(out, "no such community") || strings.Contains(out, "audit:") || strings.Contains(out, "modlog:") || strings.Contains(out, "restored:") {
		t.Errorf("missing community: code=%d\n%s", code, out)
	}

	code, out = runRestoreHidden(t, &fakeHidden{})
	if code != 0 || !strings.Contains(out, "stopped at the page cap (100 pages)") || !strings.Contains(out, "outcome=capped") || !strings.Contains(out, "listed=200 restored=200") {
		t.Errorf("capped: code=%d\n%s", code, out)
	}
}

// N-3: communityEntryBound names timeline's communityEntryMaxAge (an unexported constant), so the test reads its source.
func TestCommunityEntryBoundTracksTimeline(t *testing.T) {
	src, err := os.ReadFile("../../internal/timeline/service_community.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "communityEntryMaxAge = 5 * time.Minute") || communityEntryBound != "5 minutes" {
		t.Errorf("communityEntryMaxAge and communityEntryBound (%q) disagree", communityEntryBound)
	}
}
