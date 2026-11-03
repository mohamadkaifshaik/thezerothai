package communities

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const reportCID = "0000000000000000901"

// ReportableCommunity (ADR-0031 D14): the evidence of an ACTIVE or ARCHIVED community for a stranger; the same ErrNotFound for a
// missing and a SUSPENDED one; ErrOwnCommunity for the owner; the owner's handle only while the owner is ACTIVE.
func TestReportableCommunity_Table(t *testing.T) {
	t.Parallel()
	made := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	rules := []Rule{{Title: "Be kind", Text: "No insults."}}
	tests := []struct {
		name       string
		community  *Community
		caller     string
		ownerState identity.AccountStatus
		wantErr    error
		wantHandle string
		wantOwner  string
		wantReads  int64
	}{
		{"active community", &Community{Status: StatusActive, OwnerID: ownerUID}, "stranger", identity.AccountStatusActive, nil, "owner1-handle", ownerUID, 2},
		{"moderators may report", &Community{Status: StatusActive, OwnerID: ownerUID, ModeratorIDs: []string{modUID}}, modUID, identity.AccountStatusActive, nil, "owner1-handle", ownerUID, 2},
		{"archived community has no owner and no profile read", &Community{Status: StatusArchived}, "stranger", identity.AccountStatusActive, nil, "", "", 1},
		{"suspended community is not found", &Community{Status: StatusSuspended, OwnerID: ownerUID}, "stranger", identity.AccountStatusActive, ErrNotFound, "", "", 1},
		{"suspended community is not found for its owner either", &Community{Status: StatusSuspended, OwnerID: ownerUID}, ownerUID, identity.AccountStatusActive, ErrNotFound, "", "", 1},
		{"missing community", nil, "stranger", identity.AccountStatusActive, ErrNotFound, "", "", 1},
		{"own community", &Community{Status: StatusActive, OwnerID: ownerUID}, ownerUID, identity.AccountStatusActive, ErrOwnCommunity, "", "", 1},
		{"owner being deleted has no handle", &Community{Status: StatusActive, OwnerID: ownerUID}, "stranger", identity.AccountStatusDeleting, nil, "", ownerUID, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			f.dir.profiles[ownerUID] = profile(ownerUID, tt.ownerState)
			p := f.dir.profiles[ownerUID]
			p.Handle = "owner1-handle"
			f.dir.profiles[ownerUID] = p
			if tt.community != nil {
				c := *tt.community
				c.ID, c.Name, c.Description, c.Rules, c.CreatedAt = reportCID, "Cats", "All cats", rules, made
				f.seed(c)
			}
			ctx, ctr := budget.WithCounter(context.Background())
			got, err := f.svc.ReportableCommunity(ctx, tt.caller, reportCID)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if ctr.Reads() != tt.wantReads || ctr.Writes() != 0 {
				t.Errorf("reads = %d writes = %d, want %d 0", ctr.Reads(), ctr.Writes(), tt.wantReads)
			}
			if tt.wantErr != nil {
				return
			}
			if got.OwnerUID != tt.wantOwner || got.OwnerHandle != tt.wantHandle || got.Name != "Cats" || got.Description != "All cats" || !got.CreatedAt.Equal(made) || len(got.Rules) != 1 || got.Rules[0] != rules[0] {
				t.Errorf("got = %+v", got)
			}
		})
	}
}

// A second report within the cache window costs 0 community reads (staleness bound 60 s), and a malformed id is NotFound with 0 reads.
func TestReportableCommunity_WarmAndMalformed(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.seed(Community{ID: reportCID, Name: "Cats", Status: StatusActive})
	for i := 0; i < 2; i++ {
		if _, err := f.svc.ReportableCommunity(context.Background(), "stranger", reportCID); err != nil {
			t.Fatal(err)
		}
	}
	if f.repo.gets != 1 {
		t.Errorf("community reads = %d, want 1 (the second call is a cache hit)", f.repo.gets)
	}
	before := f.repo.gets
	if _, err := f.svc.ReportableCommunity(context.Background(), "stranger", "12"); !errors.Is(err, ErrNotFound) || f.repo.gets != before {
		t.Errorf("malformed id: err = %v, reads +%d", err, f.repo.gets-before)
	}
}

// An infrastructure error loading the owner is returned redacted, not mapped to a client answer.
func TestReportableCommunity_DirectoryErrorIsRedacted(t *testing.T) {
	t.Parallel()
	f := newFixture()
	f.seed(Community{ID: reportCID, Name: "Cats", Status: StatusActive, OwnerID: ownerUID})
	f.dir.err = errors.New("lookup " + ownerUID + " failed")
	_, err := f.svc.ReportableCommunity(context.Background(), "stranger", reportCID)
	if err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v", err)
	}
	if got := err.Error(); strings.Contains(got, ownerUID) || strings.Contains(got, "stranger") || strings.Contains(got, reportCID) {
		t.Errorf("error leaks an id: %v", err)
	}
}
