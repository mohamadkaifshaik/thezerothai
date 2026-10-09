//go:build integration

package apiserver

// T11/T16: the emulator residue sweep and the cross-module invariant check that every deletion scenario ends with.
//
// sweepResidue reads EVERY root collection the project holds (not only the ones in the T11 table, so a collection the
// table does not know fails the sweep by name), every subcollection under users/{deleted uid}, and the collection
// groups of the table's subcollection rows, and reports any document whose path, ID or nested string value contains
// the deleted uid, minus the ADR-0011 Q10 allowlist (lifecycle_collections_guard_test.go).
//
// requireInvariants re-derives, from the documents alone, the counters and mirrors the graph and posts modules
// maintain, for a cohort of uids (the apiserver tests share one Firestore project, so the check is scoped to the
// accounts a scenario created). It is the same contract as graph's invariants_integration_test.go and posts'
// invariants_integration_test.go, restated here because those helpers are unexported in packages this slice must not
// touch (no shared helper package, per the T16 brief).

import (
	"context"
	"fmt"
	"math/rand"
	"slices"
	"sort"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"
)

// residueHit is one place a deleted uid still appears.
type residueHit struct {
	Path  string
	Field string
}

func (h residueHit) String() string { return h.Path + "#" + h.Field }

// shortPath strips the "projects/.../documents/" prefix.
func shortPath(p string) string {
	if i := strings.Index(p, "/documents/"); i >= 0 {
		return p[i+len("/documents/"):]
	}
	return p
}

// containsUID reports whether v (a decoded Firestore value) holds uid in any nested string.
func containsUID(v any, uid string) bool {
	switch v := v.(type) {
	case string:
		return strings.Contains(v, uid)
	case []any:
		return slices.ContainsFunc(v, func(x any) bool { return containsUID(x, uid) })
	case map[string]any:
		for _, x := range v {
			if containsUID(x, uid) {
				return true
			}
		}
	}
	return false
}

// docHits returns the non-allowlisted references to uid in one document of collection col. inUserSubtree marks a
// document under users/{uid}: its mere existence is residue (nothing of a deleted user's subtree may survive).
func docHits(col string, snap *firestore.DocumentSnapshot, uid string, inUserSubtree bool) []residueHit {
	var hits []residueHit
	switch {
	case inUserSubtree:
		hits = append(hits, residueHit{shortPath(snap.Ref.Path), "__subtree__"})
	case strings.Contains(snap.Ref.ID, uid) && !allowed(col, "__name__"):
		hits = append(hits, residueHit{shortPath(snap.Ref.Path), "__name__"})
	}
	for field, v := range snap.Data() {
		if containsUID(v, uid) && !allowed(col, field) {
			hits = append(hits, residueHit{shortPath(snap.Ref.Path), field})
		}
	}
	return hits
}

// sweepT is the slice of *testing.T the sweep reports through, so the self-test can record the failures it expects.
type sweepT interface {
	Helper()
	Errorf(format string, args ...any)
	Fatalf(format string, args ...any)
}

// sweepResidue is the T11 emulator sweep over client c. Root collections without a row in lifecycleCollections, and
// subcollections under users/{uid} without a Sub row, are reported through t.Errorf (the runtime twin of the
// source-scanning guard).
func sweepResidue(t sweepT, c *firestore.Client, uid string) []residueHit {
	t.Helper()
	ctx := context.Background()
	var hits []residueHit
	roots := c.Collections(ctx)
	for {
		col, err := roots.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			t.Fatalf("sweep: list root collections: %v", err)
		}
		if _, ok := rowFor(col.ID); !ok {
			t.Errorf("sweep: the project holds root collection %q, which has no row in lifecycleCollections (T11)", col.ID)
		}
		docs, err := col.Documents(ctx).GetAll()
		if err != nil {
			t.Fatalf("sweep: read %s: %v", col.ID, err)
		}
		for _, snap := range docs {
			hits = append(hits, docHits(col.ID, snap, uid, false)...)
		}
	}
	// Whatever hangs under the deleted user's own document, including subcollections the table does not know.
	subs := c.Doc("users/" + uid).Collections(ctx)
	for {
		sub, err := subs.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			t.Fatalf("sweep: list subcollections of users/%s: %v", "<uid>", err)
		}
		if row, ok := rowFor(sub.ID); !ok || !row.Sub {
			t.Errorf("sweep: users/{uid} holds subcollection %q, which has no Sub row in lifecycleCollections (T11)", sub.ID)
		}
		subDocs, err := sub.Documents(ctx).GetAll()
		if err != nil {
			t.Fatalf("sweep: read %s: %v", sub.ID, err)
		}
		for _, snap := range subDocs {
			hits = append(hits, docHits(sub.ID, snap, uid, true)...)
		}
	}
	// Subcollection rows across every user (a document of someone else's that names the uid).
	for _, row := range lifecycleCollections {
		if !row.Sub {
			continue
		}
		docs, err := c.CollectionGroup(row.Name).Documents(ctx).GetAll()
		if err != nil {
			t.Fatalf("sweep: collection group %s: %v", row.Name, err)
		}
		for _, snap := range docs {
			if strings.Contains(snap.Ref.Path, "/users/"+uid+"/") {
				continue // already reported through the user's own subtree
			}
			hits = append(hits, docHits(row.Name, snap, uid, false)...)
		}
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].String() < hits[j].String() })
	return slices.Compact(hits)
}

// requireNoResidue fails with every non-allowlisted hit for uid.
func (e *lifecycleEnv) requireNoResidue(t *testing.T, uid string) {
	t.Helper()
	if hits := sweepResidue(t, e.fs, uid); len(hits) > 0 {
		t.Errorf("residue outside the Q10 allowlist for the deleted uid (%d): %v", len(hits), hits)
	}
}

func stringSet(v any) map[string]bool {
	out := map[string]bool{}
	arr, _ := v.([]any)
	for _, x := range arr {
		if s, ok := x.(string); ok {
			out[s] = true
		}
	}
	return out
}

func asInt(v any) int64 {
	switch n := v.(type) {
	case int64:
		return n
	case int:
		return int64(n)
	case float64:
		return int64(n)
	}
	return 0
}

func setsEqual(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// requireInvariants checks, for every uid of the cohort (alive or deleted), the graph invariants I1/I2 and the posts
// counter, derived from the documents: a remaining user's followersCount/followingCount/postsCount equal what the
// edges and posts say, graph.following mirrors the out-edges, blocked[] and blockedBy[] mirror each other between
// remaining users, no blockedBy entry names a deleted user, and no edge or post of a remaining user points at a deleted
// one. A deleted uid must have no users/graph doc and no edge or post at all.
func (e *lifecycleEnv) requireInvariants(t sweepT, cohort []string) {
	t.Helper()
	ctx := context.Background()
	data := func(path string) (map[string]any, bool) {
		snap, err := e.fs.Doc(path).Get(ctx)
		if err != nil || !snap.Exists() {
			return nil, false
		}
		return snap.Data(), true
	}
	ids := func(q firestore.Query) map[string]bool {
		docs, err := q.Limit(2000).Documents(ctx).GetAll()
		if err != nil {
			t.Fatalf("invariants query: %v", err)
		}
		out := map[string]bool{}
		for _, d := range docs {
			out[d.Ref.ID] = true
		}
		return out
	}
	alive := map[string]bool{}
	for _, uid := range cohort {
		if _, ok := data("users/" + uid); ok {
			alive[uid] = true
		}
	}
	for _, uid := range cohort {
		outEdges, inEdges := map[string]bool{}, map[string]bool{}
		fol := e.fs.Collection("follows")
		for id := range ids(fol.Where("followerId", "==", uid)) {
			outEdges[strings.TrimPrefix(id, uid+"_")] = true
		}
		for id := range ids(fol.Where("followeeId", "==", uid)) {
			inEdges[strings.TrimSuffix(id, "_"+uid)] = true
		}
		nPosts := int64(len(ids(e.fs.Collection("posts").Where("authorId", "==", uid))))
		if !alive[uid] {
			if len(outEdges)+len(inEdges) != 0 || nPosts != 0 {
				t.Errorf("deleted %s: %d out-edges, %d in-edges, %d posts remain", uid, len(outEdges), len(inEdges), nPosts)
			}
			if _, ok := data("graph/" + uid); ok {
				t.Errorf("deleted %s: graph doc remains", uid)
			}
			continue
		}
		u, _ := data("users/" + uid)
		for other := range outEdges {
			if slices.Contains(cohort, other) && !alive[other] {
				t.Errorf("%s follows deleted %s (dangling edge)", uid, other)
			}
		}
		for other := range inEdges {
			if slices.Contains(cohort, other) && !alive[other] {
				t.Errorf("deleted %s still follows %s (dangling edge)", other, uid)
			}
		}
		if got, want := asInt(u["followersCount"]), int64(len(inEdges)); got != want {
			t.Errorf("users/%s.followersCount = %d, edges say %d", uid, got, want)
		}
		if got, want := asInt(u["followingCount"]), int64(len(outEdges)); got != want {
			t.Errorf("users/%s.followingCount = %d, edges say %d", uid, got, want)
		}
		if got := asInt(u["postsCount"]); got != nPosts {
			t.Errorf("users/%s.postsCount = %d, posts say %d", uid, got, nPosts)
		}
		g, ok := data("graph/" + uid)
		if !ok {
			t.Errorf("users/%s has no graph doc", uid)
			continue
		}
		if following := stringSet(g["following"]); !setsEqual(following, outEdges) {
			t.Errorf("graph/%s.following = %v, edges say %v", uid, sortedKeys(following), sortedKeys(outEdges))
		}
		for b := range stringSet(g["blockedBy"]) {
			peer, ok := data("graph/" + b)
			switch {
			case !ok:
				t.Errorf("graph/%s.blockedBy lists %s, who has no graph doc (not on the Q10 allowlist)", uid, b)
			case !stringSet(peer["blocked"])[uid]:
				t.Errorf("graph/%s.blockedBy lists %s, but graph/%s.blocked does not list %s", uid, b, b, uid)
			}
		}
		for b := range stringSet(g["blocked"]) {
			if peer, ok := data("graph/" + b); ok && !stringSet(peer["blockedBy"])[uid] {
				t.Errorf("graph/%s.blocked lists %s, but graph/%s.blockedBy does not list %s", uid, b, b, uid)
			}
		}
	}
}

// TestSweepResidue_CatchesWhatItShouldAndOnlyThat proves the sweep itself on hand-made documents in a private
// Firestore project: the Q10 entries are not hits, every other kind of reference is (a follows doc id and field, a
// blockedBy entry, a post author, an exports doc, a nested value under users/{uid}/private), and an unknown root
// collection or subcollection fails by name.
func TestSweepResidue_CatchesWhatItShouldAndOnlyThat(t *testing.T) {
	skipIfNoEmulators(t)
	ctx := context.Background()
	c, err := firestore.NewClient(ctx, fmt.Sprintf("demo-sweep-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	const gone = "ghost-uid-0000000000000000000000"
	put := func(path string, data map[string]any) {
		t.Helper()
		if _, err := c.Doc(path).Set(ctx, data); err != nil {
			t.Fatal(err)
		}
	}
	// Allowed by Q10: idempotency/*, other users' blocked[]/muted[], mentions in posts.
	put("idempotency/k1", map[string]any{"uid": gone})
	put("graph/other", map[string]any{"blocked": []string{gone}, "muted": []string{gone}})
	put("posts/p1", map[string]any{"authorId": "other", "mentionIds": []string{gone}})
	if hits := sweepResidue(t, c, gone); len(hits) != 0 {
		t.Fatalf("allowlisted references reported as residue: %v", hits)
	}

	// Not allowed: each of these is a defect.
	put("graph/other2", map[string]any{"blockedBy": []string{gone}})
	put("follows/other_"+gone, map[string]any{"followerId": "other", "followeeId": gone})
	put("posts/p2", map[string]any{"authorId": gone})
	put("exports/e1", map[string]any{"uid": gone})
	put("users/"+gone+"/private/p", map[string]any{"nested": map[string]any{"deep": []any{"x", gone}}})
	put("users/someone/notifications/n1", map[string]any{"actor": map[string]any{"userId": gone}})
	var got []string
	for _, h := range sweepResidue(t, c, gone) {
		got = append(got, strings.ReplaceAll(h.String(), gone, "<gone>"))
	}
	want := []string{
		"exports/e1#uid", "follows/other_<gone>#__name__", "follows/other_<gone>#followeeId",
		"graph/other2#blockedBy", "posts/p2#authorId",
		"users/<gone>/private/p#__subtree__", "users/<gone>/private/p#nested",
		"users/someone/notifications/n1#actor",
	}
	sort.Strings(want)
	if !slices.Equal(got, want) {
		t.Errorf("hits = %v\nwant   %v", got, want)
	}

	// An unknown root collection or subcollection fails the sweep by name (the runtime twin of the source guard).
	put("bookmarks/b1", map[string]any{"x": 1})
	put("users/"+gone+"/drafts/d1", map[string]any{"x": 1})
	rec := &recordingT{}
	sweepResidue(rec, c, gone)
	joined := strings.Join(rec.errors, "\n")
	for _, name := range []string{`root collection "bookmarks"`, `subcollection "drafts"`} {
		if !strings.Contains(joined, name) {
			t.Errorf("the sweep did not name %s; it reported: %q", name, joined)
		}
	}
}

// recordingT collects the sweep's Errorf calls instead of failing the test.
type recordingT struct{ errors []string }

func (r *recordingT) Helper() {}
func (r *recordingT) Errorf(format string, args ...any) {
	r.errors = append(r.errors, fmt.Sprintf(format, args...))
}
func (r *recordingT) Fatalf(format string, args ...any) { panic(fmt.Sprintf(format, args...)) }

// TestRequireInvariants_CatchesCorruption proves the invariant check has teeth: a consistent three-account cohort
// passes, then each kind of corruption (a drifted counter, a graph mirror that disagrees with the edges, a dangling
// blockedBy entry) is reported by name.
func TestRequireInvariants_CatchesCorruption(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, relaxLimits)
	a, b, c := e.newUser(t), e.newUser(t), e.newUser(t)
	e.follow(t, a, b)
	e.follow(t, c, a)
	cohort := []string{a.uid, b.uid, c.uid}
	e.requireInvariants(t, cohort)

	corrupt := func(path string, ups []firestore.Update, wantSubstr string) {
		t.Helper()
		snap, err := e.fs.Doc(path).Get(ctx)
		if err != nil {
			t.Fatal(err)
		}
		orig := snap.Data()
		if _, err := e.fs.Doc(path).Update(ctx, ups); err != nil {
			t.Fatal(err)
		}
		rec := &recordingT{}
		e.requireInvariants(rec, cohort)
		if !strings.Contains(strings.Join(rec.errors, "\n"), wantSubstr) {
			t.Errorf("corrupting %s: reported %q, want one containing %q", path, rec.errors, wantSubstr)
		}
		if _, err := e.fs.Doc(path).Set(ctx, orig); err != nil {
			t.Fatal(err)
		}
	}
	corrupt("users/"+b.uid, []firestore.Update{{Path: "followersCount", Value: 7}}, "followersCount = 7, edges say 1")
	corrupt("users/"+a.uid, []firestore.Update{{Path: "postsCount", Value: 3}}, "postsCount = 3, posts say 0")
	corrupt("graph/"+a.uid, []firestore.Update{{Path: "following", Value: []string{}}}, ".following = []")
	corrupt("graph/"+b.uid, []firestore.Update{{Path: "blockedBy", Value: []string{"ghost"}}}, "blockedBy lists ghost")
	e.requireInvariants(t, cohort) // restored
}
