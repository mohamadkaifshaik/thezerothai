//go:build integration

// invariants_integration_test.go is the reusable graph invariant checker (ADR-0008 D3, T16a). The pure checker
// (graphInvariantViolations) has negative self-tests proving it can fail; the Firestore loader is used by the
// integration suites (newWired registers assertGraphInvariants as a t.Cleanup, so every emulator scenario ends
// with a full invariant sweep; T16b and the T25 runbook drill call assertGraphInvariants directly).
package graph_test

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"
)

// seedPadPrefix marks synthetic uids that fixtures pad arrays with to reach a cap (5,000 following, 2,000
// blocked, 10,000 blockedBy) without creating real users/edges. The checker ignores these entries (they
// have no counterpart docs by construction); every other entry is checked strictly.
const seedPadPrefix = "pad-"

func isPad(uid string) bool { return strings.HasPrefix(uid, seedPadPrefix) }

// graphState is a full snapshot of the graph module's collections in one Firestore project.
type graphState struct {
	// Edges maps follows doc ID -> its stored (followerId, followeeId).
	Edges map[string][2]string
	// Graphs maps uid -> graph/{uid}. A uid absent from the map has no graph doc.
	Graphs map[string]graphDocState
	// Users maps uid -> the two counters on users/{uid}.
	Users map[string]userCounters
}

type graphDocState struct {
	Following, Blocked, Muted, BlockedBy []string
	BlockedByOverflow                    bool
}

type userCounters struct{ Followers, Following int64 }

// graphInvariantViolations implements every ADR-0008 D3 invariant (plus structural sanity checks) over st and
// returns human-readable violations, sorted; empty means the graph is consistent.
//
//	I1  follows/{a}_{b} exists <=> b in graph/{a}.following
//	I2  users/{x}.followersCount == #follows/*_{x}; followingCount == #follows/{x}_*
//	I3  b in graph/{a}.blocked <=> a in graph/{b}.blockedBy (except when graph/{b}.blockedByOverflow)
//	I4  no follow edge in either direction between a and b while either blocks the other
//	S1  follows doc ID == followerId_followeeId, no self-follow, no self-block/self-mute
//	S2  no duplicate entries in any graph array; caps respected (5,000/2,000/2,000/10,000)
func graphInvariantViolations(st graphState) []string {
	var v []string
	add := func(format string, args ...interface{}) { v = append(v, fmt.Sprintf(format, args...)) }

	// S1 + edge indexes.
	edgeSet := map[[2]string]bool{}
	followerEdges := map[string]int64{} // uid -> edges where uid follows someone
	followeeEdges := map[string]int64{} // uid -> edges where someone follows uid
	for id, e := range st.Edges {
		if id != e[0]+"_"+e[1] {
			add("S1: follows/%s stores followerId=%q followeeId=%q (doc id mismatch)", id, e[0], e[1])
		}
		if e[0] == e[1] {
			add("S1: follows/%s is a self-follow", id)
		}
		edgeSet[e] = true
		followerEdges[e[0]]++
		followeeEdges[e[1]]++
	}

	uids := make([]string, 0, len(st.Graphs))
	for uid := range st.Graphs {
		uids = append(uids, uid)
	}
	sort.Strings(uids)

	for _, a := range uids {
		g := st.Graphs[a]
		// S2 caps + duplicates, S1 self entries.
		for name, arr := range map[string][]string{"following": g.Following, "blocked": g.Blocked, "muted": g.Muted, "blockedBy": g.BlockedBy} {
			seen := map[string]bool{}
			for _, x := range arr {
				if isPad(x) {
					continue
				}
				if seen[x] {
					add("S2: graph/%s.%s contains %q twice", a, name, x)
				}
				seen[x] = true
				if x == a && name != "blockedBy" {
					add("S1: graph/%s.%s contains itself", a, name)
				}
			}
		}
		if len(g.Following) > 5000 || len(g.Blocked) > 2000 || len(g.Muted) > 2000 || len(g.BlockedBy) > 10000 {
			add("S2: graph/%s exceeds a cap (following=%d blocked=%d muted=%d blockedBy=%d)", a, len(g.Following), len(g.Blocked), len(g.Muted), len(g.BlockedBy))
		}

		// I1 (array -> edge doc).
		for _, b := range g.Following {
			if isPad(b) {
				continue
			}
			if !edgeSet[[2]string{a, b}] {
				add("I1: %s is in graph/%s.following but follows/%s_%s does not exist", b, a, a, b)
			}
		}
		// I3 forward: a blocks b => b.blockedBy contains a, unless b overflowed (or b has no graph doc).
		for _, b := range g.Blocked {
			if isPad(b) {
				continue
			}
			gb, ok := st.Graphs[b]
			if !ok {
				add("I3: graph/%s.blocked contains %s, which has no graph doc", a, b)
				continue
			}
			if !gb.BlockedByOverflow && !containsUID(gb.BlockedBy, a) {
				add("I3: %s is in graph/%s.blocked but %s is missing from graph/%s.blockedBy (no overflow flag)", b, a, a, b)
			}
		}
		// I3 reverse: b in a.blockedBy => b.blocked contains a. Always required (overflow only drops entries).
		for _, b := range g.BlockedBy {
			if isPad(b) {
				continue
			}
			gb, ok := st.Graphs[b]
			if !ok || !containsUID(gb.Blocked, a) {
				add("I3: %s is in graph/%s.blockedBy but %s is not in graph/%s.blocked", b, a, a, b)
			}
		}
		// I4: an edge in either direction while a blocks b (covers both "a blocks b" and, via b's own doc,
		// "b blocks a"; overflowed blockedBy is covered because each side's blocked[] is authoritative).
		for _, b := range g.Blocked {
			if isPad(b) {
				continue
			}
			for _, e := range [][2]string{{a, b}, {b, a}} {
				if edgeSet[e] {
					add("I4: follows/%s_%s exists while %s blocks %s", e[0], e[1], a, b)
				}
			}
		}
	}

	// I1 (edge doc -> array).
	for e := range edgeSet {
		g, ok := st.Graphs[e[0]]
		if !ok || !containsUID(g.Following, e[1]) {
			add("I1: follows/%s_%s exists but %s is not in graph/%s.following", e[0], e[1], e[1], e[0])
		}
	}

	// I2: counters must equal edge counts, for every user that has a users doc.
	userIDs := make([]string, 0, len(st.Users))
	for uid := range st.Users {
		userIDs = append(userIDs, uid)
	}
	sort.Strings(userIDs)
	for _, uid := range userIDs {
		u := st.Users[uid]
		if _, hasGraph := st.Graphs[uid]; !hasGraph {
			// graph/{uid} deleted = the graph purge ran (ADR-0008 D10); users/{uid} is deleted later by the
			// runbook, and its own counters are intentionally not maintained by the purge.
			continue
		}
		if u.Following != followerEdges[uid] {
			add("I2: users/%s.followingCount=%d but %d follows/%s_* docs exist", uid, u.Following, followerEdges[uid], uid)
		}
		if u.Followers != followeeEdges[uid] {
			add("I2: users/%s.followersCount=%d but %d follows/*_%s docs exist", uid, u.Followers, followeeEdges[uid], uid)
		}
	}
	// Edges pointing at users with no users doc cannot be counted; flag them (purge must remove them first).
	for uid := range followerEdges {
		if _, ok := st.Users[uid]; !ok {
			add("I2: follows/%s_* edges exist but users/%s does not", uid, uid)
		}
	}
	for uid := range followeeEdges {
		if _, ok := st.Users[uid]; !ok {
			add("I2: follows/*_%s edges exist but users/%s does not", uid, uid)
		}
	}

	sort.Strings(v)
	return v
}

func containsUID(vals []string, v string) bool {
	for _, x := range vals {
		if x == v {
			return true
		}
	}
	return false
}

// loadGraphState reads every follows, graph and users doc in the client's project (each integration test
// owns a unique demo-test-<rand> project, so this is exactly the scenario's data). Emulator-only: it is an
// unbounded scan by design.
func loadGraphState(ctx context.Context, client *firestore.Client) (graphState, error) {
	st := graphState{Edges: map[string][2]string{}, Graphs: map[string]graphDocState{}, Users: map[string]userCounters{}}

	each := func(coll string, fn func(*firestore.DocumentSnapshot) error) error {
		it := client.Collection(coll).Documents(ctx)
		defer it.Stop()
		for {
			snap, err := it.Next()
			if err == iterator.Done {
				return nil
			}
			if err != nil {
				return fmt.Errorf("scan %s: %w", coll, err)
			}
			if err := fn(snap); err != nil {
				return err
			}
		}
	}

	if err := each("follows", func(s *firestore.DocumentSnapshot) error {
		st.Edges[s.Ref.ID] = [2]string{strField(s, "followerId"), strField(s, "followeeId")}
		return nil
	}); err != nil {
		return st, err
	}
	if err := each("graph", func(s *firestore.DocumentSnapshot) error {
		g := graphDocState{
			Following: strsField(s, "following"), Blocked: strsField(s, "blocked"),
			Muted: strsField(s, "muted"), BlockedBy: strsField(s, "blockedBy"),
		}
		if v, err := s.DataAt("blockedByOverflow"); err == nil {
			g.BlockedByOverflow, _ = v.(bool)
		}
		st.Graphs[s.Ref.ID] = g
		return nil
	}); err != nil {
		return st, err
	}
	if err := each("users", func(s *firestore.DocumentSnapshot) error {
		st.Users[s.Ref.ID] = userCounters{Followers: intField(s, "followersCount"), Following: intField(s, "followingCount")}
		return nil
	}); err != nil {
		return st, err
	}
	return st, nil
}

func strField(s *firestore.DocumentSnapshot, path string) string {
	v, err := s.DataAt(path)
	if err != nil {
		return ""
	}
	str, _ := v.(string)
	return str
}

func intField(s *firestore.DocumentSnapshot, path string) int64 {
	v, err := s.DataAt(path)
	if err != nil {
		return 0
	}
	n, _ := v.(int64)
	return n
}

func strsField(s *firestore.DocumentSnapshot, path string) []string {
	v, err := s.DataAt(path)
	if err != nil {
		return nil
	}
	raw, _ := v.([]interface{})
	out := make([]string, 0, len(raw))
	for _, x := range raw {
		if str, ok := x.(string); ok {
			out = append(out, str)
		}
	}
	return out
}

// assertGraphInvariants is the entry point for every emulator scenario (and the T25 drill): it loads the
// whole graph state and fails t with every violated ADR-0008 D3 invariant. Uses t.Errorf, so it can also be
// called from a t.Cleanup.
func assertGraphInvariants(t *testing.T, client *firestore.Client) {
	t.Helper()
	st, err := loadGraphState(context.Background(), client)
	if err != nil {
		t.Errorf("graph invariant checker: %v", err)
		return
	}
	if violations := graphInvariantViolations(st); len(violations) > 0 {
		t.Errorf("graph invariants violated (ADR-0008 D3):\n  %s", strings.Join(violations, "\n  "))
	}
}

// TestGraphInvariantChecker_DetectsEveryViolation proves the checker can fail: one corrupted state per
// invariant, and a clean state (including the overflow exemption and padded caps) that passes.
func TestGraphInvariantChecker_DetectsEveryViolation(t *testing.T) {
	clean := func() graphState {
		return graphState{
			Edges: map[string][2]string{"a_b": {"a", "b"}},
			Graphs: map[string]graphDocState{
				"a": {Following: []string{"b"}},
				"b": {},
				"c": {},
			},
			Users: map[string]userCounters{"a": {Following: 1}, "b": {Followers: 1}, "c": {}},
		}
	}
	blockedPair := func() graphState { // c blocks b, no edges between them
		st := clean()
		st.Graphs["c"] = graphDocState{Blocked: []string{"b"}}
		st.Graphs["b"] = graphDocState{BlockedBy: []string{"c"}}
		return st
	}

	tests := []struct {
		name   string
		mutate func() graphState
		want   string // substring of a violation; "" => must be clean
	}{
		{"clean", clean, ""},
		{"clean with block pair", blockedPair, ""},
		{"clean overflow exemption", func() graphState {
			st := blockedPair()
			g := st.Graphs["b"]
			g.BlockedBy, g.BlockedByOverflow = nil, true // c's entry was skipped at the cap
			st.Graphs["b"] = g
			return st
		}, ""},
		{"clean padded caps", func() graphState {
			st := clean()
			g := st.Graphs["c"]
			g.Following = []string{seedPadPrefix + "1", seedPadPrefix + "2"}
			st.Graphs["c"] = g
			return st
		}, ""},
		{"I1 following entry without edge doc", func() graphState {
			st := clean()
			g := st.Graphs["c"]
			g.Following = []string{"a"}
			st.Graphs["c"] = g
			return st
		}, "I1"},
		{"I1 edge doc without following entry", func() graphState {
			st := clean()
			st.Graphs["a"] = graphDocState{}
			return st
		}, "I1"},
		{"I2 followersCount drift", func() graphState {
			st := clean()
			st.Users["b"] = userCounters{Followers: 2}
			return st
		}, "followersCount"},
		{"I2 followingCount drift", func() graphState {
			st := clean()
			st.Users["a"] = userCounters{Following: 0}
			return st
		}, "followingCount"},
		{"I3 blocked without blockedBy", func() graphState {
			st := blockedPair()
			st.Graphs["b"] = graphDocState{}
			return st
		}, "missing from graph/b.blockedBy"},
		{"I3 blockedBy without blocked", func() graphState {
			st := blockedPair()
			st.Graphs["c"] = graphDocState{}
			return st
		}, "is not in graph/c.blocked"},
		{"I3 blockedBy without blocked even with overflow", func() graphState {
			st := blockedPair()
			st.Graphs["c"] = graphDocState{}
			g := st.Graphs["b"]
			g.BlockedByOverflow = true
			st.Graphs["b"] = g
			return st
		}, "is not in graph/c.blocked"},
		{"I4 edge survives a block", func() graphState {
			st := blockedPair()
			st.Edges["b_c"] = [2]string{"b", "c"}
			g := st.Graphs["b"]
			g.Following = []string{"c"}
			st.Graphs["b"] = g
			st.Users["b"] = userCounters{Followers: 1, Following: 1}
			st.Users["c"] = userCounters{Followers: 1}
			return st
		}, "I4"},
		{"S1 doc id mismatch", func() graphState {
			st := clean()
			st.Edges["a_b"] = [2]string{"a", "c"}
			return st
		}, "S1"},
		{"S2 duplicate array entry", func() graphState {
			st := clean()
			st.Graphs["c"] = graphDocState{Muted: []string{"a", "a"}}
			return st
		}, "twice"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := graphInvariantViolations(tt.mutate())
			if tt.want == "" {
				if len(got) != 0 {
					t.Fatalf("expected a clean state, got violations: %v", got)
				}
				return
			}
			for _, g := range got {
				if strings.Contains(g, tt.want) {
					return
				}
			}
			t.Fatalf("no violation containing %q; got %v", tt.want, got)
		})
	}
}
