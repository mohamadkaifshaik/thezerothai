package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	uidA   = "uid-alice"
	devID  = "device-aaaaaaaaaaaa"
	devID2 = "device-bbbbbbbbbbbb"
)

var t0 = time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)

func sigKey(tag byte) []byte { return bytes.Repeat([]byte{tag}, SignatureKeyBytes) }

func pkg(n int) []byte { return []byte(fmt.Sprintf("package-%04d", n)) }

func pkgs(from, count int) [][]byte {
	out := make([][]byte, 0, count)
	for i := 0; i < count; i++ {
		out = append(out, pkg(from+i))
	}
	return out
}

func newTestService(t *testing.T) (Service, *fakeRepo, *fakeClock) {
	t.Helper()
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	return New(Deps{Repo: repo, Now: clk.now}), repo, clk
}

// wantErr asserts err is an *apierr.Error with the given shape; meta pairs are key, value.
func wantErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta ...string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want *apierr.Error", err)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("err = %v/%v, want %v/%v", ae.Code, ae.Reason, code, reason)
	}
	for i := 0; i+1 < len(meta); i += 2 {
		if ae.Metadata[meta[i]] != meta[i+1] {
			t.Fatalf("metadata[%q] = %q, want %q", meta[i], ae.Metadata[meta[i]], meta[i+1])
		}
	}
}

func wantValidation(t *testing.T, err error, field string) {
	t.Helper()
	wantErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", field)
}

func TestValidDeviceID(t *testing.T) {
	for _, tc := range []struct {
		id   string
		want bool
	}{
		{strings.Repeat("a", 16), true},
		{strings.Repeat("a", 15), false},
		{strings.Repeat("A", 64), true},
		{strings.Repeat("a", 65), false},
		{"abc_DEF-123_ghi-456", true},
		{"abc def 1234567890", false},
		{"abc.def.1234567890", false},
		{"abcdefghijklmnop\n", false},
		{"", false},
	} {
		if got := ValidDeviceID(tc.id); got != tc.want {
			t.Errorf("ValidDeviceID(%q) = %v, want %v", tc.id, got, tc.want)
		}
	}
}

func TestDeviceActive(t *testing.T) {
	d := Device{LastSeenAt: t0}
	for _, tc := range []struct {
		name string
		now  time.Time
		want bool
	}{
		{"fresh", t0, true},
		{"one nanosecond short of 30 days", t0.Add(InactiveAfter - 1), true},
		{"exactly 30 days", t0.Add(InactiveAfter), false},
		{"past 30 days", t0.Add(InactiveAfter + time.Hour), false},
	} {
		if got := d.Active(tc.now); got != tc.want {
			t.Errorf("%s: Active = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestRegister(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, s Service, r *fakeRepo, c *fakeClock)
		id    string
		key   []byte
		field string // want VALIDATION on this field
		check func(t *testing.T, d Device, err error, r *fakeRepo)
	}{
		{name: "bad device id", id: "short", key: sigKey(1), field: "device_id"},
		{name: "empty device id", id: "", key: sigKey(1), field: "device_id"},
		{name: "key too short", id: devID, key: sigKey(1)[:31], field: "signature_public_key"},
		{name: "key too long", id: devID, key: append(sigKey(1), 0), field: "signature_public_key"},
		{name: "nil key", id: devID, key: nil, field: "signature_public_key"},
		{
			name: "new device", id: devID, key: sigKey(1),
			check: func(t *testing.T, d Device, err error, _ *fakeRepo) {
				if err != nil || d.ID != devID || !d.CreatedAt.Equal(t0) || !d.LastSeenAt.Equal(t0) || !bytes.Equal(d.SignatureKey, sigKey(1)) {
					t.Fatalf("Register = %+v, %v", d, err)
				}
			},
		},
		{
			name: "same key within 24h does not move last seen",
			setup: func(t *testing.T, s Service, _ *fakeRepo, c *fakeClock) {
				mustRegister(t, s, devID, sigKey(1))
				c.t = t0.Add(23 * time.Hour)
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, d Device, err error, r *fakeRepo) {
				if err != nil || !d.LastSeenAt.Equal(t0) || len(r.devices[uidA]) != 1 {
					t.Fatalf("Register = %+v, %v (devices %d)", d, err, len(r.devices[uidA]))
				}
			},
		},
		{
			name: "same key at exactly 24h does not move last seen (the refresh needs more than 24h)",
			setup: func(t *testing.T, s Service, _ *fakeRepo, c *fakeClock) {
				mustRegister(t, s, devID, sigKey(1))
				c.t = t0.Add(24 * time.Hour)
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, d Device, err error, r *fakeRepo) {
				if err != nil || !d.LastSeenAt.Equal(t0) || !r.devices[uidA][0].LastSeenAt.Equal(t0) {
					t.Fatalf("Register = %+v, %v", d, err)
				}
			},
		},
		{
			name: "same key after 24h refreshes, not a second device",
			setup: func(t *testing.T, s Service, _ *fakeRepo, c *fakeClock) {
				mustRegister(t, s, devID, sigKey(1))
				c.t = t0.Add(25 * time.Hour)
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, d Device, err error, r *fakeRepo) {
				if err != nil || !d.LastSeenAt.Equal(t0.Add(25*time.Hour)) || !d.CreatedAt.Equal(t0) || len(r.devices[uidA]) != 1 {
					t.Fatalf("Register = %+v, %v (devices %d)", d, err, len(r.devices[uidA]))
				}
			},
		},
		{
			name: "inactive device registering again becomes active",
			setup: func(t *testing.T, s Service, _ *fakeRepo, c *fakeClock) {
				mustRegister(t, s, devID, sigKey(1))
				c.t = t0.Add(InactiveAfter + time.Hour)
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, d Device, err error, r *fakeRepo) {
				if err != nil || !d.Active(t0.Add(InactiveAfter+time.Hour)) || len(r.devices[uidA]) != 1 {
					t.Fatalf("Register = %+v, %v", d, err)
				}
			},
		},
		{
			name: "different key is refused",
			setup: func(t *testing.T, s Service, _ *fakeRepo, _ *fakeClock) {
				mustRegister(t, s, devID, sigKey(1))
			},
			id: devID, key: sigKey(2), field: "signature_public_key",
			check: func(t *testing.T, _ Device, _ error, r *fakeRepo) {
				if ds := r.devices[uidA]; len(ds) != 1 || !bytes.Equal(ds[0].SignatureKey, sigKey(1)) || !ds[0].LastSeenAt.Equal(t0) {
					t.Fatalf("stored devices %+v, want the first key kept and nothing refreshed", ds)
				}
			},
		},
		{
			name: "sixth device is refused",
			setup: func(t *testing.T, s Service, _ *fakeRepo, _ *fakeClock) {
				for i := 0; i < MaxDevicesPerUser; i++ {
					mustRegister(t, s, fmt.Sprintf("device-%012d", i), sigKey(1))
				}
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, _ Device, err error, r *fakeRepo) {
				wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "key_devices")
				if len(r.devices[uidA]) != MaxDevicesPerUser {
					t.Fatalf("devices = %d, want %d (never evict)", len(r.devices[uidA]), MaxDevicesPerUser)
				}
			},
		},
		{
			name: "existing device re-registers when the account is full",
			setup: func(t *testing.T, s Service, _ *fakeRepo, _ *fakeClock) {
				mustRegister(t, s, devID, sigKey(1))
				for i := 1; i < MaxDevicesPerUser; i++ {
					mustRegister(t, s, fmt.Sprintf("device-%012d", i), sigKey(1))
				}
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, d Device, err error, _ *fakeRepo) {
				if err != nil || d.ID != devID {
					t.Fatalf("Register = %+v, %v", d, err)
				}
			},
		},
		{
			name: "contention is a retryable UNAVAILABLE",
			setup: func(_ *testing.T, _ Service, r *fakeRepo, _ *fakeClock) {
				r.err = status.Error(codes.Aborted, "contended")
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, _ Device, err error, _ *fakeRepo) {
				wantErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
				var ae *apierr.Error
				if errors.As(err, &ae); ae.RetryAfter <= 0 {
					t.Fatalf("RetryAfter = %v, want > 0", ae.RetryAfter)
				}
			},
		},
		{
			name: "unexpected failure is redacted and wrapped",
			setup: func(_ *testing.T, _ Service, r *fakeRepo, _ *fakeClock) {
				r.err = errors.New("boom for " + uidA + " " + devID)
			},
			id: devID, key: sigKey(1),
			check: func(t *testing.T, _ Device, err error, r *fakeRepo) {
				if err == nil || !errors.Is(err, r.err) {
					t.Fatalf("err = %v, want it to wrap the cause", err)
				}
				var ae *apierr.Error
				if errors.As(err, &ae) {
					t.Fatalf("unexpected failure must not be an apierr: %v", err)
				}
				if strings.Contains(err.Error(), uidA) {
					t.Fatalf("error leaks the uid: %v", err)
				}
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, clk := newTestService(t)
			if tc.setup != nil {
				tc.setup(t, s, repo, clk)
			}
			d, err := s.Register(context.Background(), uidA, tc.id, tc.key)
			switch {
			case tc.field != "":
				wantValidation(t, err, tc.field)
				if msg := err.Error(); strings.Contains(msg, tc.id) && tc.id != "" {
					t.Fatalf("message echoes the value: %q", msg)
				}
				if tc.check != nil {
					tc.check(t, d, err, repo)
				}
			case tc.check != nil:
				tc.check(t, d, err, repo)
			}
		})
	}
}

func mustRegister(t *testing.T, s Service, id string, key []byte) Device {
	t.Helper()
	d, err := s.Register(context.Background(), uidA, id, key)
	if err != nil {
		t.Fatalf("Register(%s): %v", id, err)
	}
	return d
}

func TestRegisterDoesNotAliasInput(t *testing.T) {
	s, repo, _ := newTestService(t)
	key := sigKey(7)
	d := mustRegister(t, s, devID, key)
	key[0] = 0xFF
	if repo.devices[uidA][0].SignatureKey[0] != 7 {
		t.Fatal("stored key aliases the caller's slice")
	}
	d.SignatureKey[1] = 0xEE
	if repo.devices[uidA][0].SignatureKey[1] != 7 {
		t.Fatal("returned key aliases the stored slice")
	}
}

func TestListMine(t *testing.T) {
	s, repo, clk := newTestService(t)
	ctx := context.Background()
	got, err := s.ListMine(ctx, uidA)
	if err != nil || got == nil || len(got) != 0 {
		t.Fatalf("empty list = %v, %v; want non-nil empty", got, err)
	}
	mustRegister(t, s, devID, sigKey(1))
	clk.t = t0.Add(time.Hour)
	mustRegister(t, s, devID2, sigKey(2))
	if _, _, err := s.Upload(ctx, uidA, devID, pkgs(0, 3), pkg(900)); err != nil {
		t.Fatal(err)
	}
	if got, err = s.ListMine(ctx, uidA); err != nil || len(got) != 2 {
		t.Fatalf("ListMine = %v, %v", got, err)
	}
	if got[0].ID != devID || got[1].ID != devID2 || got[0].PoolCount != 3 || !got[0].HasLastResort || got[1].HasLastResort {
		t.Fatalf("ListMine = %+v", got)
	}
	// An inactive device is still listed.
	clk.t = t0.Add(InactiveAfter + 2*time.Hour)
	if got, err = s.ListMine(ctx, uidA); err != nil || len(got) != 2 || got[0].Active(clk.t) {
		t.Fatalf("inactive device missing or active: %+v, %v", got, err)
	}
	if other, _ := s.ListMine(ctx, "uid-bob"); len(other) != 0 {
		t.Fatalf("another user's list = %v", other)
	}
	repo.err = status.Error(codes.Aborted, "x")
	_, err = s.ListMine(ctx, uidA)
	wantErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
}

func TestRemove(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name  string
		id    string
		field string
		run   func(t *testing.T, s Service, r *fakeRepo)
	}{
		{name: "bad device id", id: "nope", field: "device_id"},
		{
			name: "removes device pool and last resort, twice is success", id: devID,
			run: func(t *testing.T, s Service, r *fakeRepo) {
				if _, _, err := s.Upload(ctx, uidA, devID, pkgs(0, 2), pkg(900)); err != nil {
					t.Fatal(err)
				}
				if err := s.Remove(ctx, uidA, devID, RemoveSignOut); err != nil {
					t.Fatal(err)
				}
				if len(r.devices[uidA]) != 0 || len(r.pool[devKey(uidA, devID)]) != 0 || r.lastResort[devKey(uidA, devID)] != nil {
					t.Fatal("device, pool or last resort left behind")
				}
				if err := s.Remove(ctx, uidA, devID, RemoveSignOut); err != nil {
					t.Fatalf("second remove: %v", err)
				}
			},
		},
		{
			name: "missing device succeeds", id: devID2,
			run: func(t *testing.T, s Service, r *fakeRepo) {
				if err := s.Remove(ctx, uidA, devID2, RemoveSignOut); err != nil {
					t.Fatal(err)
				}
				if len(r.devices[uidA]) != 1 {
					t.Fatal("removed someone else's device")
				}
			},
		},
		{
			name: "frees a slot under the cap", id: devID,
			run: func(t *testing.T, s Service, _ *fakeRepo) {
				for i := 1; i < MaxDevicesPerUser; i++ {
					mustRegister(t, s, fmt.Sprintf("device-%012d", i), sigKey(1))
				}
				if _, err := s.Register(ctx, uidA, devID2, sigKey(1)); err == nil {
					t.Fatal("sixth device accepted")
				}
				if err := s.Remove(ctx, uidA, devID, RemoveSignOut); err != nil {
					t.Fatal(err)
				}
				mustRegister(t, s, devID2, sigKey(1))
			},
		},
		{
			name: "repo failure is wrapped", id: devID,
			run: func(t *testing.T, s Service, r *fakeRepo) {
				r.err = errors.New("boom")
				err := s.Remove(ctx, uidA, devID, RemoveSignOut)
				if err == nil || !strings.Contains(err.Error(), "boom") {
					t.Fatalf("err = %v", err)
				}
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, _ := newTestService(t)
			mustRegister(t, s, devID, sigKey(1))
			if tc.field != "" {
				wantValidation(t, s.Remove(ctx, uidA, tc.id, RemoveSignOut), tc.field)
				return
			}
			tc.run(t, s, repo)
		})
	}
}

func TestUpload(t *testing.T) {
	ctx := context.Background()
	big := bytes.Repeat([]byte{1}, MaxKeyPackageBytes+1)
	max := bytes.Repeat([]byte{2}, MaxKeyPackageBytes)
	cases := []struct {
		name     string
		id       string
		packages [][]byte
		lr       []byte
		field    string
		setup    func(t *testing.T, s Service)
		wantPool int
		wantLR   bool
	}{
		{name: "bad device id", id: "x", packages: pkgs(0, 1), field: "device_id"},
		{name: "nothing to upload", id: devID, field: "key_packages"},
		{name: "empty slices only (proto3 cannot tell empty from absent)", id: devID, packages: [][]byte{}, lr: []byte{}, field: "key_packages"},
		{name: "empty package", id: devID, packages: [][]byte{pkg(0), {}}, field: "key_packages"},
		{name: "oversize package", id: devID, packages: [][]byte{big}, field: "key_packages"},
		{name: "oversize last resort", id: devID, lr: big, field: "last_resort_key_package"},
		{name: "empty last resort means none", id: devID, packages: pkgs(0, 1), lr: []byte{}, wantPool: 1},
		{name: "101 packages in one upload", id: devID, packages: pkgs(0, MaxUploadBatch+1), field: "key_packages"},
		{name: "unknown device", id: devID2, packages: pkgs(0, 1), field: "NOT_FOUND"},
		{name: "packages only", id: devID, packages: pkgs(0, 3), wantPool: 3},
		{name: "max size package", id: devID, packages: [][]byte{max}, wantPool: 1},
		{name: "last resort only", id: devID, lr: pkg(900), wantPool: 0, wantLR: true},
		{name: "both", id: devID, packages: pkgs(0, 2), lr: pkg(900), wantPool: 2, wantLR: true},
		{name: "duplicates inside one upload are stored once", id: devID, packages: [][]byte{pkg(1), pkg(2), pkg(1), pkg(1)}, wantPool: 2},
		{
			name: "replay leaves the count unchanged", id: devID, packages: pkgs(0, 5), wantPool: 5,
			setup: func(t *testing.T, s Service) {
				if _, _, err := s.Upload(ctx, uidA, devID, pkgs(0, 5), nil); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "partial overlap adds only the new ones", id: devID, packages: pkgs(3, 5), wantPool: 8,
			setup: func(t *testing.T, s Service) {
				if _, _, err := s.Upload(ctx, uidA, devID, pkgs(0, 5), nil); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "last resort is kept when a later upload sets none", id: devID, packages: pkgs(0, 1), wantPool: 1, wantLR: true,
			setup: func(t *testing.T, s Service) {
				if _, _, err := s.Upload(ctx, uidA, devID, nil, pkg(900)); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "pool is capped at 100 and the excess dropped", id: devID, packages: pkgs(1000, 50), wantPool: MaxPoolSize,
			setup: func(t *testing.T, s Service) {
				if _, _, err := s.Upload(ctx, uidA, devID, pkgs(0, 70), nil); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "full pool still takes a last resort", id: devID, lr: pkg(900), wantPool: MaxPoolSize, wantLR: true,
			setup: func(t *testing.T, s Service) {
				if _, _, err := s.Upload(ctx, uidA, devID, pkgs(0, MaxUploadBatch), nil); err != nil {
					t.Fatal(err)
				}
			},
		},
		{name: "exactly 100 in one upload", id: devID, packages: pkgs(0, MaxUploadBatch), wantPool: MaxPoolSize},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, _, _ := newTestService(t)
			mustRegister(t, s, devID, sigKey(1))
			if tc.setup != nil {
				tc.setup(t, s)
			}
			n, lr, err := s.Upload(ctx, uidA, tc.id, tc.packages, tc.lr)
			switch tc.field {
			case "":
				if err != nil || n != tc.wantPool || lr != tc.wantLR {
					t.Fatalf("Upload = %d, %v, %v; want %d, %v", n, lr, err, tc.wantPool, tc.wantLR)
				}
			case "NOT_FOUND":
				wantErr(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
				if strings.Contains(err.Error(), tc.id) {
					t.Fatalf("NOT_FOUND echoes the device id: %q", err.Error())
				}
			default:
				wantValidation(t, err, tc.field)
			}
		})
	}
}

func TestUploadOldestStayWhenPoolFull(t *testing.T) {
	s, repo, _ := newTestService(t)
	mustRegister(t, s, devID, sigKey(1))
	if _, _, err := s.Upload(context.Background(), uidA, devID, pkgs(0, 70), nil); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Upload(context.Background(), uidA, devID, pkgs(1000, 50), nil); err != nil {
		t.Fatal(err)
	}
	pool := repo.pool[devKey(uidA, devID)]
	if !bytes.Equal(pool[0], pkg(0)) || !bytes.Equal(pool[69], pkg(69)) || !bytes.Equal(pool[99], pkg(1029)) {
		t.Fatalf("pool order wrong: first %s, [69] %s, last %s", pool[0], pool[69], pool[99])
	}
}

func TestUploadRefreshesLastSeenAfter24h(t *testing.T) {
	s, repo, clk := newTestService(t)
	mustRegister(t, s, devID, sigKey(1))
	clk.t = t0.Add(23 * time.Hour)
	if _, _, err := s.Upload(context.Background(), uidA, devID, pkgs(0, 1), nil); err != nil {
		t.Fatal(err)
	}
	if got := repo.devices[uidA][0].LastSeenAt; !got.Equal(t0) {
		t.Fatalf("LastSeenAt moved inside 24h: %v", got)
	}
	clk.t = t0.Add(25 * time.Hour)
	if _, _, err := s.Upload(context.Background(), uidA, devID, pkgs(1, 1), nil); err != nil {
		t.Fatal(err)
	}
	if got := repo.devices[uidA][0].LastSeenAt; !got.Equal(clk.t) {
		t.Fatalf("LastSeenAt = %v, want %v", got, clk.t)
	}
}

func TestUploadDoesNotAliasInput(t *testing.T) {
	s, repo, _ := newTestService(t)
	mustRegister(t, s, devID, sigKey(1))
	in := [][]byte{[]byte("alpha-package"), []byte("beta-package")}
	lr := []byte("last-resort")
	if _, _, err := s.Upload(context.Background(), uidA, devID, in, lr); err != nil {
		t.Fatal(err)
	}
	// Mutate the caller's slices and the slice of slices; the service must have copied.
	in[0][0], lr[0] = 'X', 'X'
	in[1] = []byte("replaced")
	if got := repo.pool[devKey(uidA, devID)]; string(got[0]) != "alpha-package" || string(got[1]) != "beta-package" {
		t.Fatalf("pool aliases caller input: %q", got)
	}
	if string(repo.lastResort[devKey(uidA, devID)]) != "last-resort" {
		t.Fatal("last resort aliases caller input")
	}
}

// capturingRepo records what the service hands to the repository, to prove the copy happens in the service.
type capturingRepo struct {
	*fakeRepo
	gotPackages [][]byte
	gotLR       []byte
}

func (c *capturingRepo) Upload(ctx context.Context, uid, id string, packages [][]byte, lr []byte, now time.Time) (int, bool, error) {
	c.gotPackages, c.gotLR = packages, lr
	return c.fakeRepo.Upload(ctx, uid, id, packages, lr, now)
}

func TestUploadHandsTheRepoCopies(t *testing.T) {
	repo := &capturingRepo{fakeRepo: newFakeRepo()}
	s := New(Deps{Repo: repo, Now: (&fakeClock{t: t0}).now})
	mustRegister(t, s, devID, sigKey(1))
	in := [][]byte{[]byte("alpha-package")}
	lr := []byte("last-resort")
	if _, _, err := s.Upload(context.Background(), uidA, devID, in, lr); err != nil {
		t.Fatal(err)
	}
	if &repo.gotPackages[0][0] == &in[0][0] || &repo.gotLR[0] == &lr[0] {
		t.Fatal("service passed the caller's backing arrays to the repo")
	}
}

func TestRequestLogCarriesNoSecrets(t *testing.T) {
	s, repo, _ := newTestService(t)
	ctx, info := logger.WithRequestInfo(context.Background())
	key := []byte("sigkey-sigkey-sigkey-sigkey-0001")
	packages := [][]byte{[]byte("secret-package-one"), []byte("secret-package-two")}
	lr := []byte("secret-last-resort")
	secrets := []string{devID, devID2, string(key), "secret-package", "secret-last-resort", uidA}

	if _, err := s.Register(ctx, uidA, devID, key); err != nil {
		t.Fatal(err)
	}
	ops := map[string]bool{}
	check := func(wantOp string) {
		t.Helper()
		sawOp := false
		for _, a := range info.Fields() {
			v := a.Value.String()
			for _, sec := range secrets {
				if strings.Contains(v, sec) || strings.Contains(a.Key, sec) {
					t.Fatalf("request field %s=%q contains %q", a.Key, v, sec)
				}
			}
			if a.Key == "keys_op" {
				sawOp = true
				ops[v] = true
				if v != wantOp {
					t.Fatalf("keys_op = %q, want %q", v, wantOp)
				}
			}
		}
		if !sawOp {
			t.Fatalf("no keys_op field after %s", wantOp)
		}
	}
	check("register")
	if _, _, err := s.Upload(ctx, uidA, devID, packages, lr); err != nil {
		t.Fatal(err)
	}
	check("upload")
	if _, err := s.ListMine(ctx, uidA); err != nil {
		t.Fatal(err)
	}
	check("list")
	if err := s.Remove(ctx, uidA, devID, RemoveSignOut); err != nil {
		t.Fatal(err)
	}
	check("remove")
	// Rejections carry no values either.
	if _, err := s.Register(ctx, uidA, devID2, []byte("short")); err == nil {
		t.Fatal("want validation error")
	}
	if got, _ := info.Get("outcome"); got != "rejected:validation" {
		t.Fatalf("outcome = %v", got)
	}
	repo.err = errors.New("boom " + devID + " " + uidA)
	_, _, _ = s.Upload(ctx, uidA, devID, packages, lr)
	for _, a := range info.Fields() {
		for _, sec := range secrets {
			if strings.Contains(a.Value.String(), sec) {
				t.Fatalf("field %s=%q contains %q after a failure", a.Key, a.Value.String(), sec)
			}
		}
	}
}

func TestOutcomeFields(t *testing.T) {
	ctx0 := context.Background()
	s, _, clk := newTestService(t)
	reg := func(want string) {
		t.Helper()
		ctx, info := logger.WithRequestInfo(ctx0)
		if _, err := s.Register(ctx, uidA, devID, sigKey(1)); err != nil {
			t.Fatal(err)
		}
		if got, _ := info.Get("outcome"); got != want {
			t.Fatalf("outcome = %v, want %s", got, want)
		}
	}
	reg("done")
	clk.t = t0.Add(time.Hour)
	reg("noop")
	clk.t = t0.Add(25 * time.Hour)
	reg("done")

	ctx, info := logger.WithRequestInfo(ctx0)
	if _, _, err := s.Upload(ctx, uidA, devID2, pkgs(0, 1), nil); err == nil {
		t.Fatal("want not found")
	}
	if got, _ := info.Get("outcome"); got != "rejected:not_found" {
		t.Fatalf("outcome = %v", got)
	}
}

func TestGuards(t *testing.T) {
	cases := []struct {
		name     string
		fc       FlagChecker
		guard    func(context.Context, FlagChecker, string) error
		wantOpen bool
	}{
		{"guard: on for caller", fakeFlags{on: map[string]bool{uidA: true}}, Guard, true},
		{"guard: not on for caller", fakeFlags{on: map[string]bool{"uid-bob": true}}, Guard, false},
		{"guard: nil checker", nil, Guard, false},
		{"not-off: allowlist dropped but flag not globally off", fakeFlags{}, GuardNotOff, true},
		{"not-off: globally off", fakeFlags{off: true}, GuardNotOff, false},
		{"not-off: nil checker", nil, GuardNotOff, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.guard(context.Background(), tc.fc, uidA)
			if tc.wantOpen {
				if err != nil {
					t.Fatalf("err = %v, want nil", err)
				}
				return
			}
			wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "e2ee_dm")
		})
	}
}
