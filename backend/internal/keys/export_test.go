package keys

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

type listerFunc func(ctx context.Context, uid string) ([]Device, error)

func (f listerFunc) List(ctx context.Context, uid string) ([]Device, error) { return f(ctx, uid) }

func TestExporter_Golden(t *testing.T) {
	t0 := time.Date(2026, 11, 1, 6, 30, 0, 0, time.UTC)
	t1 := time.Date(2026, 11, 17, 18, 0, 5, 0, time.FixedZone("IST", 5*3600+1800)) // exported in UTC
	devs := []Device{
		{ID: "device-aaaaaaaaaaaaaaaa", SignatureKey: bytes.Repeat([]byte{7}, 32), CreatedAt: t0, LastSeenAt: t1, PoolCount: 42, HasLastResort: true},
		{ID: "device-bbbbbbbbbbbbbbbb", SignatureKey: bytes.Repeat([]byte{9}, 32), CreatedAt: t1, LastSeenAt: t1},
	}
	var got bytes.Buffer
	x := NewExporter(listerFunc(func(context.Context, string) ([]Device, error) { return devs, nil }))
	if err := x.ExportUser(context.Background(), "u1", &got); err != nil {
		t.Fatal(err)
	}
	const want = `{"devices":[` +
		`{"device_id":"device-aaaaaaaaaaaaaaaa","created_at":"2026-11-01T06:30:00Z","last_seen_at":"2026-11-17T12:30:05Z","key_package_count":42,"has_last_resort":true},` +
		`{"device_id":"device-bbbbbbbbbbbbbbbb","created_at":"2026-11-17T12:30:05Z","last_seen_at":"2026-11-17T12:30:05Z","key_package_count":0,"has_last_resort":false}]}` + "\n"
	if got.String() != want {
		t.Errorf("export =\n%s\nwant\n%s", got.String(), want)
	}
	// No key material of any kind: the 0x07 and 0x09 key bytes never appear in any encoding.
	for _, bad := range []string{"signature", `"last_resort"`, `"key_packages"`, "BwcH", "\\u0007"} {
		if strings.Contains(got.String(), bad) {
			t.Errorf("export contains %q", bad)
		}
	}
}

func TestExporter_NoDevicesIsEmptyArray(t *testing.T) {
	var got bytes.Buffer
	x := NewExporter(listerFunc(func(context.Context, string) ([]Device, error) { return nil, nil }))
	if err := x.ExportUser(context.Background(), "u1", &got); err != nil {
		t.Fatal(err)
	}
	if got.String() != `{"devices":[]}`+"\n" {
		t.Errorf("export = %q", got.String())
	}
}

func TestExporter_ListErrorIsReturned(t *testing.T) {
	boom := errors.New("boom")
	x := NewExporter(listerFunc(func(context.Context, string) ([]Device, error) { return nil, boom }))
	if err := x.ExportUser(context.Background(), "u1", &bytes.Buffer{}); !errors.Is(err, boom) {
		t.Errorf("err = %v, want boom", err)
	}
}
