//go:build integration

package apiserver

// W2-13 / ADR-0023 D6: the `bookmarks` erase step on an account AT THE CAP (1,000 documents), through the production jobs
// handler and the T16 crash-resume harness (account_lifecycle_crash_integration_test.go). With the 1 ns work budget each
// delivery runs one step call, so the step takes exactly three invocations (500 + 500 + the empty page with the
// userLikes field clear). The instance is killed after each side effect of the step and the redelivery chain must reach
// the same end state as a clean run: every document gone, userLikes gone and not recreated by the clear, the user doc last.

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

// seedCapBookmarks writes n bookmark docs (distinct createdAt) and the matching userLikes set, with a like that must
// not matter.
func (e *lifecycleEnv) seedCapBookmarks(t *testing.T, uid string, n int) {
	t.Helper()
	ctx := context.Background()
	bw := e.fs.BulkWriter(ctx)
	ids := make([]string, n)
	base := time.Now().UTC().Add(-48 * time.Hour)
	var jobs []*firestore.BulkWriterJob
	for i := range ids {
		ids[i] = fmt.Sprintf("%019d", 8_000_000+i)
		j, err := bw.Create(e.fs.Doc("users/"+uid+"/bookmarks/"+ids[i]), map[string]any{"createdAt": base.Add(time.Duration(i) * time.Second)})
		if err != nil {
			t.Fatal(err)
		}
		jobs = append(jobs, j)
	}
	bw.End()
	for _, j := range jobs {
		if _, err := j.Results(); err != nil {
			t.Fatalf("seed bookmark: %v", err)
		}
	}
	if _, err := e.fs.Doc("userLikes/"+uid).Set(ctx, map[string]any{"bookmarks": ids, "recent": []string{"9"}}); err != nil {
		t.Fatal(err)
	}
}

func (e *lifecycleEnv) requireCapAccountErased(t *testing.T, uid string) {
	t.Helper()
	ctx := context.Background()
	if docs, err := e.fs.Doc("users/" + uid).Collection("bookmarks").Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("users/{uid}/bookmarks survived: %d docs, err %v", len(docs), err)
	}
	for _, path := range []string{"userLikes/" + uid, "users/" + uid, "quotas/" + uid} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived (or was recreated by the bookmarks step)", path)
		}
	}
	e.requireNoResidue(t, uid)
}

func TestAccountLifecycle_BookmarkEraserAtTheCapIsCrashSafe(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds 1,000 bookmark docs per crash point")
	}
	e := newLifecycleEnvCfg(t, nil, relaxLimits)
	const capSize = 1000

	run := func(t *testing.T, plan *crashPlan, key string) (deaths int) {
		t.Helper()
		u := e.newUser(t)
		e.seedCapBookmarks(t, u.uid, capSize)
		cc := e.newCrashChain(t, plan)
		msg := e.beginDeletion(t, richAccount{a: u}, key)
		e.pastGate(t, u.uid)
		deaths, _ = cc.pump(t, msg)
		e.requireCapAccountErased(t, u.uid)
		return deaths
	}

	clean := &crashPlan{}
	if d := run(t, clean, "cap-clean-delete-0001"); d != 0 {
		t.Fatalf("clean run had %d deaths", d)
	}
	var stepOps []int
	for i, op := range clean.ops {
		if op == "step.bookmarks" {
			stepOps = append(stepOps, i)
		}
	}
	if len(stepOps) != 3 {
		t.Fatalf("an account at the cap must take exactly 3 bookmarks invocations (500 + 500 + the empty page); the clean run had %d: %v", len(stepOps), clean.ops)
	}
	t.Logf("clean run: %d side effects, bookmarks step at positions %v (1-based)", clean.n, []int{stepOps[0] + 1, stepOps[1] + 1, stepOps[2] + 1})

	// Kill the instance right after each side effect from just before the first bookmarks invocation to just after the
	// last (the step's own commit, the checkpoint save, the continuation publish): every crash point of the step.
	from, to := stepOps[0], min(stepOps[2]+2, len(clean.ops)-1)
	for k := from; k <= to; k++ {
		t.Run(fmt.Sprintf("death after side effect %02d (%s)", k+1, clean.ops[k]), func(t *testing.T) {
			plan := &crashPlan{at: k + 1}
			if d := run(t, plan, fmt.Sprintf("cap-crash-delete-%04d", k)); d != 1 {
				t.Fatalf("deaths = %d, want exactly 1 (ran %d side effects, clean run %d)\n got  %v\n want %v", d, plan.n, clean.n, plan.ops, clean.ops)
			}
			lastStep := slices.Index(plan.ops, "repo.DeleteUserDoc")
			if lastStep != len(plan.ops)-1 || lastIndex(plan.ops, "step.bookmarks") > slices.Index(plan.ops, "auth.DeleteUser") {
				t.Errorf("order: the bookmarks step must finish before the Auth user and users/{uid} go, and nothing may follow users/{uid}: %v", plan.ops)
			}
		})
	}
}

func lastIndex(ops []string, op string) int {
	for i := len(ops) - 1; i >= 0; i-- {
		if ops[i] == op {
			return i
		}
	}
	return -1
}
