package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const testCutUID = "uidCutAbCdEfGhIjKlMnOpQrSt"

// fakeCutClearer is identity's ClearSessionCut over one in-memory users doc.
type fakeCutClearer struct {
	exists bool
	cut    time.Time
	err    error
	calls  int
}

func (f *fakeCutClearer) ClearSessionCut(_ context.Context, uid string) (time.Time, error) {
	f.calls++
	if f.err != nil {
		return time.Time{}, f.err
	}
	if !f.exists {
		return time.Time{}, identity.ErrNotFound
	}
	c := f.cut
	f.cut = time.Time{}
	return c, nil
}

func runIdentity(f *fakeCutClearer, stdin string, args ...string) (code int, stdout, stderr string, opened bool) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		opened = true
		return &backends{sessionCuts: f, close: func() {}}, nil
	}
	now := func() time.Time { return time.Date(2026, 11, 23, 10, 0, 0, 0, time.UTC) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String(), opened
}

// TestIdentitySessionsClearCut_Usage: every malformed invocation is exit 2 before anything is opened.
func TestIdentitySessionsClearCut_Usage(t *testing.T) {
	for _, args := range [][]string{
		{"identity"},
		{"identity", "sessions"},
		{"identity", "sessions", "list", "--project", "demo-x", "--user", testCutUID},
		{"identity", "other", "clear-cut", "--project", "demo-x", "--user", testCutUID},
		{"identity", "sessions", "clear-cut", "--user", testCutUID},                       // no --project
		{"identity", "sessions", "clear-cut", "--project", "demo-x"},                      // no --user
		{"identity", "sessions", "clear-cut", "--project", "demo-x", "--user", "bad_uid"}, // malformed uid
		{"identity", "sessions", "clear-cut", "--project", "demo-x", "--uid", testCutUID}, // --uid is not this command's
		{"identity", "sessions", "clear-cut", "--project", "demo-x", "--user", testCutUID, "--dry-run"},
		{"identity", "sessions", "clear-cut", "--project", "demo-x", "--user", testCutUID, "stray"},
	} {
		f := &fakeCutClearer{exists: true, cut: time.Now()}
		code, _, _, opened := runIdentity(f, "", args...)
		if code != 2 || opened || f.calls != 0 {
			t.Errorf("%v: code %d, opened %v, calls %d; want 2 with nothing opened", args, code, opened, f.calls)
		}
	}
}

// TestIdentitySessionsClearCut: a cut is removed with a fixed-shape audit line that carries the keyed uid_hash, never the
// uid or the cut time; a repeat writes nothing; a missing account is exit 1; a prod project needs the typed confirmation.
func TestIdentitySessionsClearCut(t *testing.T) {
	hash := keyedAuditUIDHash(t, testCutUID)
	cut := time.Date(2026, 11, 22, 8, 30, 0, 0, time.UTC)
	f := &fakeCutClearer{exists: true, cut: cut}
	code, out, errOut, _ := runIdentity(f, "", "identity", "sessions", "clear-cut", "--project", "demo-x", "--user", testCutUID)
	if code != 0 {
		t.Fatalf("code %d, stderr %s", code, errOut)
	}
	wantAudit := "audit: NOTICE identity sessions clear-cut project=demo-x at=2026-11-23T10:00:00Z uid_hash=" + hash + " wrote=true\n"
	if !strings.Contains(out, wantAudit) {
		t.Errorf("stdout = %q, want the audit line %q", out, wantAudit)
	}
	if strings.Contains(out+errOut, testCutUID) || strings.Contains(out+errOut, "2026-11-22") || strings.Contains(out+errOut, plainHash(testCutUID)) {
		t.Errorf("output names the uid, the cut time or the plain hash: %q %q", out, errOut)
	}

	code, out, _, _ = runIdentity(f, "", "identity", "sessions", "clear-cut", "--project", "demo-x", "--user", testCutUID)
	if code != 0 || !strings.Contains(out, "wrote=false") || !strings.Contains(out, "no session cut") {
		t.Errorf("repeat: code %d, stdout %q; want 0, wrote=false", code, out)
	}

	code, _, errOut, _ = runIdentity(&fakeCutClearer{}, "", "identity", "sessions", "clear-cut", "--project", "demo-x", "--user", testCutUID)
	if code != 1 || !strings.Contains(errOut, "no such user") {
		t.Errorf("missing account: code %d, stderr %q", code, errOut)
	}
	code, _, errOut, _ = runIdentity(&fakeCutClearer{err: errors.New("boom")}, "", "identity", "sessions", "clear-cut", "--project", "demo-x", "--user", testCutUID)
	if code != 1 || !strings.Contains(errOut, "boom") {
		t.Errorf("failure: code %d, stderr %q", code, errOut)
	}

	pf := &fakeCutClearer{exists: true, cut: cut}
	code, _, _, opened := runIdentity(pf, "nope\n", "identity", "sessions", "clear-cut", "--project", "dzeroth-prod", "--user", testCutUID)
	if code != 1 || opened || pf.calls != 0 {
		t.Errorf("prod without confirmation: code %d, opened %v, calls %d", code, opened, pf.calls)
	}
	code, _, _, _ = runIdentity(pf, "dzeroth-prod\n", "identity", "sessions", "clear-cut", "--project", "dzeroth-prod", "--user", testCutUID)
	if code != 0 || pf.calls != 1 {
		t.Errorf("prod with confirmation: code %d, calls %d", code, pf.calls)
	}
}
