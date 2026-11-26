package messaging

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

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

// A caller without a cut keeps today's key byte for byte (a deploy resets no counter); a cut appends a short tag of its
// Unix seconds, so each cut is a new counter; the tag never carries the uid.
func TestCapKeyAfterCut(t *testing.T) {
	const base = "uid-alice"
	if got := CapKeyAfterCut(base, time.Time{}); got != base {
		t.Fatalf("no cut: key = %q, want %q", got, base)
	}
	cut := time.Date(2026, 11, 26, 9, 30, 0, 0, time.UTC)
	got := CapKeyAfterCut(base, cut)
	if want := "uid-alice|c1795685400"; got != want {
		t.Fatalf("cut: key = %q, want %q", got, want)
	}
	if later := CapKeyAfterCut(base, cut.Add(time.Second)); later == got {
		t.Fatal("a later cut must give another key")
	}
	if tag := strings.TrimPrefix(CapKeyAfterCut("", cut), "|c"); tag != "1795685400" {
		t.Fatalf("tag = %q, want the cut's Unix seconds only", tag)
	}
}

// CommitCapKey: a nil reader and a failed lookup keep the base key (the failure is noted on the request line as a bool,
// never a time or a uid); a cut tags the base.
func TestCommitCapKey(t *testing.T) {
	cut := time.Date(2026, 11, 26, 9, 30, 0, 0, time.UTC)
	ctx, info := logger.WithRequestInfo(context.Background())
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

// The two service caps of CommitConversation start fresh after a session cut: a drain before the cut caps the caller, the
// cut gives new counters for both the per-conversation cap and the reset cap, and without a cut the per-conversation
// counter is the pre-PR key exactly (convCommitKey) and the reset counter the bare uid.
func TestCommit_ServiceCapsFreshAfterCut(t *testing.T) {
	r, convID := commitRig(t, 1, 1, func(r *rig) {
		r.limits.CommitsPerConversationPerDay = 1
		r.limits.ResetsPerDay = 1
	})
	cuts := &fakeCuts{cut: map[string]time.Time{}}
	r.svc.d.SessionCuts = cuts
	ctx := verifiedCtx()

	// Before any cut: the old keys, byte for byte.
	wantPair(t, r.mustCommit(t, alice, commitReq(ckey(1), convID, 1, 1, "c")), 1, 2)
	if got := r.svc.convCommits.Spent(convCommitKey(alice, convID)); got != 1 {
		t.Fatalf("pre-cut per-conversation counter under convCommitKey = %d, want 1", got)
	}
	_, err := r.svc.Commit(ctx, alice, commitReq(ckey(2), convID, 1, 2, "drained"))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	// Spend the reset cap under the bare uid (the reset cap is drawn after the per-conversation cap, so use another
	// conversation id, unknown: it counts and then answers NOT_FOUND).
	unknown := ConversationID(alice, "uid-nobody")
	_, _ = r.svc.Commit(ctx, alice, resetReq(ckey(3), unknown, 1, "r", devBob1))
	if got := r.svc.resets.Spent(alice); got != 1 {
		t.Fatalf("pre-cut reset counter under the uid = %d, want 1", got)
	}

	// The cut: both counters start fresh.
	cut := r.now.Add(-time.Minute)
	cuts.cut[alice] = cut
	wantPair(t, r.mustCommit(t, alice, commitReq(ckey(4), convID, 1, 2, "after cut")), 1, 3)
	if got := r.svc.convCommits.Spent(convCommitKey(alice, convID) + CapKeyAfterCut("", cut)); got != 1 {
		t.Errorf("post-cut per-conversation counter = %d, want 1", got)
	}
	_, err = r.svc.Commit(ctx, alice, resetReq(ckey(5), ConversationID(alice, "uid-nobody-2"), 1, "r", devBob1))
	if err == nil {
		t.Fatal("reset of an unknown conversation answered nil")
	}
	if got := r.svc.resets.Spent(CapKeyAfterCut(alice, cut)); got != 1 {
		t.Errorf("post-cut reset counter = %d, want 1 (a fresh counter, drawn once)", got)
	}
	// The post-cut counters cap in turn; the peer is untouched throughout.
	_, err = r.svc.Commit(ctx, alice, commitReq(ckey(6), convID, 1, 3, "again"))
	wantCapLimit(t, err, limitCommitsPerConvDaily)
	wantPair(t, r.mustCommit(t, bob, commitReq(ckey(7), convID, 1, 3, "bob")), 1, 4)
}
