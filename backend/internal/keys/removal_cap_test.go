package keys

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// Register at the cap finishes REMOTE removals that stopped after their mark (code review I-1, security audit M2): a
// device document carrying removedAt holds a slot nobody can see in ListMyKeyDevices, so without this up to 5
// interrupted removals would lock the account out of E2EE with no way back. Those ids are already marked, so finishing
// them needs no sign-in; Register then runs once more.

// capID is the i-th filler device id of these tests.
func capID(i int) string { return fmt.Sprintf("device-cap-%08d", i) }

// fillToCap registers MaxDevicesPerUser devices for uidA, each with a pool, and marks the given ones removing (a REMOTE
// removal that stopped right after its mark transaction: mark written, document stamped, nothing deleted).
func fillToCap(t *testing.T, s Service, repo *fakeRepo, stuck ...int) {
	t.Helper()
	for i := 0; i < MaxDevicesPerUser; i++ {
		mustRegister(t, s, capID(i), sigKey(byte(i+1)))
		if _, _, err := s.Upload(context.Background(), uidA, capID(i), pkgs(i*10, 3), []byte("last-resort")); err != nil {
			t.Fatal(err)
		}
	}
	for _, i := range stuck {
		k := devKey(uidA, capID(i))
		repo.marks[k] = RemovalMark{DeviceID: capID(i), RemovedAt: t0, ExpireAt: t0.Add(RemovalMarkTTL)}
		repo.removing[k] = true
	}
	repo.ops = nil
}

func TestRegister_AtCapFinishesStuckRemovals(t *testing.T) {
	cases := []struct {
		name    string
		stuck   []int
		wantOps []string
	}{
		{"one stuck removal frees its slot", []int{2}, []string{"Register", "Remove", "Register"}},
		{"every stuck removal is finished", []int{1, 3}, []string{"Register", "Remove", "Remove", "Register"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, _ := newRemovalService(t)
			fillToCap(t, s, repo, tc.stuck...)
			d, err := s.Register(context.Background(), uidA, devID2, sigKey(9))
			if err != nil {
				t.Fatalf("register past stuck removals: %v", err)
			}
			if d.ID != devID2 {
				t.Fatalf("registered %q", d.ID)
			}
			if !slices.Equal(repo.ops, tc.wantOps) {
				t.Errorf("repository calls = %v, want %v", repo.ops, tc.wantOps)
			}
			for _, i := range tc.stuck {
				k := devKey(uidA, capID(i))
				if repo.find(uidA, capID(i)) >= 0 || len(repo.pool[k]) != 0 || len(repo.lastResort[k]) != 0 {
					t.Fatalf("the stuck device %d (or its pool) is still there", i)
				}
				if _, ok := repo.marks[k]; !ok {
					t.Fatalf("finishing the removal dropped the mark of device %d", i)
				}
			}
			if n := len(repo.devices[uidA]); n != MaxDevicesPerUser-len(tc.stuck)+1 {
				t.Fatalf("%d device documents, want %d", n, MaxDevicesPerUser-len(tc.stuck)+1)
			}
		})
	}
}

// TestRegister_AtCapWithoutStuckRemovalsIsLimitReached: five live devices are a plain LIMIT_REACHED; nothing is removed.
func TestRegister_AtCapWithoutStuckRemovalsIsLimitReached(t *testing.T) {
	s, repo, _ := newRemovalService(t)
	fillToCap(t, s, repo)
	_, err := s.Register(context.Background(), uidA, devID2, sigKey(9))
	wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "key_devices")
	if !slices.Equal(repo.ops, []string{"Register"}) {
		t.Fatalf("repository calls = %v, want one Register", repo.ops)
	}
}

// TestRegister_StuckRemovalRetriesOnce: Register runs at most twice. If the second run still sees a stuck removal (one
// that appeared meanwhile), the answer is LIMIT_REACHED, not a loop.
func TestRegister_StuckRemovalRetriesOnce(t *testing.T) {
	s, repo, _ := newRemovalService(t)
	fillToCap(t, s, repo, 0)
	// Every finished removal is replaced by a new stuck one, so the retry finds the cap still full of a removing device.
	repo.afterRemove = func() {
		next := capID(100 + len(repo.devices[uidA]))
		repo.devices[uidA] = append(repo.devices[uidA], Device{ID: next, SignatureKey: sigKey(42), CreatedAt: t0, LastSeenAt: t0})
		repo.removing[devKey(uidA, next)] = true
	}
	_, err := s.Register(context.Background(), uidA, devID2, sigKey(9))
	wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "key_devices")
	if !slices.Equal(repo.ops, []string{"Register", "Remove", "Register"}) {
		t.Fatalf("repository calls = %v, want Register, Remove, Register", repo.ops)
	}
}

// TestRegister_StuckRemovalFailureIsMapped: a failed finish is the usual mapped error and Register does not run again.
func TestRegister_StuckRemovalFailureIsMapped(t *testing.T) {
	s, repo, _ := newRemovalService(t)
	fillToCap(t, s, repo, 4)
	repo.removeErr = errUnavailableForTest()
	_, err := s.Register(context.Background(), uidA, devID2, sigKey(9))
	wantErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if !slices.Equal(repo.ops, []string{"Register", "Remove"}) {
		t.Fatalf("repository calls = %v, want Register, Remove", repo.ops)
	}
}

// TestFakeRepo_RecordsOpBeforeError (code review nit): every recording method of the fake records its call before it
// fails, so a test that injects an error still sees which calls were made.
func TestFakeRepo_RecordsOpBeforeError(t *testing.T) {
	ctx := context.Background()
	calls := map[string]func(*fakeRepo) error{
		"Register": func(f *fakeRepo) error { _, err := f.Register(ctx, uidA, Device{ID: devID}, t0); return err },
		"Remove":   func(f *fakeRepo) error { return f.Remove(ctx, uidA, devID) },
		"Upload":   func(f *fakeRepo) error { _, _, err := f.Upload(ctx, uidA, devID, pkgs(0, 1), nil, t0); return err },
	}
	for name, call := range calls {
		t.Run(name, func(t *testing.T) {
			f := newFakeRepo()
			f.err = errUnavailableForTest()
			if err := call(f); err == nil {
				t.Fatal("no error")
			}
			if !slices.Equal(f.ops, []string{name}) {
				t.Fatalf("ops = %v, want [%s]", f.ops, name)
			}
		})
	}
}

// TestStuckRemovalsError:the error is ErrDeviceLimit to errors.Is, carries the ids for the service only, and its text
// never names them.
func TestStuckRemovalsError(t *testing.T) {
	err := fmt.Errorf("wrapped: %w", &StuckRemovalsError{DeviceIDs: []string{devID, devID2}})
	if !errors.Is(err, ErrDeviceLimit) {
		t.Fatal("not ErrDeviceLimit")
	}
	var stuck *StuckRemovalsError
	if !errors.As(err, &stuck) || !slices.Equal(stuck.DeviceIDs, []string{devID, devID2}) {
		t.Fatalf("ids lost: %v", stuck)
	}
	if msg := err.Error(); strings.Contains(msg, devID) || strings.Contains(msg, devID2) {
		t.Fatalf("the text names a device id: %q", msg)
	}
}
