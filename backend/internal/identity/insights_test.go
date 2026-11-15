package identity

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

type insightsFlags map[string]bool // uid -> creator_insights on

func (f insightsFlags) Enabled(uid, name string) bool { return name == CreatorInsightsFlag && f[uid] }

// fakeDailyStats serves ReadDailyStats from a map by day and records the calls.
type fakeDailyStats struct {
	byDay map[string]DailyStats
	err   error
	calls []string // uids
	days  [][]string
}

func (f *fakeDailyStats) ReadDailyStats(_ context.Context, uid string, days []string) ([]DailyStats, error) {
	f.calls = append(f.calls, uid)
	f.days = append(f.days, days)
	if f.err != nil {
		return nil, f.err
	}
	out := make([]DailyStats, len(days))
	for i, d := range days {
		out[i] = f.byDay[d]
		out[i].Date = d
	}
	return out, nil
}

type fakeTopPosts struct {
	posts []TopPost
	err   error
	uids  []string
}

func (f *fakeTopPosts) TopPostsByViews(_ context.Context, uid string, limit int) ([]TopPost, error) {
	f.uids = append(f.uids, uid)
	if limit != MaxTopPosts {
		panic("limit")
	}
	return f.posts, f.err
}

// insightsNow is 2026-11-15 12:00 IST.
var insightsNow = time.Date(2026, 11, 15, 6, 30, 0, 0, time.UTC)

func newInsights(st *fakeDailyStats, tp *fakeTopPosts, on ...string) CreatorInsightsService {
	fl := insightsFlags{}
	for _, u := range on {
		fl[u] = true
	}
	d := InsightsDeps{Flags: fl, Stats: st, Now: func() time.Time { return insightsNow }}
	if tp != nil {
		d.TopPosts = tp
	}
	return NewCreatorInsights(d)
}

// TestCreatorInsights_FlagOffBeforeAnyRead: off for the caller is FEATURE_DISABLED feature=creator_insights and reads
// nothing; on for one caller only answers that caller.
func TestCreatorInsights_FlagOffBeforeAnyRead(t *testing.T) {
	st, tp := &fakeDailyStats{}, &fakeTopPosts{}
	s := newInsights(st, tp, "on-user")
	_, err := s.GetCreatorInsights(context.Background(), "off-user", 28)
	_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", CreatorInsightsFlag)
	if len(st.calls) != 0 || len(tp.uids) != 0 {
		t.Fatalf("flag off read stats %v / top posts %v", st.calls, tp.uids)
	}
	if _, err := NewCreatorInsights(InsightsDeps{Stats: st}).GetCreatorInsights(context.Background(), "on-user", 0); err == nil {
		t.Fatal("no flag checker must read as off")
	}
	if _, err := s.GetCreatorInsights(context.Background(), "on-user", 0); err != nil {
		t.Fatalf("flag on: %v", err)
	}
	if len(st.calls) != 1 || st.calls[0] != "on-user" || tp.uids[0] != "on-user" {
		t.Fatalf("reads went to %v / %v, want the caller only", st.calls, tp.uids)
	}
}

// TestCreatorInsights_Window: 0 is 28, 1..28 are accepted, anything else is VALIDATION before any read; the days read
// are 2 x window IST day keys, oldest first, ending today.
func TestCreatorInsights_Window(t *testing.T) {
	for _, tc := range []struct {
		in, want int
		ok       bool
	}{{0, 28, true}, {28, 28, true}, {7, 7, true}, {1, 1, true}, {29, 0, false}, {-1, 0, false}, {365, 0, false}} {
		st := &fakeDailyStats{}
		got, err := newInsights(st, nil, "u").GetCreatorInsights(context.Background(), "u", tc.in)
		if !tc.ok {
			_ = wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "window_days")
			if len(st.calls) != 0 {
				t.Errorf("window %d: invalid window read stats", tc.in)
			}
			continue
		}
		if err != nil || got.WindowDays != tc.want || len(got.Days) != tc.want {
			t.Fatalf("window %d: %+v, %v; want %d days", tc.in, got, err, tc.want)
		}
		days := st.days[0]
		if len(days) != 2*tc.want || days[len(days)-1] != "20261115" || got.Days[len(got.Days)-1].Date != "20261115" {
			t.Fatalf("window %d: days %v", tc.in, days)
		}
		if tc.want == 28 && (days[0] != "20260921" || days[27] != "20261018" || days[28] != "20261019") {
			t.Fatalf("days %s..%s|%s, want 20260921..20261018|20261019", days[0], days[27], days[28])
		}
	}
}

// TestInsightsDays_ISTRollover: the last day key is the IST day of now, also just after 18:30 UTC.
func TestInsightsDays_ISTRollover(t *testing.T) {
	d := insightsDays(time.Date(2026, 11, 15, 18, 30, 0, 0, time.UTC), 3)
	if d[0] != "20261114" || d[2] != "20261116" {
		t.Fatalf("days = %v", d)
	}
}

// TestCreatorInsights_Aggregates: 28-day totals and the previous 28 days, % change, a negative day clamped to 0, empty
// data all zeros with no % change.
func TestCreatorInsights_Aggregates(t *testing.T) {
	st := &fakeDailyStats{byDay: map[string]DailyStats{
		// previous window (2026-09-21 .. 2026-10-18)
		"20260921": {Impressions: 40, Engagements: 4, FollowersGained: 1},
		"20261018": {Impressions: 60, Engagements: 6, FollowersLost: 1},
		// current window (2026-10-19 .. 2026-11-15)
		"20261019": {Impressions: 100, Engagements: 3, FollowersGained: 4},
		"20261101": {Impressions: 50, Engagements: -2, FollowersLost: 1}, // undos outweigh: clamped to 0
		"20261115": {Impressions: 0, Engagements: 2, FollowersGained: 1},
		"20260901": {Impressions: 999}, // outside both windows: never read
	}}
	got, err := newInsights(st, nil, "u").GetCreatorInsights(context.Background(), "u", 0)
	if err != nil {
		t.Fatal(err)
	}
	if want := (InsightsTotals{Impressions: 150, Engagements: 5, FollowersGained: 5, FollowersLost: 1}); got.Current != want {
		t.Errorf("current = %+v, want %+v", got.Current, want)
	}
	if want := (InsightsTotals{Impressions: 100, Engagements: 10, FollowersGained: 1, FollowersLost: 1}); got.Previous != want {
		t.Errorf("previous = %+v, want %+v", got.Previous, want)
	}
	if got.ImpressionsChangePct == nil || math.Abs(*got.ImpressionsChangePct-50) > 1e-9 {
		t.Errorf("impressions change = %v, want 50", got.ImpressionsChangePct)
	}
	if got.EngagementsChangePct == nil || math.Abs(*got.EngagementsChangePct+50) > 1e-9 {
		t.Errorf("engagements change = %v, want -50", got.EngagementsChangePct)
	}
	for _, d := range got.Days {
		if d.Date == "20261101" && (d.Engagements != 0 || d.Impressions != 50) {
			t.Errorf("clamped day = %+v", d)
		}
	}

	empty, err := newInsights(&fakeDailyStats{}, &fakeTopPosts{}, "u").GetCreatorInsights(context.Background(), "u", 0)
	if err != nil {
		t.Fatal(err)
	}
	if empty.Current != (InsightsTotals{}) || empty.Previous != (InsightsTotals{}) || empty.ImpressionsChangePct != nil ||
		empty.EngagementsChangePct != nil || len(empty.Days) != 28 || len(empty.TopPosts) != 0 {
		t.Fatalf("empty = %+v", empty)
	}
}

// TestCreatorInsights_TopPosts: the posts as read (at most 5); a missing index degrades to none; another error fails.
func TestCreatorInsights_TopPosts(t *testing.T) {
	six := make([]TopPost, 6)
	for i := range six {
		six[i] = TopPost{ID: string(rune('a' + i)), ViewCount: int64(10 - i)}
	}
	got, err := newInsights(&fakeDailyStats{}, &fakeTopPosts{posts: six}, "u").GetCreatorInsights(context.Background(), "u", 0)
	if err != nil || len(got.TopPosts) != MaxTopPosts || got.TopPosts[0].ID != "a" {
		t.Fatalf("top posts = %+v, %v", got.TopPosts, err)
	}
	got, err = newInsights(&fakeDailyStats{}, &fakeTopPosts{err: ErrTopPostsUnavailable}, "u").GetCreatorInsights(context.Background(), "u", 0)
	if err != nil || len(got.TopPosts) != 0 || len(got.Days) != 28 {
		t.Fatalf("index missing: %+v, %v; want stats and no top posts", got, err)
	}
	if _, err := newInsights(&fakeDailyStats{}, &fakeTopPosts{err: errors.New("boom")}, "u").GetCreatorInsights(context.Background(), "u", 0); err == nil {
		t.Fatal("a top-posts failure other than the index must fail the call")
	}
	if _, err := newInsights(&fakeDailyStats{err: errors.New("boom")}, nil, "u").GetCreatorInsights(context.Background(), "u", 0); err == nil {
		t.Fatal("a stats read failure must fail the call")
	}
}

// recordingInsights records the uid the handler passes.
type recordingInsights struct {
	uid    string
	window int
}

func (r *recordingInsights) GetCreatorInsights(_ context.Context, uid string, w int) (CreatorInsights, error) {
	r.uid, r.window = uid, w
	pct := 12.5
	return CreatorInsights{
		WindowDays: 28, Current: InsightsTotals{Impressions: 9}, ImpressionsChangePct: &pct,
		Days:     []DailyStats{{Date: "20261115", Impressions: 9}},
		TopPosts: []TopPost{{ID: "p1", Text: "hi", ViewCount: 9, CreatedAt: insightsNow}},
	}, nil
}

// TestServer_GetCreatorInsights_CallerOnly: the handler answers the token's uid only (the request has no target),
// refuses an unauthenticated context, converts the answer, and without a wired service gates on the flag first.
func TestServer_GetCreatorInsights_CallerOnly(t *testing.T) {
	rec := &recordingInsights{}
	srv := NewServer(nil, WithCreatorInsights(rec))
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "caller"})
	resp, err := srv.GetCreatorInsights(ctx, connect.NewRequest(&identityv1.GetCreatorInsightsRequest{WindowDays: 7}))
	if err != nil {
		t.Fatal(err)
	}
	if rec.uid != "caller" || rec.window != 7 {
		t.Fatalf("service got uid %q window %d", rec.uid, rec.window)
	}
	m := resp.Msg
	if m.GetWindowDays() != 28 || m.GetCurrent().GetImpressions() != 9 || m.GetImpressionsChangePct() != 12.5 || m.EngagementsChangePct != nil ||
		len(m.GetDays()) != 1 || m.GetDays()[0].GetDate() != "20261115" || len(m.GetTopPosts()) != 1 || m.GetTopPosts()[0].GetPostId() != "p1" ||
		!m.GetTopPosts()[0].GetCreatedAt().AsTime().Equal(insightsNow) {
		t.Fatalf("response = %v", m)
	}
	_, err = srv.GetCreatorInsights(context.Background(), connect.NewRequest(&identityv1.GetCreatorInsightsRequest{}))
	_ = wantAPIErr(t, err, connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
	if rec.uid != "caller" {
		t.Fatal("an unauthenticated call reached the service")
	}

	bare := NewServer(nil, WithFlagChecker(insightsFlags{"caller": true}))
	_, err = bare.GetCreatorInsights(authn.WithClaims(context.Background(), authn.Claims{UID: "other"}), connect.NewRequest(&identityv1.GetCreatorInsightsRequest{}))
	_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", CreatorInsightsFlag)
	if _, err := bare.GetCreatorInsights(ctx, connect.NewRequest(&identityv1.GetCreatorInsightsRequest{})); connect.CodeOf(err) != connect.CodeUnimplemented {
		t.Fatalf("not wired: %v, want Unimplemented", err)
	}
}
