//go:build integration

package communities

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// purgeAll runs the eraser to completion with the given chunk size and returns the summed counters and the invocation count.
func (e *env) purgeAll(t *testing.T, uid string, chunk int) (reads, writes, deletes int64, invocations int, cp Checkpoint) {
	t.Helper()
	er := NewEraser(e.repo, e.dir, WithChunk(chunk), WithModlogMax(100))
	for range 20 {
		ctx, c := budget.WithCounter(context.Background())
		asked := e.dir.asked
		next, done, err := er.PurgeUser(ctx, uid, cp)
		if err != nil {
			t.Fatalf("purge: %v", err)
		}
		// the fake directory charges its own reads (identity.Directory is cache-first in production); count the module's reads only
		reads, writes, deletes, invocations, cp = reads+c.Reads()-int64(e.dir.asked-asked), writes+c.Writes(), deletes+c.Deletes(), invocations+1, next
		if done {
			return
		}
	}
	t.Fatal("the eraser never finished")
	return
}

func (e *env) requireNoTrace(t *testing.T, uid string) {
	t.Helper()
	ctx := context.Background()
	if _, ok := e.data(t, "communityMemberships/"+uid); ok {
		t.Error("the memberships doc survived")
	}
	docs, err := e.client.Collection("communities").Documents(ctx).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range docs {
		raw := d.Data()
		if valuesName(raw, uid) {
			t.Errorf("communities/%s still names %s: %v", d.Ref.ID, uid, raw)
		}
		if _, ok := e.data(t, "communities/"+d.Ref.ID+"/communityMembers/"+uid); ok {
			t.Errorf("member doc of %s survived in %s", uid, d.Ref.ID)
		}
	}
	grp, err := e.client.CollectionGroup(membersSubcollection).Where("uid", "==", uid).Limit(1).Documents(ctx).GetAll()
	if err != nil || len(grp) != 0 {
		t.Errorf("a communityMembers doc still holds the uid: %d, %v", len(grp), err)
	}
}

func TestEraser_ReferenceAccountMatchesTheADRBudget(t *testing.T) {
	// ADR-0031 Cost impact: the reference account (2 joined) = 5 reads, 2 writes, 3 deletes.
	e := newEnv(t, 100)
	a, b := "0000000000000000101", "0000000000000000102"
	for _, id := range []string{a, b} {
		e.seedCommunity(t, Community{ID: id, Name: "c" + id[len(id)-1:], OwnerID: "owner", MemberCount: 3}, map[string]MemberState{"member": MemberJoined, "other": MemberJoined})
	}
	e.seedMemberships(t, "member", Memberships{Joined: []string{a, b}})
	reads, writes, deletes, n, cp := e.purgeAll(t, "member", 10)
	if reads != 5 || writes != 2 || deletes != 3 || n != 1 {
		t.Errorf("reference account = %d reads, %d writes, %d deletes in %d invocation(s), want 5, 2, 3 in 1", reads, writes, deletes, n)
	}
	if cp.Communities != 2 {
		t.Errorf("checkpoint = %+v", cp)
	}
	for _, id := range []string{a, b} {
		if c := e.community(t, id); c.MemberCount != 2 {
			t.Errorf("%s memberCount = %d, want 2", id, c.MemberCount)
		}
	}
	e.requireNoTrace(t, "member")
	// a rerun: one read, nothing written
	reads, writes, deletes, n, _ = e.purgeAll(t, "member", 10)
	if reads != 1 || writes != 0 || deletes != 0 || n != 1 {
		t.Errorf("rerun = %d reads, %d writes, %d deletes, want 1, 0, 0", reads, writes, deletes)
	}
}

func TestEraser_OwnerWithModeratorsHandsOverToTheFirstActiveOne(t *testing.T) {
	e := newEnv(t, 100)
	cid := "0000000000000000201"
	e.dir.profiles["mod1"] = profile("mod1", identity.AccountStatusDeleting) // first in appointment order, but leaving
	at := time.Now().UTC()
	e.seedCommunity(t, Community{
		ID: cid, Name: "Kept name", Description: "Kept about", OwnerID: "owner", ModeratorIDs: []string{"mod1", "mod2", "mod3"}, MemberCount: 5,
		Rules: []Rule{{Title: "Kept rule", Text: "kept"}}, ModlogSeq: 2,
		Modlog: []LogEntry{{Seq: 1, At: at, Actor: "owner", Action: ActionMakeModerator, Target: "mod2"}, {Seq: 2, At: at, Actor: "mod3", Action: ActionHide, PostID: "p1"}},
	}, map[string]MemberState{"owner": MemberJoined, "mod1": MemberJoined, "mod2": MemberJoined, "mod3": MemberJoined, "m": MemberJoined})
	e.seedMemberships(t, "owner", Memberships{Joined: []string{cid}, Owned: []string{cid}, Modlogged: []string{cid}})
	e.seedMemberships(t, "mod1", Memberships{Joined: []string{cid}})
	e.seedMemberships(t, "mod2", Memberships{Joined: []string{cid}, Modlogged: []string{cid}})
	e.seedMemberships(t, "mod3", Memberships{Joined: []string{cid}, Modlogged: []string{cid}})

	reads, writes, deletes, _, cp := e.purgeAll(t, "owner", 10)
	// 1 memberships + (community + member doc) + 3 successor checks: mod1 is DELETING (no read), mod2 is chosen (1 read)
	if reads != 1+2+1 || writes != 2 || deletes != 2 || cp.Handovers != 1 || cp.Archived != 0 {
		t.Errorf("handover = %d reads, %d writes, %d deletes, checkpoint %+v, want 4, 2 (community + the new owner's memberships), 2", reads, writes, deletes, cp)
	}
	c := e.community(t, cid)
	if c.OwnerID != "mod2" || !slices.Equal(c.ModeratorIDs, []string{"mod1", "mod3"}) || c.MemberCount != 4 || c.Status != StatusActive ||
		c.Name != "Kept name" || c.Description != "Kept about" || len(c.Rules) != 1 {
		t.Errorf("community = %+v", c)
	}
	last := c.Modlog[len(c.Modlog)-1]
	if last.Action != ActionOwnerHandover || last.Actor != DeletedMarker || last.Target != "mod2" || last.Seq != 3 || c.ModlogSeq != 3 {
		t.Errorf("handover entry = %+v, seq %d", last, c.ModlogSeq)
	}
	if c.Modlog[0].Actor != DeletedMarker || c.Modlog[0].Target != "mod2" || c.Modlog[0].Action != ActionMakeModerator {
		t.Errorf("the earlier entry by the deleted owner = %+v, want the actor scrubbed and the rest kept", c.Modlog[0])
	}
	if ms, _ := e.memberships(t, "mod2"); !slices.Equal(ms.Owned, []string{cid}) || !slices.Equal(ms.Modlogged, []string{cid}) || !slices.Equal(ms.Joined, []string{cid}) {
		t.Errorf("new owner's memberships = %+v (I-M, I-L)", ms)
	}
	e.requireNoTrace(t, "owner")
	if _, ok := e.data(t, "communities/"+cid+"/communityMembers/mod2"); !ok {
		t.Error("the new owner's member doc is gone")
	}
	// a rerun writes nothing
	reads, writes, deletes, _, _ = e.purgeAll(t, "owner", 10)
	if writes != 0 || deletes != 0 || reads != 1 {
		t.Errorf("rerun = %d reads, %d writes, %d deletes", reads, writes, deletes)
	}
}

func TestEraser_OwnerWithoutAnActiveModeratorArchivesAndKeepsTheText(t *testing.T) {
	e := newEnv(t, 100)
	none, onlyGone, susp := "0000000000000000301", "0000000000000000302", "0000000000000000303"
	e.dir.profiles["mod1"] = profile("mod1", identity.AccountStatusDeleting)
	e.seedCommunity(t, Community{ID: none, Name: "Solo", Description: "d", OwnerID: "owner", MemberCount: 1, Rules: []Rule{{Title: "r", Text: "t"}}}, map[string]MemberState{"owner": MemberJoined})
	e.seedCommunity(t, Community{ID: onlyGone, Name: "Leaving", OwnerID: "owner", ModeratorIDs: []string{"mod1", "ghost"}, MemberCount: 3}, map[string]MemberState{"owner": MemberJoined})
	e.seedCommunity(t, Community{ID: susp, Name: "Offline", OwnerID: "owner", MemberCount: 1, Status: StatusSuspended}, map[string]MemberState{"owner": MemberJoined})
	e.seedMemberships(t, "owner", Memberships{Joined: []string{none, onlyGone, susp}, Owned: []string{none, onlyGone, susp}})
	_, _, _, _, cp := e.purgeAll(t, "owner", 1) // one community per invocation: a resume mid-list
	if cp.Archived != 3 || cp.Handovers != 0 || cp.Communities != 3 {
		t.Errorf("checkpoint = %+v", cp)
	}
	c := e.community(t, none)
	if c.Status != StatusArchived || c.OwnerID != "" || c.Name != "Solo" || c.Description != "d" || len(c.Rules) != 1 || c.MemberCount != 0 || len(c.Modlog) != 0 {
		t.Errorf("archived community = %+v, want ARCHIVED, ownerId \"\", the text kept, no log entry", c)
	}
	c = e.community(t, onlyGone)
	if c.Status != StatusArchived || c.OwnerID != "" || !slices.Equal(c.ModeratorIDs, []string{"mod1", "ghost"}) {
		t.Errorf("community whose moderators cannot take over = %+v", c)
	}
	if c = e.community(t, susp); c.Status != StatusSuspended || c.OwnerID != "" {
		t.Errorf("a SUSPENDED community = %+v, want it to stay SUSPENDED with no owner", c)
	}
	e.requireNoTrace(t, "owner")
}

func TestEraser_SuccessorWhoseMembershipsAreGoneIsSkipped(t *testing.T) {
	e := newEnv(t, 100)
	cid := "0000000000000000401"
	e.seedCommunity(t, Community{ID: cid, Name: "x", OwnerID: "owner", ModeratorIDs: []string{"mod1", "mod2"}, MemberCount: 3},
		map[string]MemberState{"owner": MemberJoined, "mod1": MemberJoined, "mod2": MemberJoined})
	e.seedMemberships(t, "owner", Memberships{Joined: []string{cid}, Owned: []string{cid}})
	e.seedMemberships(t, "mod2", Memberships{Joined: []string{cid}}) // mod1's memberships doc was already erased: it is mid-deletion
	e.purgeAll(t, "owner", 10)
	if c := e.community(t, cid); c.OwnerID != "mod2" || !slices.Equal(c.ModeratorIDs, []string{"mod1"}) {
		t.Errorf("community = %+v, want mod2 to take over", c)
	}
	// the skipped moderator's memberships doc was not recreated by the hand-over
	if _, ok := e.data(t, "communityMemberships/mod1"); ok {
		t.Error("a hand-over recreated a deleted account's memberships doc")
	}
}

func TestEraser_FormerModeratorAndBannedMemberLeaveNoTrace(t *testing.T) {
	e := newEnv(t, 100)
	cid := "0000000000000000501"
	at := time.Now().UTC()
	// "gone" hid a post as a moderator, left the community (member doc and moderator role gone, memberships.joined without it, modlogged kept), was
	// the target of a ban and an unban earlier, and now deletes the account
	e.seedCommunity(t, Community{ID: cid, Name: "x", OwnerID: "owner", MemberCount: 2, ModlogSeq: 4, Modlog: []LogEntry{
		{Seq: 1, At: at, Actor: "owner", Action: ActionBan, Target: "gone"},
		{Seq: 2, At: at, Actor: "owner", Action: ActionUnban, Target: "gone"},
		{Seq: 3, At: at, Actor: "gone", Action: ActionHide, PostID: "p9"},
		{Seq: 4, At: at, Actor: "gone", Action: ActionModeratorLeft},
	}}, map[string]MemberState{"owner": MemberJoined, "other": MemberJoined})
	e.seedMemberships(t, "gone", Memberships{Modlogged: []string{cid}})
	reads, writes, deletes, _, _ := e.purgeAll(t, "gone", 10)
	if reads != 3 || writes != 1 || deletes != 1 {
		t.Errorf("former moderator = %d reads, %d writes, %d deletes, want 3 (memberships, community, member doc), 1, 1 (the memberships doc)", reads, writes, deletes)
	}
	c := e.community(t, cid)
	if c.MemberCount != 2 || len(c.Modlog) != 4 || c.Modlog[0].Target != DeletedMarker || c.Modlog[0].Actor != "owner" || c.Modlog[2].Actor != DeletedMarker || c.Modlog[3].Actor != DeletedMarker ||
		c.Modlog[2].Action != ActionHide || c.Modlog[2].PostID != "p9" {
		t.Errorf("modlog = %+v, want every mention of the uid replaced and the actions kept", c.Modlog)
	}
	e.requireNoTrace(t, "gone")

	// a banned member: the member doc goes, memberCount does not move, banned lists the community
	cid2 := "0000000000000000502"
	e.seedCommunity(t, Community{ID: cid2, Name: "y", OwnerID: "owner", MemberCount: 2, ModlogSeq: 1,
		Modlog: []LogEntry{{Seq: 1, At: at, Actor: "owner", Action: ActionBan, Target: "raider"}}}, map[string]MemberState{"owner": MemberJoined, "other": MemberJoined, "raider": MemberBanned})
	e.seedMemberships(t, "raider", Memberships{Banned: []string{cid2}, Modlogged: []string{cid2}})
	e.purgeAll(t, "raider", 10)
	if c = e.community(t, cid2); c.MemberCount != 2 || c.Modlog[0].Target != DeletedMarker {
		t.Errorf("banned member's community = %+v", c)
	}
	e.requireNoTrace(t, "raider")
}

func TestEraser_MemberWhoseCommunityIsGoneOnlyLosesTheMemberDoc(t *testing.T) {
	e := newEnv(t, 100)
	cid := "0000000000000000601"
	// an orphan member doc under a community document that does not exist
	if _, err := e.repo.memberRef(cid, "u").Set(context.Background(), memberDoc{UID: "u", State: "JOINED"}); err != nil {
		t.Fatal(err)
	}
	e.seedMemberships(t, "u", Memberships{Joined: []string{cid}})
	_, writes, deletes, _, _ := e.purgeAll(t, "u", 10)
	if writes != 0 || deletes != 2 {
		t.Errorf("= %d writes, %d deletes, want 0 and 2", writes, deletes)
	}
	e.requireNoTrace(t, "u")
}

func TestEraser_HandoverTrimsTheLogToItsCap(t *testing.T) {
	e := newEnv(t, 3)
	cid := "0000000000000000701"
	at := time.Now().UTC()
	e.seedCommunity(t, Community{ID: cid, Name: "x", OwnerID: "owner", ModeratorIDs: []string{"mod1"}, MemberCount: 2, ModlogSeq: 3, Modlog: []LogEntry{
		{Seq: 1, At: at, Actor: "mod1", Action: ActionHide}, {Seq: 2, At: at, Actor: "mod1", Action: ActionHide}, {Seq: 3, At: at, Actor: "mod1", Action: ActionHide},
	}}, map[string]MemberState{"owner": MemberJoined, "mod1": MemberJoined})
	e.seedMemberships(t, "owner", Memberships{Joined: []string{cid}, Owned: []string{cid}})
	e.seedMemberships(t, "mod1", Memberships{Joined: []string{cid}})
	er := NewEraser(e.repo, e.dir, WithModlogMax(3))
	if _, done, err := er.PurgeUser(context.Background(), "owner", Checkpoint{}); err != nil || !done {
		t.Fatalf("done=%v err=%v", done, err)
	}
	c := e.community(t, cid)
	if len(c.Modlog) != 3 || c.Modlog[0].Seq != 2 || c.Modlog[2].Action != ActionOwnerHandover || c.ModlogSeq != 4 {
		t.Errorf("modlog = %+v seq %d, want the newest 3 ending with the handover", c.Modlog, c.ModlogSeq)
	}
}

// ---- export ----

func TestExport_ReferenceAccountReadsAndShape(t *testing.T) {
	e := newEnv(t, 100)
	a, b := "0000000000000000801", "0000000000000000802"
	for _, id := range []string{a, b} {
		e.seedCommunity(t, Community{ID: id, Name: "c" + id[len(id)-1:], OwnerID: "owner", MemberCount: 2}, map[string]MemberState{"member": MemberJoined})
	}
	e.seedMemberships(t, "member", Memberships{Joined: []string{a, b}})
	var buf bytes.Buffer
	c := measured(t, "export", budgettest.Budget{Reads: 1 + 2 + 2}, func(ctx context.Context) {
		if err := NewExporter(e.repo).ExportUser(ctx, "member", &buf); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 5 || c.Writes() != 0 {
		t.Errorf("reference export = %d reads, %d writes, want 5, 0", c.Reads(), c.Writes())
	}
	var got Export
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Joined) != 2 || got.Joined[0].Role != "MEMBER" || got.Joined[0].JoinedAt == nil || got.RedactedCount != 0 || len(got.Owned) != 0 {
		t.Errorf("export = %+v", got)
	}
	if strings.Contains(buf.String(), "owner") {
		t.Errorf("another user's uid is in the export: %s", buf.String())
	}
	// an account without memberships: one read, an empty section
	buf.Reset()
	c = measured(t, "empty export", budgettest.Budget{Reads: 1}, func(ctx context.Context) {
		if err := NewExporter(e.repo).ExportUser(ctx, "nobody", &buf); err != nil {
			t.Fatal(err)
		}
	})
	if c.Reads() != 1 || strings.TrimSpace(buf.String()) != `{"joined":[],"owned":[],"banned":[],"moderationActions":[],"redactedCount":0}` {
		t.Errorf("empty export = %d reads: %s", c.Reads(), buf.String())
	}
}

func TestExport_OwnerBannedSuspendedAndAnyNumberOfCommunities(t *testing.T) {
	e := newEnv(t, 100)
	at := time.Now().UTC()
	mine, banned, susp := "0000000000000000811", "0000000000000000812", "0000000000000000813"
	e.seedCommunity(t, Community{ID: mine, Name: "Mine", Description: "About", OwnerID: "me", ModeratorIDs: []string{"mod1"}, MemberCount: 2,
		Rules: []Rule{{Title: "Rule", Text: "Text"}}, ModlogSeq: 2,
		Modlog: []LogEntry{{Seq: 1, At: at, Actor: "me", Action: ActionEdit}, {Seq: 2, At: at, Actor: "mod1", Action: ActionBan, Target: "troll"}}},
		map[string]MemberState{"me": MemberJoined, "mod1": MemberJoined})
	e.seedCommunity(t, Community{ID: banned, Name: "Banned from", OwnerID: "boss"}, map[string]MemberState{"me": MemberBanned})
	e.seedCommunity(t, Community{ID: susp, Name: "Offline", OwnerID: "boss", Status: StatusSuspended, ModlogSeq: 1,
		Modlog: []LogEntry{{Seq: 1, At: at, Actor: "me", Action: ActionHide}}}, map[string]MemberState{"me": MemberJoined})
	e.seedMemberships(t, "me", Memberships{Joined: []string{mine, susp}, Owned: []string{mine}, Banned: []string{banned}, Modlogged: []string{mine, susp}})
	x, err := NewExporter(e.repo).BuildExport(context.Background(), "me")
	if err != nil {
		t.Fatal(err)
	}
	if len(x.Joined) != 1 || x.Joined[0].Role != "OWNER" || len(x.Owned) != 1 || x.Owned[0].Description != "About" || x.Owned[0].Rules[0].Title != "Rule" ||
		len(x.Banned) != 1 || x.Banned[0].BannedAt == nil || len(x.ModerationActions) != 1 || x.ModerationActions[0].Action != "EDIT" || x.RedactedCount != 1 {
		t.Errorf("export = %+v", x)
	}
	// more than one GetAll batch
	many := make([]string, 120)
	for i := range many {
		many[i] = fmt.Sprintf("%019d", 5000+i)
		e.seedCommunity(t, Community{ID: many[i], Name: "m", OwnerID: "boss"}, map[string]MemberState{"big": MemberJoined})
	}
	e.seedMemberships(t, "big", Memberships{Joined: many})
	x, err = NewExporter(e.repo).BuildExport(context.Background(), "big")
	if err != nil || len(x.Joined) != 120 || x.RedactedCount != 0 {
		t.Errorf("120 communities: %d joined, redacted %d, %v", len(x.Joined), x.RedactedCount, err)
	}
}

// valuesName reports whether uid appears in any value (not a field name) of v.
func valuesName(v any, uid string) bool {
	switch v := v.(type) {
	case string:
		return strings.Contains(v, uid)
	case []any:
		return slices.ContainsFunc(v, func(x any) bool { return valuesName(x, uid) })
	case map[string]any:
		for _, x := range v {
			if valuesName(x, uid) {
				return true
			}
		}
	}
	return false
}
