// export.go is the right-to-access path of users/{uid}/keyDevices and users/{uid}/keyDeviceRemovals: the `keys` export
// section lists the user's devices by id and times with the pool size, and the removed marks by id and times. It never
// carries key bytes (signature key, last-resort package, key packages): the section
// says whether a last-resort package exists, not what it is. Not flag-gated: documents outlive the flag.
package keys

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"
)

// exportMarkPage is how many removed marks one export read takes.
const exportMarkPage = 100

// ExportSource is what the export needs (FirestoreRepo in production): List (at most MaxDevicesPerUser rows, one query
// with a Limit) and ListRemovalMarks (the marks ordered by device id, after afterID exclusive, at most limit).
type ExportSource interface {
	List(ctx context.Context, uid string) ([]Device, error)
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
}

// NewExporter builds the section on an ExportSource (FirestoreRepo in production).
func NewExporter(src ExportSource) *Exporter { return &Exporter{src: src} }

// Name is the export section's name (identity.ExportSection).
func (*Exporter) Name() string { return "keys" }

// WriteSection implements identity.ExportSection: it streams the section to w.
func (x *Exporter) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return x.ExportUser(ctx, uid, w)
}

// ExportedRemovedDevice is one removed mark (a REMOTE removal) in the `keys` export section: the id and its two times.
type ExportedRemovedDevice struct {
	DeviceID  string    `json:"device_id"`
	RemovedAt time.Time `json:"removed_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

// maxExportMarkPages bounds the mark reads of one export (exportMarkPage each). Marks are bounded by their 90-day TTL and
// the keys write bucket, and each new one needs a recent sign-in, so this is far above any real account; past it the
// export fails loudly rather than silently leaving rows out.
const maxExportMarkPages = 1000

// ExportUser streams {"devices":[...],"removed_devices":[...]} to w: devices oldest first (a device whose removal is in
// progress is left out: it is listed under removed_devices), marks by device id. Reads: one query of at most
// MaxDevicesPerUser documents, then the marks in pages of exportMarkPage by document id (no index).
func (x *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	devs, err := x.src.List(ctx, uid)
	if err != nil {
		return err
	}
	out := struct {
		Devices        []ExportedDevice        `json:"devices"`
		RemovedDevices []ExportedRemovedDevice `json:"removed_devices"`
	}{Devices: make([]ExportedDevice, 0, len(devs)), RemovedDevices: []ExportedRemovedDevice{}}
	for _, d := range devs {
		out.Devices = append(out.Devices, ExportedDevice{
			DeviceID: d.ID, CreatedAt: d.CreatedAt.UTC(), LastSeenAt: d.LastSeenAt.UTC(),
			KeyPackageCount: d.PoolCount, HasLastResort: d.HasLastResort,
		})
	}
	after := ""
	for page := 0; ; page++ {
		if page == maxExportMarkPages {
			return fmt.Errorf("keys: export: more than %d removed marks", maxExportMarkPages*exportMarkPage)
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
	if err := json.NewEncoder(w).Encode(out); err != nil {
		return fmt.Errorf("keys: write export: %w", err)
	}
	return nil
}
