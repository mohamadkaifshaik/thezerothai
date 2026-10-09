//go:build integration

package apiserver

// T16/T17 budget assertions on the plan's REFERENCE ACCOUNT (docs/plans/account-deletion-export.md "Cost": P = 300
// posts, O = 100 followees, I = 100 followers, B = Bb = M = 0, E = 1 export), seeded through the production RPCs, then
// exported and deleted over the real chain. The measured fs_reads/fs_writes/fs_deletes come from the same
// `account_job` and request log lines production emits, so a budget regression here is a regression in the lines the
// cost report reads. The numbers are logged as `BUDGET ...` for the test report.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

const (
	refPosts, refFollowing, refFollowers = 300, 100, 100
	// ADR-0011 budget table, reference row, as constants of the formula.
	refDeleteReadsBase = refPosts + refFollowing + refFollowers + 2 /* 2*ceil((max(B,Bb)+1)/500) */ + 2 + 3 + 2 /* identity */ + 1 /* max(E,1) */
	refDeleteWrites    = refFollowing + 2*refFollowers
	refDeleteDeletes   = refPosts + refFollowing + refFollowers + 1 + 3 + 1
	// Plan T16 acceptance criterion: <= 509 R + job state, <= 300 W + checkpoints, <= 505 D.
	planDeleteReads = 509
	// Export job: 1 users + 1 exports + P + O + I + 1 graph + distinct handles (O + I) = 703 (+ the lease claim and
	// status writes of the L-4 amendment).
	refExportReads  = 1 + 1 + refPosts + refFollowing + refFollowers + 1 + refFollowing + refFollowers
	refExportWrites = 2
)

func TestAccountLifecycle_ReferenceAccountBudgets(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds ~1,000 RPCs")
	}
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, relaxLimits)
	a := e.newUser(t)
	cohort := []string{a.uid}
	for range refFollowing {
		f := e.newUser(t)
		cohort = append(cohort, f.uid)
		e.follow(t, a, f)
	}
	for range refFollowers {
		g := e.newUser(t)
		cohort = append(cohort, g.uid)
		e.follow(t, g, a)
	}
	for i := range refPosts {
		if _, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: fmt.Sprintf("reference-post-%s-%04d", a.uid[:12], i), Text: fmt.Sprintf("reference post %d", i)})); err != nil {
			t.Fatalf("CreatePost %d: %v", i, err)
		}
	}
	e.requireInvariants(t, cohort) // the seed itself is consistent before anything is deleted

	// --- export of the reference account (T17 budget) ---
	exp, err := e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "reference-export-key-0001"}))
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range e.pull(t) {
		if m["kind"] == "account_export" {
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("export delivery = %d", code)
			}
		}
	}
	var export map[string]any
	for _, l := range e.jobLines() {
		if l["account_job"] == "export" && l["outcome"] == "done" {
			export = l
		}
	}
	if export == nil {
		t.Fatalf("no export `done` line: %v", e.jobLines())
	}
	t.Logf("BUDGET account-export job (P=300 O=100 I=100) reads=%v writes=%v bytes=%v sections=%v (budget: reads <= %d, writes <= %d)",
		export["fs_reads"], export["fs_writes"], export["bytes"], export["sections"], refExportReads, refExportWrites)
	if r := export["fs_reads"].(float64); r > refExportReads || export["fs_writes"].(float64) > refExportWrites || export["fs_deletes"].(float64) != 0 {
		t.Errorf("export job cost = %v, over the reference budget (reads %d, writes %d, deletes 0)", export, refExportReads, refExportWrites)
	}
	if _, err := e.identity.GetAccountExport(ctx, authed(a.token, &identityv1.GetAccountExportRequest{ExportId: exp.Msg.GetExportId()})); err != nil {
		// A signed URL cannot be minted against the emulators; only the cost of the poll matters here.
		t.Logf("GetAccountExport on the emulator: %v", err)
	}
	t.Logf("BUDGET GetAccountExport reads=%v writes=%v (budget: reads <= 2 cold, 0 writes)", e.lineNum(t, "/dzeroth.identity.v1.IdentityService/GetAccountExport", -1, "fs_reads"), e.lineNum(t, "/dzeroth.identity.v1.IdentityService/GetAccountExport", -1, "fs_writes"))
	if w := e.lineNum(t, "/dzeroth.identity.v1.IdentityService/GetAccountExport", -1, "fs_writes"); w != 0 {
		t.Errorf("GetAccountExport wrote %v docs", w)
	}

	// --- deletion ---
	if _, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "reference-delete-key-0001"})); err != nil {
		t.Fatal(err)
	}
	const rpc = "/dzeroth.identity.v1.IdentityService/DeleteAccount"
	t.Logf("BUDGET DeleteAccount (sync) reads=%v writes=%v (budget: reads <= 2, writes 1)", e.lineNum(t, rpc, -1, "fs_reads"), e.lineNum(t, rpc, -1, "fs_writes"))
	if e.lineNum(t, rpc, -1, "fs_reads") > 2 || e.lineNum(t, rpc, -1, "fs_writes") != 1 {
		t.Errorf("DeleteAccount cost over budget")
	}
	e.pastGate(t, a.uid)
	deliveries := 0
	for _, m := range e.pull(t) {
		if m["kind"] != "account_delete" {
			continue
		}
		for pending := []map[string]any{m}; len(pending) > 0 && deliveries < 50; {
			deliveries++
			code := e.deliver(t, pending[0])
			pending = append(pending, e.pull(t)...)
			if code == http.StatusNoContent {
				pending = pending[1:]
			}
		}
	}
	var reads, writes, deletes float64
	var progressed, deleteLines int
	for _, l := range e.jobLines() {
		if l["account_job"] != "delete" {
			continue
		}
		deleteLines++
		reads += l["fs_reads"].(float64)
		writes += l["fs_writes"].(float64)
		deletes += l["fs_deletes"].(float64)
		if l["outcome"] == "progressed" {
			progressed++
		}
	}
	t.Logf("BUDGET account-delete job (P=300 O=100 I=100 E=1) over %d deliveries (%d progressed): reads=%.0f writes=%.0f deletes=%.0f", deleteLines, progressed, reads, writes, deletes)
	t.Logf("BUDGET account-delete limits: reads <= %d + D (ADR-0011 formula; plan AC %d + job state), writes <= %d + checkpoints(%d), deletes <= %d",
		refDeleteReadsBase, planDeleteReads, refDeleteWrites, progressed, refDeleteDeletes)
	if reads > float64(refDeleteReadsBase+deleteLines) {
		t.Errorf("delete job reads = %.0f, over %d + D(%d) from the ADR-0011 formula", reads, refDeleteReadsBase, deleteLines)
	}
	if reads > float64(planDeleteReads+deleteLines) {
		t.Errorf("delete job reads = %.0f, over the plan T16 criterion 509 + job state (D=%d)", reads, deleteLines)
	}
	if writes > float64(refDeleteWrites+progressed) {
		t.Errorf("delete job writes = %.0f, over %d + %d checkpoints", writes, refDeleteWrites, progressed)
	}
	if deletes > refDeleteDeletes {
		t.Errorf("delete job deletes = %.0f, over %d", deletes, refDeleteDeletes)
	}

	// --- end state ---
	for _, path := range []string{"users/" + a.uid, "graph/" + a.uid, "quotas/" + a.uid, "exports/" + exp.Msg.GetExportId()} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	if present, _ := e.authUser(t, a.uid); present {
		t.Error("the Firebase Auth user survived")
	}
	e.requireNoResidue(t, a.uid)
	e.requireInvariants(t, cohort)
	// Counterparts: every followee lost its one follower, every follower lost its one followee.
	for i, uid := range cohort[1 : 1+refFollowing] {
		if got := intField(t, e, "users/"+uid, "followersCount"); got != 0 {
			t.Fatalf("followee %d followersCount = %d", i, got)
		}
	}
	for i, uid := range cohort[1+refFollowing:] {
		if got := intField(t, e, "users/"+uid, "followingCount"); got != 0 {
			t.Fatalf("follower %d followingCount = %d", i, got)
		}
	}
	for _, l := range e.jobLines() {
		if strings.Contains(fmt.Sprint(l), a.uid) {
			t.Errorf("a job line carries the raw uid: %v", l)
		}
	}
}
