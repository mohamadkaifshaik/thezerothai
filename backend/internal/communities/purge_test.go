package communities

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// fakePurger is an in-memory PagePurger that records the order of calls.
type fakePurger struct {
	ms        Memberships
	exists    bool
	calls     []string
	failAt    string
	deleted   int
	loadErr   error
	results   map[string]PurgeResult
	gotParams []PurgeParams
}

func (p *fakePurger) LoadMemberships(context.Context, string) (Memberships, bool, error) {
	p.calls = append(p.calls, "load")
	return p.ms, p.exists, p.loadErr
}

func (p *fakePurger) PurgeCommunity(_ context.Context, _ string, cid string, pp PurgeParams) (PurgeResult, error) {
	p.calls = append(p.calls, cid)
	p.gotParams = append(p.gotParams, pp)
	if cid == p.failAt {
		return PurgeResult{}, errors.New("boom")
	}
	return p.results[cid], nil
}

func (p *fakePurger) DeleteMemberships(context.Context, string) error {
	p.calls = append(p.calls, "delete")
	p.deleted++
	p.exists = false
	return nil
}

func TestMemberships_UnionIsSortedAndDeduplicated(t *testing.T) {
	m := Memberships{Joined: []string{"c3", "c1"}, Owned: []string{"c1"}, Banned: []string{"c2"}, Modlogged: []string{"c3", "c4"}}
	if got := m.union(); !slices.Equal(got, []string{"c1", "c2", "c3", "c4"}) {
		t.Errorf("union = %v", got)
	}
	if got := (Memberships{}).union(); len(got) != 0 {
		t.Errorf("empty union = %v", got)
	}
}

func TestScrub(t *testing.T) {
	log := []LogEntry{
		{Seq: 1, Actor: "u", Action: ActionHide, PostID: "p1"},
		{Seq: 2, Actor: "m", Action: ActionBan, Target: "u"},
		{Seq: 3, Actor: "u", Action: ActionUnban, Target: "u"},
		{Seq: 4, Actor: "m", Action: ActionEdit},
	}
	got, n := scrub(log, "u")
	if n != 3 {
		t.Errorf("scrubbed = %d, want 3", n)
	}
	want := []LogEntry{
		{Seq: 1, Actor: DeletedMarker, Action: ActionHide, PostID: "p1"},
		{Seq: 2, Actor: "m", Action: ActionBan, Target: DeletedMarker},
		{Seq: 3, Actor: DeletedMarker, Action: ActionUnban, Target: DeletedMarker},
		{Seq: 4, Actor: "m", Action: ActionEdit},
	}
	if !slices.Equal(got, want) {
		t.Errorf("scrub = %+v, want %+v", got, want)
	}
	if log[0].Actor != "u" {
		t.Error("scrub changed its input")
	}
	if _, n := scrub(log, "nobody"); n != 0 {
		t.Errorf("an uninvolved uid scrubbed %d entries", n)
	}
}

func cids(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = "c" + string(rune('a'+i))
	}
	return out
}

func TestEraser_NoMembershipsIsOneReadAndDone(t *testing.T) {
	p := &fakePurger{}
	next, done, err := NewEraser(p, nil).PurgeUser(context.Background(), "u", Checkpoint{})
	if err != nil || !done || next != (Checkpoint{}) {
		t.Fatalf("= %+v, %v, %v", next, done, err)
	}
	if !slices.Equal(p.calls, []string{"load"}) {
		t.Errorf("calls = %v, want only the memberships read", p.calls)
	}
}

func TestEraser_ChunksResumesAndDeletesMembershipsLast(t *testing.T) {
	list := cids(5)
	p := &fakePurger{
		ms: Memberships{Joined: list[:3], Owned: []string{list[1]}, Banned: []string{list[3]}, Modlogged: []string{list[4], list[0]}}, exists: true,
		results: map[string]PurgeResult{list[1]: {HandedOver: true}, list[3]: {Archived: true}},
	}
	e := NewEraser(p, nil, WithChunk(2))
	cp, invocations := Checkpoint{}, 0
	for {
		invocations++
		next, done, err := e.PurgeUser(context.Background(), "u", cp)
		if err != nil {
			t.Fatal(err)
		}
		cp = next
		if done {
			break
		}
		if p.deleted != 0 {
			t.Fatal("the memberships doc went before the last community")
		}
		if invocations > 10 {
			t.Fatal("never finished")
		}
	}
	if invocations != 3 {
		t.Errorf("invocations = %d, want 3 (2 + 2 + 1)", invocations)
	}
	want := []string{"load", "ca", "cb", "load", "cc", "cd", "load", "ce", "delete"}
	if !slices.Equal(p.calls, want) {
		t.Errorf("calls = %v\n want %v", p.calls, want)
	}
	if cp.Communities != 5 || cp.Handovers != 1 || cp.Archived != 1 || cp.After != "ce" {
		t.Errorf("checkpoint = %+v", cp)
	}
	// a rerun after completion is one read and no writes
	p.calls = nil
	if _, done, err := e.PurgeUser(context.Background(), "u", cp); err != nil || !done || !slices.Equal(p.calls, []string{"load"}) {
		t.Errorf("rerun: done=%v err=%v calls=%v", done, err, p.calls)
	}
}

func TestEraser_ExactlyOneChunkDeletesInTheSameCall(t *testing.T) {
	p := &fakePurger{ms: Memberships{Joined: cids(2)}, exists: true}
	_, done, err := NewEraser(p, nil).PurgeUser(context.Background(), "u", Checkpoint{})
	if err != nil || !done || !slices.Equal(p.calls, []string{"load", "ca", "cb", "delete"}) {
		t.Errorf("done=%v err=%v calls=%v", done, err, p.calls)
	}
}

func TestEraser_ResumeSurvivesAChangedList(t *testing.T) {
	// the checkpoint is a community id, not an index: ids the user left behind (or gained) cannot shift the resume point
	p := &fakePurger{ms: Memberships{Joined: []string{"ca", "cc", "cd"}}, exists: true}
	_, done, err := NewEraser(p, nil, WithChunk(5)).PurgeUser(context.Background(), "u", Checkpoint{After: "cb"})
	if err != nil || !done || !slices.Equal(p.calls, []string{"load", "cc", "cd", "delete"}) {
		t.Errorf("done=%v err=%v calls=%v", done, err, p.calls)
	}
}

func TestEraser_ErrorKeepsTheCheckpointAndTheMembershipsDoc(t *testing.T) {
	p := &fakePurger{ms: Memberships{Joined: cids(3)}, exists: true, failAt: "cb"}
	cp := Checkpoint{After: "c0"}
	next, done, err := NewEraser(p, nil).PurgeUser(context.Background(), "u", cp)
	if err == nil || done || next != cp || p.deleted != 0 {
		t.Errorf("next=%+v done=%v err=%v deleted=%d, want the input checkpoint, not done, the memberships doc kept", next, done, err, p.deleted)
	}
	p.loadErr = errors.New("down")
	if _, _, err := NewEraser(p, nil).PurgeUser(context.Background(), "u", cp); err == nil {
		t.Error("a load error was swallowed")
	}
}

func TestEraser_OnlyAnActiveAccountMayTakeOver(t *testing.T) {
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		"a": profile("a", identity.AccountStatusActive), "d": profile("d", identity.AccountStatusDeleting),
	}}
	e := NewEraser(&fakePurger{}, dir)
	ctx := context.Background()
	for uid, want := range map[string]bool{"a": true, "d": false, "missing": false} {
		if got := e.active(ctx, uid); got != want {
			t.Errorf("active(%q) = %v, want %v", uid, got, want)
		}
	}
	dir.err = errors.New("down")
	if e.active(ctx, "a") {
		t.Error("an unreadable account was chosen")
	}
	if NewEraser(&fakePurger{}, nil).active(ctx, "a") {
		t.Error("no directory chose an owner")
	}
}

func TestEraser_PassesTheModlogCap(t *testing.T) {
	p := &fakePurger{ms: Memberships{Joined: cids(1)}, exists: true}
	if _, _, err := NewEraser(p, nil, WithModlogMax(7), WithChunk(0), WithModlogMax(0)).PurgeUser(context.Background(), "u", Checkpoint{}); err != nil {
		t.Fatal(err)
	}
	if p.gotParams[0].ModlogMax != 7 {
		t.Errorf("modlog cap = %d, want 7 (a non-positive option is ignored)", p.gotParams[0].ModlogMax)
	}
}

// ---- export ----

type fakeExportSource struct {
	ms     Memberships
	exists bool
	rows   map[string]ExportRow
	gotIDs []string
	gotMem []string
	err    error
}

func (s *fakeExportSource) LoadMemberships(context.Context, string) (Memberships, bool, error) {
	return s.ms, s.exists, s.err
}

func (s *fakeExportSource) ExportRows(_ context.Context, _ string, ids, withMember []string) ([]ExportRow, error) {
	s.gotIDs, s.gotMem = ids, withMember
	out := make([]ExportRow, len(ids))
	for i, id := range ids {
		out[i] = s.rows[id]
	}
	return out, nil
}

func TestExport_ShapeRedactionAndNoOtherUID(t *testing.T) {
	at := time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)
	src := &fakeExportSource{exists: true,
		ms: Memberships{Joined: []string{"c1", "c2", "c3"}, Owned: []string{"c1"}, Banned: []string{"c4", "c5"}, Modlogged: []string{"c6", "c2"}},
		rows: map[string]ExportRow{
			"c1": {Exists: true, MemberState: MemberJoined, MemberAt: at, Community: Community{ID: "c1", Name: "Mine", Description: "d", OwnerID: "me", CreatedAt: at,
				Rules: []Rule{{Title: "Be kind", Text: "always"}}, ModeratorIDs: []string{"other-mod"},
				Modlog: []LogEntry{{Seq: 1, At: at, Actor: "me", Action: ActionEdit}, {Seq: 2, At: at, Actor: "other-mod", Action: ActionBan, Target: "banned-person"}}}},
			"c2": {Exists: true, MemberState: MemberJoined, MemberAt: at, Community: Community{ID: "c2", Name: "Moderated", OwnerID: "boss", ModeratorIDs: []string{"me"},
				Modlog: []LogEntry{{Seq: 1, At: at, Actor: "me", Action: ActionBan, Target: "someone"}, {Seq: 2, At: at, Actor: "me", Action: ActionHide, PostID: "p9"}}}},
			"c3": {Exists: true, MemberState: MemberJoined, MemberAt: at, Community: Community{ID: "c3", Name: "Plain", OwnerID: "boss"}},
			"c4": {Exists: true, MemberState: MemberBanned, MemberAt: at, Community: Community{ID: "c4", Name: "Banned from", OwnerID: "boss"}},
			"c5": {Exists: true, Community: Community{ID: "c5", Name: "Suspended", OwnerID: "boss", Status: StatusSuspended}},
			"c6": {Exists: true, Community: Community{ID: "c6", Name: "Suspended log", OwnerID: "boss", Status: StatusSuspended,
				Modlog: []LogEntry{{Seq: 1, At: at, Actor: "me", Action: ActionHide}}}},
		},
	}
	var buf bytes.Buffer
	if err := NewExporter(src).ExportUser(context.Background(), "me", &buf); err != nil {
		t.Fatal(err)
	}
	var got struct {
		Joined            []map[string]any
		Owned             []map[string]any
		Banned            []map[string]any
		ModerationActions []map[string]any
		RedactedCount     int
	}
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("not one JSON value: %v\n%s", err, buf.String())
	}
	if len(got.Joined) != 3 || len(got.Owned) != 1 || len(got.Banned) != 1 || len(got.ModerationActions) != 3 || got.RedactedCount != 2 {
		t.Errorf("joined %d, owned %d, banned %d, actions %d, redacted %d\n%s", len(got.Joined), len(got.Owned), len(got.Banned), len(got.ModerationActions), got.RedactedCount, buf.String())
	}
	roles := map[string]string{}
	for _, j := range got.Joined {
		roles[j["communityId"].(string)] = j["role"].(string)
	}
	if roles["c1"] != "OWNER" || roles["c2"] != "MODERATOR" || roles["c3"] != "MEMBER" {
		t.Errorf("roles = %v", roles)
	}
	for _, other := range []string{"other-mod", "banned-person", "someone", "boss", "p9"} {
		if strings.Contains(buf.String(), other) {
			t.Errorf("the export names %q (another user or a post id)", other)
		}
	}
	for _, a := range got.ModerationActions {
		for k := range a {
			if k != "communityId" && k != "action" && k != "at" {
				t.Errorf("a moderation action carries %q", k)
			}
		}
	}
	// member docs are read for the joined and banned communities only, once each
	if !slices.Equal(src.gotMem, []string{"c1", "c2", "c3", "c4", "c5"}) || len(src.gotIDs) != 6 {
		t.Errorf("member docs %v, community docs %v", src.gotMem, src.gotIDs)
	}
}

func TestExport_EmptyAndErrors(t *testing.T) {
	var buf bytes.Buffer
	if err := NewExporter(&fakeExportSource{}).ExportUser(context.Background(), "me", &buf); err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(buf.String()); got != `{"joined":[],"owned":[],"banned":[],"moderationActions":[],"redactedCount":0}` {
		t.Errorf("empty export = %s", got)
	}
	// a community whose doc is gone is redacted, not an error
	src := &fakeExportSource{exists: true, ms: Memberships{Joined: []string{"gone"}}, rows: map[string]ExportRow{}}
	e, err := NewExporter(src).BuildExport(context.Background(), "me")
	if err != nil || e.RedactedCount != 1 || len(e.Joined) != 0 {
		t.Errorf("= %+v, %v", e, err)
	}
	if _, err := NewExporter(&fakeExportSource{err: errors.New("down")}).BuildExport(context.Background(), "me"); err == nil {
		t.Error("a source error was swallowed")
	}
}
