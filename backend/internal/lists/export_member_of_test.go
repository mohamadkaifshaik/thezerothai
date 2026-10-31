package lists

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

type fakeExportSrc struct{}

func (fakeExportSrc) ExportPage(context.Context, string, string, int) ([]ExportedList, error) {
	return nil, nil
}

// fakeMemberOf pages a fixed slice like the repo: ids ascending, `full` when the page filled.
type fakeMemberOf struct {
	rows  []MemberOfDoc
	pages int
}

func (f *fakeMemberOf) MemberOfPage(_ context.Context, _, after string, limit int) ([]MemberOfDoc, string, bool, error) {
	f.pages++
	var out []MemberOfDoc
	for _, r := range f.rows {
		if r.ListID > after {
			out = append(out, r)
		}
	}
	if len(out) > limit {
		out = out[:limit]
	}
	if len(out) == 0 {
		return nil, "", false, nil
	}
	return out, out[len(out)-1].ListID, len(out) == limit, nil
}

type fakeHandles struct {
	profs map[string]identity.Profile
	calls [][]string
}

func (f *fakeHandles) GetProfiles(_ context.Context, ids []string) (map[string]identity.Profile, error) {
	f.calls = append(f.calls, ids)
	out := map[string]identity.Profile{}
	for _, id := range ids {
		if p, ok := f.profs[id]; ok {
			out[id] = p
		}
	}
	return out, nil
}

type fakeSocial struct {
	snap  graph.Snapshot
	calls int
}

func (f *fakeSocial) Snapshot(context.Context, string) (graph.Snapshot, error) {
	f.calls++
	return f.snap, nil
}

func exportMemberOf(t *testing.T, rows []MemberOfDoc, profs map[string]identity.Profile, snap graph.Snapshot) (out string, h *fakeHandles, s *fakeSocial) {
	t.Helper()
	h, s = &fakeHandles{profs: profs}, &fakeSocial{snap: snap}
	x := NewExporter(fakeExportSrc{}).WithMembership(&fakeMemberOf{rows: rows}, h, s)
	var buf bytes.Buffer
	if err := x.ExportUser(context.Background(), "me", &buf); err != nil {
		t.Fatal(err)
	}
	return buf.String(), h, s
}

// W5-46: public memberships are listed with id, owner handle and name; private, hidden, inactive-owner and unapproved
// protected-owner memberships are only counted; nothing names another member or the private list.
func TestExportMemberOf_RedactsAndNeverNamesOthers(t *testing.T) {
	t.Parallel()
	rows := []MemberOfDoc{
		{ListID: "01", OwnerID: "o1", Name: "Public One"},
		{ListID: "02", OwnerID: "o1", Name: "SECRET NAME", IsPrivate: true},
		{ListID: "03", OwnerID: "o2", Name: "MODERATED", Hidden: true},
		{ListID: "04", OwnerID: "o3", Name: "Gone owner"},
		{ListID: "05", OwnerID: "o4", Name: "Protected followed"},
		{ListID: "06", OwnerID: "o5", Name: "Protected not followed"},
	}
	profs := map[string]identity.Profile{
		"o1": {UserID: "o1", Handle: "alice", Status: identity.AccountStatusActive},
		"o3": {UserID: "o3", Handle: "gone", Status: identity.AccountStatusSuspended},
		"o4": {UserID: "o4", Handle: "pfollowed", Status: identity.AccountStatusActive, IsPrivate: true},
		"o5": {UserID: "o5", Handle: "pstranger", Status: identity.AccountStatusActive, IsPrivate: true},
	}
	out, h, s := exportMemberOf(t, rows, profs, graph.Snapshot{Following: set("o4")})
	var got struct {
		Lists         []any `json:"lists"`
		ListsMemberOf struct {
			Public   []ExportedMembership `json:"public"`
			Redacted int                  `json:"redactedCount"`
		} `json:"lists_member_of"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, out)
	}
	pub := got.ListsMemberOf.Public
	if len(pub) != 2 || pub[0] != (ExportedMembership{"01", "alice", "Public One"}) || pub[1] != (ExportedMembership{"05", "pfollowed", "Protected followed"}) {
		t.Errorf("public = %+v", pub)
	}
	if got.ListsMemberOf.Redacted != 4 {
		t.Errorf("redactedCount = %d, want 4", got.ListsMemberOf.Redacted)
	}
	for _, leak := range []string{"SECRET NAME", "MODERATED", "Gone owner", "Protected not followed", "pstranger", "gone", `"02"`, `"03"`, `"06"`, "memberIds"} {
		if strings.Contains(out, leak) {
			t.Errorf("export leaks %q:\n%s", leak, out)
		}
	}
	// private/hidden owners are never looked up; the graph is read once, only because a protected owner was met
	if len(h.calls) != 1 || len(h.calls[0]) != 4 || s.calls != 1 {
		t.Errorf("directory calls %v, graph calls %d", h.calls, s.calls)
	}
}

func TestExportMemberOf_EmptyAndNoGraphReadWithoutProtectedOwner(t *testing.T) {
	t.Parallel()
	out, h, s := exportMemberOf(t, nil, nil, graph.Snapshot{})
	if out != `{"lists":[],"lists_member_of":{"public":[],"redactedCount":0}}`+"\n" {
		t.Errorf("empty = %q", out)
	}
	if len(h.calls) != 0 || s.calls != 0 {
		t.Errorf("reads on an empty export: %v %d", h.calls, s.calls)
	}
	out, _, s = exportMemberOf(t, []MemberOfDoc{{ListID: "01", OwnerID: "o1", Name: "n"}},
		map[string]identity.Profile{"o1": {Handle: "a", Status: identity.AccountStatusActive}}, graph.Snapshot{})
	if s.calls != 0 || !strings.Contains(out, `"ownerHandle":"a"`) {
		t.Errorf("public owner: graph calls %d, out %s", s.calls, out)
	}
}

// More than one page of memberships: every page is read, the cursor is the last matched id, and the owner lookup chunks at 50.
func TestExportMemberOf_PagesAndChunks(t *testing.T) {
	t.Parallel()
	var rows []MemberOfDoc
	profs := map[string]identity.Profile{}
	for i := range 120 {
		id := "o" + string(rune('A'+i/26)) + string(rune('a'+i%26))
		rows = append(rows, MemberOfDoc{ListID: "L" + id, OwnerID: id, Name: "n"})
		profs[id] = identity.Profile{Handle: id, Status: identity.AccountStatusActive}
	}
	rows = append(rows, MemberOfDoc{ListID: "Lzz", OwnerID: "zz", Name: "x", IsPrivate: true})
	f := &fakeMemberOf{rows: rows}
	h := &fakeHandles{profs: profs}
	var buf bytes.Buffer
	if err := NewExporter(fakeExportSrc{}).WithMembership(f, h, &fakeSocial{}).ExportUser(context.Background(), "me", &buf); err != nil {
		t.Fatal(err)
	}
	var got struct {
		M struct {
			Public []ExportedMembership `json:"public"`
			N      int                  `json:"redactedCount"`
		} `json:"lists_member_of"`
	}
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil || len(got.M.Public) != 120 || got.M.N != 1 {
		t.Fatalf("err %v, public %d, redacted %d", err, len(got.M.Public), got.M.N)
	}
	if f.pages != 2 {
		t.Errorf("pages = %d, want 2", f.pages)
	}
	for _, c := range h.calls {
		if len(c) > 50 {
			t.Errorf("directory call of %d ids", len(c))
		}
	}
}
