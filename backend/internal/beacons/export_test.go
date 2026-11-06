package beacons

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

// fakeSource pages through fixed slices by beacon id order.
type fakeSource struct {
	beacons     []ExportedBeacon
	memberships []ExportedMembership
}

func (s fakeSource) ExportBeaconsPage(_ context.Context, _ string, after string, limit int) ([]ExportedBeacon, error) {
	start := 0
	if after != "" {
		for i, b := range s.beacons {
			if b.BeaconID == after {
				start = i + 1
			}
		}
	}
	end := min(start+limit, len(s.beacons))
	return s.beacons[start:end], nil
}

func (s fakeSource) ExportMembershipsPage(_ context.Context, _ string, after string, limit int) ([]ExportedMembership, error) {
	start := 0
	if after != "" {
		for i, m := range s.memberships {
			if m.BeaconID == after {
				start = i + 1
			}
		}
	}
	end := min(start+limit, len(s.memberships))
	return s.memberships[start:end], nil
}

// TestExporter_StreamsBothSectionsAcrossPages: {"beacons":[...],"memberships":[...]} with every row, in id order, over
// more than one page.
func TestExporter_StreamsBothSectionsAcrossPages(t *testing.T) {
	src := fakeSource{}
	for i := range exportPage + 1 {
		src.beacons = append(src.beacons, ExportedBeacon{BeaconID: fmt.Sprintf("%019d", i), Title: "t", StartAt: testNow, EndAt: testNow.Add(time.Hour)})
	}
	src.memberships = []ExportedMembership{{BeaconID: "0000000000000000001", Role: RoleParticipant, State: "accepted"}}
	var buf bytes.Buffer
	if err := NewExporter(src).ExportUser(context.Background(), "u", &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Beacons     []ExportedBeacon     `json:"beacons"`
		Memberships []ExportedMembership `json:"memberships"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, buf.String())
	}
	if len(out.Beacons) != exportPage+1 || out.Beacons[exportPage].BeaconID != fmt.Sprintf("%019d", exportPage) {
		t.Fatalf("beacons = %d rows", len(out.Beacons))
	}
	if len(out.Memberships) != 1 || out.Memberships[0].Role != RoleParticipant {
		t.Fatalf("memberships = %+v", out.Memberships)
	}
	if buf.Bytes()[buf.Len()-1] != '\n' {
		t.Fatal("export must end with a newline")
	}
}

// TestExporter_EmptyUser: no rows is still a valid document with both arrays.
func TestExporter_EmptyUser(t *testing.T) {
	var buf bytes.Buffer
	if err := NewExporter(fakeSource{}).ExportUser(context.Background(), "u", &buf); err != nil {
		t.Fatal(err)
	}
	if got := buf.String(); got != "{\"beacons\":[],\"memberships\":[]}\n" {
		t.Fatalf("export = %q", got)
	}
}
