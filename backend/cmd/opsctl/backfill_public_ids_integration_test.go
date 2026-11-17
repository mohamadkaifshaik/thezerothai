//go:build integration

package main

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// End-to-end emulator test of `opsctl backfill-public-ids`: the real run() flag handling and output over the real identity
// repo (the walk, the mint and repair transactions). The opener wires only the backfill store.

func runPublicIDsCLI(t *testing.T, client *firestore.Client, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	open := func(context.Context, string) (*backends, error) {
		return &backends{publicIDBackfill: identity.NewFirestoreRepo(client, nil), close: func() {}}, nil
	}
	var out, errOut bytes.Buffer
	code = run(context.Background(), args, strings.NewReader(""), &out, &errOut, open, time.Now)
	return code, out.String(), errOut.String()
}

func TestBackfillPublicIDs_Integration_CLI(t *testing.T) {
	client, project := backfillTestClient(t)
	ctx := context.Background()
	const (
		pubRestored = "u0000000000000000000000000r"
		pubTaken    = "u0000000000000000000000000t"
		pubDel      = "u0000000000000000000000000d"
	)
	users := map[string]map[string]any{
		"intActive0000000000000000001": {"handle": "Ann", "status": "ACTIVE", "bio": "keep me"},
		"intSuspended0000000000000002": {"handle": "Sue", "status": "SUSPENDED"},
		"intDeleting00000000000000003": {"handle": "Dan", "status": "DELETING", "publicId": pubDel},
		"intDeletingNoID000000000004":  {"handle": "Dee", "status": "DELETING"},
		"intRestored00000000000000005": {"handle": "Rex", "status": "ACTIVE", "publicId": pubRestored},
		"intConflict00000000000000006": {"handle": "Con", "status": "ACTIVE", "publicId": pubTaken},
	}
	for uid, d := range users {
		if _, err := client.Collection("users").Doc(uid).Set(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := client.Collection("publicIds").Doc(pubTaken).Set(ctx, map[string]any{"uid": "someoneElse000000000000000", "createdAt": time.Now()}); err != nil {
		t.Fatal(err)
	}
	userData := func(uid string) map[string]any {
		s, err := client.Collection("users").Doc(uid).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return s.Data()
	}
	lookupOwner := func(id string) (string, bool) {
		s, err := client.Collection("publicIds").Doc(id).Get(ctx)
		if err != nil {
			return "", false
		}
		uid, _ := s.Data()["uid"].(string)
		return uid, true
	}
	assertNoRaw := func(texts ...string) {
		t.Helper()
		for _, text := range texts {
			for uid := range users {
				if strings.Contains(text, uid) {
					t.Errorf("output carries the raw uid %s", uid)
				}
			}
			for _, id := range []string{pubRestored, pubTaken, pubDel} {
				if strings.Contains(text, id) {
					t.Errorf("output carries the raw public id %s", id)
				}
			}
		}
	}
	cp := filepath.Join(t.TempDir(), "pub.json")

	// Dry run first: counts, writes nothing.
	code, stdout, stderr := runPublicIDsCLI(t, client, "backfill-public-ids", "--project", project, "--dry-run")
	if code != 0 {
		t.Fatalf("dry run exit code = %d, stderr=%q", code, stderr)
	}
	t.Logf("dry run output:\n%s", stdout)
	if want := "dry-run: scanned=6 already_ok=0 would_mint=2 would_repair=1 skipped_deleting=2 skipped_status=0 gone=0 conflicts=1 collisions=0 (nothing written)"; !strings.Contains(stdout, want) {
		t.Errorf("dry run stdout missing %q:\n%s", want, stdout)
	}
	if userData("intActive0000000000000000001")["publicId"] != nil {
		t.Fatal("the dry run minted")
	}
	if _, ok := lookupOwner(pubRestored); ok {
		t.Fatal("the dry run repaired")
	}
	assertNoRaw(stdout, stderr)

	// The real run.
	code, stdout, stderr = runPublicIDsCLI(t, client, "backfill-public-ids", "--project", project, "--checkpoint", cp)
	if code != 0 {
		t.Fatalf("exit code = %d, stderr=%q", code, stderr)
	}
	t.Logf("real run output:\n%s", stdout)
	for _, want := range []string{
		"backfill-public-ids: complete: scanned=6 already_ok=0 minted=2 repaired=1 skipped_deleting=2 skipped_status=0 gone=0 conflicts=1 collisions=0",
		"conflict: reason=foreign_lookup",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("run stdout missing %q:\n%s", want, stdout)
		}
	}
	assertNoRaw(stdout, stderr)
	minted := map[string]string{}
	for _, uid := range []string{"intActive0000000000000000001", "intSuspended0000000000000002"} {
		d := userData(uid)
		id, _ := d["publicId"].(string)
		if !identity.ValidPublicID(id) {
			t.Fatalf("users/%s.publicId = %v", uid, d["publicId"])
		}
		if owner, ok := lookupOwner(id); !ok || owner != uid {
			t.Errorf("lookup of %s's id names %q (exists %v)", uid, owner, ok)
		}
		minted[uid] = id
	}
	// Field-level update: the rest of the document is untouched.
	if d := userData("intActive0000000000000000001"); d["bio"] != "keep me" || d["handle"] != "Ann" || d["status"] != "ACTIVE" {
		t.Errorf("the mint rewrote the document: %v", d)
	}
	// Repair: the same id, re-created.
	if owner, ok := lookupOwner(pubRestored); !ok || owner != "intRestored00000000000000005" {
		t.Errorf("repaired lookup names %q (exists %v)", owner, ok)
	}
	if userData("intRestored00000000000000005")["publicId"] != pubRestored {
		t.Error("the repair changed the stored id")
	}
	// DELETING: never minted, never repaired.
	if _, ok := lookupOwner(pubDel); ok {
		t.Error("a DELETING account's lookup was re-created")
	}
	if userData("intDeletingNoID000000000004")["publicId"] != nil {
		t.Error("a DELETING account was minted")
	}
	// Conflict: untouched.
	if owner, _ := lookupOwner(pubTaken); owner != "someoneElse000000000000000" {
		t.Errorf("the foreign lookup changed to %q", owner)
	}

	// The rerun is clean: it reads everything and writes nothing.
	code, stdout, stderr = runPublicIDsCLI(t, client, "backfill-public-ids", "--project", project, "--checkpoint", cp, "--force")
	if code != 0 {
		t.Fatalf("rerun exit code = %d, stderr=%q", code, stderr)
	}
	t.Logf("rerun output:\n%s", stdout)
	if want := "backfill-public-ids: complete: scanned=6 already_ok=3 minted=0 repaired=0 skipped_deleting=2 skipped_status=0 gone=0 conflicts=1 collisions=0"; !strings.Contains(stdout, want) {
		t.Errorf("rerun stdout missing %q:\n%s", want, stdout)
	}
	for uid, id := range minted {
		if userData(uid)["publicId"] != id {
			t.Errorf("the rerun changed %s's id", uid)
		}
	}
	assertNoRaw(stdout, stderr)

	// --resume after the complete run: nothing after the last account, nothing written.
	code, stdout, stderr = runPublicIDsCLI(t, client, "backfill-public-ids", "--project", project, "--checkpoint", cp, "--resume")
	if code != 0 || !strings.Contains(stdout, "complete: scanned=0 ") {
		t.Errorf("--resume run: code=%d stdout=\n%s\nstderr=%q", code, stdout, stderr)
	}
}
