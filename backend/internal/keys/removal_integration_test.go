//go:build integration

package keys

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// The removed marks on the emulator (security audit H1; removal-server design 2026-11-23, sections 2.1-2.5).

const itReauth = 5 * time.Minute

// removalSvc is the service on the emulator repository with the composition root's reauth window and a fixed clock.
func (e *repoEnv) removalSvc(now time.Time) Service {
	return New(Deps{Repo: e.repo, Now: func() time.Time { return now }, ReauthMaxAge: itReauth})
}

// signedInAt is a caller context whose ID token's auth_time is at.
func signedInAt(uid string, at time.Time) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, AuthTime: at})
}

func (e *repoEnv) markData(t *testing.T, uid, id string) (map[string]any, bool) {
	t.Helper()
	s, err := e.repo.markRef(uid, id).Get(context.Background())
	if status.Code(err) == codes.NotFound {
		return nil, false
	}
	if err != nil {
		t.Fatal(err)
	}
	return s.Data(), true
}

func wantReason(t *testing.T, err error, reason commonv1.ErrorReason) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeFailedPrecondition || ae.Reason != reason {
		t.Fatalf("err = %v, want FAILED_PRECONDITION %v", err, reason)
	}
}

// TestRemoval_RemoteRefusesRegisterAndUpload: after a REMOTE removal the same id is refused by Register (also at the
// cap, before LIMIT_REACHED) and Upload with DEVICE_REMOVED, and the mark document carries removedAt and the TTL field
// expireAt = removedAt + 90 days, and nothing else.
func TestRemoval_RemoteRefusesRegisterAndUpload(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	for i := 1; i <= MaxDevicesPerUser; i++ {
		e.mustRegister(t, uid, dvc(i), skey(byte(i)), it0)
	}
	now := it0.Add(time.Hour)
	svc := e.removalSvc(now)
	if err := svc.Remove(signedInAt(uid, now.Add(-time.Minute)), uid, dvc(1), RemoveRemote); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); status.Code(err) != codes.NotFound {
		t.Fatalf("device document after a remote removal: %v, want deleted", err)
	}
	data, ok := e.markData(t, uid, dvc(1))
	if !ok {
		t.Fatal("no removed mark")
	}
	if len(data) != 2 || !data["removedAt"].(time.Time).Equal(now) || !data["expireAt"].(time.Time).Equal(now.Add(90*24*time.Hour)) {
		t.Fatalf("mark = %v, want removedAt %v and expireAt (TTL) 90 days later only", data, now)
	}
	_, err := svc.Register(ctx, uid, dvc(1), skey(1))
	wantReason(t, err, commonv1.ErrorReason_ERROR_REASON_DEVICE_REMOVED)
	_, _, err = svc.Upload(ctx, uid, dvc(1), [][]byte{pkgN(1)}, nil)
	wantReason(t, err, commonv1.ErrorReason_ERROR_REASON_DEVICE_REMOVED)

	// Fill the freed slot, then a marked id at the cap still answers DEVICE_REMOVED, never LIMIT_REACHED.
	e.mustRegister(t, uid, dvc(6), skey(6), now)
	if err := e.repo.MarkRemoved(ctx, uid, dvc(9), now); err != nil {
		t.Fatal(err)
	}
	_, err = svc.Register(ctx, uid, dvc(9), skey(9))
	wantReason(t, err, commonv1.ErrorReason_ERROR_REASON_DEVICE_REMOVED)
	if _, err := e.register(t, uid, dvc(7), skey(7), now); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("an unmarked sixth device: %v, want ErrDeviceLimit", err)
	}
	// A missing unmarked device is still NOT_FOUND on upload.
	if _, _, err := e.repo.Upload(ctx, uid, dvc(8), [][]byte{pkgN(1)}, nil, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("upload to a missing unmarked device: %v, want ErrNotFound", err)
	}
}

// TestRemoval_SignOutMarksNothing: SIGN_OUT (and UNSPECIFIED, which the handler maps to it) deletes the device and writes
// no mark, so the same id registers again (the failed sign-out path).
func TestRemoval_SignOutMarksNothing(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	svc := e.removalSvc(it0)
	if err := svc.Remove(signedInAt(uid, time.Time{}), uid, dvc(1), RemoveSignOut); err != nil {
		t.Fatal(err)
	}
	if _, ok := e.markData(t, uid, dvc(1)); ok {
		t.Fatal("a sign-out removal wrote a mark")
	}
	marked, err := e.repo.RemovalMarked(ctx, uid, dvc(1))
	if err != nil || marked {
		t.Fatalf("RemovalMarked = %v, %v", marked, err)
	}
	if _, err := svc.Register(ctx, uid, dvc(1), skey(1)); err != nil {
		t.Fatalf("register again after sign-out: %v", err)
	}
}

// TestRemoval_StaleSignInWritesNothing: REMOTE of an unmarked id with an old auth_time is REAUTH_REQUIRED and leaves the
// device and its pool as they were; once marked (here by an earlier attempt), a retry finishes without a sign-in.
func TestRemoval_StaleSignInWritesNothing(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seed(t, uid, 1, 3)
	now := it0.Add(time.Hour)
	svc := e.removalSvc(now)
	err := svc.Remove(signedInAt(uid, now.Add(-itReauth-time.Second)), uid, dvc(0), RemoveRemote)
	wantReason(t, err, commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED)
	if _, ok := e.markData(t, uid, dvc(0)); ok {
		t.Fatal("a refused removal wrote a mark")
	}
	if _, ok := e.snap(t, uid, dvc(0)).Data()["removedAt"]; ok || len(e.poolDocs(t, uid, dvc(0))) != 3 {
		t.Fatal("a refused removal touched the device")
	}
	if err := e.repo.MarkRemoved(ctx, uid, dvc(0), now); err != nil {
		t.Fatal(err)
	}
	if err := svc.Remove(signedInAt(uid, time.Time{}), uid, dvc(0), RemoveRemote); err != nil {
		t.Fatalf("retry of a marked id: %v", err)
	}
	if n := e.deviceDocs(t, uid); n != 0 {
		t.Fatalf("%d device refs left after the retry", n)
	}
}

// TestRemoval_CrashAfterMark: a removal that stopped after the mark transaction leaves a device document carrying
// removedAt. Every reader skips it (List, ActiveDevices, Claim, Claim's exclude), Register and Upload refuse the id, it
// still holds its slot under the cap (so there are never more than MaxDevicesPerUser device documents for the Limit 5
// readers), and a retry deletes it. The mark is created once: a second MarkRemoved keeps the first time.
func TestRemoval_CrashAfterMark(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid, peer := uniqueUID(), uniqueUID()
	e.seed(t, uid, MaxDevicesPerUser-1, 2) // dvc(0)..dvc(3), each with a pool and a last resort
	now := it0.Add(time.Hour)
	if err := e.repo.MarkRemoved(ctx, uid, dvc(1), now); err != nil {
		t.Fatal(err)
	}
	if err := e.repo.MarkRemoved(ctx, uid, dvc(1), now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if data, _ := e.markData(t, uid, dvc(1)); !data["removedAt"].(time.Time).Equal(now) {
		t.Fatalf("a second mark moved removedAt: %v", data)
	}
	if got := e.snap(t, uid, dvc(1)).Data()["removedAt"]; got == nil || !got.(time.Time).Equal(now) {
		t.Fatalf("device removedAt = %v, want %v", got, now)
	}
	ids := func(ds []Device) []string {
		var out []string
		for _, d := range ds {
			out = append(out, d.ID)
		}
		return out
	}
	list, err := e.repo.List(ctx, uid)
	if err != nil || fmt.Sprint(ids(list)) != fmt.Sprint([]string{dvc(0), dvc(2), dvc(3)}) {
		t.Fatalf("List = %v, %v", ids(list), err)
	}
	active, err := e.repo.ActiveDevices(ctx, uid, now)
	if err != nil || len(active) != 3 {
		t.Fatalf("ActiveDevices = %v, %v", ids(active), err)
	}
	claimed, err := e.repo.Claim(ctx, uid, "", now)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range claimed {
		if c.DeviceID == dvc(1) {
			t.Fatal("Claim took a package of a removed device")
		}
	}
	if len(claimed) != 3 {
		t.Fatalf("claimed %d devices, want 3", len(claimed))
	}
	if _, err := e.repo.Claim(ctx, uid, dvc(1), now); !errors.Is(err, ErrExcludeNotFound) {
		t.Fatalf("Claim excluding the removed device: %v, want ErrExcludeNotFound", err)
	}
	if _, err := e.register(t, uid, dvc(1), skey(2), now); !errors.Is(err, ErrDeviceRemoved) {
		t.Fatalf("Register of the removing id: %v, want ErrDeviceRemoved", err)
	}
	if _, _, err := e.repo.Upload(ctx, uid, dvc(1), [][]byte{pkgN(900)}, nil, now); !errors.Is(err, ErrDeviceRemoved) {
		t.Fatalf("Upload to the removing id: %v, want ErrDeviceRemoved", err)
	}
	// 3 live + 1 removing = 4 documents: a fifth registers, a sixth is refused while the removing one is not deleted.
	e.mustRegister(t, uid, dvc(4), skey(5), now)
	if _, err := e.register(t, uid, dvc(5), skey(6), now); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("Register past the cap with a removing device: %v, want ErrDeviceLimit", err)
	}
	if n := e.deviceDocs(t, uid); n != MaxDevicesPerUser {
		t.Fatalf("%d device documents, want %d", n, MaxDevicesPerUser)
	}
	// The retry (no sign-in needed: the id is marked) deletes the document and its pool.
	if err := e.removalSvc(now).Remove(signedInAt(uid, time.Time{}), uid, dvc(1), RemoveRemote); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); status.Code(err) != codes.NotFound {
		t.Fatalf("device after the retry: %v, want deleted", err)
	}
	if left := e.poolDocs(t, uid, dvc(1)); len(left) != 0 {
		t.Fatalf("%d pool documents left", len(left))
	}
	// Another user's id of the same name is untouched by this user's mark.
	e.mustRegister(t, peer, dvc(1), skey(1), now)
}

// TestRemoval_RaceWithRegister: a REMOTE Remove and a Register of the same id, run together 50 times. Whatever the
// order, once both returned there is a mark and no device document (the register either landed first and was removed,
// or saw the mark and was refused), and the register answers success or ErrDeviceRemoved only.
func TestRemoval_RaceWithRegister(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	now := it0.Add(time.Hour)
	svc := e.removalSvc(now)
	refused := 0
	for i := 0; i < 50; i++ {
		uid := uniqueUID()
		var wg sync.WaitGroup
		var regErr, rmErr error
		start := make(chan struct{})
		wg.Add(2)
		go func() { defer wg.Done(); <-start; _, regErr = e.register(t, uid, dvc(1), skey(1), now) }()
		go func() {
			defer wg.Done()
			<-start
			rmErr = svc.Remove(signedInAt(uid, now), uid, dvc(1), RemoveRemote)
		}()
		close(start)
		wg.Wait()
		if rmErr != nil {
			t.Fatalf("run %d: remove: %v", i, rmErr)
		}
		switch {
		case regErr == nil:
		case errors.Is(regErr, ErrDeviceRemoved):
			refused++
		default:
			t.Fatalf("run %d: register: %v", i, regErr)
		}
		if _, ok := e.markData(t, uid, dvc(1)); !ok {
			t.Fatalf("run %d: no mark", i)
		}
		snap, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx)
		if status.Code(err) != codes.NotFound {
			if err != nil {
				t.Fatal(err)
			}
			if _, has := snap.Data()["removedAt"]; !has {
				t.Fatalf("run %d: a live device document without removedAt beside a mark", i)
			}
			t.Fatalf("run %d: the device document survived the removal", i)
		}
	}
	t.Logf("register refused in %d of 50 runs", refused)
}

// TestRemoval_ListRemovalMarksPagesByID: the export read pages the marks by document id, afterID exclusive.
func TestRemoval_ListRemovalMarksPagesByID(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	for i := 0; i < 5; i++ {
		if err := e.repo.MarkRemoved(ctx, uid, dvc(i), it0.Add(time.Duration(i)*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	first, err := e.repo.ListRemovalMarks(ctx, uid, "", 3)
	if err != nil || len(first) != 3 || first[0].DeviceID != dvc(0) || first[2].DeviceID != dvc(2) {
		t.Fatalf("first page = %+v, %v", first, err)
	}
	if !first[1].RemovedAt.Equal(it0.Add(time.Minute)) || !first[1].ExpireAt.Equal(it0.Add(time.Minute).Add(RemovalMarkTTL)) {
		t.Fatalf("mark times = %+v", first[1])
	}
	rest, err := e.repo.ListRemovalMarks(ctx, uid, first[2].DeviceID, 3)
	if err != nil || len(rest) != 2 || rest[0].DeviceID != dvc(3) {
		t.Fatalf("second page = %+v, %v", rest, err)
	}
}

// TestPurge_ErasesRemovalMarks: account deletion erases the devices, then the marks, an orphan mark (no device document)
// included; another user's marks survive.
func TestPurge_ErasesRemovalMarks(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid, other := uniqueUID(), uniqueUID()
	e.seed(t, uid, 2, 3)
	if err := e.removalSvc(it0).Remove(signedInAt(uid, it0), uid, dvc(0), RemoveRemote); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{dvc(1), dvc(7)} { // dvc(1): removing (document carries removedAt); dvc(7): orphan mark
		if err := e.repo.MarkRemoved(ctx, uid, id, it0); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.repo.MarkRemoved(ctx, other, dvc(0), it0); err != nil {
		t.Fatal(err)
	}
	er := NewEraser(e.repo)
	var cp Checkpoint
	for i := 0; ; i++ {
		if i > 10 {
			t.Fatal("the purge did not finish")
		}
		next, done, err := er.PurgeUser(ctx, uid, cp)
		if err != nil {
			t.Fatal(err)
		}
		cp = next
		if done {
			break
		}
	}
	if cp.Marks != 3 {
		t.Errorf("checkpoint marks = %d, want 3", cp.Marks)
	}
	refs, err := e.repo.marks(uid).DocumentRefs(ctx).GetAll()
	if err != nil || len(refs) != 0 {
		t.Fatalf("%d mark refs left, %v", len(refs), err)
	}
	if n := e.deviceDocs(t, uid); n != 0 {
		t.Fatalf("%d device refs left", n)
	}
	if _, ok := e.markData(t, other, dvc(0)); !ok {
		t.Fatal("another user's mark was erased")
	}
}
