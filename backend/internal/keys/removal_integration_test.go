//go:build integration

package keys

import (
	"bytes"
	"context"
	"encoding/json"
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
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
	if err := e.repo.MarkRemoved(ctx, uid, dvc(9), now, true); err != nil {
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
	if err := e.repo.MarkRemoved(ctx, uid, dvc(0), now, true); err != nil {
		t.Fatal(err)
	}
	if err := svc.Remove(signedInAt(uid, time.Time{}), uid, dvc(0), RemoveRemote); err != nil {
		t.Fatalf("retry of a marked id: %v", err)
	}
	if n := e.deviceDocs(t, uid); n != 0 {
		t.Fatalf("%d device refs left after the retry", n)
	}
}

// putMark writes a removed mark directly, without stamping the device document: what an image from before the marks
// leaves behind when it re-registers an id that a newer image had marked (a rollback, security audit M3).
func (e *repoEnv) putMark(t *testing.T, uid, id string, at time.Time) {
	t.Helper()
	if _, err := e.repo.markRef(uid, id).Create(context.Background(), markDoc{RemovedAt: at, ExpireAt: at.Add(RemovalMarkTTL)}); err != nil {
		t.Fatal(err)
	}
}

// TestRemoval_LiveDocumentUnderMark (code review Minor 2, security audit M3 defence): a live device document whose id has
// a mark must not survive a rollback to an image without the marks. Register refuses it with DEVICE_REMOVED and stamps
// removedAt in the same transaction (so every reader skips it from then on); a REMOTE removal of it is not a retry and
// still needs a recent sign-in.
func TestRemoval_LiveDocumentUnderMark(t *testing.T) {
	ctx := context.Background()
	now := it0.Add(time.Hour)

	t.Run("register is refused and stamps the document", func(t *testing.T) {
		e := newRepoEnv(t)
		uid := uniqueUID()
		e.seed(t, uid, 2, 3)
		e.putMark(t, uid, dvc(1), it0)
		_, err := e.removalSvc(now).Register(ctx, uid, dvc(1), skey(2))
		wantReason(t, err, commonv1.ErrorReason_ERROR_REASON_DEVICE_REMOVED)
		got := e.snap(t, uid, dvc(1)).Data()["removedAt"]
		if got == nil || !got.(time.Time).Equal(now) {
			t.Fatalf("device removedAt = %v, want %v (stamped by the refused Register)", got, now)
		}
		if list, err := e.repo.List(ctx, uid); err != nil || len(list) != 1 || list[0].ID != dvc(0) {
			t.Fatalf("List = %+v, %v; want only %s", list, err, dvc(0))
		}
		if _, _, err := e.repo.Upload(ctx, uid, dvc(1), [][]byte{pkgN(900)}, nil, now); !errors.Is(err, ErrDeviceRemoved) {
			t.Fatalf("Upload after the stamp: %v, want ErrDeviceRemoved", err)
		}
	})

	t.Run("remote with a stale sign-in is refused and writes nothing", func(t *testing.T) {
		e := newRepoEnv(t)
		uid := uniqueUID()
		e.seed(t, uid, 1, 3)
		e.putMark(t, uid, dvc(0), it0)
		svc := e.removalSvc(now)
		err := svc.Remove(signedInAt(uid, now.Add(-itReauth-time.Second)), uid, dvc(0), RemoveRemote)
		wantReason(t, err, commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED)
		if _, ok := e.snap(t, uid, dvc(0)).Data()["removedAt"]; ok || len(e.poolDocs(t, uid, dvc(0))) != 3 {
			t.Fatal("a refused removal touched the live device")
		}
		if data, _ := e.markData(t, uid, dvc(0)); !data["removedAt"].(time.Time).Equal(it0) {
			t.Fatalf("a refused removal moved the mark: %v", data)
		}
		if err := svc.Remove(signedInAt(uid, now), uid, dvc(0), RemoveRemote); err != nil {
			t.Fatalf("remote with a recent sign-in: %v", err)
		}
		if n := e.deviceDocs(t, uid); n != 0 {
			t.Fatalf("%d device refs left", n)
		}
	})
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
	if err := e.repo.MarkRemoved(ctx, uid, dvc(1), now, true); err != nil {
		t.Fatal(err)
	}
	if err := e.repo.MarkRemoved(ctx, uid, dvc(1), now.Add(time.Hour), false); err != nil { // a retry: no sign-in needed
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

// TestRemoval_RegisterAtCapFinishesStuckRemoval (code review I-1, security audit M2): a REMOTE removal that crashed right
// after its mark, while the account is at the cap, must not leave a slot nobody can see or free. The next Register of a
// new id finishes it (no sign-in: the id is marked) and then succeeds; the stuck document and its whole pool are gone and
// the mark stays.
func TestRemoval_RegisterAtCapFinishesStuckRemoval(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seed(t, uid, MaxDevicesPerUser, 3) // dvc(0)..dvc(4), each with a pool of 3 and a last resort
	now := it0.Add(time.Hour)
	if err := e.repo.MarkRemoved(ctx, uid, dvc(2), now, true); err != nil { // the crash: mark written, nothing deleted
		t.Fatal(err)
	}
	if _, err := e.register(t, uid, dvc(9), skey(9), now); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("repository Register at the cap with a removing device: %v, want ErrDeviceLimit", err)
	}
	d, err := e.removalSvc(now).Register(ctx, uid, dvc(9), skey(9))
	if err != nil {
		t.Fatalf("Register past a stuck removal: %v", err)
	}
	if d.ID != dvc(9) {
		t.Fatalf("registered %q", d.ID)
	}
	if _, err := e.repo.deviceRef(uid, dvc(2)).Get(ctx); status.Code(err) != codes.NotFound {
		t.Fatalf("the stuck device document: %v, want deleted", err)
	}
	if left := e.poolDocs(t, uid, dvc(2)); len(left) != 0 {
		t.Fatalf("%d pool documents of the stuck device left", len(left))
	}
	if _, ok := e.markData(t, uid, dvc(2)); !ok {
		t.Fatal("finishing the removal dropped the mark")
	}
	if n := e.deviceDocs(t, uid); n != MaxDevicesPerUser {
		t.Fatalf("%d device refs, want %d", n, MaxDevicesPerUser)
	}
	// Five live devices now: the next new id is a plain LIMIT_REACHED, and nothing live was removed.
	_, err = e.removalSvc(now).Register(ctx, uid, dvc(8), skey(8))
	wantReason(t, err, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if list, err := e.repo.List(ctx, uid); err != nil || len(list) != MaxDevicesPerUser {
		t.Fatalf("List = %d devices, %v; want %d", len(list), err, MaxDevicesPerUser)
	}
}

// raceInFlight bounds how many race pairs run at once, and raceAttempts how often one side of a pair is tried when it
// gets a transient answer. Measured on the emulator (fix round 2026-11-23): 50 pairs released at once made 12 of the 50
// Registers exceed the 5 s transaction budget (txTimeout), and 10 in flight still gave 8 transient answers in 100 calls.
// The emulator resolves each pair's read-then-write lock conflict slowly (about 2.5 s a pair when run one at a time).
// Never an invariant failure. A client retries exactly these answers (UNAVAILABLE carries a retry hint, and a retried
// REMOTE removal of a marked id needs no sign-in), so the test does the same and then asserts strictly.
const (
	raceInFlight = 10
	raceAttempts = 4
)

// transientErr reports a contention or deadline answer, at the repository (gRPC status, context) or the service
// (UNAVAILABLE, DEADLINE_EXCEEDED) level.
func transientErr(err error) bool {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.Code == connect.CodeUnavailable || ae.Code == connect.CodeDeadlineExceeded
	}
	return store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded
}

// TestRemoval_RaceWithRegister: a REMOTE Remove and a Register of the same id, in 50 pairs (one uid each) run
// concurrently, raceInFlight at a time, with both calls of a pair released together (code review Minor 4: concurrent,
// not one pair after another). A transient answer is retried, as a client would, up to raceAttempts. Whatever the order
// inside a pair, once both returned that uid has a mark and no device document (the register either landed first and
// was removed, or saw the mark and was refused), and the register answered success or ErrDeviceRemoved only. Every
// assertion is per uid.
func TestRemoval_RaceWithRegister(t *testing.T) {
	const pairs = 50
	e := newRepoEnv(t)
	ctx := context.Background()
	now := it0.Add(time.Hour)
	svc := e.removalSvc(now)
	type result struct {
		uid           string
		regErr, rmErr error
		retries       int
	}
	results := make([]result, pairs)
	for i := range results {
		results[i].uid = uniqueUID()
	}
	retry := func(retries *int, call func() error) error {
		var err error
		for attempt := 0; attempt < raceAttempts; attempt++ {
			if err = call(); !transientErr(err) {
				return err
			}
			*retries++
		}
		return err
	}
	sem := make(chan struct{}, raceInFlight)
	var all sync.WaitGroup
	for i := range results {
		r := &results[i]
		all.Add(1)
		go func() {
			defer all.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			var regRetries, rmRetries int
			var pair sync.WaitGroup
			start := make(chan struct{})
			pair.Add(2)
			go func() {
				defer pair.Done()
				<-start
				r.regErr = retry(&regRetries, func() error { _, err := e.register(t, r.uid, dvc(1), skey(1), now); return err })
			}()
			go func() {
				defer pair.Done()
				<-start
				r.rmErr = retry(&rmRetries, func() error {
					return svc.Remove(signedInAt(r.uid, now), r.uid, dvc(1), RemoveRemote)
				})
			}()
			close(start)
			pair.Wait()
			r.retries = regRetries + rmRetries
		}()
	}
	all.Wait()
	refused := 0
	for i, r := range results {
		if r.rmErr != nil {
			t.Errorf("pair %d: remove: %v", i, r.rmErr)
			continue
		}
		switch {
		case r.regErr == nil:
		case errors.Is(r.regErr, ErrDeviceRemoved):
			refused++
		default:
			t.Errorf("pair %d: register: %v", i, r.regErr)
			continue
		}
		if _, ok := e.markData(t, r.uid, dvc(1)); !ok {
			t.Errorf("pair %d: no mark", i)
		}
		snap, err := e.repo.deviceRef(r.uid, dvc(1)).Get(ctx)
		switch {
		case status.Code(err) == codes.NotFound:
		case err != nil:
			t.Errorf("pair %d: get device: %v", i, err)
		default:
			if _, has := snap.Data()["removedAt"]; !has {
				t.Errorf("pair %d: a live device document without removedAt beside a mark", i)
			} else {
				t.Errorf("pair %d: the device document survived the removal", i)
			}
		}
	}
	retried := 0
	for _, r := range results {
		retried += r.retries
	}
	t.Logf("register refused in %d of %d pairs; %d transient answers retried", refused, pairs, retried)
}

// TestRemoval_ExportListsPendingRemoval (security audit M2(a)): the export reads the device documents on the emulator; a
// document carrying removedAt is listed under removed_devices with removal_pending and its stored metadata until it is
// deleted, then only its mark is.
func TestRemoval_ExportListsPendingRemoval(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seed(t, uid, 2, 3)
	if err := e.repo.MarkRemoved(ctx, uid, dvc(1), it0, true); err != nil { // stopped after the mark
		t.Fatal(err)
	}
	type row struct {
		DeviceID       string `json:"device_id"`
		RemovalPending bool   `json:"removal_pending"`
		Device         *struct {
			KeyPackageCount int  `json:"key_package_count"`
			HasLastResort   bool `json:"has_last_resort"`
		} `json:"device"`
	}
	export := func() (devices []string, removed []row) {
		t.Helper()
		var buf bytes.Buffer
		if err := NewExporter(e.repo).ExportUser(ctx, uid, &buf); err != nil {
			t.Fatal(err)
		}
		var out struct {
			Devices []struct {
				DeviceID string `json:"device_id"`
			} `json:"devices"`
			RemovedDevices []row `json:"removed_devices"`
		}
		if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		for _, d := range out.Devices {
			devices = append(devices, d.DeviceID)
		}
		return devices, out.RemovedDevices
	}
	devices, removed := export()
	if fmt.Sprint(devices) != fmt.Sprint([]string{dvc(0)}) {
		t.Fatalf("devices = %v, want only %s", devices, dvc(0))
	}
	if len(removed) != 1 || removed[0].DeviceID != dvc(1) || !removed[0].RemovalPending || removed[0].Device == nil ||
		removed[0].Device.KeyPackageCount != 3 || !removed[0].Device.HasLastResort {
		t.Fatalf("removed_devices = %+v, want %s pending with its pool of 3 and a last resort", removed, dvc(1))
	}
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatal(err)
	}
	if _, removed = export(); len(removed) != 1 || removed[0].RemovalPending || removed[0].Device != nil {
		t.Fatalf("after the delete removed_devices = %+v, want the mark only", removed)
	}
}

// TestRemoval_ListRemovalMarksPagesByID: the export read pages the marks by document id, afterID exclusive.
func TestRemoval_ListRemovalMarksPagesByID(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	for i := 0; i < 5; i++ {
		if err := e.repo.MarkRemoved(ctx, uid, dvc(i), it0.Add(time.Duration(i)*time.Minute), true); err != nil {
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
		if err := e.repo.MarkRemoved(ctx, uid, id, it0, true); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.repo.MarkRemoved(ctx, other, dvc(0), it0, true); err != nil {
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
