package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
)

// fakeBannerMedia serves pages from a fixed number of legacy banners; with apply it erases them.
type fakeBannerMedia struct {
	left   int
	err    error
	calls  []string // "after/dryRun"
	dryRun []bool
}

func (f *fakeBannerMedia) PurgeLegacyBanners(_ context.Context, after string, limit int, dryRun bool) (media.LegacyBannerPage, error) {
	f.calls = append(f.calls, after)
	f.dryRun = append(f.dryRun, dryRun)
	if f.err != nil {
		return media.LegacyBannerPage{}, f.err
	}
	// A dry run pages past what it listed; an applied page erases what it found, so the next call starts over.
	skip := 0
	if dryRun && after != "" {
		skip = len(strings.Split(after, ","))
	}
	n := min(f.left-skip, limit)
	if n < 0 {
		n = 0
	}
	p := media.LegacyBannerPage{Found: n}
	if n > 0 {
		p.Last = strings.TrimPrefix(after+strings.Repeat(",x", n), ",")
	}
	if !dryRun {
		p.Deleted = n
		f.left -= n
	}
	return p, nil
}

// fakeBannerProfiles scans `total` users documents of which `holding` hold the legacy fields.
type fakeBannerProfiles struct {
	total, holding int
	err            error
	afters         []string
	dryRun         []bool
}

func (f *fakeBannerProfiles) ClearLegacyBannerFields(_ context.Context, after string, limit int, dryRun bool) (identity.LegacyBannerFieldsPage, error) {
	f.afters = append(f.afters, after)
	f.dryRun = append(f.dryRun, dryRun)
	if f.err != nil {
		return identity.LegacyBannerFieldsPage{}, f.err
	}
	start := len(f.afters) - 1
	n := min(f.total-start*limit, limit)
	if n < 0 {
		n = 0
	}
	p := identity.LegacyBannerFieldsPage{Scanned: n, Last: "u" + strings.Repeat("x", start+1)}
	if start == 0 {
		p.Found = f.holding
		if !dryRun {
			p.Cleared = f.holding
		}
	}
	return p, nil
}

func runPurgeBanners(t *testing.T, m *fakeBannerMedia, u *fakeBannerProfiles, stdin string, args ...string) (int, string, string) {
	t.Helper()
	open := func(context.Context, string) (*backends, error) {
		return &backends{bannerMedia: m, bannerProfiles: u, close: func() {}}, nil
	}
	var out, errOut bytes.Buffer
	code := run(context.Background(), append([]string{"purge-banners"}, args...), strings.NewReader(stdin), &out, &errOut, open, time.Now)
	return code, out.String(), errOut.String()
}

func TestPurgeBanners_DryRunByDefault(t *testing.T) {
	t.Parallel()
	for _, extra := range [][]string{nil, {"--dry-run"}} {
		m, u := &fakeBannerMedia{left: 150}, &fakeBannerProfiles{total: 250, holding: 3}
		code, out, errOut := runPurgeBanners(t, m, u, "", append([]string{"--project", "dzeroth-dev"}, extra...)...)
		if code != 0 {
			t.Fatalf("%v: code=%d stderr=%q", extra, code, errOut)
		}
		for _, d := range append(m.dryRun, u.dryRun...) {
			if !d {
				t.Fatalf("%v: a call was not a dry run (media %v users %v)", extra, m.dryRun, u.dryRun)
			}
		}
		if m.left != 150 {
			t.Errorf("%v: a dry run erased media", extra)
		}
		if len(m.calls) != 2 || m.calls[1] == "" {
			t.Errorf("%v: media pages = %q, want two, the second after the first page's checkpoint", extra, m.calls)
		}
		if len(u.afters) != 3 || u.afters[0] != "" || u.afters[1] != "ux" || u.afters[2] != "uxx" {
			t.Errorf("%v: users pages = %q, want three, each after the previous checkpoint", extra, u.afters)
		}
		if !strings.Contains(out, "dry-run: media documents to erase=150, users documents to clear=3 of 250 scanned (nothing written; pass --apply)") {
			t.Errorf("%v: out = %s", extra, out)
		}
	}
}

func TestPurgeBanners_ApplyErasesAndIsIdempotent(t *testing.T) {
	t.Parallel()
	m, u := &fakeBannerMedia{left: 150}, &fakeBannerProfiles{total: 40, holding: 2}
	code, out, errOut := runPurgeBanners(t, m, u, "", "--project", "dzeroth-dev", "--apply")
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, errOut)
	}
	if m.left != 0 || len(m.calls) != 2 || m.calls[0] != "" || m.calls[1] != "" {
		t.Errorf("media left %d calls %q: an applied run restarts from the first page (the erased documents are gone)", m.left, m.calls)
	}
	if !strings.Contains(out, "purge-banners: complete: media documents erased=150 (objects first), users documents cleared=2 of 40 scanned") {
		t.Errorf("out = %s", out)
	}
	// A rerun finds nothing.
	u2 := &fakeBannerProfiles{total: 40}
	if code, out, _ := runPurgeBanners(t, m, u2, "", "--project", "dzeroth-dev", "--apply"); code != 0 || !strings.Contains(out, "media documents erased=0") {
		t.Errorf("rerun: code=%d out=%s", code, out)
	}
}

func TestPurgeBanners_UsageAndErrors(t *testing.T) {
	t.Parallel()
	for name, args := range map[string][]string{
		"apply and dry-run":    {"--project", "dzeroth-dev", "--apply", "--dry-run"},
		"no project":           {"--apply"},
		"a stray argument":     {"--project", "dzeroth-dev", "now"},
		"--after is not taken": {"--project", "dzeroth-dev", "--after", "0000000000000000001"},
	} {
		m, u := &fakeBannerMedia{}, &fakeBannerProfiles{}
		if code, _, errOut := runPurgeBanners(t, m, u, "", args...); code != 2 || len(m.calls)+len(u.afters) != 0 {
			t.Errorf("%s: code=%d calls=%d stderr=%q, want a usage error before anything runs", name, code, len(m.calls)+len(u.afters), errOut)
		}
	}
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) { return &backends{close: func() {}}, nil }
	if code := run(context.Background(), []string{"backfill-has-media", "--project", "dzeroth-dev", "--apply"}, strings.NewReader(""), &out, &errOut, open, time.Now); code != 2 {
		t.Errorf("--apply on another command: code=%d", code)
	}

	m, u := &fakeBannerMedia{err: errors.New("gcs down")}, &fakeBannerProfiles{}
	if code, _, errOut := runPurgeBanners(t, m, u, "", "--project", "dzeroth-dev", "--apply"); code != 1 || !strings.Contains(errOut, "rerun") || len(u.afters) != 0 {
		t.Errorf("media failure: code=%d stderr=%q users calls=%d, want exit 1, the rerun hint and no users phase", code, errOut, len(u.afters))
	}
	m, u = &fakeBannerMedia{}, &fakeBannerProfiles{err: errors.New("firestore down")}
	if code, _, errOut := runPurgeBanners(t, m, u, "", "--project", "dzeroth-dev", "--apply"); code != 1 || !strings.Contains(errOut, "users phase") {
		t.Errorf("users failure: code=%d stderr=%q", code, errOut)
	}
	if code, _, errOut := runPurgeBanners(t, &fakeBannerMedia{}, &fakeBannerProfiles{}, "wrong\n", "--project", "dzeroth-prod", "--apply"); code != 1 || !strings.Contains(errOut, "aborted") {
		t.Errorf("prod without the typed confirmation: code=%d stderr=%q", code, errOut)
	}
	var out2, errOut2 bytes.Buffer
	none := func(context.Context, string) (*backends, error) { return &backends{close: func() {}}, nil }
	if code := run(context.Background(), []string{"purge-banners", "--project", "dzeroth-dev"}, strings.NewReader(""), &out2, &errOut2, none, time.Now); code != 1 {
		t.Errorf("no repos wired: code=%d", code)
	}
}
