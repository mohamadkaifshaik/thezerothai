package graph

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// failingProfiles is a ProfileReader whose error names the people it was asked for, as the identity repo and Firestore can.
type failingProfiles struct {
	err func(uids []string) error
}

func (f failingProfiles) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	return nil, f.err(uids)
}

// The export reads the profile of everyone the subject follows, is followed by, blocked or muted. An error of that read
// names those people; the error the exporter returns names nobody (it ends up on the export job log line).
func TestPeopleFor_ErrorNamesNobody(t *testing.T) {
	t.Parallel()
	sentinel := errors.New("firestore unavailable")
	tests := []struct {
		name string
		err  func(uids []string) error
	}{
		{"bare uid (the identity decode error)", func(u []string) error { return fmt.Errorf("identity: decode profile %s: %w", u[0], sentinel) }},
		{"document path", func(u []string) error {
			return fmt.Errorf(`identity: get profiles: rpc error: "projects/demo-p/databases/(default)/documents/users/%s": %w`, u[1], sentinel)
		}},
		{"both", func(u []string) error {
			return fmt.Errorf("decode profile %s at projects/demo-p/databases/(default)/documents/users/%s: %w", u[1], u[0], sentinel)
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := &FirestoreRepo{profiles: failingProfiles{err: tt.err}}
			_, err := r.peopleFor(context.Background(), []string{expUIDWithID}, []string{expUIDNoID})
			if err == nil {
				t.Fatal("a failing ProfileReader exported")
			}
			for _, raw := range []string{expUIDWithID, expUIDNoID, "documents/"} {
				if strings.Contains(err.Error(), raw) {
					t.Errorf("the error carries %q: %v", raw, err)
				}
			}
			if !errors.Is(err, sentinel) {
				t.Errorf("errors.Is no longer reaches the cause: %v", err)
			}
			if !strings.Contains(err.Error(), "graph: export: profiles") {
				t.Errorf("the error lost its context: %v", err)
			}
		})
	}
}

// The legitimate path is unchanged: a working reader still resolves everyone.
func TestPeopleFor_StillResolves(t *testing.T) {
	t.Parallel()
	r := &FirestoreRepo{profiles: exportFixture()}
	people, err := r.peopleFor(context.Background(), []string{expUIDWithID, expUIDNoID})
	if err != nil || people[expUIDWithID].Handle != "withid" || people[expUIDNoID].Handle != "noid" {
		t.Errorf("people = %+v, err = %v", people, err)
	}
}
