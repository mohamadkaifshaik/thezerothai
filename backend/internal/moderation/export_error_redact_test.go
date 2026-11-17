package moderation

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// The reports section reads the profile of every account the subject reported. An error of that read names the
// reported account (who reported whom); the error the exporter returns names nobody.
func TestResolveAccountTargets_ErrorNamesNobody(t *testing.T) {
	t.Parallel()
	sentinel := errors.New("firestore unavailable")
	tests := []struct {
		name string
		err  error
	}{
		{"bare uid (the identity decode error)", fmt.Errorf("identity: decode profile %s: %w", expUIDWithID, sentinel)},
		{"document path", fmt.Errorf(`identity: get profiles: rpc error: "projects/demo-p/databases/(default)/documents/users/%s": %w`, expUIDNoID, sentinel)},
		{"both", fmt.Errorf("decode profile %s at projects/demo-p/databases/(default)/documents/users/%s: %w", expUIDNoID, expUIDWithID, sentinel)},
	}
	docs := []reportDoc{
		{TargetType: string(TargetAccount), TargetID: expUIDWithID},
		{TargetType: string(TargetAccount), TargetID: expUIDNoID},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			err := resolveAccountTargets(context.Background(), &fakePeople{err: tt.err}, docs, map[string]exportedPerson{})
			if err == nil {
				t.Fatal("a failing ProfileReader resolved")
			}
			for _, raw := range []string{expUIDWithID, expUIDNoID, "documents/"} {
				if strings.Contains(err.Error(), raw) {
					t.Errorf("the error carries %q: %v", raw, err)
				}
			}
			if !errors.Is(err, sentinel) {
				t.Errorf("errors.Is no longer reaches the cause: %v", err)
			}
			if !strings.Contains(err.Error(), "moderation: export: profiles") {
				t.Errorf("the error lost its context: %v", err)
			}
		})
	}
}

// The legitimate path is unchanged: a working reader still resolves the reported accounts.
func TestResolveAccountTargets_StillResolves(t *testing.T) {
	t.Parallel()
	people := map[string]exportedPerson{}
	docs := []reportDoc{{TargetType: string(TargetAccount), TargetID: expUIDWithID}}
	if err := resolveAccountTargets(context.Background(), exportPeople(), docs, people); err != nil || people[expUIDWithID].Handle != "withid" {
		t.Errorf("people = %+v, err = %v", people, err)
	}
}
