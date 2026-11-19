package keys

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The server-internal device directory: ActiveDeviceIDs answers only active devices, DeviceIDs every registered one, both
// oldest first, with no permission or flag check (a nil Permission and a nil flag checker refuse every RPC lookup of another
// user, yet these answer), nothing on the request line, and a read failure as an error with the uid hashed.
func TestDeviceDirectory(t *testing.T) {
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	svc := New(Deps{Repo: repo, Now: clk.now}) // no Permission, no Flags: GetDevices would refuse another user
	dir, ok := svc.(DeviceDirectory)
	if !ok {
		t.Fatal("the service does not implement DeviceDirectory")
	}
	ctx, info := logger.WithRequestInfo(context.Background())

	if got, err := dir.ActiveDeviceIDs(ctx, uidA); err != nil || got == nil || len(got) != 0 {
		t.Fatalf("no devices: ActiveDeviceIDs = %v, %v; want non-nil empty", got, err)
	}
	if _, err := svc.Register(context.Background(), uidA, devID, sigKey(1)); err != nil {
		t.Fatal(err)
	}
	clk.t = t0.Add(InactiveAfter - time.Hour)
	if _, err := svc.Register(context.Background(), uidA, devID2, sigKey(2)); err != nil {
		t.Fatal(err)
	}
	if got, err := dir.ActiveDeviceIDs(ctx, uidA); err != nil || !slices.Equal(got, []string{devID, devID2}) {
		t.Fatalf("both active: %v, %v", got, err)
	}
	// devID was last seen exactly InactiveAfter ago: inactive (the Active rule), still registered.
	clk.t = t0.Add(InactiveAfter)
	if got, err := dir.ActiveDeviceIDs(ctx, uidA); err != nil || !slices.Equal(got, []string{devID2}) {
		t.Fatalf("one inactive: ActiveDeviceIDs = %v, %v", got, err)
	}
	if got, err := dir.DeviceIDs(ctx, uidA); err != nil || !slices.Equal(got, []string{devID, devID2}) {
		t.Fatalf("DeviceIDs = %v, %v; want both, inactive included", got, err)
	}
	if got, _ := dir.DeviceIDs(ctx, "uid-bob"); len(got) != 0 {
		t.Fatalf("another user's ids = %v", got)
	}
	if fields := info.Fields(); len(fields) != 0 {
		t.Fatalf("request-line fields = %v, want none (server-internal)", fields)
	}

	repo.err = errors.New("boom " + uidA)
	for name, call := range map[string]func(context.Context, string) ([]string, error){"active": dir.ActiveDeviceIDs, "all": dir.DeviceIDs} {
		got, err := call(ctx, uidA)
		if err == nil || got != nil {
			t.Fatalf("%s: read failure = %v, %v; want an error, never an empty answer", name, got, err)
		}
		if strings.Contains(err.Error(), uidA) {
			t.Fatalf("%s: error carries the uid: %v", name, err)
		}
	}
}

// The flag of the looked-up user does not matter: the directory is not the GetKeyDevices RPC.
func TestDeviceDirectoryIgnoresTheTargetFlag(t *testing.T) {
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	off := flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off})
	svc := New(Deps{Repo: repo, Now: clk.now, Flags: off})
	if _, err := svc.Register(context.Background(), uidA, devID, sigKey(1)); err != nil {
		t.Fatal(err)
	}
	got, err := svc.(DeviceDirectory).ActiveDeviceIDs(context.Background(), uidA)
	if err != nil || !slices.Equal(got, []string{devID}) {
		t.Fatalf("flag off: ActiveDeviceIDs = %v, %v", got, err)
	}
}
