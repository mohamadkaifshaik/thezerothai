package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"
)

// fakeExportSource answers List from list and pages marks by device id (afterID exclusive), like the repository.
type fakeExportSource struct {
	list    func(ctx context.Context, uid string) ([]Device, error)
	marks   []RemovalMark
	markErr error
	pages   []int // limits seen by ListRemovalMarks
}

func (f *fakeExportSource) List(ctx context.Context, uid string) ([]Device, error) {
	return f.list(ctx, uid)
}

func (f *fakeExportSource) ListRemovalMarks(_ context.Context, _, afterID string, limit int) ([]RemovalMark, error) {
	if f.markErr != nil {
		return nil, f.markErr
	}
	f.pages = append(f.pages, limit)
	sorted := append([]RemovalMark(nil), f.marks...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].DeviceID < sorted[j].DeviceID })
	var out []RemovalMark
	for _, m := range sorted {
		if m.DeviceID > afterID && len(out) < limit {
			out = append(out, m)
		}
	}
	return out, nil
}

func devicesOnly(devs []Device) *fakeExportSource {
	return &fakeExportSource{list: func(context.Context, string) ([]Device, error) { return devs, nil }}
}

func TestExporter_Golden(t *testing.T) {
	t0 := time.Date(2026, 11, 1, 6, 30, 0, 0, time.UTC)
	t1 := time.Date(2026, 11, 17, 18, 0, 5, 0, time.FixedZone("IST", 5*3600+1800)) // exported in UTC
	devs := []Device{
		{ID: "device-aaaaaaaaaaaaaaaa", SignatureKey: bytes.Repeat([]byte{7}, 32), CreatedAt: t0, LastSeenAt: t1, PoolCount: 42, HasLastResort: true},
		{ID: "device-bbbbbbbbbbbbbbbb", SignatureKey: bytes.Repeat([]byte{9}, 32), CreatedAt: t1, LastSeenAt: t1},
	}
	src := devicesOnly(devs)
	src.marks = []RemovalMark{
		{DeviceID: "device-zzzzzzzzzzzzzzzz", RemovedAt: t1, ExpireAt: t1.Add(RemovalMarkTTL)},
		{DeviceID: "device-cccccccccccccccc", RemovedAt: t0, ExpireAt: t0.Add(RemovalMarkTTL)},
	}
	var got bytes.Buffer
	if err := NewExporter(src).ExportUser(context.Background(), "u1", &got); err != nil {
		t.Fatal(err)
	}
	const want = `{"devices":[` +
		`{"device_id":"device-aaaaaaaaaaaaaaaa","created_at":"2026-11-01T06:30:00Z","last_seen_at":"2026-11-17T12:30:05Z","key_package_count":42,"has_last_resort":true},` +
		`{"device_id":"device-bbbbbbbbbbbbbbbb","created_at":"2026-11-17T12:30:05Z","last_seen_at":"2026-11-17T12:30:05Z","key_package_count":0,"has_last_resort":false}],` +
		`"removed_devices":[` +
		`{"device_id":"device-cccccccccccccccc","removed_at":"2026-11-01T06:30:00Z","expires_at":"2027-01-30T06:30:00Z"},` +
		`{"device_id":"device-zzzzzzzzzzzzzzzz","removed_at":"2026-11-17T12:30:05Z","expires_at":"2027-02-15T12:30:05Z"}]}` + "\n"
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
	if err := NewExporter(devicesOnly(nil)).ExportUser(context.Background(), "u1", &got); err != nil {
		t.Fatal(err)
	}
	if got.String() != `{"devices":[],"removed_devices":[]}`+"\n" {
		t.Errorf("export = %q", got.String())
	}
}

// TestExporter_MarksArePagedBy100: more than one page of marks is read in pages of exportMarkPage, every mark once.
func TestExporter_MarksArePagedBy100(t *testing.T) {
	src := devicesOnly(nil)
	for i := 0; i < 2*exportMarkPage+5; i++ {
		src.marks = append(src.marks, RemovalMark{DeviceID: fmt.Sprintf("device-%016d", i), RemovedAt: time.Unix(0, 0)})
	}
	var got bytes.Buffer
	if err := NewExporter(src).ExportUser(context.Background(), "u1", &got); err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(got.String(), `"removed_at"`); n != 2*exportMarkPage+5 {
		t.Errorf("exported %d marks, want %d", n, 2*exportMarkPage+5)
	}
	if len(src.pages) != 3 {
		t.Errorf("pages = %v, want 3 reads", src.pages)
	}
	for _, l := range src.pages {
		if l != exportMarkPage {
			t.Errorf("a page asked for %d marks, want %d", l, exportMarkPage)
		}
	}
}

func TestExporter_ListErrorIsReturned(t *testing.T) {
	boom := errors.New("boom")
	x := NewExporter(&fakeExportSource{list: func(context.Context, string) ([]Device, error) { return nil, boom }})
	if err := x.ExportUser(context.Background(), "u1", &bytes.Buffer{}); !errors.Is(err, boom) {
		t.Errorf("err = %v, want boom", err)
	}
	src := devicesOnly(nil)
	src.markErr = boom
	if err := NewExporter(src).ExportUser(context.Background(), "u1", &bytes.Buffer{}); !errors.Is(err, boom) {
		t.Errorf("mark read err = %v, want boom", err)
	}
}
