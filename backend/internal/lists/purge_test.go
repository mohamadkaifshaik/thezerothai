package lists

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// fakePurger plays back one answer per call and records the calls, so the phase machine is tested without Firestore.
type fakePurger struct {
	owned     []int
	members   []MemberPage
	ownedErr  error
	memberErr error
	calls     []string
}

func (f *fakePurger) PurgeOwnedPage(context.Context, string) (int, error) {
	f.calls = append(f.calls, "own")
	if f.ownedErr != nil {
		return 0, f.ownedErr
	}
	n := f.owned[0]
	f.owned = f.owned[1:]
	return n, nil
}

func (f *fakePurger) RemoveMemberPage(context.Context, string) (MemberPage, error) {
	f.calls = append(f.calls, "member")
	if f.memberErr != nil {
		return MemberPage{}, f.memberErr
	}
	p := f.members[0]
	f.members = f.members[1:]
	return p, nil
}

// drive runs the eraser to completion and returns every checkpoint it produced.
func drive(t *testing.T, e *Eraser, cp Checkpoint) ([]Checkpoint, bool) {
	t.Helper()
	var seen []Checkpoint
	for range 20 {
		next, done, err := e.PurgeUser(context.Background(), "u1", cp)
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, next)
		if done {
			return seen, true
		}
		cp = next
	}
	return seen, false
}

func TestEraser_Phases(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		p         *fakePurger
		start     Checkpoint
		wantCalls string
		want      Checkpoint
	}{
		{"an account with no lists takes one empty page per phase", &fakePurger{owned: []int{0}, members: []MemberPage{{}}}, Checkpoint{}, "own member", Checkpoint{Phase: "member"}},
		{"own lists, then membership", &fakePurger{owned: []int{2}, members: []MemberPage{{Scanned: 3, Updated: 3}}}, Checkpoint{}, "own member", Checkpoint{Phase: "member", Deleted: 2, Updated: 3}},
		{"a full own page runs again before the member phase", &fakePurger{owned: []int{500, 7}, members: []MemberPage{{}}}, Checkpoint{}, "own own member", Checkpoint{Phase: "member", Deleted: 507}},
		{"a full member page runs again", &fakePurger{owned: []int{0}, members: []MemberPage{{Scanned: 500, Updated: 500}, {Scanned: 1, Updated: 1}}}, Checkpoint{}, "own member member", Checkpoint{Phase: "member", Updated: 501}},
		{"a conflict re-queries and counts nothing", &fakePurger{owned: []int{0}, members: []MemberPage{{Scanned: 4, Conflict: true}, {Scanned: 4, Updated: 4}}}, Checkpoint{}, "own member member", Checkpoint{Phase: "member", Updated: 4}},
		{"resumes in the member phase from a checkpoint", &fakePurger{members: []MemberPage{{}}}, Checkpoint{Phase: "member", Deleted: 5}, "member", Checkpoint{Phase: "member", Deleted: 5}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			seen, done := drive(t, NewEraser(tt.p), tt.start)
			if !done || seen[len(seen)-1] != tt.want {
				t.Errorf("done %v checkpoint %+v, want true %+v", done, seen[len(seen)-1], tt.want)
			}
			if got := strings.Join(tt.p.calls, " "); got != tt.wantCalls {
				t.Errorf("calls = %q, want %q", got, tt.wantCalls)
			}
		})
	}
}

// A page that errors reports not done and hands back the checkpoint it was given, so the job retries the same page.
func TestEraser_ErrorKeepsCheckpoint(t *testing.T) {
	t.Parallel()
	boom := errors.New("boom")
	cp := Checkpoint{Phase: "member", Updated: 2}
	next, done, err := NewEraser(&fakePurger{memberErr: boom}).PurgeUser(context.Background(), "u1", cp)
	if !errors.Is(err, boom) || done || next != cp {
		t.Errorf("member error: next %+v done %v err %v", next, done, err)
	}
	cp = Checkpoint{Deleted: 1}
	next, done, err = NewEraser(&fakePurger{ownedErr: boom}).PurgeUser(context.Background(), "u1", cp)
	if !errors.Is(err, boom) || done || next != cp {
		t.Errorf("own error: next %+v done %v err %v", next, done, err)
	}
}

type fakeSource struct {
	pages [][]ExportedList
	after []string
}

func (f *fakeSource) ExportPage(_ context.Context, _, after string, _ int) ([]ExportedList, error) {
	f.after = append(f.after, after)
	if len(f.pages) == 0 {
		return nil, nil
	}
	p := f.pages[0]
	f.pages = f.pages[1:]
	return p, nil
}

// TestExporter_Golden: the section for a user with two lists, byte for byte (member ids included, no hidden flag), against
// testdata/export_lists.golden.json. Change the file only for an intended format change: it is the contract of the `lists`
// section in the account export.
func TestExporter_Golden(t *testing.T) {
	t.Parallel()
	at := time.Date(2026, 10, 30, 9, 0, 0, 0, time.UTC)
	src := &fakeSource{pages: [][]ExportedList{{
		{ListID: "0000000000000000001", Name: "Cricket", Description: "Test and ODI", IsPrivate: true, MemberIDs: []string{"u-a", "u-b"}, CreatedAt: at, UpdatedAt: at.Add(time.Hour)},
		{ListID: "0000000000000000002", Name: "Empty", Description: "", IsPrivate: false, MemberIDs: []string{}, CreatedAt: at, UpdatedAt: at},
	}}}
	var buf bytes.Buffer
	if err := NewExporter(src).ExportUser(context.Background(), "u1", &buf); err != nil {
		t.Fatal(err)
	}
	want, err := os.ReadFile("testdata/export_lists.golden.json")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.ReplaceAll(buf.String(), "\r\n", "\n"); got != strings.ReplaceAll(string(want), "\r\n", "\n") {
		t.Errorf("export =\n%s\nwant\n%s", got, want)
	}
}

func TestExporter_EmptyAndPaging(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	if err := NewExporter(&fakeSource{}).ExportUser(context.Background(), "u1", &buf); err != nil || buf.String() != "{\"lists\":[]}\n" {
		t.Errorf("empty export = %q, %v", buf.String(), err)
	}
	// A full page is followed by a request after its last id; a short page ends the section.
	full := make([]ExportedList, exportPage)
	for i := range full {
		full[i] = ExportedList{ListID: string(rune('A'+i%26)) + string(rune('a'+i/26)), MemberIDs: []string{}}
	}
	last := full[len(full)-1].ListID
	src := &fakeSource{pages: [][]ExportedList{full, {{ListID: "zz", MemberIDs: []string{}}}}}
	buf.Reset()
	if err := NewExporter(src).ExportUser(context.Background(), "u1", &buf); err != nil {
		t.Fatal(err)
	}
	if len(src.after) != 2 || src.after[0] != "" || src.after[1] != last {
		t.Errorf("page cursors = %q, want [\"\" %q]", src.after, last)
	}
	if n := strings.Count(buf.String(), `"listId"`); n != exportPage+1 {
		t.Errorf("rows = %d, want %d", n, exportPage+1)
	}
}
