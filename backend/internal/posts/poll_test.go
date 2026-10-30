package posts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

// testPollLimits are the config defaults (POLL_MAX_CHOICES 4, POLL_CHOICE_MAX_CODEPOINTS 25, 5 min to 7 days).
var testPollLimits = PollLimits{MaxChoices: 4, ChoiceMaxCodepoints: 25, MinDuration: 5 * time.Minute, MaxDuration: 7 * 24 * time.Hour}

func goodPoll() *PollInput { return &PollInput{Choices: []string{"Yes", "No"}, DurationMinutes: 1440} }

type pollRulesFixture struct {
	Limits struct {
		MaxChoices          int `json:"max_choices"`
		ChoiceMaxCodepoints int `json:"choice_max_codepoints"`
		MinDurationMinutes  int `json:"min_duration_minutes"`
		MaxDurationMinutes  int `json:"max_duration_minutes"`
	} `json:"limits"`
	Cases []struct {
		Name            string   `json:"name"`
		Choices         []string `json:"choices"`
		DurationMinutes int32    `json:"duration_minutes"`
		Valid           bool     `json:"valid"`
		Stored          []string `json:"stored"`
	} `json:"cases"`
}

// TestPollRules_SharedFixture runs every row of testdata/poll_rules.json (the same rows the Dart validator runs) through
// validatePoll with the fixture's own limits.
func TestPollRules_SharedFixture(t *testing.T) {
	t.Parallel()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "poll_rules.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx pollRulesFixture
	if err := json.Unmarshal(b, &fx); err != nil {
		t.Fatal(err)
	}
	l := PollLimits{
		MaxChoices: fx.Limits.MaxChoices, ChoiceMaxCodepoints: fx.Limits.ChoiceMaxCodepoints,
		MinDuration: time.Duration(fx.Limits.MinDurationMinutes) * time.Minute, MaxDuration: time.Duration(fx.Limits.MaxDurationMinutes) * time.Minute,
	}
	if l != testPollLimits {
		t.Fatalf("fixture limits %+v differ from the config defaults %+v", l, testPollLimits)
	}
	if len(fx.Cases) < 20 {
		t.Fatalf("only %d fixture rows", len(fx.Cases))
	}
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			t.Parallel()
			d, err := validatePoll(l, &PollInput{Choices: c.Choices, DurationMinutes: c.DurationMinutes})
			if c.Valid {
				if err != nil {
					t.Fatalf("want valid, got %v", err)
				}
				if !reflect.DeepEqual(d.Options, c.Stored) || d.DurationMin != int(c.DurationMinutes) {
					t.Fatalf("stored %q dur %d, want %q dur %d", d.Options, d.DurationMin, c.Stored, c.DurationMinutes)
				}
				return
			}
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "poll" {
				t.Fatalf("field = %q, want poll", ae.Metadata["field"])
			}
		})
	}
}

// TestPollLimits_ZeroValueRejectsEveryPoll: an unwired or zero limit fails closed instead of opening an unbounded poll.
func TestPollLimits_ZeroValueRejectsEveryPoll(t *testing.T) {
	t.Parallel()
	for name, l := range map[string]PollLimits{
		"zero":            {},
		"one choice max":  {MaxChoices: 1, ChoiceMaxCodepoints: 25, MinDuration: time.Minute, MaxDuration: time.Hour},
		"over structural": {MaxChoices: 5, ChoiceMaxCodepoints: 25, MinDuration: time.Minute, MaxDuration: time.Hour},
		"no duration":     {MaxChoices: 4, ChoiceMaxCodepoints: 25},
		"max below min":   {MaxChoices: 4, ChoiceMaxCodepoints: 25, MinDuration: time.Hour, MaxDuration: time.Minute},
	} {
		if _, err := validatePoll(l, goodPoll()); err == nil {
			t.Errorf("%s: a poll was accepted", name)
		}
	}
}

// TestCreate_PollValidation drives the service: every refusal is VALIDATION field=poll with 0 reads, 0 writes and no repo call
// (ADR-0029 D1), and the combinations are refused whichever way they are reached.
func TestCreate_PollValidation(t *testing.T) {
	t.Parallel()
	base := func(mod func(*CreateInput)) CreateInput {
		in := CreateInput{IdempotencyKey: key1, Text: "Which?", Poll: goodPoll(), PollsEnabled: true, MediaEnabled: true, RepliesEnabled: true, QuotesEnabled: true}
		mod(&in)
		return in
	}
	tests := []struct {
		name string
		in   CreateInput
	}{
		{"five choices", base(func(in *CreateInput) { in.Poll.Choices = []string{"a", "b", "c", "d", "e"} })},
		{"26 code points", base(func(in *CreateInput) { in.Poll.Choices = []string{strings.Repeat("x", 26), "b"} })},
		{"duplicate Yes/yes", base(func(in *CreateInput) { in.Poll.Choices = []string{"Yes", "yes"} })},
		{"4 minutes", base(func(in *CreateInput) { in.Poll.DurationMinutes = 4 })},
		{"8 days", base(func(in *CreateInput) { in.Poll.DurationMinutes = 8 * 24 * 60 })},
		{"empty poll message", base(func(in *CreateInput) { in.Poll = &PollInput{} })},
		{"with media", base(func(in *CreateInput) { in.MediaIDs = []string{mid1} })},
		{"with alt text only", base(func(in *CreateInput) { in.MediaAltTexts = []string{"x"} })},
		{"reply", base(func(in *CreateInput) { in.ReplyToPostID = rReply1 })},
		{"quote", base(func(in *CreateInput) { in.QuoteOfPostID = rReply1 })},
		{"empty text", base(func(in *CreateInput) { in.Text = "" })},
		{"blank text", base(func(in *CreateInput) { in.Text = " ​ " })},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newCreateEnv()
			_, c, err := e.create(tt.in)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "poll" || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("field=%q reads=%d writes=%d creates=%d, want poll and nothing touched", ae.Metadata["field"], c.Reads(), c.Writes(), e.repo.createCalls)
			}
		})
	}
}

// TestCreate_PollStored: a valid poll is stored in the same write (the fake charges the root-post 2 reads and 4 writes, so
// +0/+0), the labels are normalised, closesAt = createdAt + duration from the attempt (never the client), counts are all 0,
// and the response carries the poll. The author's response shows the per-choice counts.
func TestCreate_PollStored(t *testing.T) {
	t.Parallel()
	e := newCreateEnv()
	p, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "Which?", PollsEnabled: true,
		Poll: &PollInput{Choices: []string{" Yes ", "No", "Maybe"}, DurationMinutes: 1440}})
	if err != nil {
		t.Fatal(err)
	}
	if c.Reads() != 2 || c.Writes() != 4 {
		t.Fatalf("reads=%d writes=%d, want the root post's 2/4", c.Reads(), c.Writes())
	}
	if p.Poll == nil || !reflect.DeepEqual(p.Poll.Options, []string{"Yes", "No", "Maybe"}) || p.Poll.DurationMin != 1440 ||
		!p.Poll.ClosesAt.Equal(p.CreatedAt.Add(24*time.Hour)) || !reflect.DeepEqual(p.Poll.Counts, []int64{0, 0, 0}) || p.Poll.Total != 0 {
		t.Fatalf("poll = %+v (createdAt %v)", p.Poll, p.CreatedAt)
	}
	v := toProtoAt(p, testUID, p.CreatedAt).GetPoll()
	if len(v.Choices) != 3 || v.Choices[0].Label != "Yes" || v.Closed || !v.ResultsVisible || !v.ClosesAt.AsTime().Equal(p.Poll.ClosesAt) {
		t.Fatalf("author view = %v", v)
	}
	if g, err := e.svc.Get(googleCtx(t.Context(), testUID), p.ID); err != nil || g.Poll == nil || g.Poll.DurationMin != 1440 {
		t.Fatalf("get = %+v, %v", g, err)
	}
}

// TestCreate_PollRequestHash: the poll suffix follows ADR-0029 D2 and a request without a poll hashes byte for byte as today.
// The no-poll goldens are the canonical strings written out by hand, not built by the code under test.
func TestCreate_PollRequestHash(t *testing.T) {
	t.Parallel()
	sum := func(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
	goldens := []struct {
		name string
		got  string
		want string
	}{
		{"root", requestHashWithPoll("hi", "", "", nil, nil, ReplyPolicyEveryone, false, false, nil),
			sum(`v1|text="hi"|media=""|alts=""|reply=""|quote=""`)},
		{"media and alts", requestHashWithPoll("hi", "", "", []string{"1", "2"}, []string{"a", "b"}, ReplyPolicyEveryone, false, false, nil),
			sum(`v1|text="hi"|media="1,2"|alts="a\x1fb"|reply=""|quote=""`)}, // %q prints the separator as the text \x1f
		{"policy and labels", requestHashWithPoll("hi", "", "", nil, nil, ReplyPolicyFollowing, true, true, nil),
			sum(`v1|text="hi"|media=""|alts=""|reply=""|quote=""|policy=FOLLOWING|pp=1|ai=1`)},
		{"reply", requestHashWithPoll("hi", "7", "", nil, nil, ReplyPolicyEveryone, false, false, nil),
			sum(`v1|text="hi"|media=""|alts=""|reply="7"|quote=""`)},
	}
	for _, g := range goldens {
		if g.got != g.want {
			t.Errorf("%s: no-poll hash changed", g.name)
		}
	}
	if requestHash("hi", "", "", nil, nil, ReplyPolicyEveryone, false, false) != goldens[0].want {
		t.Error("requestHash changed")
	}
	d := &PollDraft{Options: []string{"Yes", "No"}, DurationMin: 1440}
	wantPoll := sum(`v1|text="hi"|media=""|alts=""|reply=""|quote=""|ai=1` + "|poll=2:" + sum("Yes\x1fNo") + "|dur=1440")
	if got := requestHashWithPoll("hi", "", "", nil, nil, ReplyPolicyEveryone, false, true, d); got != wantPoll {
		t.Errorf("poll hash = %s, want %s", got, wantPoll)
	}
	other := []*PollDraft{
		{Options: []string{"Yes", "Nope"}, DurationMin: 1440}, {Options: []string{"Yes", "No"}, DurationMin: 60},
		{Options: []string{"Yes", "No", "Maybe"}, DurationMin: 1440}, {Options: []string{"No", "Yes"}, DurationMin: 1440},
	}
	seen := map[string]bool{requestHashWithPoll("hi", "", "", nil, nil, ReplyPolicyEveryone, false, false, d): true}
	for _, o := range other {
		h := requestHashWithPoll("hi", "", "", nil, nil, ReplyPolicyEveryone, false, false, o)
		if seen[h] {
			t.Errorf("poll %+v collides", o)
		}
		seen[h] = true
	}
}

// TestCreate_PollReplayAndReuse: the same key with the same poll replays, with another poll it is IDEMPOTENCY_KEY_REUSED.
func TestCreate_PollReplayAndReuse(t *testing.T) {
	t.Parallel()
	e := newCreateEnv()
	in := CreateInput{IdempotencyKey: key1, Text: "Which?", PollsEnabled: true, Poll: goodPoll()}
	first, _, err := e.create(in)
	if err != nil {
		t.Fatal(err)
	}
	again, c, err := e.create(in)
	if err != nil || again.ID != first.ID || c.Writes() != 0 {
		t.Fatalf("replay: %v %v writes=%d", again, err, c.Writes())
	}
	in.Poll = &PollInput{Choices: []string{"Yes", "Maybe"}, DurationMinutes: 1440}
	_, _, err = e.create(in)
	wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	in.Poll = nil
	_, _, err = e.create(in)
	wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

// Far from "now" on both sides, so the tests never depend on the clock edge.
var (
	pollOpen   = time.Now().Add(24 * time.Hour)
	pollClosed = time.Now().Add(-24 * time.Hour)
)

func pollPost(closes time.Time, counts ...int64) *Post {
	var total int64
	for _, c := range counts {
		total += c
	}
	return &Post{ID: "100", AuthorID: "author", Kind: KindPost, Poll: &Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: closes, Counts: counts, Total: total}}
}

// TestToView_PollRedaction: hidden is the default; the author and a closed poll show the counts; total_votes is always real;
// the bytes of a hidden poll are identical whether the real count is 0 or 57; and the cached post is never written to.
func TestToView_PollRedaction(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		post        *Post
		viewer      string
		wantVisible bool
		wantClosed  bool
		wantVotes   []int64
	}{
		{"stranger, open", pollPost(pollOpen, 5, 7), "viewer", false, false, []int64{0, 0}},
		{"anonymous empty viewer, open", pollPost(pollOpen, 5, 7), "", false, false, []int64{0, 0}},
		{"author, open", pollPost(pollOpen, 5, 7), "author", true, false, []int64{5, 7}},
		{"stranger, closed", pollPost(pollClosed, 5, 7), "viewer", true, true, []int64{5, 7}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			beforeCounts := append([]int64(nil), tt.post.Poll.Counts...)
			v := ToView(tt.post, ViewerSet{}, tt.viewer).GetPost().GetPoll()
			if v.ResultsVisible != tt.wantVisible || v.Closed != tt.wantClosed || v.TotalVotes != tt.post.Poll.Total {
				t.Fatalf("visible=%v closed=%v total=%d", v.ResultsVisible, v.Closed, v.TotalVotes)
			}
			for i, c := range v.Choices {
				if c.Votes != tt.wantVotes[i] {
					t.Errorf("choice %d votes = %d, want %d", i, c.Votes, tt.wantVotes[i])
				}
			}
			if !reflect.DeepEqual(beforeCounts, tt.post.Poll.Counts) {
				t.Fatal("the cached poll was modified")
			}
		})
	}
	a := proto.Clone(ToView(pollPost(pollOpen, 0, 0), ViewerSet{}, "viewer").GetPost().GetPoll()).(*postsv1.Poll)
	b := proto.Clone(ToView(pollPost(pollOpen, 57, 0), ViewerSet{}, "viewer").GetPost().GetPoll()).(*postsv1.Poll)
	a.TotalVotes, b.TotalVotes = 0, 0 // total_votes is shown on purpose; everything else must be identical
	ab, _ := proto.MarshalOptions{Deterministic: true}.Marshal(a)
	bb, _ := proto.MarshalOptions{Deterministic: true}.Marshal(b)
	if !reflect.DeepEqual(ab, bb) {
		t.Fatal("hidden poll bytes depend on the real counts")
	}
	if ToProto(pollPost(pollOpen, 5, 7)).GetPoll().GetResultsVisible() {
		t.Fatal("ToProto without a viewer must hide the counts")
	}
	if ToView(&Post{ID: "1"}, ViewerSet{}, "x").GetPost().GetPoll() != nil {
		t.Fatal("a post without a poll has no poll")
	}
}

// TestSnapshotOf_PollIsAFrozenDefinition: a quote or repost of a poll post embeds the labels and closing time only: every
// count 0, total 0, results never visible (ADR-0029 D5); the copy does not alias the original's slice; the ADR-0025 strips
// drop it.
func TestSnapshotOf_PollIsAFrozenDefinition(t *testing.T) {
	t.Parallel()
	orig := pollPost(pollOpen, 9, 3)
	orig.Author = AuthorSnapshot{UserID: "author", Handle: "a"}
	emb := snapshotOf(orig)
	if emb.Poll == nil || !reflect.DeepEqual(emb.Poll.Options, []string{"A", "B"}) || !emb.Poll.ClosesAt.Equal(orig.Poll.ClosesAt) {
		t.Fatalf("embedded poll = %+v", emb.Poll)
	}
	orig.Poll.Options[0] = "changed"
	if emb.Poll.Options[0] != "A" {
		t.Fatal("the embed aliases the original's labels")
	}
	if snapshotOf(&Post{ID: "2"}).Poll != nil {
		t.Fatal("a plain post embeds no poll")
	}

	q := NewRepostPost("9", time.Now(), AuthorSnapshot{UserID: "u"}, 1, pollPost(pollClosed, 9, 3))
	v := ToView(q, ViewerSet{}, "author") // even the original's author sees an embed without counts
	ep := v.GetPost().GetEmbedded().GetPoll()
	if ep == nil || ep.TotalVotes != 0 || ep.ResultsVisible || !ep.Closed || ep.Choices[0].Votes != 0 || ep.Choices[0].Label != "A" {
		t.Fatalf("embedded poll view = %v", ep)
	}
	if v.GetPost().GetPoll() != nil {
		t.Fatal("a REPOST row has no poll of its own")
	}

	ApplyEmbedState(v, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED)
	if v.GetPost().GetEmbedded().GetPoll() != nil {
		t.Fatal("a PROTECTED embed kept its poll")
	}
	pv := ToView(pollPost(pollOpen, 1, 1), ViewerSet{}, "author")
	ApplyWithheld(pv)
	if pv.GetPost().GetPoll() != nil {
		t.Fatal("a withheld row kept its poll")
	}
}

// TestPollDoc_RoundTrip: the stored shape keys counts "0".."n-1", all present, and survives toDoc/toPost; a plain post has no
// poll field.
func TestPollDoc_RoundTrip(t *testing.T) {
	t.Parallel()
	p := pollPost(pollOpen, 4, 0)
	p.Poll.ClosesAt = p.Poll.ClosesAt.Truncate(time.Millisecond)
	d := toDoc(p)
	if d.Poll == nil || !reflect.DeepEqual(d.Poll.Counts, map[string]int64{"0": 4, "1": 0}) || d.Poll.Total != 4 {
		t.Fatalf("doc poll = %+v", d.Poll)
	}
	d.CreatedAt = time.Now()
	back := d.toPost("100")
	if !reflect.DeepEqual(back.Poll.Counts, []int64{4, 0}) || !reflect.DeepEqual(back.Poll.Options, []string{"A", "B"}) || back.Poll.Total != 4 || !back.Poll.ClosesAt.Equal(p.Poll.ClosesAt) {
		t.Fatalf("round trip = %+v", back.Poll)
	}
	if toDoc(&Post{ID: "1"}).Poll != nil {
		t.Fatal("a plain post wrote a poll")
	}
	e := toDoc(NewRepostPost("9", time.Now(), AuthorSnapshot{UserID: "u"}, 1, pollPost(pollOpen, 1, 1)))
	if e.Embedded == nil || e.Embedded.Poll == nil || len(e.Embedded.Poll.Options) != 2 {
		t.Fatalf("embedded doc = %+v", e.Embedded)
	}
	if got := e.toPost("9").Embedded.Poll; got == nil || got.Options[1] != "B" {
		t.Fatalf("embedded round trip = %+v", got)
	}
}

// TestExport_PollShape: the author's own export names the poll only when there is one (ADR-0029 D8).
func TestExport_PollShape(t *testing.T) {
	t.Parallel()
	plain, _ := json.Marshal(exportedPost{ID: "1"})
	if strings.Contains(string(plain), "poll") {
		t.Fatalf("plain export changed: %s", plain)
	}
	set, _ := json.Marshal(exportedPost{ID: "1", Poll: &exportedPoll{Choices: []string{"A", "B"}, Counts: []int64{1, 2}, Total: 3}})
	if !strings.Contains(string(set), `"poll":{"choices":["A","B"]`) || !strings.Contains(string(set), `"counts":[1,2],"total":3`) {
		t.Fatalf("poll export = %s", set)
	}
}
