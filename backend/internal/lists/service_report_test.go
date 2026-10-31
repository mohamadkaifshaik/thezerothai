package lists

import (
	"context"
	"errors"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// ReportableList (plan W5-44) applies the same D3 rules as GetList: what a caller cannot see they cannot report, and the
// refusal is the same ErrNotFound for every cause.
func TestReportableList_D3Matrix(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		list     List
		profiles map[string]identity.Profile
		snaps    map[string]graph.Snapshot
		viewer   string
		want     error // nil = reportable
	}{
		{"public list", pubList("m1"), nil, nil, viewerUID, nil},
		{"private list, other viewer", List{ID: testListID, OwnerID: testUID, IsPrivate: true}, nil, nil, viewerUID, ErrNotFound},
		{"hidden list, other viewer", List{ID: testListID, OwnerID: testUID, Hidden: true}, nil, nil, viewerUID, ErrNotFound},
		{"viewer's blockedBy names the owner", pubList(), nil, map[string]graph.Snapshot{viewerUID: {BlockedBy: set(testUID)}}, viewerUID, ErrNotFound},
		{"owner blocks the viewer", pubList(), nil, map[string]graph.Snapshot{testUID: {Blocked: set(viewerUID)}}, viewerUID, ErrNotFound},
		{"owner not ACTIVE", pubList(), map[string]identity.Profile{testUID: {UserID: testUID, Status: identity.AccountStatusSuspended}}, nil, viewerUID, ErrNotFound},
		{"own public list", pubList(), nil, nil, testUID, ErrOwnList},
		{"own private list", List{ID: testListID, OwnerID: testUID, IsPrivate: true}, nil, nil, testUID, ErrOwnList},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newReadEnv(tt.profiles, tt.snaps, tt.list)
			got, err := e.svc.ReportableList(context.Background(), tt.viewer, testListID)
			if tt.want != nil {
				if !errors.Is(err, tt.want) {
					t.Fatalf("err = %v, want %v", err, tt.want)
				}
				if got != (ReportedList{}) {
					t.Errorf("a refusal returned evidence: %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.OwnerUID != testUID || got.OwnerHandle != testUID || got.Name != "Cricket" || got.Description != "ODI" {
				t.Errorf("evidence = %+v", got)
			}
		})
	}
}

func TestReportableList_MissingAndMalformedIdsAreNotFound(t *testing.T) {
	t.Parallel()
	e := newReadEnv(nil, nil)
	for _, id := range []string{testListID, "abc", ""} {
		if _, err := e.svc.ReportableList(context.Background(), viewerUID, id); !errors.Is(err, ErrNotFound) {
			t.Errorf("id %q: err = %v, want ErrNotFound", id, err)
		}
	}
}
