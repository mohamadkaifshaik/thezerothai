package lists

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const (
	expPubA = "u0123456789abcdefghjkmnpqrs"
)

// exportPeople is the PeopleSource of the export tests: identity's repo answers every status, and an erased account is
// absent. u-a has a public id, u-b is SUSPENDED and has none, u-gone is erased.
func exportPeople() *fakeHandles {
	return &fakeHandles{profs: map[string]identity.Profile{
		"u-a": {UserID: "u-a", PublicID: expPubA, Handle: "alice", Status: identity.AccountStatusActive},
		"u-b": {UserID: "u-b", Handle: "bob", Status: identity.AccountStatusSuspended},
	}}
}

// Members are written as {publicId, handle} rows in memberIds order, one row per member: a member without a public id by
// handle only, a suspended one still listed, an erased one as an empty row. No row ever carries the uid.
func TestExporter_MembersByHandleAndPublicID(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		members []string
		want    string
	}{
		{"with public id", []string{"u-a"}, `[{"publicId":"` + expPubA + `","handle":"alice"}]`},
		{"suspended, no public id", []string{"u-b"}, `[{"handle":"bob"}]`},
		{"erased", []string{"u-gone"}, `[{}]`},
		{"order and duplicates kept", []string{"u-gone", "u-b", "u-a", "u-b"}, `[{},{"handle":"bob"},{"publicId":"` + expPubA + `","handle":"alice"},{"handle":"bob"}]`},
		{"no members", []string{}, `[]`},
		{"nil members", nil, `[]`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			src := &fakeSource{pages: [][]ExportedList{{{ListID: "0000000000000000001", MemberIDs: tt.members}}}}
			var buf bytes.Buffer
			if err := NewExporter(src, exportPeople()).ExportUser(context.Background(), "u1", &buf); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(buf.String(), `"members":`+tt.want+`,`) {
				t.Errorf("export = %s, want members %s", buf.String(), tt.want)
			}
			for _, uid := range []string{"u-a", "u-b", "u-gone"} {
				if strings.Contains(buf.String(), `"`+uid+`"`) {
					t.Errorf("the export carries the member uid %s: %s", uid, buf.String())
				}
			}
			if strings.Contains(buf.String(), "memberIds") {
				t.Errorf("the export still has memberIds: %s", buf.String())
			}
		})
	}
}

// Every distinct member is read once per export, in batches of at most 50, however many lists and pages name them.
func TestExporter_MembersOneReadPerDistinctPerson(t *testing.T) {
	t.Parallel()
	var many []string
	for i := range memberOfLookupChunk + 1 {
		many = append(many, fmt.Sprintf("m%03d", i))
	}
	full := make([]ExportedList, exportPage)
	for i := range full {
		full[i] = ExportedList{ListID: fmt.Sprintf("%019d", i), MemberIDs: many[:2]}
	}
	full[0].MemberIDs = many
	src := &fakeSource{pages: [][]ExportedList{full, {{ListID: "zz", MemberIDs: append([]string{"m999"}, many...)}}}}
	people := exportPeople()
	var buf bytes.Buffer
	if err := NewExporter(src, people).ExportUser(context.Background(), "u1", &buf); err != nil {
		t.Fatal(err)
	}
	var sizes []int
	seen := map[string]int{}
	for _, c := range people.calls {
		sizes = append(sizes, len(c))
		for _, id := range c {
			seen[id]++
		}
	}
	// Page 1: 51 distinct (50 + 1); page 2: only m999 is new.
	if fmt.Sprint(sizes) != "[50 1 1]" {
		t.Errorf("profile batches = %v, want [50 1 1]", sizes)
	}
	for id, n := range seen {
		if n != 1 {
			t.Errorf("%s read %d times", id, n)
		}
	}
}

func TestExporter_MembersFailClosed(t *testing.T) {
	t.Parallel()
	src := func() *fakeSource {
		return &fakeSource{pages: [][]ExportedList{{{ListID: "1", MemberIDs: []string{"u-a"}}}}}
	}
	var buf bytes.Buffer
	if err := NewExporter(src(), nil).ExportUser(context.Background(), "u1", &buf); err == nil {
		t.Error("an exporter without a PeopleSource exported")
	}
	boom := errors.New("boom")
	buf.Reset()
	if err := NewExporter(src(), failingPeople{boom}).ExportUser(context.Background(), "u1", &buf); !errors.Is(err, boom) {
		t.Errorf("err = %v, want %v", err, boom)
	}
	if strings.Contains(buf.String(), "u-a") {
		t.Errorf("a failed lookup wrote the uid: %s", buf.String())
	}
}

type failingPeople struct{ err error }

func (f failingPeople) GetProfiles(context.Context, []string) (map[string]identity.Profile, error) {
	return nil, f.err
}
