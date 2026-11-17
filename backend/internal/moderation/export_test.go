package moderation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

// fakePeople is a ProfileReader over a fixed set (every status, as identity's repo answers) that records each batch.
type fakePeople struct {
	profiles map[string]identity.Profile
	calls    [][]string
	err      error
}

func (f *fakePeople) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	f.calls = append(f.calls, append([]string(nil), uids...))
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := f.profiles[u]; ok {
			out[u] = p
		}
	}
	return out, nil
}

// exportPeople: one account with a public id, one SUSPENDED without one (still named), and an erased one (absent).
func exportPeople() *fakePeople {
	return &fakePeople{profiles: map[string]identity.Profile{
		expUIDWithID: {UserID: expUIDWithID, PublicID: expPubID, Handle: "withid", Status: identity.AccountStatusActive},
		expUIDNoID:   {UserID: expUIDNoID, Handle: "noid", Status: identity.AccountStatusSuspended},
	}}
}

// An ACCOUNT report names its target by public id and handle (each omitted when absent), never by uid; every other
// target type keeps its id as stored.
func TestExportedReport_AccountTargetsByHandleAndPublicID(t *testing.T) {
	t.Parallel()
	at := time.Date(2026, 11, 18, 9, 0, 0, 0, time.UTC)
	tail := `"reason":"SPAM","note":"n","status":"OPEN","createdAt":"2026-11-18T09:00:00Z"}`
	tests := []struct {
		name       string
		targetType TargetType
		targetID   string
		want       string
	}{
		{"account with public id", TargetAccount, expUIDWithID, `{"id":"r1","targetType":"ACCOUNT","targetPublicId":"` + expPubID + `","targetHandle":"withid",` + tail},
		{"suspended account without public id", TargetAccount, expUIDNoID, `{"id":"r1","targetType":"ACCOUNT","targetHandle":"noid",` + tail},
		{"erased account", TargetAccount, expUIDGone, `{"id":"r1","targetType":"ACCOUNT",` + tail},
		{"post", TargetPost, "0000000000000000123", `{"id":"r1","targetType":"POST","targetId":"0000000000000000123",` + tail},
		{"message", TargetMessage, "conv:0000000000000000124", `{"id":"r1","targetType":"MESSAGE","targetId":"conv:0000000000000000124",` + tail},
		{"list", TargetList, "0000000000000000125", `{"id":"r1","targetType":"LIST","targetId":"0000000000000000125",` + tail},
		{"community", TargetCommunity, "c1", `{"id":"r1","targetType":"COMMUNITY","targetId":"c1",` + tail},
		{"beacon", TargetBeacon, "b1", `{"id":"r1","targetType":"BEACON","targetId":"b1",` + tail},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			d := reportDoc{TargetType: string(tt.targetType), TargetID: tt.targetID, TargetOwnerID: expUIDWithID, Reason: "SPAM", Note: "n", Status: "OPEN", CreatedAt: at}
			people := map[string]exportedPerson{}
			if err := resolveAccountTargets(context.Background(), exportPeople(), []reportDoc{d}, people); err != nil {
				t.Fatal(err)
			}
			raw, err := json.Marshal(toExportedReport("r1", d, people))
			if err != nil {
				t.Fatal(err)
			}
			if string(raw) != tt.want {
				t.Errorf("json = %s\nwant   %s", raw, tt.want)
			}
			for _, uid := range []string{expUIDWithID, expUIDNoID, expUIDGone} {
				if strings.Contains(string(raw), uid) {
					t.Errorf("the row carries the uid %s: %s", uid, raw)
				}
			}
		})
	}
}

// Only ACCOUNT targets are looked up, each distinct one once per export, in batches of at most 50.
func TestResolveAccountTargets_Batches(t *testing.T) {
	t.Parallel()
	var docs []reportDoc
	for i := range profileGetAllCap + 1 {
		docs = append(docs, reportDoc{TargetType: string(TargetAccount), TargetID: fmt.Sprintf("acct%03d", i)})
		docs = append(docs, reportDoc{TargetType: string(TargetAccount), TargetID: fmt.Sprintf("acct%03d", i)})
		docs = append(docs, reportDoc{TargetType: string(TargetPost), TargetID: fmt.Sprintf("post%03d", i)})
	}
	fx := exportPeople()
	people := map[string]exportedPerson{}
	if err := resolveAccountTargets(context.Background(), fx, docs, people); err != nil {
		t.Fatal(err)
	}
	// A second page naming the same accounts reads nothing more.
	if err := resolveAccountTargets(context.Background(), fx, docs[:3], people); err != nil {
		t.Fatal(err)
	}
	if len(fx.calls) != 2 || len(fx.calls[0]) != profileGetAllCap || len(fx.calls[1]) != 1 {
		t.Errorf("profile batches = %v", fx.calls)
	}
	for _, c := range fx.calls {
		for _, id := range c {
			if !strings.HasPrefix(id, "acct") {
				t.Errorf("a non-account target was looked up: %s", id)
			}
		}
	}
}

func TestReportExporter_FailClosed(t *testing.T) {
	t.Parallel()
	var sb strings.Builder
	if err := NewReportExporter(&FirestoreRepo{}, nil).ExportUser(context.Background(), "u1", &sb); err == nil {
		t.Error("an exporter without a ProfileReader exported")
	}
	if sb.Len() != 0 {
		t.Errorf("wrote %q before failing", sb.String())
	}
	boom := errors.New("boom")
	d := reportDoc{TargetType: string(TargetAccount), TargetID: expUIDWithID}
	if err := resolveAccountTargets(context.Background(), &fakePeople{err: boom}, []reportDoc{d}, map[string]exportedPerson{}); !errors.Is(err, boom) {
		t.Errorf("err = %v, want %v", err, boom)
	}
}
