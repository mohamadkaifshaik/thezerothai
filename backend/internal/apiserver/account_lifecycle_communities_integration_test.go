//go:build integration

package apiserver

// / The `communities` erase step through the production jobs handler and the crash-resume harness
// (account_lifecycle_crash_integration_test.go), with one community per invocation so the instance is killed between communities.
// The deleted account owns a community with one moderator (the moderator must become its owner), is a member of a second community
// and banned from a third, and the unrelated fourth community must stay as it was. The redelivery chain must reach the same end state as a
// clean run: no document names the uid (the residue sweep), the counts are right, and the order users/{uid} last.

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"
)

type seededCommunities struct {
	owned, member, banned, unrelated string
}

func (e *lifecycleEnv) seedCommunityDoc(t *testing.T, id, owner string, mods []string, count int64, log []map[string]any, members map[string]string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC()
	if log == nil {
		log = []map[string]any{}
	}
	doc := map[string]any{
		"name": "community " + id[len(id)-3:], "description": "about", "rules": []any{map[string]any{"title": "Be kind", "text": "always"}},
		"ownerId": owner, "moderatorIds": append([]string{}, mods...), "memberCount": count, "status": "ACTIVE", "visibility": "PUBLIC",
		"recentRemovals": []any{}, "modlog": log, "modlogSeq": int64(len(log)), "createdAt": now, "updatedAt": now,
	}
	if _, err := e.fs.Collection("communities").Doc(id).Set(ctx, doc); err != nil {
		t.Fatal(err)
	}
	for uid, state := range members {
		md := map[string]any{"uid": uid, "state": state}
		if state == "JOINED" {
			md["joinedAt"] = now
		} else {
			md["bannedAt"] = now
		}
		if _, err := e.fs.Collection("communities").Doc(id).Collection("communityMembers").Doc(uid).Set(ctx, md); err != nil {
			t.Fatal(err)
		}
	}
}

func (e *lifecycleEnv) seedMembershipsDoc(t *testing.T, uid string, joined, owned, banned, modlogged []string) {
	t.Helper()
	doc := map[string]any{"joined": nz(joined), "owned": nz(owned), "banned": nz(banned), "modlogged": nz(modlogged), "updatedAt": time.Now().UTC()}
	if _, err := e.fs.Collection("communityMemberships").Doc(uid).Set(context.Background(), doc); err != nil {
		t.Fatal(err)
	}
}

func nz(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func (e *lifecycleEnv) seedCommunitiesFor(t *testing.T, doomed, friend string) seededCommunities {
	t.Helper()
	at := time.Now().UTC()
	s := seededCommunities{
		owned: fmt.Sprintf("%019d", 9_400_001), member: fmt.Sprintf("%019d", 9_400_002),
		banned: fmt.Sprintf("%019d", 9_400_003), unrelated: fmt.Sprintf("%019d", 9_400_004),
	}
	// owned by the doomed account; the friend is its only moderator; the doomed account appointed them and hid a post
	e.seedCommunityDoc(t, s.owned, doomed, []string{friend}, 3, []map[string]any{
		{"seq": int64(1), "at": at, "actor": doomed, "action": "MAKE_MODERATOR", "target": friend},
		{"seq": int64(2), "at": at, "actor": friend, "action": "HIDE", "postId": "0000000000000000999"},
	}, map[string]string{doomed: "JOINED", friend: "JOINED", "someone-else": "JOINED"})
	e.seedCommunityDoc(t, s.member, friend, nil, 3, []map[string]any{{"seq": int64(1), "at": at, "actor": friend, "action": "BAN", "target": "troll"}},
		map[string]string{friend: "JOINED", doomed: "JOINED", "someone-else": "JOINED"})
	e.seedCommunityDoc(t, s.banned, friend, nil, 2, []map[string]any{{"seq": int64(1), "at": at, "actor": friend, "action": "BAN", "target": doomed}},
		map[string]string{friend: "JOINED", "someone-else": "JOINED", doomed: "BANNED"})
	e.seedCommunityDoc(t, s.unrelated, friend, nil, 2, nil, map[string]string{friend: "JOINED", "someone-else": "JOINED"})
	e.seedMembershipsDoc(t, doomed, []string{s.owned, s.member}, []string{s.owned}, []string{s.banned}, []string{s.owned, s.banned})
	e.seedMembershipsDoc(t, friend, []string{s.owned, s.member, s.banned, s.unrelated}, []string{s.member, s.banned, s.unrelated}, nil, []string{s.owned, s.member, s.banned})
	return s
}

func (e *lifecycleEnv) requireCommunitiesErased(t *testing.T, uid, friend string, s seededCommunities) {
	t.Helper()
	ctx := context.Background()
	data := func(path string) map[string]any {
		snap, err := e.fs.Doc(path).Get(ctx)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		return snap.Data()
	}
	// the owned community went to the moderator, with the counts right and the text kept
	c := data("communities/" + s.owned)
	if c["ownerId"] != friend || len(toStrings(c["moderatorIds"])) != 0 || c["memberCount"].(int64) != 2 || c["status"] != "ACTIVE" || c["name"] != "community "+s.owned[len(s.owned)-3:] {
		t.Errorf("owned community = %v, want the moderator as owner, no moderators, memberCount 2", c)
	}
	log, _ := c["modlog"].([]any)
	if len(log) != 3 {
		t.Fatalf("modlog = %v, want the 2 earlier entries and the handover", log)
	}
	if first := log[0].(map[string]any); first["actor"] != "_deleted" || first["target"] != friend {
		t.Errorf("the entry the deleted owner wrote = %v, want the actor replaced", first)
	}
	if last := log[2].(map[string]any); last["action"] != "OWNER_HANDOVER" || last["actor"] != "_deleted" || last["target"] != friend {
		t.Errorf("handover entry = %v", last)
	}
	fm := data("communityMemberships/" + friend)
	if !slices.Contains(toStrings(fm["owned"]), s.owned) || !slices.Contains(toStrings(fm["modlogged"]), s.owned) || !slices.Contains(toStrings(fm["joined"]), s.owned) {
		t.Errorf("the new owner's memberships = %v (I-M, I-L)", fm)
	}
	// the member community lost one member; the banned one did not (a ban never counted) but its log no longer names the uid
	if m := data("communities/" + s.member); m["memberCount"].(int64) != 2 || m["ownerId"] != friend {
		t.Errorf("member community = %v", m)
	}
	if b := data("communities/" + s.banned); b["memberCount"].(int64) != 2 {
		t.Errorf("banned community = %v, want memberCount unchanged", b)
	} else if entry := b["modlog"].([]any)[0].(map[string]any); entry["target"] != "_deleted" || entry["actor"] != friend {
		t.Errorf("banned community log entry = %v", entry)
	}
	if u := data("communities/" + s.unrelated); u["memberCount"].(int64) != 2 || len(u["modlog"].([]any)) != 0 {
		t.Errorf("unrelated community changed: %v", u)
	}
	for _, id := range []string{s.owned, s.member, s.banned} {
		if fsDocExists(t, e.fs, "communities/"+id+"/communityMembers/"+uid) {
			t.Errorf("member doc of the deleted uid survived in %s", id)
		}
	}
	for _, path := range []string{"communityMemberships/" + uid, "users/" + uid, "quotas/" + uid} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	e.requireNoResidue(t, uid)
}

func TestAccountLifecycle_CommunitiesEraserIsCrashSafe(t *testing.T) {
	e := newLifecycleEnvCfg(t, nil, relaxLimits)

	run := func(t *testing.T, plan *crashPlan, key string) (deaths int) {
		t.Helper()
		u := e.newUser(t)
		friend := e.newUser(t)
		s := e.seedCommunitiesFor(t, u.uid, friend.uid)
		cc := e.newCrashChain(t, plan)
		msg := e.beginDeletion(t, richAccount{a: u}, key)
		e.pastGate(t, u.uid)
		deaths, _ = cc.pump(t, msg)
		e.requireCommunitiesErased(t, u.uid, friend.uid, s)
		return deaths
	}

	clean := &crashPlan{}
	if d := run(t, clean, "communities-clean-delete-0001"); d != 0 {
		t.Fatalf("clean run had %d deaths", d)
	}
	var stepOps []int
	for i, op := range clean.ops {
		if op == "step.communities" {
			stepOps = append(stepOps, i)
		}
	}
	if len(stepOps) != 3 {
		t.Fatalf("the communities step takes one invocation per community with the chunk at 1 (3 communities in the union); the clean run had %d: %v", len(stepOps), clean.ops)
	}
	// Kill the instance after every side effect from just before the first communities invocation to just after the last.
	from, to := stepOps[0], min(stepOps[len(stepOps)-1]+2, len(clean.ops)-1)
	for k := from; k <= to; k++ {
		t.Run(fmt.Sprintf("death after side effect %02d (%s)", k+1, clean.ops[k]), func(t *testing.T) {
			plan := &crashPlan{at: k + 1}
			if d := run(t, plan, fmt.Sprintf("communities-crash-delete-%04d", k)); d != 1 {
				t.Fatalf("deaths = %d, want exactly 1 (ran %d side effects, clean run %d)\n got  %v\n want %v", d, plan.n, clean.n, plan.ops, clean.ops)
			}
			if slices.Index(plan.ops, "repo.DeleteUserDoc") != len(plan.ops)-1 || lastIndex(plan.ops, "step.communities") > slices.Index(plan.ops, "auth.DeleteUser") {
				t.Errorf("order: the communities step must finish before the Auth user and users/{uid} go, and nothing may follow users/{uid}: %v", plan.ops)
			}
		})
	}
}

// A former moderator: hid a post, left the community, then deleted the account. Its memberships doc names the community only under
// modlogged; the community's log must stop naming the uid, and the member count must not move.
func TestAccountLifecycle_FormerModeratorLeavesNoTrace(t *testing.T) {
	e := newLifecycleEnvCfg(t, nil, relaxLimits)
	u := e.newUser(t)
	owner := e.newUser(t)
	cid := fmt.Sprintf("%019d", 9_500_001)
	at := time.Now().UTC()
	e.seedCommunityDoc(t, cid, owner.uid, nil, 2, []map[string]any{
		{"seq": int64(1), "at": at, "actor": u.uid, "action": "HIDE", "postId": "0000000000000000998"},
		{"seq": int64(2), "at": at, "actor": u.uid, "action": "MODERATOR_LEFT"},
	}, map[string]string{owner.uid: "JOINED", "someone-else": "JOINED"})
	e.seedMembershipsDoc(t, u.uid, nil, nil, nil, []string{cid})
	cc := e.newCrashChain(t, &crashPlan{})
	msg := e.beginDeletion(t, richAccount{a: u}, "communities-former-mod-0001")
	e.pastGate(t, u.uid)
	cc.pump(t, msg)
	snap, err := e.fs.Collection("communities").Doc(cid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	log := snap.Data()["modlog"].([]any)
	if len(log) != 2 || log[0].(map[string]any)["actor"] != "_deleted" || log[0].(map[string]any)["action"] != "HIDE" || log[1].(map[string]any)["actor"] != "_deleted" {
		t.Errorf("modlog = %v, want both entries kept with the actor replaced", log)
	}
	if got := snap.Data()["memberCount"].(int64); got != 2 {
		t.Errorf("memberCount = %d, want 2 (the former moderator was not a member)", got)
	}
	e.requireNoResidue(t, u.uid)
}
