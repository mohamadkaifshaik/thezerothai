//go:build integration

package apiserver

// W5-5 / ADR-0030 D8: the `lists` erase step through the production jobs handler and the T16 crash-resume harness
// (account_lifecycle_crash_integration_test.go). The deleted account owns 2 lists and is a member of 3 lists owned by a
// friend (one of which also names the friend's other members). The instance is killed after each side effect of the step; the
// redelivery chain must reach the same end state as a clean run: the 2 own lists gone, the 3 other lists no longer naming the
// uid but keeping everyone else, the unrelated list untouched, nothing mentioning the uid left (the residue sweep), and the
// order users/{uid} last.

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"
)

type seededLists struct {
	own, member []string
	unrelated   string
}

func (e *lifecycleEnv) seedList(t *testing.T, id, owner string, members []string) {
	t.Helper()
	e.seedListWith(t, id, owner, members, true, false)
}

// seedListWith seeds a list with the given privacy and moderator-hidden flags.
func (e *lifecycleEnv) seedListWith(t *testing.T, id, owner string, members []string, private, hidden bool) {
	t.Helper()
	now := time.Now().UTC()
	doc := map[string]any{
		"ownerId": owner, "name": "list " + id[len(id)-3:], "description": "", "isPrivate": private,
		"memberIds": members, "createdAt": now, "updatedAt": now,
	}
	if hidden {
		doc["hidden"] = true
	}
	if _, err := e.fs.Collection("lists").Doc(id).Set(context.Background(), doc); err != nil {
		t.Fatal(err)
	}
}

func (e *lifecycleEnv) seedListsFor(t *testing.T, doomed, friend string) seededLists {
	t.Helper()
	var s seededLists
	for i := range 2 {
		id := fmt.Sprintf("%019d", 9_100_000+i)
		e.seedList(t, id, doomed, []string{friend, doomed})
		s.own = append(s.own, id)
	}
	for i := range 3 {
		id := fmt.Sprintf("%019d", 9_200_000+i)
		members := []string{friend, doomed, "someone-else"}
		e.seedList(t, id, friend, members)
		s.member = append(s.member, id)
	}
	s.unrelated = fmt.Sprintf("%019d", 9_300_000)
	e.seedList(t, s.unrelated, friend, []string{"someone-else"})
	return s
}

func (e *lifecycleEnv) requireListsErased(t *testing.T, uid, friend string, s seededLists) {
	t.Helper()
	ctx := context.Background()
	for _, id := range s.own {
		if fsDocExists(t, e.fs, "lists/"+id) {
			t.Errorf("own list %s survived", id)
		}
	}
	for _, id := range s.member {
		snap, err := e.fs.Collection("lists").Doc(id).Get(ctx)
		if err != nil {
			t.Fatalf("another owner's list %s: %v", id, err)
		}
		got, _ := snap.DataAt("memberIds")
		members := toStrings(got)
		slices.Sort(members)
		want := []string{friend, "someone-else"}
		slices.Sort(want)
		if !slices.Equal(members, want) {
			t.Errorf("list %s members = %v, want [%s someone-else] (the deleted uid removed, the rest kept)", id, members, friend)
		}
		if o, _ := snap.DataAt("ownerId"); o != friend {
			t.Errorf("list %s owner = %v", id, o)
		}
	}
	snap, err := e.fs.Collection("lists").Doc(s.unrelated).Get(ctx)
	if err != nil {
		t.Fatalf("unrelated list: %v", err)
	}
	if got, _ := snap.DataAt("memberIds"); fmt.Sprint(got) != "[someone-else]" {
		t.Errorf("unrelated list members = %v", got)
	}
	if docs, err := e.fs.Collection("lists").Where("memberIds", "array-contains", uid).Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("a list still names the deleted uid: %d docs, err %v", len(docs), err)
	}
	if docs, err := e.fs.Collection("lists").Where("ownerId", "==", uid).Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("a list is still owned by the deleted uid: %d docs, err %v", len(docs), err)
	}
	for _, path := range []string{"users/" + uid, "quotas/" + uid} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	e.requireNoResidue(t, uid)
}

func toStrings(v any) []string {
	raw, _ := v.([]any)
	out := make([]string, 0, len(raw))
	for _, x := range raw {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func TestAccountLifecycle_ListsEraserIsCrashSafe(t *testing.T) {
	e := newLifecycleEnvCfg(t, nil, relaxLimits)

	run := func(t *testing.T, plan *crashPlan, key string) (deaths int) {
		t.Helper()
		u := e.newUser(t)
		friend := e.newUser(t)
		s := e.seedListsFor(t, u.uid, friend.uid)
		cc := e.newCrashChain(t, plan)
		msg := e.beginDeletion(t, richAccount{a: u}, key)
		e.pastGate(t, u.uid)
		deaths, _ = cc.pump(t, msg)
		e.requireListsErased(t, u.uid, friend.uid, s)
		return deaths
	}

	clean := &crashPlan{}
	if d := run(t, clean, "lists-clean-delete-0001"); d != 0 {
		t.Fatalf("clean run had %d deaths", d)
	}
	var stepOps []int
	for i, op := range clean.ops {
		if op == "step.lists" {
			stepOps = append(stepOps, i)
		}
	}
	if len(stepOps) != 2 {
		t.Fatalf("the lists step takes exactly 2 invocations (own lists, then membership); the clean run had %d: %v", len(stepOps), clean.ops)
	}
	// Kill the instance after every side effect from just before the first lists invocation to just after the last.
	from, to := stepOps[0], min(stepOps[1]+2, len(clean.ops)-1)
	for k := from; k <= to; k++ {
		t.Run(fmt.Sprintf("death after side effect %02d (%s)", k+1, clean.ops[k]), func(t *testing.T) {
			plan := &crashPlan{at: k + 1}
			if d := run(t, plan, fmt.Sprintf("lists-crash-delete-%04d", k)); d != 1 {
				t.Fatalf("deaths = %d, want exactly 1 (ran %d side effects, clean run %d)\n got  %v\n want %v", d, plan.n, clean.n, plan.ops, clean.ops)
			}
			if slices.Index(plan.ops, "repo.DeleteUserDoc") != len(plan.ops)-1 || lastIndex(plan.ops, "step.lists") > slices.Index(plan.ops, "auth.DeleteUser") {
				t.Errorf("order: the lists step must finish before the Auth user and users/{uid} go, and nothing may follow users/{uid}: %v", plan.ops)
			}
		})
	}
}
