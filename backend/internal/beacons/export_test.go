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

// TestWithOwnParticipation (D03): a membership row carries the exporting user's own participant note and times; a
// missing row leaves them empty and a row naming another user is never copied.
func TestWithOwnParticipation(t *testing.T) {
	req, resp := testNow.Add(-time.Hour), testNow
	rows := []ExportedMembership{
		{BeaconID: "b-accepted", Role: RoleParticipant, State: PStateAccepted},
		{BeaconID: "b-requested", Role: RoleRequester, State: PStateRequested},
		{BeaconID: "b-organiser", Role: RoleOrganiser, State: string(StatusOpen)},
		{BeaconID: "b-foreign", Role: RoleParticipant, State: PStateAccepted},
	}
	own := map[string]participantDoc{
		"b-accepted":  {UID: "me", State: PStateAccepted, Note: "see you there", RequestedAt: req, RespondedAt: resp},
		"b-requested": {UID: "me", State: PStateRequested, Note: "can I join?", RequestedAt: req},
		"b-foreign":   {UID: "someone-else", State: PStateAccepted, Note: "their secret note", RequestedAt: req, RespondedAt: resp},
	}
	got := withOwnParticipation("me", rows, own)
	tm := func(p *time.Time) string {
		if p == nil {
			return "-"
		}
		return p.Format(time.RFC3339)
	}
	for _, tt := range []struct {
		i               int
		note, req, resp string
	}{
		{0, "see you there", req.Format(time.RFC3339), resp.Format(time.RFC3339)},
		{1, "can I join?", req.Format(time.RFC3339), "-"},
		{2, "", "-", "-"},
		{3, "", "-", "-"},
	} {
		m := got[tt.i]
		if m.Note != tt.note || tm(m.RequestedAt) != tt.req || tm(m.RespondedAt) != tt.resp {
			t.Errorf("%s: note=%q requested=%s responded=%s, want %q %s %s", m.BeaconID, m.Note, tm(m.RequestedAt), tm(m.RespondedAt), tt.note, tt.req, tt.resp)
		}
	}
}

// TestExporter_MembershipCarriesOwnNote (D03): the streamed membership row includes the user's note and request and
// response times, and omits them when unset (an organiser row), with no other participant data in the document.
func TestExporter_MembershipCarriesOwnNote(t *testing.T) {
	req := testNow.Add(-time.Hour).UTC()
	src := fakeSource{memberships: []ExportedMembership{
		{BeaconID: "0000000000000000001", Role: RoleRequester, State: PStateRequested, Note: "can I join?", RequestedAt: &req},
		{BeaconID: "0000000000000000002", Role: RoleOrganiser, State: string(StatusOpen)},
	}}
	var buf bytes.Buffer
	if err := NewExporter(src).ExportUser(context.Background(), "me", &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Memberships []map[string]any `json:"memberships"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, buf.String())
	}
	if len(out.Memberships) != 2 {
		t.Fatalf("memberships = %+v", out.Memberships)
	}
	if m := out.Memberships[0]; m["note"] != "can I join?" || m["requestedAt"] != req.Format(time.RFC3339Nano) || m["respondedAt"] != nil {
		t.Errorf("requester row = %v", m)
	}
	for _, k := range []string{"note", "requestedAt", "respondedAt"} {
		if _, ok := out.Memberships[1][k]; ok {
			t.Errorf("organiser row has %q: %v", k, out.Memberships[1])
		}
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
