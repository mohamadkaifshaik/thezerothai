//go:build integration

package keys

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

var it0 = time.Date(2026, 11, 18, 6, 0, 0, 0, time.UTC)

type repoEnv struct {
	client *firestore.Client
	repo   *FirestoreRepo
}

func newRepoEnv(t *testing.T) *repoEnv {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return &repoEnv{client: client, repo: NewFirestoreRepo(client)}
}

func uniqueUID() string { return fmt.Sprintf("keys-it-%d", rand.Int63()) }

func dvc(n int) string { return fmt.Sprintf("device-%016d", n) }

func skey(b byte) []byte { return bytes.Repeat([]byte{b}, SignatureKeyBytes) }

func pkgN(n int) []byte { return []byte(fmt.Sprintf("package-%04d", n)) }

func pkgRange(from, to int) [][]byte {
	var out [][]byte
	for i := from; i < to; i++ {
		out = append(out, pkgN(i))
	}
	return out
}

func (e *repoEnv) register(t *testing.T, uid, id string, key []byte, now time.Time) (Device, error) {
	t.Helper()
	return e.repo.Register(context.Background(), uid, Device{ID: id, SignatureKey: key}, now)
}

func (e *repoEnv) mustRegister(t *testing.T, uid, id string, key []byte, now time.Time) Device {
	t.Helper()
	d, err := e.register(t, uid, id, key, now)
	if err != nil {
		t.Fatalf("register %s: %v", id, err)
	}
	return d
}

func (e *repoEnv) snap(t *testing.T, uid, id string) *firestore.DocumentSnapshot {
	t.Helper()
	s, err := e.repo.deviceRef(uid, id).Get(context.Background())
	if err != nil {
		t.Fatalf("get device doc: %v", err)
	}
	return s
}

func (e *repoEnv) poolDocs(t *testing.T, uid, id string) []*firestore.DocumentSnapshot {
	t.Helper()
	s, err := e.repo.poolCol(uid, id).Limit(MaxPoolSize + 50).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func pkgDocID(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])[:32]
}

func TestRepo_RegisterListRoundTrip(t *testing.T) {
	e := newRepoEnv(t)
	uid := uniqueUID()
	key := skey(7)
	d := e.mustRegister(t, uid, dvc(1), key, it0)
	key[0] = 99 // the caller's slice is not aliased
	if d.ID != dvc(1) || !d.CreatedAt.Equal(it0) || !d.LastSeenAt.Equal(it0) || d.PoolCount != 0 || d.HasLastResort || !bytes.Equal(d.SignatureKey, skey(7)) {
		t.Fatalf("registered device = %+v", d)
	}
	data := e.snap(t, uid, dvc(1)).Data()
	if len(data) != 4 {
		t.Fatalf("stored fields = %v, want signatureKey, createdAt, lastSeenAt, poolCount only", data)
	}
	if !bytes.Equal(data["signatureKey"].([]byte), skey(7)) || !data["createdAt"].(time.Time).Equal(it0) ||
		!data["lastSeenAt"].(time.Time).Equal(it0) || data["poolCount"].(int64) != 0 {
		t.Fatalf("stored = %v", data)
	}
	e.mustRegister(t, uid, dvc(2), skey(8), it0.Add(time.Minute))
	got, err := e.repo.List(context.Background(), uid)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != dvc(1) || got[1].ID != dvc(2) {
		t.Fatalf("list (oldest first) = %+v", got)
	}
	got[0].SignatureKey[0] ^= 0xff
	again, _ := e.repo.List(context.Background(), uid)
	if !bytes.Equal(again[0].SignatureKey, skey(7)) {
		t.Fatal("list result aliases state")
	}
	if none, err := e.repo.List(context.Background(), uniqueUID()); err != nil || len(none) != 0 {
		t.Fatalf("list of unknown user = %v, %v", none, err)
	}
}

func TestRepo_SixthDeviceRefused(t *testing.T) {
	e := newRepoEnv(t)
	uid := uniqueUID()
	for i := 1; i <= MaxDevicesPerUser; i++ {
		e.mustRegister(t, uid, dvc(i), skey(byte(i)), it0)
	}
	if _, err := e.register(t, uid, dvc(6), skey(6), it0); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("sixth device err = %v, want ErrDeviceLimit", err)
	}
	// An existing device still registers at the cap, and the refused one left nothing behind.
	e.mustRegister(t, uid, dvc(3), skey(3), it0)
	if got, _ := e.repo.List(context.Background(), uid); len(got) != MaxDevicesPerUser {
		t.Fatalf("devices = %d, want %d", len(got), MaxDevicesPerUser)
	}
}

// Two new ids racing at four existing devices: exactly one gets the fifth slot.
func TestRepo_ConcurrentRegisterExactlyOneWins(t *testing.T) {
	e := newRepoEnv(t)
	for round := 0; round < 10; round++ {
		uid := uniqueUID()
		for i := 1; i <= MaxDevicesPerUser-1; i++ {
			e.mustRegister(t, uid, dvc(i), skey(byte(i)), it0)
		}
		var wg sync.WaitGroup
		errs := make([]error, 2)
		start := make(chan struct{})
		for i := range errs {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				_, errs[i] = e.register(t, uid, dvc(100+i), skey(byte(100+i)), it0)
			}()
		}
		close(start)
		wg.Wait()
		ok, limited := 0, 0
		for _, err := range errs {
			switch {
			case err == nil:
				ok++
			case errors.Is(err, ErrDeviceLimit):
				limited++
			default:
				t.Fatalf("round %d: unexpected error %v", round, err)
			}
		}
		if ok != 1 || limited != 1 {
			t.Fatalf("round %d: %d succeeded, %d refused, want 1 and 1", round, ok, limited)
		}
		if got, _ := e.repo.List(context.Background(), uid); len(got) != MaxDevicesPerUser {
			t.Fatalf("round %d: %d devices stored", round, len(got))
		}
	}
}

func TestRepo_SameDeviceIDUnderTwoUsersIsIndependent(t *testing.T) {
	e := newRepoEnv(t)
	a, b := uniqueUID(), uniqueUID()
	e.mustRegister(t, a, dvc(1), skey(1), it0)
	e.mustRegister(t, b, dvc(1), skey(2), it0) // a different key under another user is not a mismatch
	if _, _, err := e.repo.Upload(context.Background(), a, dvc(1), pkgRange(0, 3), []byte("lr"), it0); err != nil {
		t.Fatal(err)
	}
	gb, _ := e.repo.List(context.Background(), b)
	if len(gb) != 1 || gb[0].PoolCount != 0 || gb[0].HasLastResort || !bytes.Equal(gb[0].SignatureKey, skey(2)) {
		t.Fatalf("user b's device = %+v", gb)
	}
	if err := e.repo.Remove(context.Background(), a, dvc(1)); err != nil {
		t.Fatal(err)
	}
	if gb, _ = e.repo.List(context.Background(), b); len(gb) != 1 {
		t.Fatal("removing a's device touched b's")
	}
}

func TestRepo_KeyMismatch(t *testing.T) {
	e := newRepoEnv(t)
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	if _, err := e.register(t, uid, dvc(1), skey(2), it0.Add(48*time.Hour)); !errors.Is(err, ErrKeyMismatch) {
		t.Fatalf("err = %v, want ErrKeyMismatch", err)
	}
	if d := e.snap(t, uid, dvc(1)).Data(); !d["lastSeenAt"].(time.Time).Equal(it0) || !bytes.Equal(d["signatureKey"].([]byte), skey(1)) {
		t.Fatalf("a refused register changed the device: %v", d)
	}
}

func TestRepo_UploadStoresDedupesAndReplays(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	in := append(pkgRange(0, 5), pkgN(2), pkgN(0)) // duplicates inside the batch
	n, hasLR, err := e.repo.Upload(ctx, uid, dvc(1), in, nil, it0)
	if err != nil || n != 5 || hasLR {
		t.Fatalf("upload = %d, %v, %v", n, hasLR, err)
	}
	docs := e.poolDocs(t, uid, dvc(1))
	if len(docs) != 5 {
		t.Fatalf("pool documents = %d", len(docs))
	}
	for _, s := range docs {
		d := s.Data()
		if len(d) != 2 || s.Ref.ID != pkgDocID(d["data"].([]byte)) || len(s.Ref.ID) != 32 || !d["createdAt"].(time.Time).Equal(it0) {
			t.Fatalf("pool doc %s = %v", s.Ref.ID, d)
		}
	}
	// Replay of the same upload, and an overlap with new ones.
	if n, _, err = e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, 5), nil, it0.Add(time.Minute)); err != nil || n != 5 {
		t.Fatalf("replay = %d, %v", n, err)
	}
	if n, _, err = e.repo.Upload(ctx, uid, dvc(1), pkgRange(3, 8), nil, it0.Add(2*time.Minute)); err != nil || n != 8 {
		t.Fatalf("overlap = %d, %v", n, err)
	}
	if got := e.snap(t, uid, dvc(1)).Data()["poolCount"].(int64); got != 8 || len(e.poolDocs(t, uid, dvc(1))) != 8 {
		t.Fatalf("poolCount = %d, documents = %d, want 8", got, len(e.poolDocs(t, uid, dvc(1))))
	}
	if got, _ := e.repo.List(ctx, uid); got[0].PoolCount != 8 {
		t.Fatalf("listed PoolCount = %d", got[0].PoolCount)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	if _, _, err = e.repo.Upload(ctx, uid, dvc(9), pkgRange(0, 1), nil, it0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown device err = %v, want ErrNotFound", err)
	}
}

func TestRepo_PoolCapKeepsOldest(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	if n, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, 100), nil, it0); err != nil || n != 100 {
		t.Fatalf("fill = %d, %v", n, err)
	}
	if n, _, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(100, 103), nil, it0); err != nil || n != 100 {
		t.Fatalf("full pool upload = %d, %v", n, err)
	}
	if docs := e.poolDocs(t, uid, dvc(1)); len(docs) != 100 {
		t.Fatalf("pool documents = %d", len(docs))
	}
	if _, err := e.repo.poolCol(uid, dvc(1)).Doc(pkgDocID(pkgN(100))).Get(ctx); err == nil {
		t.Fatal("a package past the cap was stored")
	}
	// A partly fitting batch: free two slots, upload five new, the first two fit.
	uid2 := uniqueUID()
	e.mustRegister(t, uid2, dvc(1), skey(1), it0)
	if _, _, err := e.repo.Upload(ctx, uid2, dvc(1), pkgRange(0, 98), nil, it0); err != nil {
		t.Fatal(err)
	}
	n, _, err := e.repo.Upload(ctx, uid2, dvc(1), pkgRange(200, 205), nil, it0)
	if err != nil || n != 100 {
		t.Fatalf("partial = %d, %v", n, err)
	}
	e.assertPoolInvariant(t, uid2, dvc(1))
	for i, want := range []bool{true, true, false, false, false} {
		_, gerr := e.repo.poolCol(uid2, dvc(1)).Doc(pkgDocID(pkgN(200 + i))).Get(ctx)
		if (gerr == nil) != want {
			t.Fatalf("package %d stored = %v, want %v", 200+i, gerr == nil, want)
		}
	}
}

func TestRepo_LastResortReplaceKeep(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	lr := []byte("last-resort-one")
	if _, has, err := e.repo.Upload(ctx, uid, dvc(1), nil, lr, it0); err != nil || !has {
		t.Fatalf("set = %v, %v", has, err)
	}
	lr[0] = 'X' // not aliased
	if got := e.snap(t, uid, dvc(1)).Data()["lastResort"].([]byte); string(got) != "last-resort-one" {
		t.Fatalf("stored = %q", got)
	}
	for _, empty := range [][]byte{nil, {}} {
		if _, has, err := e.repo.Upload(ctx, uid, dvc(1), pkgRange(0, 1), empty, it0); err != nil || !has {
			t.Fatalf("keep = %v, %v", has, err)
		}
		if got := e.snap(t, uid, dvc(1)).Data()["lastResort"].([]byte); string(got) != "last-resort-one" {
			t.Fatalf("an empty last resort replaced it: %q", got)
		}
	}
	if _, has, err := e.repo.Upload(ctx, uid, dvc(1), nil, []byte("two"), it0); err != nil || !has {
		t.Fatal(has, err)
	}
	if got := e.snap(t, uid, dvc(1)).Data()["lastResort"].([]byte); string(got) != "two" {
		t.Fatalf("replace = %q", got)
	}
	e.assertPoolInvariant(t, uid, dvc(1))
	if d, _ := e.repo.List(ctx, uid); !d[0].HasLastResort || d[0].PoolCount != 1 {
		t.Fatalf("listed = %+v", d)
	}
}

func TestRepo_LastSeenRefreshOnlyAfter24h(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	first := e.snap(t, uid, dvc(1)).UpdateTime

	// Register and upload (with nothing to store) at exactly 24 h and just under: no write at all.
	for _, at := range []time.Duration{time.Hour, 24 * time.Hour} {
		d := e.mustRegister(t, uid, dvc(1), skey(1), it0.Add(at))
		if !d.LastSeenAt.Equal(it0) {
			t.Fatalf("at +%v LastSeenAt = %v", at, d.LastSeenAt)
		}
		if _, _, err := e.repo.Upload(ctx, uid, dvc(1), nil, nil, it0.Add(at)); err != nil {
			t.Fatal(err)
		}
		if got := e.snap(t, uid, dvc(1)).UpdateTime; !got.Equal(first) {
			t.Fatalf("at +%v the document was rewritten (%v -> %v)", at, first, got)
		}
	}
	// Past 24 h the refresh happens, once.
	late := it0.Add(24*time.Hour + time.Second)
	d := e.mustRegister(t, uid, dvc(1), skey(1), late)
	if !d.LastSeenAt.Equal(late) {
		t.Fatalf("LastSeenAt = %v, want %v", d.LastSeenAt, late)
	}
	second := e.snap(t, uid, dvc(1))
	if second.UpdateTime.Equal(first) || !second.Data()["lastSeenAt"].(time.Time).Equal(late) || !second.Data()["createdAt"].(time.Time).Equal(it0) {
		t.Fatalf("refresh not stored correctly: %v", second.Data())
	}
	if _, _, err := e.repo.Upload(ctx, uid, dvc(1), nil, nil, late.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got := e.snap(t, uid, dvc(1)).UpdateTime; !got.Equal(second.UpdateTime) {
		t.Fatal("a second call within 24 h rewrote the document")
	}
	// An upload past 24 h refreshes too.
	later := late.Add(25 * time.Hour)
	if _, _, err := e.repo.Upload(ctx, uid, dvc(1), nil, nil, later); err != nil {
		t.Fatal(err)
	}
	if got := e.snap(t, uid, dvc(1)).Data()["lastSeenAt"].(time.Time); !got.Equal(later) {
		t.Fatalf("upload refresh = %v", got)
	}
}

func TestRepo_RemoveDeletesPoolAndDevice(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	e.mustRegister(t, uid, dvc(2), skey(2), it0)
	for _, id := range []string{dvc(1), dvc(2)} {
		if _, _, err := e.repo.Upload(ctx, uid, id, pkgRange(0, 100), []byte("lr"), it0); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatal(err)
	}
	if n := len(e.poolDocs(t, uid, dvc(1))); n != 0 {
		t.Fatalf("%d pool documents left", n)
	}
	if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); err == nil {
		t.Fatal("device document left")
	}
	if n := len(e.poolDocs(t, uid, dvc(2))); n != 100 {
		t.Fatalf("the other device's pool = %d", n)
	}
	e.assertPoolInvariant(t, uid, dvc(2))
	if got, _ := e.repo.List(ctx, uid); len(got) != 1 || got[0].ID != dvc(2) {
		t.Fatalf("list = %+v", got)
	}
	if err := e.repo.Remove(ctx, uid, dvc(1)); err != nil {
		t.Fatalf("removing a missing device: %v", err)
	}
	// The id can be registered afresh, with an empty pool.
	if d := e.mustRegister(t, uid, dvc(1), skey(5), it0); d.PoolCount != 0 || d.HasLastResort {
		t.Fatalf("re-registered = %+v", d)
	}
}
