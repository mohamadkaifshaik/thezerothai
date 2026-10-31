package engagement

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

const retentionTTL = 30 * 24 * time.Hour

// retNow is after the Snowflake epoch by far; legacy entries use real post ids so the creation time decodes.
var retNow = time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)

func TestPollEntryExpiry(t *testing.T) {
	t.Parallel()
	closes := retNow.Add(-31 * 24 * time.Hour)
	tests := []struct {
		name    string
		entry   string
		wantOK  bool
		wantExp time.Time
	}{
		{"three part is closesAt plus ttl", pollEntry(pidA, 1, closes), true, closes.Add(retentionTTL)},
		{"unreadable closes is kept", pidA + ":1:abc", false, time.Time{}},
		{"no separator is kept", "junk", false, time.Time{}},
		{"two part with a bad post id is kept", "x:1", false, time.Time{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			exp, ok := pollEntryExpiry(tt.entry, retentionTTL)
			if ok != tt.wantOK || (ok && !exp.Equal(tt.wantExp)) {
				t.Fatalf("expiry = %v,%v want %v,%v", exp, ok, tt.wantExp, tt.wantOK)
			}
		})
	}
	// A two-part entry (before W6-29) expires at creation + 30 d + ttl: never early for a poll of at most 30 d.
	exp, ok := pollEntryExpiry(pidA+":1", retentionTTL)
	if !ok || exp.Before(time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("legacy expiry = %v,%v", exp, ok)
	}
}

func TestSplitPollVotes(t *testing.T) {
	t.Parallel()
	expired := pollEntry("1", 0, retNow.Add(-retentionTTL-time.Hour))
	atEdge := pollEntry("2", 0, retNow.Add(-retentionTTL)) // expires exactly now: gone
	live := pollEntry("3", 2, retNow.Add(-retentionTTL+time.Hour))
	open := pollEntry("4", 1, retNow.Add(time.Hour)) // an open poll is never touched
	tests := []struct {
		name         string
		in           []string
		ttl          time.Duration
		wantLive     []string
		wantExpiredN int
	}{
		{"mixed", []string{expired, live, atEdge, open, "junk"}, retentionTTL, []string{live, open, "junk"}, 2},
		{"ttl zero keeps everything", []string{expired}, 0, []string{expired}, 0},
		{"empty", nil, retentionTTL, nil, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			l, x := splitPollVotes(tt.in, tt.ttl, retNow)
			if strings.Join(l, ",") != strings.Join(tt.wantLive, ",") || len(x) != tt.wantExpiredN {
				t.Fatalf("live %v expired %v, want live %v expired %d", l, x, tt.wantLive, tt.wantExpiredN)
			}
		})
	}
}

func TestPollDueDay(t *testing.T) {
	t.Parallel()
	a := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	if pollDueDay(a) != pollDueDay(a.Add(23*time.Hour+59*time.Minute)) || pollDueDay(a) == pollDueDay(a.Add(-time.Second)) {
		t.Fatal("a due day is a UTC calendar day")
	}
	if got := dueDaysOf([]string{pollEntry("1", 0, a), pollEntry("2", 0, a), "junk"}, 0); len(got) != 1 {
		t.Fatalf("dueDaysOf = %v, want one distinct day", got)
	}
}

// An expired per-account entry is not returned (the viewer set, the cache) and is pruned once with a single field-level write.
func TestState_ExpiredPollEntryNotReturnedAndPruned(t *testing.T) {
	e := newPollEnv(t)
	gone := pollEntry(pidA, 1, e.now.Add(-retentionTTL-time.Minute))
	kept := pollEntry(pidB, 2, e.now.Add(-time.Hour)) // closed an hour ago: the vote doc is still there
	e.repo.loaded = UserLikes{Recent: []string{pidB}, PollVotes: []string{gone, kept}}
	vs := e.m.Viewer(e.ctx, "viewer")
	if _, ok := vs.PollChoice(&posts.Post{ID: pidA}); ok {
		t.Error("an expired entry is still returned")
	}
	if i, ok := vs.PollChoice(&posts.Post{ID: pidB}); !ok || i != 2 {
		t.Errorf("live entry = %d,%v, want 2,true", i, ok)
	}
	if len(e.pr.trims) != 1 || len(e.pr.trims[0]) != 1 || e.pr.trims[0][0] != gone {
		t.Fatalf("prune writes = %v, want one ArrayRemove of the expired string", e.pr.trims)
	}
	// Cached: no second load, no second write.
	_ = e.m.Viewer(e.ctx, "viewer")
	if e.repo.loads != 1 || len(e.pr.trims) != 1 {
		t.Errorf("loads %d prune writes %d, want 1 and 1", e.repo.loads, len(e.pr.trims))
	}
}

func TestState_PollPruneIsBestEffortAndHonoursReadonly(t *testing.T) {
	for _, tt := range []struct {
		name      string
		opt       pollEnvOpt
		trimErr   error
		wantTrims int
	}{
		{"write fails: still served", func(*Deps, *pollEnv) {}, errors.New("boom"), 1},
		{"readonly writes nothing", func(d *Deps, _ *pollEnv) { d.ReadOnly = true }, nil, 0},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newPollEnv(t, tt.opt)
			e.pr.trimErr = tt.trimErr
			e.repo.loaded = UserLikes{PollVotes: []string{pollEntry(pidA, 0, e.now.Add(-retentionTTL-time.Hour)), pollEntry(pidB, 1, e.now.Add(time.Hour))}}
			vs := e.m.Viewer(e.ctx, "viewer")
			if _, ok := vs.PollChoice(&posts.Post{ID: pidA}); ok {
				t.Error("expired entry returned")
			}
			if _, ok := vs.PollChoice(&posts.Post{ID: pidB}); !ok {
				t.Error("open poll vote lost")
			}
			if len(e.pr.trims) != tt.wantTrims {
				t.Errorf("prune writes = %d, want %d", len(e.pr.trims), tt.wantTrims)
			}
		})
	}
}

// A vote carries the closing time into the batch (the repo builds the entry and the due day from it).
func TestVotePoll_PassesClosesAt(t *testing.T) {
	e := newPollEnv(t)
	if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 1, 0); err != nil {
		t.Fatal(err)
	}
	if !e.pr.last.ClosesAt.Equal(e.closes) || !e.pr.last.ExpireAt.Equal(e.closes.Add(retentionTTL)) {
		t.Errorf("params = %+v, want ClosesAt %v and ExpireAt closes + ttl", e.pr.last, e.closes)
	}
}

type fakeExportSrc struct{}

func (fakeExportSrc) ExportPollVotesPage(context.Context, string, string, int) ([]ExportedPollVote, error) {
	return []ExportedPollVote{{PostID: pidA, Choice: 1, CreatedAt: retNow}}, nil
}

// The export lists the voter's current choice per poll from userLikes.pollVotes, without time, expired entries left out.
func TestPollVoteExporter_CurrentChoices(t *testing.T) {
	t.Parallel()
	live := pollEntry(pidA, 1, retNow.Add(-time.Hour))
	old := pollEntry(pidB, 0, retNow.Add(-retentionTTL-time.Hour))
	reads := 0
	load := func(context.Context, string) (UserLikes, error) {
		reads++
		return UserLikes{PollVotes: []string{old, live, "junk"}}, nil
	}
	var buf bytes.Buffer
	x := NewPollVoteExporter(fakeExportSrc{}).WithChoices(load, retentionTTL, func() time.Time { return retNow })
	if err := x.ExportUser(context.Background(), "u", &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		PollVotes      []map[string]any `json:"poll_votes"`
		CurrentChoices []map[string]any `json:"current_choices"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("not valid JSON: %v\n%s", err, buf.String())
	}
	if len(out.PollVotes) != 1 || len(out.CurrentChoices) != 1 || out.CurrentChoices[0]["postId"] != pidA || out.CurrentChoices[0]["choice"] != float64(1) {
		t.Fatalf("export = %s", buf.String())
	}
	if _, hasTime := out.CurrentChoices[0]["createdAt"]; hasTime || len(out.CurrentChoices[0]) != 2 {
		t.Errorf("a current choice carries only postId and choice: %v", out.CurrentChoices[0])
	}
	if reads != 1 {
		t.Errorf("userLikes loads = %d, want 1", reads)
	}
	// No votes at all: an empty list, never null.
	buf.Reset()
	empty := NewPollVoteExporter(fakeExportSrc{}).WithChoices(func(context.Context, string) (UserLikes, error) { return UserLikes{}, nil }, retentionTTL, nil)
	if err := empty.ExportUser(context.Background(), "u", &buf); err != nil || !strings.Contains(buf.String(), `"current_choices":[]`) {
		t.Fatalf("empty export = %q, err %v", buf.String(), err)
	}
	// A load failure fails the section (the job retries) instead of exporting less.
	bad := NewPollVoteExporter(fakeExportSrc{}).WithChoices(func(context.Context, string) (UserLikes, error) { return UserLikes{}, errors.New("down") }, retentionTTL, nil)
	if err := bad.ExportUser(context.Background(), "u", &bytes.Buffer{}); err == nil {
		t.Fatal("a failed userLikes read exported a partial section")
	}
}
