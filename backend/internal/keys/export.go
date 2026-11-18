// export.go is the right-to-access path of users/{uid}/keyDevices: the `keys` export section lists the user's devices by id
// and times with the pool size. It never carries key bytes (signature key, last-resort package, key packages): the section
// says whether a last-resort package exists, not what it is. Not flag-gated: documents outlive the flag.
package keys

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"
)

// DeviceLister is the one Repo method the export needs (FirestoreRepo in production; at most MaxDevicesPerUser rows, one
// query with a Limit).
type DeviceLister interface {
	List(ctx context.Context, uid string) ([]Device, error)
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
	src DeviceLister
}

// NewExporter builds the section on a DeviceLister (FirestoreRepo in production).
func NewExporter(src DeviceLister) *Exporter { return &Exporter{src: src} }

// Name is the export section's name (identity.ExportSection).
func (*Exporter) Name() string { return "keys" }

// WriteSection implements identity.ExportSection: it streams the section to w.
func (x *Exporter) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return x.ExportUser(ctx, uid, w)
}

// ExportUser streams {"devices":[...]} to w, oldest device first. Reads: one query of at most MaxDevicesPerUser documents.
func (x *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	devs, err := x.src.List(ctx, uid)
	if err != nil {
		return err
	}
	out := struct {
		Devices []ExportedDevice `json:"devices"`
	}{Devices: make([]ExportedDevice, 0, len(devs))}
	for _, d := range devs {
		out.Devices = append(out.Devices, ExportedDevice{
			DeviceID: d.ID, CreatedAt: d.CreatedAt.UTC(), LastSeenAt: d.LastSeenAt.UTC(),
			KeyPackageCount: d.PoolCount, HasLastResort: d.HasLastResort,
		})
	}
	if err := json.NewEncoder(w).Encode(out); err != nil {
		return fmt.Errorf("keys: write export: %w", err)
	}
	return nil
}
