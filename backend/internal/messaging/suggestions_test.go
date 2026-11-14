package messaging

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	beaconsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

type fakeFollows struct {
	back  map[string]bool
	err   error
	asked [][]string
}

func (f *fakeFollows) FollowersAmong(_ context.Context, _ string, cands []string) (map[string]bool, error) {
	f.asked = append(f.asked, cands)
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]bool{}
	for _, c := range cands {
		if f.back[c] {
			out[c] = true
		}
	}
	return out, nil
}

type fakePlans struct {
	mates []PlanMate
	err   error
	since time.Time
	calls int
}

func (f *fakePlans) RecentCoParticipants(_ context.Context, _ string, since time.Time, _, _ int) ([]PlanMate, error) {
	f.calls++
	f.since = since
	return f.mates, f.err
}

type fakeCommunityMates struct {
	mates []CommunityMate
	err   error
	calls int
}

func (f *fakeCommunityMates) RecentCoMembers(context.Context, string, int) ([]CommunityMate, error) {
	f.calls++
	return f.mates, f.err
}

const me = "uid-me"

type suggestRig struct {
	svc    *service
	repo   *fakeRepo
	social *fakeSocial
	profs  *fakeProfiles
	follow *fakeFollows
	plans  *fakePlans
	comm   *fakeCommunityMates
	now    time.Time
}

// newSuggestRig: messaging and dm_suggestions on for everyone, beacons and communities on, dm_policy on for everyone, and every
// uid in active an ACTIVE profile. specs replace the default registry when given.
func newSuggestRig(t *testing.T, active []string, specs ...flags.Spec) *suggestRig {
	t.Helper()
	if len(specs) == 0 {
		specs = []flags.Spec{
			{Name: FlagName, Mode: flags.On}, {Name: SuggestionsFlagName, Mode: flags.On}, {Name: beaconsFlagName, Mode: flags.On},
			{Name: communitiesFlagName, Mode: flags.On}, {Name: identity.DMPolicyFlag, Mode: flags.On},
		}
	}
	r := &suggestRig{
		repo: &fakeRepo{convs: map[string]ConvDoc{}, entries: map[string][]EntryRow{}}, social: &fakeSocial{snaps: map[string]graph.Snapshot{}},
		profs: &fakeProfiles{profiles: map[string]identity.Profile{}}, follow: &fakeFollows{back: map[string]bool{}},
		plans: &fakePlans{}, comm: &fakeCommunityMates{}, now: time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC),
	}
	for _, u := range active {
		r.profs.profiles[u] = activeProfile(u, u, r.now.Add(-90*24*time.Hour))
	}
	r.svc = New(flags.NewRegistry(specs...), Deps{
		Repo: r.repo, Social: r.social, Profiles: r.profs, CursorKey: testCursorKey, Now: func() time.Time { return r.now },
		Suggestions: SuggestionDeps{Follows: r.follow, Plans: r.plans, Communities: r.comm},
	}).(*service)
	return r
}

func (r *suggestRig) inbox(peers ...string) {
	for i, p := range peers {
		r.repo.entries[entryKey(me, dmInboxCollection)] = append(r.repo.entries[entryKey(me, dmInboxCollection)], EntryRow{
			ID: "conv-" + p, EntryDoc: EntryDoc{PeerID: p, LastMessageAt: r.now.Add(-time.Duration(i) * time.Minute)},
		})
	}
}

func (r *suggestRig) list(t *testing.T, limit int32) []*messagingv1.MessageSuggestion {
	t.Helper()
	resp, err := r.svc.ListSuggestions(context.Background(), me, &messagingv1.ListMessageSuggestionsRequest{Limit: limit})
	if err != nil {
		t.Fatal(err)
	}
	return resp.GetSuggestions()
}

func suggestedUIDs(rows []*messagingv1.MessageSuggestion) []string {
	out := make([]string, len(rows))
	for i, s := range rows {
		out[i] = s.GetUser().GetUserId()
	}
	return out
}

// TestSuggestions_Flags: messaging off, then dm_suggestions off, each FEATURE_DISABLED naming that flag before any read.
func TestSuggestions_Flags(t *testing.T) {
	for _, tc := range []struct {
		name string
		on   []string
		want string
	}{
		{"messaging off", []string{SuggestionsFlagName}, FlagName},
		{"dm_suggestions off", []string{FlagName}, SuggestionsFlagName},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var specs []flags.Spec
			for _, n := range tc.on {
				specs = append(specs, flags.Spec{Name: n, Mode: flags.On})
			}
			r := newSuggestRig(t, nil, specs...)
			_, err := r.svc.ListSuggestions(context.Background(), me, &messagingv1.ListMessageSuggestionsRequest{})
			code, reason, meta := reasonOf(t, err)
			if code != connect.CodeFailedPrecondition || reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != tc.want {
				t.Fatalf("got %v %v %v", code, reason, meta)
			}
			if r.social.calls+r.repo.lists+r.profs.calls != 0 {
				t.Fatal("a disabled call read something")
			}
		})
	}
}

func TestSuggestions_Limit(t *testing.T) {
	r := newSuggestRig(t, nil)
	_, err := r.svc.ListSuggestions(context.Background(), me, &messagingv1.ListMessageSuggestionsRequest{Limit: -1})
	if code, reason, meta := reasonOf(t, err); code != connect.CodeInvalidArgument || reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || meta["field"] != "limit" {
		t.Fatalf("got %v %v %v", code, reason, meta)
	}
	for in, want := range map[int32]int{0: 10, 3: 3, 20: 20, 99: 20} {
		if got, err := suggestLimit(in); err != nil || got != want {
			t.Fatalf("suggestLimit(%d) = %d, %v", in, got, err)
		}
	}
}

// TestSuggestions_LeakMatrix: every refusal cause of a send leaves the candidate out, and the policy exemptions keep them.
func TestSuggestions_LeakMatrix(t *testing.T) {
	const (
		ok          = "ok"
		blocked     = "blocked"      // the caller blocks them
		blocker     = "blocker"      // they block the caller
		muted       = "muted"        // the caller mutes them
		inactive    = "inactive"     // not ACTIVE (absent from the directory)
		msgOff      = "msg-off"      // messaging off for them
		fonlyNew    = "fonly-new"    // FOLLOWING_ONLY, a requester-pending entry, does not follow the caller
		fonlyAcc    = "fonly-acc"    // FOLLOWING_ONLY, ACCEPTED conversation: exempt
		fonlyBack   = "fonly-back"   // FOLLOWING_ONLY, follows the caller: allowed
		fonlyNoFlag = "fonly-noflag" // FOLLOWING_ONLY stored, but dm_policy off for them: today's behaviour
		mutual      = "mutual"       // a followee who follows back
		oneWay      = "one-way"      // a followee who does not
	)
	active := []string{me, ok, blocked, blocker, muted, msgOff, fonlyNew, fonlyAcc, fonlyBack, fonlyNoFlag, mutual, oneWay}
	allOn := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.On} }
	r := newSuggestRig(t, active,
		flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: allowSet(me, ok, blocked, blocker, muted, fonlyNew, fonlyAcc, fonlyBack, fonlyNoFlag, mutual, oneWay)},
		allOn(SuggestionsFlagName), allOn(beaconsFlagName), allOn(communitiesFlagName),
		flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.Allowlist, Allowlist: allowSet(fonlyNew, fonlyAcc, fonlyBack)},
	)
	for _, u := range []string{fonlyNew, fonlyAcc, fonlyBack, fonlyNoFlag} {
		p := r.profs.profiles[u]
		p.DMPolicy = identity.DMPolicyFollowingOnly
		r.profs.profiles[u] = p
	}
	r.inbox(ok, blocked, blocker, muted, inactive, msgOff, fonlyNew, fonlyAcc, me)
	rows := r.repo.entries[entryKey(me, dmInboxCollection)]
	for i := range rows {
		rows[i].RequestPending = rows[i].PeerID == fonlyNew
	}
	r.plans.mates = []PlanMate{{UID: fonlyBack, Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_COFFEE}}
	r.comm.mates = []CommunityMate{{UID: fonlyNoFlag, CommunityID: "c1", CommunityName: "Go"}}
	r.social.snaps[me] = graph.Snapshot{
		Blocked: bset(blocked), BlockedBy: bset(blocker), Muted: bset(muted), RecentFollowing: []string{mutual, oneWay},
	}
	r.follow.back = map[string]bool{fonlyBack: true, mutual: true}

	got := suggestedUIDs(r.list(t, 20))
	want := []string{ok, fonlyAcc, fonlyBack, mutual, fonlyNoFlag}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	// The follow-back lookup was one batch, only for the rows that need it.
	if len(r.follow.asked) != 1 {
		t.Fatalf("follow lookups = %d", len(r.follow.asked))
	}
	asked := bset(r.follow.asked[0]...)
	for _, u := range []string{fonlyNew, fonlyBack, mutual, oneWay} {
		if !asked[u] {
			t.Fatalf("%s not asked (asked %v)", u, r.follow.asked[0])
		}
	}
	if asked[fonlyAcc] || asked[ok] || asked[fonlyNoFlag] {
		t.Fatalf("asked too much: %v", r.follow.asked[0])
	}
}

func bset(ids ...string) map[string]bool {
	m := map[string]bool{}
	for _, i := range ids {
		m[i] = true
	}
	return m
}

func allowSet(ids ...string) map[string]struct{} {
	m := map[string]struct{}{}
	for _, i := range ids {
		m[i] = struct{}{}
	}
	return m
}

// TestSuggestions_ReasonsAndOrder: source order, the first reason wins, the chips' details, the plan lookback and the limit.
func TestSuggestions_ReasonsAndOrder(t *testing.T) {
	r := newSuggestRig(t, []string{"a", "b", "c", "d"})
	r.inbox("a")
	r.plans.mates = []PlanMate{{UID: "a"}, {UID: "b", Activity: beaconsv1.BeaconActivity_BEACON_ACTIVITY_WALK}}
	r.social.snaps[me] = graph.Snapshot{RecentFollowing: []string{"c", "b"}}
	r.follow.back = map[string]bool{"c": true, "b": true}
	r.comm.mates = []CommunityMate{{UID: "d", CommunityID: "0000000000000000001", CommunityName: "Runners"}}
	rows := r.list(t, 0)
	if got := suggestedUIDs(rows); len(got) != 4 || got[0] != "a" || got[1] != "b" || got[2] != "c" || got[3] != "d" {
		t.Fatalf("order = %v", got)
	}
	if rows[0].GetReason() != messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_RECENT_CONVERSATION ||
		rows[1].GetReason() != messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_MET_ON_PLAN ||
		rows[1].GetPlanActivity() != beaconsv1.BeaconActivity_BEACON_ACTIVITY_WALK ||
		rows[2].GetReason() != messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_MUTUAL_FOLLOW ||
		rows[3].GetReason() != messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_COMMUNITY_MEMBER ||
		rows[3].GetCommunityName() != "Runners" || rows[3].GetCommunityId() != "0000000000000000001" {
		t.Fatalf("rows = %v", rows)
	}
	if rows[0].GetUser().GetHandle() != "a" || rows[0].GetPlanActivity() != beaconsv1.BeaconActivity_BEACON_ACTIVITY_UNSPECIFIED {
		t.Fatalf("row 0 = %v", rows[0])
	}
	if want := r.now.Add(-30 * 24 * time.Hour); !r.plans.since.Equal(want) {
		t.Fatalf("plan lookback since = %v, want %v", r.plans.since, want)
	}
	if got := r.list(t, 2); len(got) != 2 {
		t.Fatalf("limit 2 = %d rows", len(got))
	}
	if q := r.repo.queries[0]; q.Limit != suggestInbox {
		t.Fatalf("inbox query limit = %d", q.Limit)
	}
}

// TestSuggestions_SourcesGatedAndBestEffort: a source whose module flag is off is not read; a failing optional source contributes
// nothing; a failed follow lookup drops exactly the rows that need it; the inbox is required.
func TestSuggestions_SourcesGatedAndBestEffort(t *testing.T) {
	t.Run("module flags off", func(t *testing.T) {
		r := newSuggestRig(t, []string{"p"}, flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: SuggestionsFlagName, Mode: flags.On})
		r.plans.mates = []PlanMate{{UID: "p"}}
		r.comm.mates = []CommunityMate{{UID: "p"}}
		if rows := r.list(t, 0); len(rows) != 0 || r.plans.calls+r.comm.calls != 0 {
			t.Fatalf("rows %v, plan calls %d, community calls %d", rows, r.plans.calls, r.comm.calls)
		}
	})
	t.Run("optional sources fail", func(t *testing.T) {
		r := newSuggestRig(t, []string{"a"})
		r.inbox("a")
		r.plans.err, r.comm.err = errors.New("down"), errors.New("down")
		if got := suggestedUIDs(r.list(t, 0)); len(got) != 1 || got[0] != "a" {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("follow lookup fails closed", func(t *testing.T) {
		r := newSuggestRig(t, []string{"a", "m"})
		r.inbox("a")
		r.social.snaps[me] = graph.Snapshot{RecentFollowing: []string{"m"}}
		r.follow.err = errors.New("down")
		if got := suggestedUIDs(r.list(t, 0)); len(got) != 1 || got[0] != "a" {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("inbox fails", func(t *testing.T) {
		r := newSuggestRig(t, nil)
		r.repo.listErr = errors.New("down")
		if _, err := r.svc.ListSuggestions(context.Background(), me, &messagingv1.ListMessageSuggestionsRequest{}); err == nil {
			t.Fatal("an inbox failure must fail the call")
		}
	})
	t.Run("blockedBy overflow is empty", func(t *testing.T) {
		r := newSuggestRig(t, []string{"a"})
		r.inbox("a")
		r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true}
		if rows := r.list(t, 0); len(rows) != 0 || r.repo.lists != 0 {
			t.Fatalf("rows %v, inbox reads %d", rows, r.repo.lists)
		}
	})
}
