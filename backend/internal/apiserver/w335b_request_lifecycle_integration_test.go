//go:build integration

package apiserver

// W3-35b: follow requests through the account lifecycle (ADR-0025 D11, W3-32) over the real Build chain: Firestore, Auth,
// Pub/Sub and Storage emulators, the real graph.RequestEraser step and the real export section.
//
//   - the export of an account with requests both ways: a section golden (testdata/w335b_follow_requests_export_golden.json,
//     rewritten with -update-golden), newest-first order, and no other account's request in anyone's export;
//   - the deletion of a requester: its request and the target's pending list are clean, the target keeps its other requests;
//   - the deletion of a protected target with requests both ways: no request names it, the requesters' `requested` entries
//     are gone, the queue it had joined is clean, its entry is gone from privacy/protectedAuthors (the identity step), and
//     the T11 residue sweep finds nothing;
//   - the deletion of the second protected account closes the set entry too, and the whole followRequests collection holds
//     no pair of the cohort (I-R: no request without its `requested` entry, nothing left over).
// The wiring lists (steps, sections) and the T11 coverage guard are lifecycle_wiring_test.go and
// lifecycle_collections_guard_test.go; the minimum cost of the step on an empty account is in the reference-account budgets.

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w335bDelete deletes u through the real job chain: DeleteAccount, past the start gate, every message delivered until the
// job publishes no continuation.
func (e *lifecycleEnv) w335bDelete(t *testing.T, u testUser, key string) {
	t.Helper()
	ctx := context.Background()
	if _, err := e.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: key})); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	e.pastGate(t, u.uid)
	for round := 0; round < 12; round++ {
		msgs := e.pull(t)
		delivered := false
		for _, m := range msgs {
			if m["kind"] != "account_delete" || m["uid"] != u.uid {
				continue
			}
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("delivery of the delete job = %d, want 204", code)
			}
			delivered = true
		}
		if !delivered {
			return
		}
	}
	t.Fatal("the delete job kept publishing continuations")
}

func (e *lifecycleEnv) w335bRequestsTo(t *testing.T, owner testUser) []string {
	t.Helper()
	r, err := e.graph.ListFollowRequests(context.Background(), authed(owner.token, &graphv1.ListFollowRequestsRequest{PageSize: 50}))
	if err != nil {
		t.Fatalf("ListFollowRequests: %v", err)
	}
	var out []string
	for _, it := range r.Msg.GetRequests() {
		out = append(out, it.GetUser().GetUserId())
	}
	return out
}

func (e *lifecycleEnv) w335bRequested(t *testing.T, uid string) []string {
	t.Helper()
	snap, err := e.fs.Doc("graph/" + uid).Get(context.Background())
	if err != nil {
		return nil
	}
	return strSlice(snap.Data()["requested"])
}

func strSlice(v any) []string {
	var out []string
	arr, _ := v.([]any)
	for _, x := range arr {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func (e *lifecycleEnv) w335bInSet(t *testing.T, uid string) bool {
	t.Helper()
	snap, err := e.fs.Doc("privacy/protectedAuthors").Get(context.Background())
	if err != nil {
		return false
	}
	return slices.Contains(strSlice(snap.Data()["uids"]), uid)
}

func TestW335b_FollowRequestsThroughAccountLifecycle(t *testing.T) {
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		relaxLimits(c)
		c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
		c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.On}
	})
	p, q, r1, r2 := e.newUser(t), e.newUser(t), e.newUser(t), e.newUser(t)
	e.w328bToggle(t, p, "w335b-protect-p-00001", true)
	e.w328bToggle(t, q, "w335b-protect-q-00001", true)
	e.w328bRequest(t, r1, p.uid)
	e.w328bRequest(t, r2, p.uid)
	e.w328bRequest(t, r1, q.uid)
	e.w328bRequest(t, p, q.uid) // a protected account may itself ask another protected account
	for _, u := range []testUser{p, q} {
		if !e.w335bInSet(t, u.uid) {
			t.Fatalf("setup: %s is not in the protected set", u.uid)
		}
	}
	e.pull(t)

	// --- export: the section golden and the order ---
	_, rawP := e.exportOf(t, p, "w335b-export-p-0001")
	var env map[string]json.RawMessage
	if err := json.Unmarshal(rawP, &env); err != nil {
		t.Fatalf("export is not JSON: %v", err)
	}
	section, ok := env["follow_requests"]
	if !ok {
		t.Fatalf("the export has no follow_requests section: %s", rawP)
	}
	var lower struct {
		Sent []struct {
			UserID      string    `json:"userId"`
			Handle      string    `json:"handle"`
			RequestedAt time.Time `json:"requestedAt"`
		} `json:"sent"`
		Received []struct {
			UserID      string    `json:"userId"`
			Handle      string    `json:"handle"`
			RequestedAt time.Time `json:"requestedAt"`
		} `json:"received"`
	}
	if err := json.Unmarshal(section, &lower); err != nil {
		t.Fatalf("section: %v: %s", err, section)
	}
	if len(lower.Sent) != 1 || lower.Sent[0].UserID != q.uid || len(lower.Received) != 2 {
		t.Fatalf("P's section = %s, want sent [Q] and received [R1 R2]", section)
	}
	if lower.Received[0].RequestedAt.Before(lower.Received[1].RequestedAt) {
		t.Errorf("received is not newest first: %v then %v", lower.Received[0].RequestedAt, lower.Received[1].RequestedAt)
	}
	if got := []string{lower.Received[0].UserID, lower.Received[1].UserID}; !slices.Contains(got, r1.uid) || !slices.Contains(got, r2.uid) {
		t.Errorf("received = %v, want R1 and R2", got)
	}

	repl := map[string]string{}
	for name, u := range map[string]testUser{"P": p, "Q": q, "R1": r1, "R2": r2} {
		h, _ := e.profileOf(t, u)
		repl[u.uid], repl[h] = "<uid:"+name+">", "<handle:"+name+">"
	}
	norm := normalizeExport(t, section, repl)
	var shaped map[string][]map[string]any
	if err := json.Unmarshal(norm, &shaped); err != nil {
		t.Fatal(err)
	}
	for _, rows := range shaped { // the two requests to P were made in one run: order them by role for a stable golden
		sort.SliceStable(rows, func(i, j int) bool { return rows[i]["userId"].(string) < rows[j]["userId"].(string) })
	}
	var gbuf bytes.Buffer
	enc := json.NewEncoder(&gbuf)
	enc.SetEscapeHTML(false) // keep the <uid:P> placeholders readable
	enc.SetIndent("", "  ")
	if err := enc.Encode(shaped); err != nil {
		t.Fatal(err)
	}
	golden := gbuf.Bytes()
	path := filepath.Join("testdata", "w335b_follow_requests_export_golden.json")
	if *updateGolden {
		if err := os.WriteFile(path, golden, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden: %v (run with -update-golden)", err)
	}
	if string(want) != string(golden) {
		t.Errorf("follow_requests section differs from %s:\n got: %s\nwant: %s", path, golden, want)
	}

	// Nobody's export lists a request they are not a party to: R2's has P and nothing of R1, Q or P's other requests.
	_, rawR2 := e.exportOf(t, r2, "w335b-export-r2-0001")
	for _, other := range []string{r1.uid, q.uid} {
		if strings.Contains(string(rawR2), other) {
			t.Errorf("R2's export names %s, a party to none of R2's requests", other)
		}
	}
	var envR2 map[string]json.RawMessage
	_ = json.Unmarshal(rawR2, &envR2)
	var r2Section struct {
		Sent     []map[string]any `json:"sent"`
		Received []map[string]any `json:"received"`
	}
	if err := json.Unmarshal(envR2["follow_requests"], &r2Section); err != nil || len(r2Section.Sent) != 1 || len(r2Section.Received) != 0 || r2Section.Sent[0]["userId"] != p.uid {
		t.Errorf("R2's section = %s (%v), want sent [P] only", envR2["follow_requests"], err)
	}

	// --- delete a requester: R2 ---
	e.w335bDelete(t, r2, "w335b-delete-r2-0001")
	e.requireNoResidue(t, r2.uid)
	if fsDocExists(t, e.fs, "followRequests/"+r2.uid+"_"+p.uid) {
		t.Error("R2's request to P survived R2's deletion")
	}
	if got := e.w335bRequestsTo(t, p); !slices.Equal(got, []string{r1.uid}) {
		t.Errorf("P's pending list after R2 left = %v, want [R1]", got)
	}

	// --- delete a protected target with requests both ways: P ---
	e.w335bDelete(t, p, "w335b-delete-p-0001")
	e.requireNoResidue(t, p.uid)
	if e.w335bInSet(t, p.uid) {
		t.Error("P's uid is still in privacy/protectedAuthors after its deletion (the identity step must remove it)")
	}
	if !e.w335bInSet(t, q.uid) {
		t.Error("Q's entry left the protected set when P was deleted")
	}
	for _, id := range []string{r1.uid + "_" + p.uid, p.uid + "_" + q.uid} {
		if fsDocExists(t, e.fs, "followRequests/"+id) {
			t.Errorf("followRequests/%s survived P's deletion", id)
		}
	}
	if got := e.w335bRequested(t, r1.uid); !slices.Equal(got, []string{q.uid}) {
		t.Errorf("R1's requested after P left = %v, want only Q", got)
	}
	if got := e.w335bRequestsTo(t, q); !slices.Equal(got, []string{r1.uid}) {
		t.Errorf("Q's pending list after P left = %v, want only R1 (P's own request went with P)", got)
	}

	// --- delete the second protected account: Q ---
	e.w335bDelete(t, q, "w335b-delete-q-0001")
	e.requireNoResidue(t, q.uid)
	if e.w335bInSet(t, q.uid) {
		t.Error("Q's uid is still in privacy/protectedAuthors after its deletion")
	}
	if got := e.w335bRequested(t, r1.uid); len(got) != 0 {
		t.Errorf("R1's requested after everyone left = %v, want empty", got)
	}
	docs, err := e.fs.Collection("followRequests").Where("followerId", "in", []string{p.uid, q.uid, r1.uid, r2.uid}).Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 0 {
		t.Errorf("followRequests still holds %d docs of the cohort (err %v)", len(docs), err)
	}
}
