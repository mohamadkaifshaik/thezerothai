// export.go is the right-to-access path of users/{uid}/keyDevices and users/{uid}/keyDeviceRemovals: the `keys` export
// section lists the user's devices by id and times with the pool size, and the removed marks by id and times (with the
// metadata of a device document whose removal is still pending). It never
// carries key bytes (signature key, last-resort package, key packages): the section
// says whether a last-resort package exists, not what it is. Not flag-gated: documents outlive the flag.
package keys

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"strings"
	"time"
)

// exportMarkPage is how many removed marks one export read takes.
const exportMarkPage = 100

// ExportSource is what the export needs (FirestoreRepo in production): ExportDevices (one query with a Limit, at most
// MaxDevicesPerUser documents: the live devices, and apart from them the documents carrying removedAt) and
// ListRemovalMarks (the marks ordered by device id, after afterID exclusive, at most limit).
type ExportSource interface {
	ExportDevices(ctx context.Context, uid string) ([]Device, []PendingRemoval, error)
	ListRemovalMarks(ctx context.Context, uid, afterID string, limit int) ([]RemovalMark, error)
}

// ExportedDevice is one row of the `keys` export section. There is deliberately no field for key material.
type ExportedDevice struct {
	DeviceID        string    `json:"device_id"`
	CreatedAt       time.Time `json:"created_at"`
	LastSeenAt      time.Time `json:"last_seen_at"`
	KeyPackageCount int       `json:"key_package_count"`
	HasLastResort   bool      `json:"has_last_resort"`
}

// Exporter writes the `keys` export section.
type Exporter struct {
	src ExportSource
	// maxMarkPages is the hard stop on mark reads (maxExportMarkPages; tests inject a small one).
	maxMarkPages int
}

// NewExporter builds the section on an ExportSource (FirestoreRepo in production).
func NewExporter(src ExportSource) *Exporter {
	return &Exporter{src: src, maxMarkPages: maxExportMarkPages}
}

// Name is the export section's name (identity.ExportSection).
func (*Exporter) Name() string { return "keys" }

// WriteSection implements identity.ExportSection: it streams the section to w.
func (x *Exporter) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return x.ExportUser(ctx, uid, w)
}

// ExportedRemovedDevice is one REMOTE removal in the `keys` export section: the id and the mark's two times. While the
// device document still exists (it carries removedAt: the removal has not deleted it yet) RemovalPending is true and
// Device is that document's metadata, as a device row (security audit M2(a): stored data is never left out). A pending
// removal whose mark is gone (its TTL ran out first) has removed_at from the document and no expires_at.
type ExportedRemovedDevice struct {
	DeviceID       string          `json:"device_id"`
	RemovedAt      time.Time       `json:"removed_at"`
	ExpiresAt      time.Time       `json:"expires_at,omitzero"`
	RemovalPending bool            `json:"removal_pending,omitempty"`
	Device         *ExportedDevice `json:"device,omitempty"`
}

// exportedDevice is the export row of a device (no key bytes).
func exportedDevice(d Device) ExportedDevice {
	return ExportedDevice{
		DeviceID: d.ID, CreatedAt: d.CreatedAt.UTC(), LastSeenAt: d.LastSeenAt.UTC(),
		KeyPackageCount: d.PoolCount, HasLastResort: d.HasLastResort,
	}
}

// maxExportMarkPages bounds the mark reads of one export (exportMarkPage each). Marks are bounded by their 90-day TTL and
// the keys write bucket, and each new one needs a recent sign-in, so this is far above any real account; past it the
// export fails loudly (an error, nothing written) rather than silently leaving rows out. An account with exactly the
// bound's worth of marks fails too: the loop cannot tell that no further page exists without reading it.
const maxExportMarkPages = 1000

// ExportUser streams {"devices":[...],"removed_devices":[...]} to w: devices oldest first; removed_devices by device id,
// one row per mark, with a device whose removal is in progress (its document carries removedAt) on its mark's row, or on
// a row of its own when it has no mark, marked removal_pending (never under devices). Reads: one query of at most
// MaxDevicesPerUser documents, then the marks in pages of exportMarkPage by document id (no index).
func (x *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	devs, pending, err := x.src.ExportDevices(ctx, uid)
	if err != nil {
		return err
	}
	out := struct {
		Devices        []ExportedDevice        `json:"devices"`
		RemovedDevices []ExportedRemovedDevice `json:"removed_devices"`
	}{Devices: make([]ExportedDevice, 0, len(devs)), RemovedDevices: []ExportedRemovedDevice{}}
	for _, d := range devs {
		out.Devices = append(out.Devices, exportedDevice(d))
	}
	after := ""
	for page := 0; ; page++ {
		if page == x.maxMarkPages {
			return fmt.Errorf("keys: export: removed marks reach the bound of %d pages of %d", x.maxMarkPages, exportMarkPage)
		}
		marks, err := x.src.ListRemovalMarks(ctx, uid, after, exportMarkPage)
		if err != nil {
			return err
		}
		for _, m := range marks {
			out.RemovedDevices = append(out.RemovedDevices, ExportedRemovedDevice{DeviceID: m.DeviceID, RemovedAt: m.RemovedAt.UTC(), ExpiresAt: m.ExpireAt.UTC()})
		}
		if len(marks) < exportMarkPage {
			break
		}
		after = marks[len(marks)-1].DeviceID
	}
	out.RemovedDevices = mergePending(out.RemovedDevices, pending)
	if err := json.NewEncoder(w).Encode(out); err != nil {
		return fmt.Errorf("keys: write export: %w", err)
	}
	return nil
}

// mergePending puts the pending removals (at most MaxDevicesPerUser) on the rows of their marks, adds a row for each one
// without a mark, and keeps the rows ordered by device id (the marks already are).
func mergePending(rows []ExportedRemovedDevice, pending []PendingRemoval) []ExportedRemovedDevice {
	if len(pending) == 0 {
		return rows
	}
	at := make(map[string]int, len(rows))
	for i, r := range rows {
		at[r.DeviceID] = i
	}
	added := false
	for _, p := range pending {
		dev := exportedDevice(p.Device)
		if i, ok := at[p.Device.ID]; ok {
			rows[i].RemovalPending, rows[i].Device = true, &dev
			continue
		}
		rows = append(rows, ExportedRemovedDevice{DeviceID: p.Device.ID, RemovedAt: p.RemovedAt.UTC(), RemovalPending: true, Device: &dev})
		added = true
	}
	if added {
		slices.SortFunc(rows, func(a, b ExportedRemovedDevice) int { return strings.Compare(a.DeviceID, b.DeviceID) })
	}
	return rows
}
