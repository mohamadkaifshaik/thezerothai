package graph

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const (
	expUIDWithID = "UidWithPublicIdAbCdEfGhIj12"
	expUIDNoID   = "UidWithoutPublicIdAbCdEf123"
	expUIDGone   = "UidOfAnErasedAccountAbCd1234"
	expPubID     = "u0123456789abcdefghjkmnpqrs"
)

// countingProfiles is a ProfileReader that records every batch it is asked for.
type countingProfiles struct {
	profiles map[string]identity.Profile
	calls    [][]string
}

func (c *countingProfiles) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	c.calls = append(c.calls, append([]string(nil), uids...))
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := c.profiles[u]; ok {
			out[u] = p
		}
	}
	return out, nil
}

func exportFixture() *countingProfiles {
	return &countingProfiles{profiles: map[string]identity.Profile{
		expUIDWithID: {UserID: expUIDWithID, PublicID: expPubID, Handle: "withid"},
		expUIDNoID:   {UserID: expUIDNoID, Handle: "noid"},
	}}
}

// Other people are listed by handle and public id; a person with no public id by handle only, an erased one as an
// empty row (the row stays, so the list length is the edge count). The uid is never written, in any case.
func TestExportRows_OtherPeopleByHandleAndPublicID(t *testing.T) {
	t.Parallel()
	r := &FirestoreRepo{profiles: exportFixture()}
	people, err := r.peopleFor(context.Background(), []string{expUIDWithID, expUIDNoID}, []string{expUIDGone, expUIDWithID})
	if err != nil {
		t.Fatal(err)
	}
	got := exportRows([]string{expUIDWithID, expUIDNoID, expUIDGone}, people)
	want := []ExportUser{{PublicID: expPubID, Handle: "withid"}, {Handle: "noid"}, {}}
	if len(got) != len(want) {
		t.Fatalf("rows = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("row %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	raw, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `[{"publicId":"`+expPubID+`","handle":"withid"},{"handle":"noid"},{}]` {
		t.Errorf("json = %s", raw)
	}
	for _, uid := range []string{expUIDWithID, expUIDNoID, expUIDGone} {
		if strings.Contains(string(raw), uid) {
			t.Errorf("a row carries the uid %s: %s", uid, raw)
		}
	}
}

// The public id rides on the profile read the handle lookup already makes: one batch per 50 distinct people, no
// second lookup.
func TestPeopleFor_OneProfileReadPerDistinctPerson(t *testing.T) {
	t.Parallel()
	fx := exportFixture()
	r := &FirestoreRepo{profiles: fx}
	var many []string
	for i := 0; i < profileGetAllCap+1; i++ {
		many = append(many, strings.Repeat("a", 20)+string(rune('A'+i%26))+string(rune('a'+i/26)))
	}
	if _, err := r.peopleFor(context.Background(), many, many); err != nil {
		t.Fatal(err)
	}
	if len(fx.calls) != 2 || len(fx.calls[0]) != profileGetAllCap || len(fx.calls[1]) != 1 {
		t.Errorf("profile batches = %d (%v)", len(fx.calls), fx.calls)
	}
}

func TestRequestExportRow_JSON(t *testing.T) {
	t.Parallel()
	at := time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC)
	tests := []struct {
		row  RequestExportRow
		want string
	}{
		{RequestExportRow{PublicID: expPubID, Handle: "withid", RequestedAt: at}, `{"publicId":"` + expPubID + `","handle":"withid","requestedAt":"2026-11-18T09:00:00Z"}`},
		{RequestExportRow{Handle: "noid", RequestedAt: at}, `{"handle":"noid","requestedAt":"2026-11-18T09:00:00Z"}`},
		{RequestExportRow{RequestedAt: at}, `{"requestedAt":"2026-11-18T09:00:00Z"}`},
	}
	for _, tt := range tests {
		raw, err := json.Marshal(tt.row)
		if err != nil {
			t.Fatal(err)
		}
		if string(raw) != tt.want {
			t.Errorf("json = %s, want %s", raw, tt.want)
		}
	}
}
