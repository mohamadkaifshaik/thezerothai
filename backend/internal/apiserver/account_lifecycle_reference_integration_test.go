//go:build integration

package apiserver

// budget assertions on the plan's REFERENCE ACCOUNT (plan "Cost": P = 300
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
	// Budget table, reference row, as constants of the formula. Steps added after the original formula, each one read
	// per empty query on the reference account: notifications +3 (devices, own rows, rows naming the user)
	// and reports +1 (reports the account filed). The media step is inside 509 + D.
	refDeleteReadsBase = refPosts + refFollowing + refFollowers + 2 /* 2*ceil((max(B,Bb)+1)/500) */ + 2 + 3 + 2 /* identity */ + 1 /* max(E,1) */ +
		3 /* P6 notifications step */ +
		1 /* P7 reports step */ +
		3 /* P5 engagement: likes, reposts and the posts copy-phase queries, one read each when empty */ +
		1 /* posts phase 2: the user's postRemovals entries by authorId, one read when empty */ +
		1 /* scheduled step: users/{uid}/scheduled page query, one read when empty */ +
		1 /* bookmarks step: users/{uid}/bookmarks page query, one read when empty */ +
		2 /* W3-32 follow_requests step: outgoing + incoming empty pages, one read each */ +
		1 /* W7-6 messaging step: the conversation cursor query, one read when empty */ +
		2 /* W5-5 lists step: one empty page per phase (own lists, then membership), one read each */ +
		1 /* W5-24 communities step: the memberships doc read, one read when absent */
	refDeleteWrites  = refFollowing + 2*refFollowers
	refDeleteDeletes = refPosts + refFollowing + refFollowers + 1 + 3 + 1 + 1 /* P5 userLikes doc */
	// Plan acceptance criterion: <= 509 R + job state (D, one per delivery), <= 300 W + checkpoints, <= 505 D;
	// +3 R for the notifications step and +1 R for the reports step: 513 R +
	// job state. The media step's read was already absorbed by 509 + D on main. Amendment pending sign-off by
	// the account-deletion plan owner.
	planDeleteReads = 509 + 3 + 1 + 3 /* P5 engagement */ + 1 /* postRemovals by authorId */ + 1 /* scheduled step */ + 1 /* bookmarks step */ + 2 /* W3-32 follow_requests step */ + 1 /* W7-6 messaging step */ + 2 /* W5-5 lists step */ + 1 /* W6-8 poll_votes step: the votes query, one read when empty */ + 1 /* W5-24 communities step: the memberships doc, one read when absent */
	// Export job: 1 users + 1 exports + P + O + I + 1 graph + distinct handles (O + I) = 703, + 1 for the media
	// section (one read even when the account has no images; ceil(M/100) pages otherwise) = 704, + 2 for the
	// notifications section (the devices query and one notifications page; an empty query bills 1 read)
	// + 1 for the reports section (one read per page of reports the account filed, minimum 1 for the empty page)
	// = 707, + 2 for the engagement section (the likes and reposts queries, one read each when empty)
	// = 709, + 1 for the scheduled section (one read per page of users/{uid}/scheduled
	// documents, minimum 1 for the empty page) = 710, + 1 for the bookmarks section (one read per page of
	// users/{uid}/bookmarks, minimum 1 for the empty page) = 711, + 2 for the follow_requests section (the sent and received queries, one read each when empty) = 713, + 1 for the messages section (the conversations query, one read when empty) = 714, + 1 for the lists section (one read per page of own lists, minimum 1 for the empty page) = 715, + 1 for the poll_votes section (one read per page of the account's votes, minimum 1 for the empty page) = 716, + 1 for the poll_votes section current_choices (the userLikes read, billed even when the document is missing) = 717, + 1 for the lists_member_of part (one read per page of lists that name the account, minimum 1 for the empty page) = 718, + 1 for the communities section (the memberships doc, one read when absent) = 719 (+ the lease claim and status writes of the L-4 amendment).
	refExportReads  = 1 + 1 + refPosts + refFollowing + refFollowers + 1 + refFollowing + refFollowers + 1 + 2 + 1 + 2 + 1 + 1 + 2 + 1 + 1 + 1 + 1 /* W6-29: poll_votes current_choices reads userLikes */ + 1 /* W5-46: lists_member_of */ + 1 /* W5-24: communities section, the memberships doc read, one read when absent */
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

	// --- export of the reference account (budget) ---
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
		t.Errorf("delete job reads = %.0f, over the plan T16 criterion %d (509 + P7 reports) + job state (D=%d)", reads, planDeleteReads, deleteLines)
	}
	// refDeleteWrites + 1: the identity step's ArrayRemove on privacy/protectedAuthors, a real write
	// because the setup creates the set doc as dev and prod always have it (D-2).
	if writes != float64(refDeleteWrites+1+progressed) {
		t.Errorf("delete job writes = %.0f, want exactly %d + 1 (set ArrayRemove) + %d checkpoints", writes, refDeleteWrites, progressed)
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
