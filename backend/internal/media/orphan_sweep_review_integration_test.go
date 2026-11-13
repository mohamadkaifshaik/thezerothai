//go:build integration

package media

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// Integration tests for the 2026-11-11 review of the orphan sweep (kill switch, claimed documents, undecodable documents)
// over the real Firestore repo and the Storage emulator. Each test has its own project and buckets (newOrphanIntEnv).

// TestIntegration_OrphanSweepClaimedDocIsFinished: phase 2 claims and deletes the objects, then the document delete
// fails. A draft holds the image before the next run, which must finish the delete, never restore it. In between, the
// claim alone (even with the mark removed) makes the attach and the cover preview refuse the image.
func TestIntegration_OrphanSweepClaimedDocIsFinished(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireOff)
	d := e.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	if res := e.sweep(t, sweepNow, 10); res.Marked != 1 {
		t.Fatalf("phase 1 = %+v", res)
	}
	e.hooked.deleteErr = errors.New("deadline exceeded")
	if res, err := e.sweeper.Sweep(context.Background(), sweepNow.Add(OrphanGrace), 10); err == nil || res.Failed != 1 {
		t.Fatalf("phase 2 = %+v, %v: want the document delete to fail", res, err)
	}
	got := e.get(t, d.ID)
	if got == nil || !timeIs(got.OrphanDeletingAt, sweepNow.Add(OrphanGrace)) || e.objectsLeft(t, d) != 0 {
		t.Fatalf("after the failed delete: doc=%+v objects=%d, want claimed with no objects", got, e.objectsLeft(t, d))
	}
	ctx := context.Background()
	if _, err := e.client.Collection(mediaCollection).Doc(d.ID).Update(ctx, []firestore.Update{{Path: "orphanedAt", Value: firestore.Delete}}); err != nil {
		t.Fatal(err)
	}
	if err := e.attachInTx(ctx, uidA, d.ID, "0000000000000000558"); !IsNotReady(err) {
		t.Fatalf("attach of a claimed image = %v, want ErrNotReady", err)
	}
	if _, err := e.lib.ResolvePostCover(ctx, uidA, d.ID); !IsNotReady(err) {
		t.Fatalf("cover of a claimed image = %v, want ErrNotReady", err)
	}

	e.hooked.deleteErr = nil
	e.drafts.held[uidA] = map[string]bool{d.ID: true}
	res := e.sweep(t, sweepNow.Add(2*OrphanGrace), 10)
	if res.Deleted != 1 || res.Restored != 0 || res.Held != 0 {
		t.Fatalf("next run = %+v, want the delete finished", res)
	}
	if e.get(t, d.ID) != nil {
		t.Fatal("the claimed document survived")
	}
}

// TestIntegration_OrphanSweepClaimedProfileImagesAreRefused: the avatar resolver refuses a claimed document,
// and SetOrphanState can never remove the claim.
func TestIntegration_OrphanSweepClaimedProfileImagesAreRefused(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireAll)
	avatar := e.seed(t, uidA, PurposeAvatar, sweepNow.Add(-time.Minute))
	ctx := context.Background()
	for _, id := range []string{avatar.ID} {
		cur := e.get(t, id)
		if _, err := e.repo.ClaimOrphan(ctx, id, cur.UpdateTime, sweepNow.Add(OrphanGrace), sweepNow); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.lib.ResolveAvatar(ctx, uidA, avatar.ID); !IsNotReady(err) {
		t.Fatalf("avatar = %v, want ErrNotReady", err)
	}
	cur := e.get(t, avatar.ID)
	if _, err := e.repo.SetOrphanState(ctx, avatar.ID, cur.UpdateTime, OrphanState{}); err != nil {
		t.Fatal(err)
	}
	if got := e.get(t, avatar.ID); !timeIs(got.OrphanDeletingAt, sweepNow) {
		t.Fatalf("claim after SetOrphanState = %v, want kept", got.OrphanDeletingAt)
	}
}

// TestIntegration_OrphanSweepKillSwitch: off reads and writes nothing; mark marks and defers but never claims or deletes;
// the same document is deleted once the switch is delete.
func TestIntegration_OrphanSweepKillSwitch(t *testing.T) {
	off := newOrphanIntEnvMode(t, config.ProfileMediaRetireOff, config.MediaOrphanSweepOff)
	d := off.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	before := off.get(t, d.ID).UpdateTime
	if res := off.sweep(t, sweepNow, 10); res != (OrphanSweepResult{}) {
		t.Fatalf("off = %+v, want nothing", res)
	}
	if !off.get(t, d.ID).UpdateTime.Equal(before) {
		t.Fatal("off wrote")
	}

	mark := newOrphanIntEnvMode(t, config.ProfileMediaRetireOff, config.MediaOrphanSweepMark)
	d = mark.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	if res := mark.sweep(t, sweepNow, 10); res.Marked != 1 {
		t.Fatalf("mark phase 1 = %+v", res)
	}
	if res := mark.sweep(t, sweepNow.Add(OrphanGrace), 10); res.Deferred != 1 || res.Deleted != 0 {
		t.Fatalf("mark phase 2 = %+v, want deferred", res)
	}
	got := mark.get(t, d.ID)
	if got == nil || got.OrphanDeletingAt != nil || !timeIs(got.OrphanedAt, sweepNow) || mark.objectsLeft(t, d) != 4 {
		t.Fatalf("after mark mode: doc=%+v objects=%d, want marked, unclaimed, intact", got, mark.objectsLeft(t, d))
	}

	del, err := NewOrphanSweeper(OrphanSweepDeps{
		Repo: mark.hooked, Objects: mark.buckets, Drafts: mark.drafts, Profiles: mark.profiles, Mode: config.MediaOrphanSweepDelete,
	})
	if err != nil {
		t.Fatal(err)
	}
	if res, err := del.Sweep(context.Background(), sweepNow.Add(2*OrphanGrace), 10); err != nil || res.Deleted != 1 {
		t.Fatalf("delete = %+v, %v", res, err)
	}
	if mark.get(t, d.ID) != nil || mark.objectsLeft(t, d) != 0 {
		t.Fatal("delete mode left the document or its objects")
	}
}

// TestIntegration_OrphanSweepSkipsUndecodable: a due document whose stored shape does not decode is skipped by id and the
// rest of the page is swept.
func TestIntegration_OrphanSweepSkipsUndecodable(t *testing.T) {
	e := newOrphanIntEnv(t, config.ProfileMediaRetireOff)
	ctx := context.Background()
	bad := fmt.Sprintf("%019d", 6_000_000_000_000_000_000+rand.Int64N(1_000_000_000))
	if _, err := e.client.Collection(mediaCollection).Doc(bad).Set(ctx, map[string]any{
		"ownerId": 42, "status": []string{"READY"}, "orphanCheckAt": sweepNow.Add(-time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	good := e.seed(t, uidA, PurposePost, sweepNow.Add(-time.Minute))
	page, err := e.repo.DueOrphans(ctx, sweepNow, 10)
	if err != nil || len(page.Undecodable) != 1 || page.Undecodable[0] != bad || page.Read != 2 || len(page.Docs) != 1 {
		t.Fatalf("due = %+v, %v: want the bad document skipped by id", page, err)
	}
	if res := e.sweep(t, sweepNow, 10); res.Undecodable != 1 || res.Marked != 1 {
		t.Fatalf("res = %+v", res)
	}
	if e.get(t, good.ID).OrphanedAt == nil {
		t.Fatal("the good document was not swept")
	}
}
