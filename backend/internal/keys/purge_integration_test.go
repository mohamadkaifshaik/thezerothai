//go:build integration

package keys

import (
	"context"
	"testing"
)

func (e *repoEnv) deviceDocs(t *testing.T, uid string) int {
	t.Helper()
	refs, err := e.repo.devices(uid).DocumentRefs(context.Background()).GetAll() // includes missing documents
	if err != nil {
		t.Fatal(err)
	}
	return len(refs)
}

// seed registers n devices with a pool of pool packages each (and a last resort) for uid.
func (e *repoEnv) seed(t *testing.T, uid string, n, pool int) {
	t.Helper()
	for i := 0; i < n; i++ {
		e.mustRegister(t, uid, dvc(i), skey(byte(i+1)), it0)
		// The repository refuses more than MaxUploadBatch packages per call: upload in chunks (an over-full request is
		// dropped by the pool cap, as before).
		for from := i * 1000; from < i*1000+pool; from += MaxUploadBatch {
			to := min(from+MaxUploadBatch, i*1000+pool)
			if _, _, err := e.repo.Upload(context.Background(), uid, dvc(i), pkgRange(from, to), []byte("last-resort"), it0); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestPurge_RemovesEveryDeviceAndPoolAndSurvivesResume(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid, other := uniqueUID(), uniqueUID()
	e.seed(t, uid, MaxDevicesPerUser, MaxPoolSize)
	e.seed(t, other, 1, 10) // another user's device must survive

	er := NewEraser(e.repo)
	var cp Checkpoint
	for i := 0; ; i++ {
		if i > 20 {
			t.Fatal("the purge did not finish")
		}
		next, done, err := er.PurgeUser(ctx, uid, cp)
		if err != nil {
			t.Fatal(err)
		}
		// Replaying the same checkpoint (a crash before it was saved) is harmless: it just erases the next device.
		if _, _, err := er.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatalf("replay from checkpoint %+v: %v", cp, err)
		}
		cp = next
		if done {
			break
		}
	}
	if n := e.deviceDocs(t, uid); n != 0 {
		t.Errorf("%d device documents (including missing ones) remain", n)
	}
	if got := e.poolDocs(t, uid, dvc(0)); len(got) != 0 {
		t.Errorf("%d pool documents remain", len(got))
	}
	if devs, err := e.repo.List(ctx, other); err != nil || len(devs) != 1 || devs[0].PoolCount != 10 {
		t.Errorf("other user's devices = %+v, %v", devs, err)
	}
	// A repeat after completion is done at once and writes nothing.
	if _, done, err := er.PurgeUser(ctx, uid, cp); err != nil || !done {
		t.Errorf("repeat: done=%v err=%v", done, err)
	}
}

func TestPurge_OneDevicePerCallWithCheckpoint(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seed(t, uid, 3, 5)
	er := NewEraser(e.repo)
	cp, done, err := er.PurgeUser(ctx, uid, Checkpoint{})
	if err != nil || done || cp.Devices != 1 || cp.LastDevice == "" {
		t.Fatalf("cp=%+v done=%v err=%v", cp, done, err)
	}
	if n := e.deviceDocs(t, uid); n != 2 {
		t.Errorf("%d devices left after one call, want 2", n)
	}
}

func TestPurge_FindsOrphanPoolUnderMissingDevice(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.seed(t, uid, 1, 120) // pool of 100 max: upload keeps 100
	// A concurrent Remove can delete the device document and leave pool documents behind.
	if _, err := e.repo.deviceRef(uid, dvc(0)).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	if got := e.poolDocs(t, uid, dvc(0)); len(got) == 0 {
		t.Fatal("setup: no orphan pool documents")
	}
	er := NewEraser(e.repo)
	var cp Checkpoint
	for i := 0; i < 10; i++ {
		var done bool
		var err error
		if cp, done, err = er.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatal(err)
		}
		if done {
			break
		}
	}
	if got := e.poolDocs(t, uid, dvc(0)); len(got) != 0 {
		t.Errorf("%d orphan pool documents remain", len(got))
	}
	if n := e.deviceDocs(t, uid); n != 0 {
		t.Errorf("%d device refs remain", n)
	}
}
