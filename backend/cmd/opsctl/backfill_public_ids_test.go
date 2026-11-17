package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// pubStore is an in-memory identity.PublicIDBackfillStore with the repo's transaction rules (status re-check, create-only
// lookup, same id on repair).
type pubStore struct {
	ids     map[string]string // uid -> stored publicId
	status  map[string]identity.AccountStatus
	lookups map[string]string // publicId -> uid
	failTx  map[string]error  // uid -> error of its transaction
	writes  int
}

func newPubStore() *pubStore {
	return &pubStore{ids: map[string]string{}, status: map[string]identity.AccountStatus{}, lookups: map[string]string{}, failTx: map[string]error{}}
}

func (s *pubStore) add(uid, publicID string, st identity.AccountStatus) {
	s.ids[uid], s.status[uid] = publicID, st
}

func (s *pubStore) ScanPublicIDs(_ context.Context, after string, limit int) ([]identity.PublicIDScanRow, error) {
	var uids []string
	for uid := range s.status {
		if uid > after {
			uids = append(uids, uid)
		}
	}
	sort.Strings(uids)
	uids = uids[:min(limit, len(uids))]
	rows := make([]identity.PublicIDScanRow, 0, len(uids))
	for _, uid := range uids {
		row := identity.PublicIDScanRow{UID: uid, PublicID: s.ids[uid], Status: s.status[uid]}
		if identity.ValidPublicID(row.PublicID) {
			row.LookupOwner, row.LookupExists = s.lookups[row.PublicID]
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func (s *pubStore) gate(uid string) (identity.PublicIDTxResult, bool) {
	st, ok := s.status[uid]
	switch {
	case !ok:
		return identity.PublicIDTxGone, false
	case st == identity.AccountStatusDeleting:
		return identity.PublicIDTxDeleting, false
	case st != identity.AccountStatusActive && st != identity.AccountStatusSuspended:
		return identity.PublicIDTxOtherStatus, false
	}
	return 0, true
}

func (s *pubStore) MintPublicIDForBackfill(_ context.Context, uid, publicID string, _ time.Time) (identity.PublicIDTxResult, error) {
	if err := s.failTx[uid]; err != nil {
		return 0, err
	}
	if r, ok := s.gate(uid); !ok {
		return r, nil
	}
	if s.ids[uid] != "" {
		return identity.PublicIDTxAlreadyOK, nil
	}
	if _, taken := s.lookups[publicID]; taken {
		return 0, identity.ErrPublicIDCollision
	}
	s.ids[uid], s.lookups[publicID] = publicID, uid
	s.writes++
	return identity.PublicIDTxWrote, nil
}

func (s *pubStore) RepairPublicIDLookup(_ context.Context, uid, publicID string, _ time.Time) (identity.PublicIDTxResult, error) {
	if err := s.failTx[uid]; err != nil {
		return 0, err
	}
	if r, ok := s.gate(uid); !ok {
		return r, nil
	}
	if owner, exists := s.lookups[publicID]; exists {
		if owner == uid {
			return identity.PublicIDTxAlreadyOK, nil
		}
		return identity.PublicIDTxForeign, nil
	}
	s.lookups[publicID] = uid
	s.writes++
	return identity.PublicIDTxWrote, nil
}

// Firebase-shaped uids and well-formed public ids, so a leak of either into the output is unmistakable.
const (
	uidActive    = "AAaaaaaaaaaaaaaaaaaaaaaaaaa1"
	uidSuspended = "BBbbbbbbbbbbbbbbbbbbbbbbbbb2"
	uidDeleting  = "CCccccccccccccccccccccccccc3"
	uidRepair    = "DDddddddddddddddddddddddddd4"
	uidConflict  = "EEeeeeeeeeeeeeeeeeeeeeeeeee5"
	uidOK        = "FFfffffffffffffffffffffffff6"
	uidForeign   = "ZZzzzzzzzzzzzzzzzzzzzzzzzz9"
	pubRepair    = "u00000000000000000000000004"
	pubConflict  = "u00000000000000000000000005"
	pubOK        = "u00000000000000000000000006"
	pubDeleting  = "u00000000000000000000000003"
)

func seededPubStore() *pubStore {
	s := newPubStore()
	s.add(uidActive, "", identity.AccountStatusActive)
	s.add(uidSuspended, "", identity.AccountStatusSuspended)
	s.add(uidDeleting, pubDeleting, identity.AccountStatusDeleting) // lookup already erased: never repaired
	s.add(uidRepair, pubRepair, identity.AccountStatusActive)       // restored by hand: lookup missing
	s.add(uidConflict, pubConflict, identity.AccountStatusActive)
	s.lookups[pubConflict] = uidForeign
	s.add(uidOK, pubOK, identity.AccountStatusActive)
	s.lookups[pubOK] = uidOK
	return s
}

func runPubCLI(t *testing.T, s *pubStore, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	open := func(context.Context, string) (*backends, error) {
		return &backends{publicIDBackfill: s, close: func() {}}, nil
	}
	var out, errOut bytes.Buffer
	code = run(context.Background(), append([]string{"backfill-public-ids", "--project", "demo-p"}, args...), strings.NewReader(""), &out, &errOut, open,
		func() time.Time { return time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC) })
	return code, out.String(), errOut.String()
}

// assertNoRawIDs fails when any seeded uid or public id appears in the text.
func assertNoRawIDs(t *testing.T, s *pubStore, texts ...string) {
	t.Helper()
	raw := []string{uidForeign}
	for uid, id := range s.ids {
		raw = append(raw, uid)
		if id != "" {
			raw = append(raw, id)
		}
	}
	for _, text := range texts {
		for _, r := range raw {
			if strings.Contains(text, r) {
				t.Errorf("output carries the raw id %q:\n%s", r, text)
			}
		}
	}
}

func readPubCheckpoint(t *testing.T, path string) publicIDsCheckpointFile {
	t.Helper()
	data, err := os.ReadFile(path) //nolint:gosec // test temp file
	if err != nil {
		t.Fatal(err)
	}
	var c publicIDsCheckpointFile
	if err := json.Unmarshal(data, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

// TestBackfillPublicIDs_CLI: dry run, real run, the idempotent rerun, and hashed-only output. Not parallel (t.Setenv).
func TestBackfillPublicIDs_CLI(t *testing.T) {
	keyedAuditUIDHash(t, "") // CURSOR_HMAC_KEY set and installed
	s := seededPubStore()
	cp := filepath.Join(t.TempDir(), "pub.json")

	code, stdout, stderr := runPubCLI(t, s, "--dry-run")
	if code != 0 {
		t.Fatalf("dry run exit %d, stderr %q", code, stderr)
	}
	for _, want := range []string{
		"mode=dry-run", "FEATURE_PUBLIC_IDS is not read",
		"dry-run: scanned=6 already_ok=1 would_mint=2 would_repair=1 skipped_deleting=1 skipped_status=0 gone=0 conflicts=1 collisions=0 (nothing written)",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("dry run stdout lacks %q:\n%s", want, stdout)
		}
	}
	if s.writes != 0 || s.ids[uidActive] != "" {
		t.Fatalf("the dry run wrote %d times", s.writes)
	}
	assertNoRawIDs(t, s, stdout, stderr)

	code, stdout, stderr = runPubCLI(t, s, "--checkpoint", cp)
	if code != 0 {
		t.Fatalf("run exit %d, stderr %q", code, stderr)
	}
	t.Logf("run output:\n%s", stdout)
	conflictLine := "conflict: reason=foreign_lookup uid_hash=" + uidHashForAudit(uidConflict) + " public_id_hash=" + uidHashForAudit(pubConflict) + " owner_hash=" + uidHashForAudit(uidForeign)
	for _, want := range []string{
		"mode=write", "checkpoint=" + cp,
		"backfill-public-ids: complete: scanned=6 already_ok=1 minted=2 repaired=1 skipped_deleting=1 skipped_status=0 gone=0 conflicts=1 collisions=0",
		conflictLine,
		"checkpoint_hash=" + uidHashForAudit(uidOK),
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("run stdout lacks %q:\n%s", want, stdout)
		}
	}
	if !identity.ValidPublicID(s.ids[uidActive]) || !identity.ValidPublicID(s.ids[uidSuspended]) || s.lookups[pubRepair] != uidRepair {
		t.Errorf("ids %v lookups %v", s.ids, s.lookups)
	}
	if _, ok := s.lookups[pubDeleting]; ok || s.lookups[pubConflict] != uidForeign {
		t.Errorf("a DELETING lookup was re-created or the foreign lookup changed: %v", s.lookups)
	}
	if c := readPubCheckpoint(t, cp); c.State != "complete" || c.After != uidOK || c.Project != "demo-p" {
		t.Errorf("checkpoint = %+v", c)
	}
	assertNoRawIDs(t, s, stdout, stderr)

	// An existing checkpoint is never overwritten without --resume or --force.
	if code, _, stderr = runPubCLI(t, s, "--checkpoint", cp); code != 2 || !strings.Contains(stderr, "pass --resume to continue it or --force") {
		t.Errorf("rerun without --force: exit %d stderr %q", code, stderr)
	}
	// The forced full rerun writes nothing.
	writes := s.writes
	code, stdout, stderr = runPubCLI(t, s, "--checkpoint", cp, "--force")
	if code != 0 || s.writes != writes ||
		!strings.Contains(stdout, "complete: scanned=6 already_ok=4 minted=0 repaired=0 skipped_deleting=1 skipped_status=0 gone=0 conflicts=1") {
		t.Errorf("idempotent rerun: exit %d writes %d -> %d stdout:\n%s\nstderr %q", code, writes, s.writes, stdout, stderr)
	}
	assertNoRawIDs(t, s, stdout, stderr)
}

// TestBackfillPublicIDs_FailureAndResume: a failing account stops the run with the checkpoint before it (stderr carries no
// raw id); --resume continues from there and reads nothing before it.
func TestBackfillPublicIDs_FailureAndResume(t *testing.T) {
	keyedAuditUIDHash(t, "")
	s := seededPubStore()
	s.failTx[uidRepair] = errors.New("rpc error: documents/users/" + uidRepair + " publicIds/" + pubRepair + " unavailable")
	cp := filepath.Join(t.TempDir(), "pub.json")

	code, stdout, stderr := runPubCLI(t, s, "--checkpoint", cp)
	if code != 1 || !strings.Contains(stderr, "failed at checkpoint_hash="+uidHashForAudit(uidDeleting)+": checkpoint saved, rerun with --resume") {
		t.Fatalf("exit %d stderr %q", code, stderr)
	}
	if c := readPubCheckpoint(t, cp); c.State != "failed" || c.After != uidDeleting {
		t.Errorf("checkpoint = %+v, want failed after the account before the failing one", c)
	}
	assertNoRawIDs(t, s, stdout, stderr)

	delete(s.failTx, uidRepair)
	code, stdout, stderr = runPubCLI(t, s, "--checkpoint", cp, "--resume")
	if code != 0 {
		t.Fatalf("resume exit %d stderr %q", code, stderr)
	}
	for _, want := range []string{
		"resume_after_hash=" + uidHashForAudit(uidDeleting),
		"complete: scanned=3 already_ok=1 minted=0 repaired=1 skipped_deleting=0 skipped_status=0 gone=0 conflicts=1",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("resume stdout lacks %q:\n%s", want, stdout)
		}
	}
	assertNoRawIDs(t, s, stdout, stderr)
}

func TestBackfillPublicIDs_UsageErrors(t *testing.T) {
	dir := t.TempDir()
	other := filepath.Join(dir, "other.json")
	if err := writeCheckpointFile(other, publicIDsCheckpointFile{Version: publicIDsCheckpointVersion, Command: "backfill-public-ids", Project: "demo-other"}); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"dry run with --resume", []string{"--dry-run", "--resume"}, "writes nothing, not even a checkpoint"},
		{"dry run with --checkpoint", []string{"--dry-run", "--checkpoint", other}, "writes nothing, not even a checkpoint"},
		{"--resume and --force", []string{"--resume", "--force"}, "exclusive"},
		{"--resume without a file", []string{"--resume", "--checkpoint", filepath.Join(dir, "none.json")}, "--resume: read checkpoint"},
		{"--resume of another project", []string{"--resume", "--checkpoint", other}, `for project "demo-other"`},
		{"--after is not supported", []string{"--after", "x"}, "--after is not supported"},
		{"--write is not supported", []string{"--write"}, "--write is not supported"},
		{"--before is not supported", []string{"--before", "2026-01-01T00:00:00Z"}, "--before is not supported"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			opened := false
			open := func(context.Context, string) (*backends, error) {
				opened = true
				return &backends{close: func() {}}, nil
			}
			var out, errOut bytes.Buffer
			code := run(context.Background(), append([]string{"backfill-public-ids", "--project", "demo-p"}, tc.args...), strings.NewReader(""), &out, &errOut, open, time.Now)
			if code != 2 || !strings.Contains(errOut.String(), tc.want) || opened {
				t.Errorf("exit %d opened %v stderr %q; want 2 and %q", code, opened, errOut.String(), tc.want)
			}
		})
	}
}

func TestBackfillPublicIDs_NoKeyMarker(t *testing.T) {
	t.Setenv(cursorKeyEnv, "")
	s := seededPubStore()
	code, stdout, _ := runPubCLI(t, s, "--dry-run")
	if code != 0 || !strings.Contains(stdout, "warning: "+cursorKeyEnv+" is not set") {
		t.Errorf("exit %d stdout:\n%s", code, stdout)
	}
	assertNoRawIDs(t, s, stdout)
}
