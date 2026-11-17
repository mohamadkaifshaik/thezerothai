package lists

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const (
	redactSubject = "SubjectUidAbCdEfGhIjKlMn0123"
	redactOther   = "OtherPersonUidAbCdEfGhIj4567"
)

// leakingPeople is a PeopleSource / HandleSource whose error names the people it was asked for.
type leakingPeople struct {
	err func(ids []string) error
}

func (f leakingPeople) GetProfiles(_ context.Context, ids []string) (map[string]identity.Profile, error) {
	return nil, f.err(ids)
}

type failingSocial struct{ err error }

func (f failingSocial) Snapshot(context.Context, string) (graph.Snapshot, error) {
	return graph.Snapshot{}, f.err
}

// Every read of another person's document the lists section makes (the members of the subject's lists, the owners of the
// lists that name the subject, the subject's graph) returns an error that names nobody: no uid, no document path.
func TestExporter_ErrorsNameNobody(t *testing.T) {
	t.Parallel()
	sentinel := errors.New("firestore unavailable")
	leak := func(ids []string) error {
		return fmt.Errorf(`identity: decode profile %s: rpc error: "projects/demo-p/databases/(default)/documents/users/%s": %w`, ids[0], ids[0], sentinel)
	}
	protectedOwner := map[string]identity.Profile{
		redactOther: {UserID: redactOther, Handle: "owner", Status: identity.AccountStatusActive, IsPrivate: true},
	}
	rows := []MemberOfDoc{{ListID: "01", OwnerID: redactOther, Name: "Public"}}
	tests := []struct {
		name string
		x    func() *Exporter
		want string
	}{
		{"members", func() *Exporter {
			src := &fakeSource{pages: [][]ExportedList{{{ListID: "0000000000000000001", MemberIDs: []string{redactOther}}}}}
			return NewExporter(src, leakingPeople{err: leak})
		}, "lists: export members"},
		{"member-of owners", func() *Exporter {
			return NewExporter(fakeExportSrc{}, exportPeople()).WithMembership(&fakeMemberOf{rows: rows}, leakingPeople{err: leak}, &fakeSocial{})
		}, "lists: export member-of owners"},
		{"member-of graph", func() *Exporter {
			gerr := fmt.Errorf("graph: get %s: documents/graph/%s and follows/%s_%s: %w", redactSubject, redactSubject, redactSubject, redactOther, sentinel)
			return NewExporter(fakeExportSrc{}, exportPeople()).WithMembership(&fakeMemberOf{rows: rows}, &fakeHandles{profs: protectedOwner}, failingSocial{err: gerr})
		}, "lists: export member-of graph"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			err := tt.x().ExportUser(context.Background(), redactSubject, &buf)
			if err == nil {
				t.Fatal("a failing source exported")
			}
			for _, raw := range []string{redactSubject, redactOther, "documents/"} {
				if strings.Contains(err.Error(), raw) {
					t.Errorf("the error carries %q: %v", raw, err)
				}
			}
			if !errors.Is(err, sentinel) {
				t.Errorf("errors.Is no longer reaches the cause: %v", err)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("err = %v, want it to keep %q", err, tt.want)
			}
		})
	}
}
