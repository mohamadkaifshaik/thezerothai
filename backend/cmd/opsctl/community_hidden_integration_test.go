//go:build integration

package main

import (
	"bytes"
	"context"
	"fmt"
	"math/rand"
	"slices"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// `opsctl community hidden` and `restore-hidden` over the real communities and posts repositories on the emulator. The emulator never
// demands an index, so the query shape itself is proven on dev Firestore (recorded in the plan ticket), not here.

type hiddenEnv struct {
	t       *testing.T
	client  *firestore.Client
	project string
	now     time.Time
	crepo   *communities.FirestoreRepo
}

func newHiddenEnv(t *testing.T, size int) *hiddenEnv {
	t.Helper()
	client, project := backfillTestClient(t)
	return newHiddenEnvOn(t, client, project, size)
}

func newHiddenEnvOn(t *testing.T, client *firestore.Client, project string, size int) *hiddenEnv {
	t.Helper()
	old := hiddenPageSize
	hiddenPageSize = size
	t.Cleanup(func() { hiddenPageSize = old })
	crepo := communities.NewFirestoreRepo(client, nil).WithHiddenPosts(posts.NewCommunityModerator(client))
	return &hiddenEnv{t: t, client: client, project: project, now: time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC), crepo: crepo}
}

func (e *hiddenEnv) community(cid, status string, removals ...string) {
	e.t.Helper()
	rem := []any{}
	for _, id := range removals {
		rem = append(rem, map[string]any{"postId": id, "at": e.now.Add(-time.Hour)})
	}
	if _, err := e.client.Collection("communities").Doc(cid).Set(context.Background(), map[string]any{
		"name": "Cats", "description": "d", "rules": []any{}, "ownerId": "u-owner", "moderatorIds": []string{},
		"memberCount": 1, "status": status, "visibility": "PUBLIC", "recentRemovals": rem, "modlog": []any{}, "modlogSeq": 0,
		"createdAt": e.now.Add(-48 * time.Hour), "updatedAt": e.now.Add(-48 * time.Hour),
	}); err != nil {
		e.t.Fatal(err)
	}
}

// post seeds a hidden root (kind POST, no communityId) or reply; at zero means hidden before communityHiddenAt existed.
func (e *hiddenEnv) post(id, cid string, reply bool, at time.Time, moderation string) {
	e.t.Helper()
	d := map[string]any{
		"authorId": "u-author", "text": "SECRET-TEXT", "createdAt": e.now.Add(-24 * time.Hour), "visibility": "PUBLIC",
		"conversationCommunityId": cid, "communityHidden": true,
	}
	if reply {
		d["kind"], d["isReply"] = "REPLY", true
	} else {
		d["kind"] = "POST"
		d["community"] = map[string]any{"id": cid, "name": "Cats"}
	}
	if !at.IsZero() {
		d["communityHiddenAt"] = at
	}
	if moderation != "" {
		d["moderation"] = moderation
	}
	if _, err := e.client.Collection("posts").Doc(id).Set(context.Background(), d); err != nil {
		e.t.Fatal(err)
	}
}

func (e *hiddenEnv) cli(args ...string) (code int, stdout, stderr string) {
	e.t.Helper()
	open := func(context.Context, string) (*backends, error) {
		return &backends{communities: e.crepo, hidden: e.crepo, close: func() {}}, nil
	}
	var out, errOut bytes.Buffer
	code = run(context.Background(), append(args, "--project", e.project), strings.NewReader(""), &out, &errOut, open, func() time.Time { return e.now })
	return code, out.String(), errOut.String()
}

func (e *hiddenEnv) postDoc(id string) map[string]any {
	e.t.Helper()
	snap, err := e.client.Collection("posts").Doc(id).Get(context.Background())
	if err != nil {
		e.t.Fatal(err)
	}
	return snap.Data()
}

func (e *hiddenEnv) communityDoc(cid string) map[string]any {
	e.t.Helper()
	snap, err := e.client.Collection("communities").Doc(cid).Get(context.Background())
	if err != nil {
		e.t.Fatal(err)
	}
	return snap.Data()
}

func (e *hiddenEnv) listed(id string) bool {
	d := e.postDoc(id)
	_, hasID := d["communityId"]
	_, hidden := d["communityHidden"]
	_, hasAt := d["communityHiddenAt"]
	return hasID && !hidden && !hasAt
}

func mustContain(t *testing.T, name, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("%s: output lacks %q:\n%s", name, w, out)
		}
	}
}

// 3 hidden posts and 2 hidden replies are listed, nothing from another community, over 3 pages of 2; the time reads "unknown" for a post hidden
// before communityHiddenAt; no text appears.
func TestCommunityHidden_Integration_List(t *testing.T) {
	// The audit line prints the project id. A CI run drew demo-test-2452080805636171993, whose digits hold "7199", and a leak check on
	// that short form failed with nothing leaked. This project always holds the short forms of the foreign post and of cid, so the
	// check below must match whole ids (regression for that flake).
	client, project := testClientFor(t, fmt.Sprintf("demo-test-7199-7001-%d", rand.Int63()))
	e := newHiddenEnvOn(t, client, project, 2)
	const cid, other, foreignPost = "0000000000000007001", "0000000000000007002", "0000000000000007199"
	e.community(cid, "ACTIVE")
	e.community(other, "ACTIVE")
	t0 := e.now.Add(-time.Hour)
	e.post("0000000000000007101", cid, false, t0, "")
	e.post("0000000000000007102", cid, true, t0, "")
	e.post("0000000000000007103", cid, false, time.Time{}, "") // before then: no time
	e.post("0000000000000007104", cid, true, t0, "")
	e.post("0000000000000007105", cid, false, t0, "TAKEN_DOWN")
	e.post(foreignPost, other, false, t0, "")

	var all strings.Builder
	token := ""
	for page := range 3 {
		args := []string{"community", "hidden", cid}
		if token != "" {
			args = append(args, "--page-token", token)
		}
		code, out, errOut := e.cli(args...)
		if code != 0 {
			t.Fatalf("page %d: code=%d stderr=%s", page, code, errOut)
		}
		mustContain(t, "page", out, "community_hash=")
		all.WriteString(out)
		token = ""
		for _, l := range strings.Split(out, "\n") {
			if rest, ok := strings.CutPrefix(l, "page: rows="); ok && !strings.HasSuffix(rest, "next_page_token=none") {
				token = rest[strings.Index(rest, "next_page_token=")+len("next_page_token="):]
			}
		}
	}
	if token != "" {
		t.Errorf("a token remained after the last page: %q", token)
	}
	s := all.String()
	mustContain(t, "all", s,
		"post=0000000000000007101 kind=root hidden_at="+t0.Format(time.RFC3339)+" moderation=none",
		"post=0000000000000007102 kind=reply",
		"post=0000000000000007103 kind=root hidden_at=unknown moderation=none",
		"post=0000000000000007104 kind=reply",
		"post=0000000000000007105 kind=root", "moderation=set")
	// Privacy: the rows are exactly cid's five hidden posts, each once; the other community's post id, any text and the raw cid appear
	// nowhere in the output (audit lines included). Ids are matched whole: a short digit run can occur in the random project id.
	var listed []string
	for _, l := range strings.Split(s, "\n") {
		if rest, ok := strings.CutPrefix(l, "post="); ok {
			id, _, _ := strings.Cut(rest, " ")
			listed = append(listed, id)
		}
	}
	if want := []string{"0000000000000007101", "0000000000000007102", "0000000000000007103", "0000000000000007104", "0000000000000007105"}; !slices.Equal(listed, want) {
		t.Errorf("listed posts = %v, want exactly %v:\n%s", listed, want, s)
	}
	if strings.Contains(s, foreignPost) || strings.Contains(s, "SECRET-TEXT") || strings.Contains(s, cid) {
		t.Errorf("output leaks another community's post, text or the community id:\n%s", s)
	}
	if code, _, errOut := e.cli("community", "hidden", "0000000000009999999"); code != 1 || !strings.Contains(errOut, "no such community") {
		t.Errorf("missing community: code=%d stderr=%q", code, errOut)
	}
}

// restore-hidden: the --since cut, the L-2 skip, the no-time case, one modlog entry per run, dry-run, re-run, and a SUSPENDED community.
func TestCommunityRestoreHidden_Integration(t *testing.T) {
	e := newHiddenEnv(t, 2)
	const cid = "0000000000000008001"
	since := e.now.Add(-2 * time.Hour)
	a1, a2, a3, a4, a5 := "0000000000000008101", "0000000000000008102", "0000000000000008103", "0000000000000008104", "0000000000000008105"
	e.community(cid, "SUSPENDED", a1, a2, a5)                  // restore-hidden works in any status
	e.post(a1, cid, false, since.Add(-time.Hour), "")          // hidden before the cut
	e.post(a2, cid, false, since.Add(time.Hour), "")           // after the cut
	e.post(a3, cid, true, since.Add(90*time.Minute), "")       // a reply after the cut
	e.post(a4, cid, false, time.Time{}, "")                    // no time
	e.post(a5, cid, false, since.Add(time.Hour), "TAKEN_DOWN") // platform removal

	// dry-run --since: reports the same counts, nothing changed.
	code, out, errOut := e.cli("community", "restore-hidden", cid, "--since", since.Format(time.RFC3339), "--dry-run")
	if code != 0 {
		t.Fatalf("dry-run: code=%d stderr=%s", code, errOut)
	}
	mustContain(t, "dry-run", out, "listed=5 would_restore=2 skipped_platform=1 skipped_no_time=1")
	for _, id := range []string{a1, a2, a3, a4, a5} {
		if e.listed(id) {
			t.Fatalf("dry-run restored %s", id)
		}
	}
	if len(e.communityDoc(cid)["modlog"].([]any)) != 0 {
		t.Fatal("dry-run wrote a modlog entry")
	}

	// --since: only a2 and a3 come back; one platform entry; a2's recentRemovals entry goes, a1's and a5's stay.
	code, out, errOut = e.cli("community", "restore-hidden", cid, "--since", since.Format(time.RFC3339))
	if code != 0 {
		t.Fatalf("restore: code=%d stderr=%s", code, errOut)
	}
	mustContain(t, "restore", out, "listed=5 restored=2 skipped_platform=1 skipped_no_time=1", "modlog: 1 platform entry", "5 minutes",
		"audit: community restore-hidden project="+e.project)
	if !e.listed(a2) {
		t.Errorf("a2/a3 not restored: %v %v", e.postDoc(a2), e.postDoc(a3))
	}
	if _, hidden := e.postDoc(a3)["communityHidden"]; hidden {
		t.Errorf("reply still hidden: %v", e.postDoc(a3))
	}
	if _, has := e.postDoc(a3)["communityHiddenAt"]; has {
		t.Errorf("a restored reply keeps communityHiddenAt: %v", e.postDoc(a3))
	}
	for _, id := range []string{a1, a4, a5} {
		if e.postDoc(id)["communityHidden"] != true {
			t.Errorf("%s was restored", id)
		}
	}
	if got := e.postDoc(a5)["moderation"]; got != "TAKEN_DOWN" {
		t.Errorf("a5 moderation = %v", got)
	}
	c := e.communityDoc(cid)
	log := c["modlog"].([]any)
	if len(log) != 1 || c["status"] != "SUSPENDED" {
		t.Fatalf("modlog = %v status = %v", log, c["status"])
	}
	entry := log[0].(map[string]any)
	if entry["actor"] != communities.PlatformMarker || entry["action"] != communities.ActionRestore || entry["postId"] != nil || entry["target"] != nil {
		t.Errorf("entry = %v", entry)
	}
	rem := c["recentRemovals"].([]any)
	if len(rem) != 2 || rem[0].(map[string]any)["postId"] != a1 || rem[1].(map[string]any)["postId"] != a5 {
		t.Errorf("recentRemovals = %v", rem)
	}
	if n, _ := c["name"].(string); n != "Cats" {
		t.Errorf("name = %v: writes must be field-level", c["name"])
	}

	// A re-run restores nothing and writes nothing.
	_, out, _ = e.cli("community", "restore-hidden", cid, "--since", since.Format(time.RFC3339))
	mustContain(t, "re-run", out, "listed=3 restored=0 skipped_platform=1 skipped_no_time=1", "modlog: 0 platform entry")
	if len(e.communityDoc(cid)["modlog"].([]any)) != 1 {
		t.Error("a re-run wrote a modlog entry")
	}

	// Without --since the post with no time (and the older one) come back; the platform removal never does; a new run, a new entry.
	_, out, _ = e.cli("community", "restore-hidden", cid)
	mustContain(t, "no --since", out, "listed=3 restored=2 skipped_platform=1 skipped_no_time=0", "modlog: 1 platform entry")
	if !e.listed(a1) || !e.listed(a4) || e.postDoc(a5)["communityHidden"] != true {
		t.Error("run without --since did not restore a1 and a4 only")
	}
	c = e.communityDoc(cid)
	if rem := c["recentRemovals"].([]any); len(rem) != 1 || rem[0].(map[string]any)["postId"] != a5 {
		t.Errorf("recentRemovals = %v, want only the platform removal", rem)
	}
	if len(c["modlog"].([]any)) != 2 {
		t.Errorf("modlog = %v, want one entry per run", c["modlog"])
	}

	// Nothing but the platform removal is left.
	_, out, _ = e.cli("community", "restore-hidden", cid)
	mustContain(t, "final", out, "listed=1 restored=0 skipped_platform=1")
}

func TestCommunityHidden_Integration_Args(t *testing.T) {
	e := newHiddenEnv(t, 2)
	for _, args := range [][]string{
		{"community", "hidden"},
		{"community", "hidden", "123"},
		{"community", "hidden", "0000000000000007001", "--since", "2026-11-02T00:00:00Z"},
		{"community", "hidden", "0000000000000007001", "--dry-run"},
		{"community", "restore-hidden", "0000000000000007001", "--since", "yesterday"},
		{"community", "restore-hidden", "0000000000000007001", "--page-token", "x1"},
		{"community", "suspend", "0000000000000007001", "--since", "2026-11-02T00:00:00Z"},
		{"lists", "hide", "0000000000000007001", "--page-token", "h1.1"},
	} {
		if code, _, _ := e.cli(args...); code != 2 {
			t.Errorf("%v: code = %d, want 2", args, code)
		}
	}
}

// M-4 / N-1: a REPOST and a root labelled with another community are never restored (and the dry-run says so too); a restored reply loses
// communityHiddenAt; when the first pages restore nothing, the run's modlog entry is written on the page that does.
func TestCommunityRestoreHidden_Integration_OtherRowsAndLatePage(t *testing.T) {
	e := newHiddenEnv(t, 2)
	const cid, foreign = "0000000000000009001", "0000000000000009002"
	since := e.now.Add(-2 * time.Hour)
	after := since.Add(time.Hour)
	c1, c2, c3, c4, c5, c6 := "0000000000000009101", "0000000000000009102", "0000000000000009103", "0000000000000009104", "0000000000000009105", "0000000000000009106"
	e.community(cid, "ACTIVE")
	e.post(c1, cid, false, since.Add(-time.Hour), "") // older than the cut
	e.post(c2, cid, false, since.Add(-time.Hour), "")
	// c3: a REPOST that carries the conversation key; c4: a root whose label names another community
	e.post(c3, cid, false, after, "")
	if _, err := e.client.Collection("posts").Doc(c3).Update(context.Background(), []firestore.Update{{Path: "kind", Value: "REPOST"}}); err != nil {
		t.Fatal(err)
	}
	e.post(c4, cid, false, after, "")
	if _, err := e.client.Collection("posts").Doc(c4).Update(context.Background(), []firestore.Update{{Path: "community", Value: map[string]any{"id": foreign, "name": "Dogs"}}}); err != nil {
		t.Fatal(err)
	}
	e.post(c5, cid, false, after, "")
	e.post(c6, cid, true, after, "")

	_, out, _ := e.cli("community", "restore-hidden", cid, "--since", since.Format(time.RFC3339), "--dry-run")
	mustContain(t, "dry-run", out, "listed=6 would_restore=2 skipped_platform=0 skipped_no_time=0 skipped_other=2")
	if e.listed(c5) || e.postDoc(c6)["communityHidden"] != true {
		t.Error("the dry run restored c5 or c6")
	}

	_, out, _ = e.cli("community", "restore-hidden", cid, "--since", since.Format(time.RFC3339))
	mustContain(t, "restore", out, "listed=6 restored=2 skipped_platform=0 skipped_no_time=0 skipped_other=2", "modlog: 1 platform entry", "outcome=ok")
	for _, id := range []string{c1, c2, c3, c4} {
		if e.postDoc(id)["communityHidden"] != true {
			t.Errorf("%s was restored", id)
		}
	}
	if _, has := e.postDoc(c3)["communityId"]; has {
		t.Error("the REPOST gained communityId")
	}
	if _, has := e.postDoc(c4)["communityId"]; has {
		t.Error("the foreign-label root gained communityId")
	}
	if !e.listed(c5) {
		t.Errorf("c5 not restored: %v", e.postDoc(c5))
	}
	r := e.postDoc(c6)
	if _, has := r["communityHidden"]; has {
		t.Errorf("reply still hidden: %v", r)
	}
	if _, has := r["communityHiddenAt"]; has {
		t.Errorf("a restored reply keeps communityHiddenAt: %v", r)
	}
	if n := len(e.communityDoc(cid)["modlog"].([]any)); n != 1 {
		t.Errorf("modlog entries = %d, want 1 (written on the third page)", n)
	}
}
