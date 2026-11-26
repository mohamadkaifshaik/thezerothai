package messaging

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fakeCuts answers a fixed cut per uid (zero = none), or err for everyone.
type fakeCuts struct {
	cut   map[string]time.Time
	err   error
	calls int
}

func (f *fakeCuts) SessionsValidAfter(_ context.Context, uid string) (time.Time, error) {
	f.calls++
	if f.err != nil {
		return time.Time{}, f.err
	}
	return f.cut[uid], nil
}

// sessionAt is a verified caller whose session signed in at authTime.
func sessionAt(authTime time.Time) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{SignInProvider: authn.SignInProviderGoogle, AuthTime: authTime})
}

// A caller without a cut keeps today's key byte for byte (a deploy resets no counter); a cut appends its IST calendar
// day, so two cuts on one IST day share a key (no renewal) and a cut on another day is another key. The tag never carries
// the uid or the time of day.
func TestCapKeyAfterCut(t *testing.T) {
	const base = "uid-alice"
	if got := CapKeyAfterCut(base, time.Time{}); got != base {
		t.Fatalf("no cut: key = %q, want %q", got, base)
	}
	cut := time.Date(2026, 11, 26, 9, 30, 0, 0, time.UTC) // 15:00 IST
	if got, want := CapKeyAfterCut(base, cut), "uid-alice|c20261126"; got != want {
		t.Fatalf("cut: key = %q, want %q", got, want)
	}
	for _, tc := range []struct {
		name string
		at   time.Time
		same bool
	}{
		{"a later cut the same IST day", cut.Add(8 * time.Hour), true},                       // 23:00 IST
		{"just before IST midnight", time.Date(2026, 11, 26, 18, 29, 59, 0, time.UTC), true}, // 23:59:59 IST
		{"IST midnight is the next day", time.Date(2026, 11, 26, 18, 30, 0, 0, time.UTC), false},
		{"the day before", cut.Add(-24 * time.Hour), false},
	} {
		if got := CapKeyAfterCut(base, tc.at) == CapKeyAfterCut(base, cut); got != tc.same {
			t.Errorf("%s: same key = %v, want %v", tc.name, got, tc.same)
		}
	}
}

// CommitCapKeyFor tags only a session that signed in at or after the cut; a pre-cut session, a zero auth_time and a
// caller without claims keep the base key.
func TestCommitCapKeyFor(t *testing.T) {
	cut := time.Date(2026, 11, 26, 9, 30, 0, 0, time.UTC)
	tagged := CapKeyAfterCut("b", cut)
	for _, tc := range []struct {
		name string
		ctx  context.Context
		cut  time.Time
		want string
	}{
		{"no cut", sessionAt(cut), time.Time{}, "b"},
		{"signed in at the cut (the remover)", sessionAt(cut), cut, tagged},
		{"signed in after the cut", sessionAt(cut.Add(time.Hour)), cut, tagged},
		{"signed in before the cut (globally off, or the stale window)", sessionAt(cut.Add(-time.Second)), cut, "b"},
		{"zero auth_time", sessionAt(time.Time{}), cut, "b"},
		{"no claims", context.Background(), cut, "b"},
	} {
		if got := CommitCapKeyFor(tc.ctx, "b", tc.cut); got != tc.want {
			t.Errorf("%s: %q, want %q", tc.name, got, tc.want)
		}
	}
}

// CommitCapKey: a nil reader and a failed lookup keep the base key (the failure is noted on the request line as a bool,
// never a time or a uid); a cut tags the base for a post-cut session.
func TestCommitCapKey(t *testing.T) {
	cut := time.Date(2026, 11, 26, 9, 30, 0, 0, time.UTC)
	ctx, info := logger.WithRequestInfo(sessionAt(cut))
	if got := CommitCapKey(ctx, nil, alice, "b"); got != "b" {
		t.Errorf("nil reader: %q, want b", got)
	}
	if got := CommitCapKey(ctx, &fakeCuts{cut: map[string]time.Time{}}, alice, "b"); got != "b" {
		t.Errorf("no cut: %q, want b", got)
	}
	if got := CommitCapKey(ctx, &fakeCuts{cut: map[string]time.Time{alice: cut}}, alice, "b"); got != CapKeyAfterCut("b", cut) {
		t.Errorf("cut: %q, want the tagged key", got)
	}
	if len(info.Fields()) != 0 {
		t.Fatalf("fields %v before any failure, want none", info.Fields())
	}
	if got := CommitCapKey(ctx, &fakeCuts{err: errors.New("down " + alice)}, alice, "b"); got != "b" {
		t.Errorf("failed lookup: %q, want b", got)
	}
	fields := info.Fields()
	if len(fields) != 1 || fields[0].Key != fieldCapCutUnknown || !fields[0].Value.Bool() {
		t.Fatalf("fields = %v, want only %s=true", fields, fieldCapCutUnknown)
	}
}

// The two service caps of CommitConversation start fresh after a session cut for a session that signed in at the cut: a
// drain before the cut caps the caller, the cut gives new counters for both the per-conversation cap and the reset cap,
// and without a cut the per-conversation counter is the pre-PR key exactly (convCommitKey) and the reset counter the bare
// uid. A pre-cut session stays on the drained counters.
func TestCommit_ServiceCapsFreshAfterCut(t *testing.T) {
	r, convID := commitRig(t, 1, 1, func(r *rig) {
		r.limits.CommitsPerConversationPerDay = 1
		r.limits.ResetsPerDay = 1
	})
	cuts := &fakeCuts{cut: map[string]time.Time{}}
	r.svc.d.SessionCuts = cuts
	cut := r.now.Add(-time.Minute)
	thief, owner := sessionAt(cut.Add(-time.Hour)), sessionAt(cut)

	// Before any cut: the old keys, byte for byte.
	if _, err := r.svc.Commit(thief, alice, commitReq(ckey(1), convID, 1, 1, "c")); err != nil {
		t.Fatal(err)
	}
	if got := r.svc.convCommits.Spent(convCommitKey(alice, convID)); got != 1 {
		t.Fatalf("pre-cut per-conversation counter under convCommitKey = %d, want 1", got)
	}
	_, err := r.svc.Commit(thief, alice, commitReq(ckey(2), convID, 1, 2, "drained"))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	// Spend the reset cap under the bare uid (on an unknown conversation id: it counts, then answers NOT_FOUND).
	if _, err := r.svc.Commit(thief, alice, resetReq(ckey(3), ConversationID(alice, "uid-nobody"), 1, "r", devBob1)); err == nil {
		t.Fatal("reset of an unknown conversation answered nil")
	}
	if got := r.svc.resets.Spent(alice); got != 1 {
		t.Fatalf("pre-cut reset counter under the uid = %d, want 1", got)
	}

	// The cut: the owner's session (signed in at the cut) draws on fresh counters for both caps.
	cuts.cut[alice] = cut
	resp, err := r.svc.Commit(owner, alice, commitReq(ckey(4), convID, 1, 2, "after cut"))
	if err != nil {
		t.Fatalf("the owner's commit after the cut: %v", err)
	}
	wantPair(t, resp, 1, 3)
	if got := r.svc.convCommits.Spent(convCommitKey(alice, convID) + CapKeyAfterCut("", cut)); got != 1 {
		t.Errorf("post-cut per-conversation counter = %d, want 1", got)
	}
	if _, err := r.svc.Commit(owner, alice, resetReq(ckey(5), ConversationID(alice, "uid-nobody-2"), 1, "r", devBob1)); err == nil {
		t.Fatal("reset of an unknown conversation answered nil")
	}
	if got := r.svc.resets.Spent(CapKeyAfterCut(alice, cut)); got != 1 {
		t.Errorf("post-cut reset counter = %d, want 1 (a fresh counter, drawn once)", got)
	}
	// A pre-cut session that still gets through (globally off) stays on the drained counter.
	_, err = r.svc.Commit(thief, alice, commitReq(ckey(6), convID, 1, 3, "thief"))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	// A second cut the same IST day renews nothing: the owner's new session is on the same, now spent, counter.
	cuts.cut[alice] = cut.Add(30 * time.Second)
	_, err = r.svc.Commit(sessionAt(cut.Add(30*time.Second)), alice, commitReq(ckey(7), convID, 1, 3, "again"))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	if cuts.calls == 0 {
		t.Error("the service never read the cut")
	}
}
