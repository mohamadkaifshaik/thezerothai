package posts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const schedUID = "uid-alice"

var schedClock = schedNow

type schedSvcEnv struct {
	svc   *service
	repo  *fakeSchedRepo
	dir   *fakeDirectory
	clock time.Time
}

func defaultScheduleLimits() ScheduleLimits {
	return ScheduleLimits{
		MaxPending: 25, WindowCap: 3, MinLead: 2 * time.Minute, Horizon: 1440 * time.Hour, TerminalTTL: 168 * time.Hour,
		SchedulesPerDay: 50, NewAccountSchedulesPerDay: 10,
	}
}

func newSchedSvcEnv(ps ...*ScheduledPost) *schedSvcEnv {
	e := &schedSvcEnv{
		repo:  newFakeSchedRepo(ps...),
		clock: schedClock,
		dir: &fakeDirectory{profiles: map[string]identity.Profile{
			schedUID: {UserID: schedUID, Handle: "Alice", HandleLower: "alice", Status: identity.AccountStatusActive, CreatedAt: schedClock.Add(-72 * time.Hour)},
		}, handles: map[string]string{"bob": "uid-bob"}},
	}
	e.svc = New(Deps{
		Repo: newFakeRepo(), Cache: NewCache(time.Minute, 0, 0), Directory: e.dir,
		NewAccountWindow: 24 * time.Hour, CursorKey: schedKey,
		Scheduled: e.repo, Schedule: defaultScheduleLimits(),
		Now: func() time.Time { return e.clock },
	}).(*service)
	return e
}

// validIn is a valid request at clock+1h with every sub-feature on.
func (e *schedSvcEnv) validIn(mut ...func(*ScheduleInput)) ScheduleInput {
	in := ScheduleInput{
		IdempotencyKey: schedKeyFor(1), Text: "hello later", PublishAt: e.clock.Add(time.Hour),
		MediaEnabled: true, ReplyAudienceEnabled: true, DisclosureEnabled: true,
	}
	for _, m := range mut {
		m(&in)
	}
	return in
}

func (e *schedSvcEnv) schedule(in ScheduleInput) (*ScheduledPost, error) {
	return e.svc.Schedule(googleCtx(context.Background(), schedUID), schedUID, in)
}

func (e *schedSvcEnv) pendingAt(n int, at time.Time) *ScheduledPost {
	id, _ := ScheduledID(schedUID, schedKeyFor(100+n))
	return &ScheduledPost{
		ID: id, UID: schedUID, SchemaVersion: ScheduledSchemaVersion, PublishAt: at, Status: ScheduledPending, RequestHash: "h",
		Draft: &ScheduledDraft{Text: "x"}, CreatedAt: e.clock, UpdatedAt: e.clock,
	}
}

func mediaIDs(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("%019d", 1000+i)
	}
	return out
}

func TestSchedule_StoresTheDocumentedItem(t *testing.T) {
	e := newSchedSvcEnv()
	in := e.validIn(func(i *ScheduleInput) {
		i.PublishAt = e.clock.Add(time.Hour + 59*time.Second) // truncated to the whole minute
		i.Text = "Hello @bob #Go"
		i.ReplyPolicy = int32(postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY)
		i.PaidPartnership, i.MadeWithAI = true, true
	})
	p, err := e.schedule(in)
	if err != nil {
		t.Fatalf("Schedule: %v", err)
	}
	wantID, _ := ScheduledID(schedUID, in.IdempotencyKey)
	if p.ID != wantID || p.UID != schedUID || p.Status != ScheduledPending || p.SchemaVersion != ScheduledSchemaVersion {
		t.Errorf("item = %+v", p)
	}
	if want := e.clock.Add(time.Hour).Truncate(time.Minute); !p.PublishAt.Equal(want) {
		t.Errorf("PublishAt = %v, want the whole minute %v", p.PublishAt, want)
	}
	d := p.Draft
	if d == nil || d.Text != "Hello @bob #Go" || d.ReplyPolicy != ReplyPolicyMentionedOnly || !d.PaidPartnership || !d.MadeWithAI {
		t.Errorf("draft = %+v", d)
	}
	if !p.CreatedAt.Equal(e.clock) || p.RequestHash == "" {
		t.Errorf("CreatedAt/RequestHash = %v / %q", p.CreatedAt, p.RequestHash)
	}
	if len(e.dir.resolved) != 0 {
		t.Errorf("mentions were resolved at schedule time (%v): they resolve at publish", e.dir.resolved)
	}
	if e.repo.lastCreate.QuotaLimit != 50 {
		t.Errorf("quota limit = %d, want 50 for an established account", e.repo.lastCreate.QuotaLimit)
	}
	if e.repo.lastPendingLimit != 26 || e.repo.lastCreate.WindowCap != 3 {
		t.Errorf("pending limit %d, window cap %d, want 26 and 3 (the repository counts WindowCap+1)", e.repo.lastPendingLimit, e.repo.lastCreate.WindowCap)
	}
	if !e.repo.lastCreate.PublishAt.Equal(p.PublishAt) {
		t.Errorf("window centre = %v, want the stored minute %v", e.repo.lastCreate.PublishAt, p.PublishAt)
	}
}

func TestSchedule_MediaIsPassedThrough(t *testing.T) {
	e := newSchedSvcEnv()
	ids := mediaIDs(4)
	p, err := e.schedule(e.validIn(func(i *ScheduleInput) {
		i.MediaIDs, i.MediaAltTexts, i.Text = ids, []string{"a", "", "c", "d"}, ""
	}))
	if err != nil {
		t.Fatalf("Schedule: %v", err)
	}
	if len(p.Draft.Media) != 4 || p.Draft.Media[0].AltText != "a" || p.Draft.Media[2].AltText != "c" || p.Draft.Text != "" {
		t.Errorf("draft media = %+v text %q", p.Draft.Media, p.Draft.Text)
	}
}

func TestSchedule_FlagsComeBeforeAnyLookup(t *testing.T) {
	tests := []struct {
		name        string
		mut         func(*ScheduleInput)
		wantFeature string
	}{
		{"media off", func(i *ScheduleInput) { i.MediaEnabled, i.MediaIDs = false, mediaIDs(1) }, "media"},
		{"media alt texts alone", func(i *ScheduleInput) { i.MediaEnabled, i.MediaAltTexts = false, []string{"x"} }, "media"},
		{"reply audience off", func(i *ScheduleInput) {
			i.ReplyAudienceEnabled, i.ReplyPolicy = false, int32(postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING)
		}, "reply_audience"},
		{"reply audience off, EVERYONE counts too", func(i *ScheduleInput) {
			i.ReplyAudienceEnabled, i.ReplyPolicy = false, int32(postsv1.ReplyPolicy_REPLY_POLICY_EVERYONE)
		}, "reply_audience"},
		{"disclosure off", func(i *ScheduleInput) { i.DisclosureEnabled, i.MadeWithAI = false, true }, "content_disclosure"},
		{"flag checks beat validation", func(i *ScheduleInput) {
			i.MediaEnabled, i.MediaIDs, i.IdempotencyKey, i.PublishAt = false, mediaIDs(9), "bad", time.Time{}
		}, "media"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			_, err := e.schedule(e.validIn(tt.mut))
			ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if ae.Metadata["feature"] != tt.wantFeature {
				t.Errorf("feature = %q, want %q", ae.Metadata["feature"], tt.wantFeature)
			}
			if e.repo.gets+e.repo.pendingCounts+e.repo.creates != 0 {
				t.Error("the repository was touched")
			}
		})
	}
}

func TestSchedule_ShapeErrorsComeBeforeAnyLookup(t *testing.T) {
	longText := strings.Repeat("a", 281)
	tests := []struct {
		name      string
		mut       func(*ScheduleInput)
		field     string // empty: not a field error
		wantCode  connect.Code
		wantRsn   commonv1.ErrorReason
		anonymous bool
	}{
		{"short key", func(i *ScheduleInput) { i.IdempotencyKey = "short" }, "idempotency_key", 0, 0, false},
		{"key with a space", func(i *ScheduleInput) { i.IdempotencyKey = "0123456789 abcdef" }, "idempotency_key", 0, 0, false},
		{"reply policy not available", func(i *ScheduleInput) {
			i.ReplyPolicy = int32(postsv1.ReplyPolicy_REPLY_POLICY_VERIFIED)
		}, "reply_policy", 0, 0, false},
		{"reply policy unknown number", func(i *ScheduleInput) { i.ReplyPolicy = 99 }, "reply_policy", 0, 0, false},
		{"five media", func(i *ScheduleInput) { i.MediaIDs = mediaIDs(5) }, "media_ids", 0, 0, false},
		{"media id not 19 digits", func(i *ScheduleInput) { i.MediaIDs = []string{"abc"} }, "media_ids", 0, 0, false},
		{"duplicate media id", func(i *ScheduleInput) { i.MediaIDs = []string{mediaIDs(1)[0], mediaIDs(1)[0]} }, "media_ids", 0, 0, false},
		{"alt texts not parallel", func(i *ScheduleInput) { i.MediaIDs, i.MediaAltTexts = mediaIDs(2), []string{"x"} }, "media_alt_texts", 0, 0, false},
		{"missing publish_at", func(i *ScheduleInput) { i.PublishAt = time.Time{} }, "publish_at", 0, 0, false},
		{"empty text without media", func(i *ScheduleInput) { i.Text = "  " }, "", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, false},
		{"text over 280", func(i *ScheduleInput) { i.Text = longText }, "", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, false},
		{"control character", func(i *ScheduleInput) { i.Text = "a\x00b" }, "", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, false},
		{"anonymous sign-in", func(*ScheduleInput) {}, "", connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			ctx := googleCtx(context.Background(), schedUID)
			if tt.anonymous {
				ctx = authn.WithClaims(context.Background(), authn.Claims{UID: schedUID, SignInProvider: authn.SignInProviderAnonymous})
			}
			_, err := e.svc.Schedule(ctx, schedUID, e.validIn(tt.mut))
			code, rsn := tt.wantCode, tt.wantRsn
			if tt.field != "" {
				code, rsn = connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION
			}
			ae := wantAPIError(t, err, code, rsn)
			if tt.field != "" && ae.Metadata["field"] != tt.field {
				t.Errorf("field = %q, want %q", ae.Metadata["field"], tt.field)
			}
			if e.repo.gets+e.repo.pendingCounts+e.repo.creates != 0 {
				t.Error("the repository was reached before the shape checks")
			}
		})
	}
}

func TestSchedule_ImageOnlyPostIsValid(t *testing.T) {
	e := newSchedSvcEnv()
	if _, err := e.schedule(e.validIn(func(i *ScheduleInput) { i.Text, i.MediaIDs = "", mediaIDs(1) })); err != nil {
		t.Fatalf("image-only post: %v", err)
	}
}

func TestSchedule_ReplayReturnsTheStoredItem(t *testing.T) {
	e := newSchedSvcEnv()
	in := e.validIn()
	first, err := e.schedule(in)
	if err != nil {
		t.Fatal(err)
	}
	ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), schedUID))
	again, err := e.svc.Schedule(ctx, schedUID, in)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if again.ID != first.ID || e.repo.creates != 1 || e.repo.schedules[schedUID] != 1 {
		t.Errorf("replay created again: id %s/%s creates %d quota %d", again.ID, first.ID, e.repo.creates, e.repo.schedules[schedUID])
	}
	if v, _ := info.Get("outcome"); v != "replay" {
		t.Errorf("outcome = %v, want replay", v)
	}
}

// TestSchedule_ReplayWinsOverTheLeadTimeAndTheCaps is security review L-6: the replay lookup comes before the time
// checks and both caps, so a retry that arrives late still gets its item and never re-schedules under a new key.
func TestSchedule_ReplayWinsOverTheLeadTimeAndTheCaps(t *testing.T) {
	tests := []struct {
		name  string
		after func(*schedSvcEnv)
	}{
		{"lead time passed", func(e *schedSvcEnv) { e.clock = e.clock.Add(59 * time.Minute) }}, // 1 minute before publish_at
		{"publish time passed", func(e *schedSvcEnv) { e.clock = e.clock.Add(3 * time.Hour) }},
		{"pending cap full", func(e *schedSvcEnv) {
			for n := 0; n < 25; n++ {
				e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(n, e.clock.Add(48*time.Hour+time.Duration(n)*time.Hour)))
			}
		}},
		{"window cap full", func(e *schedSvcEnv) {
			for n := 0; n < 3; n++ {
				e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(n, e.clock.Add(time.Hour+time.Duration(n)*time.Minute)))
			}
		}},
		{"daily cap spent", func(e *schedSvcEnv) { e.repo.schedules[schedUID] = 50 }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			in := e.validIn()
			first, err := e.schedule(in)
			if err != nil {
				t.Fatal(err)
			}
			tt.after(e)
			again, err := e.schedule(in)
			if err != nil || again.ID != first.ID {
				t.Fatalf("replay = %+v, %v; want the stored item", again, err)
			}
			if e.repo.pendingCounts != 1 || e.repo.windowEvals != 1 || e.repo.creates != 1 {
				t.Errorf("the replay ran counts or a create: pending %d window %d creates %d", e.repo.pendingCounts, e.repo.windowEvals, e.repo.creates)
			}
		})
	}
}

func TestSchedule_ReplayOfATerminalItemCarriesNoDraft(t *testing.T) {
	for _, st := range []ScheduledStatus{ScheduledPublished, ScheduledCancelled} {
		t.Run(string(st), func(t *testing.T) {
			e := newSchedSvcEnv()
			in := e.validIn()
			p, err := e.schedule(in)
			if err != nil {
				t.Fatal(err)
			}
			doc := e.repo.stored(schedUID, p.ID)
			doc.Status, doc.Draft = st, nil
			again, err := e.schedule(in)
			if err != nil || again.Status != st || again.Draft != nil {
				t.Fatalf("replay = %+v, %v; want %s without a draft", again, err, st)
			}
		})
	}
}

func TestSchedule_EffectiveRequestDecidesReplayOrReuse(t *testing.T) {
	policy := func(p postsv1.ReplyPolicy) func(*ScheduleInput) {
		return func(i *ScheduleInput) { i.ReplyPolicy = int32(p) }
	}
	tests := []struct {
		name       string
		first      func(*ScheduleInput)
		second     func(*ScheduleInput)
		wantReplay bool
	}{
		{"same seconds-different minute is the same", nil, func(i *ScheduleInput) { i.PublishAt = i.PublishAt.Add(59 * time.Second) }, true},
		{"UNSPECIFIED equals EVERYONE", nil, policy(postsv1.ReplyPolicy_REPLY_POLICY_EVERYONE), true},
		{"text differs", nil, func(i *ScheduleInput) { i.Text = "other" }, false},
		{"one minute later", nil, func(i *ScheduleInput) { i.PublishAt = i.PublishAt.Add(time.Minute) }, false},
		{"policy differs", nil, policy(postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING), false},
		{"paid partnership differs", nil, func(i *ScheduleInput) { i.PaidPartnership = true }, false},
		{"made with AI differs", nil, func(i *ScheduleInput) { i.MadeWithAI = true }, false},
		{"media differs", nil, func(i *ScheduleInput) { i.MediaIDs = mediaIDs(1) }, false},
		{"alt text differs", func(i *ScheduleInput) { i.MediaIDs, i.MediaAltTexts = mediaIDs(1), []string{"a"} },
			func(i *ScheduleInput) { i.MediaIDs, i.MediaAltTexts = mediaIDs(1), []string{"b"} }, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			if tt.first == nil {
				tt.first = func(*ScheduleInput) {}
			}
			first, err := e.schedule(e.validIn(tt.first))
			if err != nil {
				t.Fatal(err)
			}
			_, err = e.schedule(e.validIn(tt.first, tt.second))
			if tt.wantReplay {
				if err != nil {
					t.Fatalf("want a replay, got %v", err)
				}
				return
			}
			_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
			if e.repo.stored(schedUID, first.ID).Draft.Text != "hello later" {
				t.Error("the stored item changed")
			}
		})
	}
}

func TestSchedule_PublishAtBounds(t *testing.T) {
	now := schedClock.Add(30 * time.Second) // 09:00:30
	tests := []struct {
		name string
		at   time.Time
		ok   bool
	}{
		{"exactly the minimum lead (a whole minute)", time.Date(2026, 11, 2, 9, 3, 0, 0, time.UTC), true},             // 2m30s ahead
		{"truncates below the lead", time.Date(2026, 11, 2, 9, 2, 45, 0, time.UTC), false},                            // 09:02:00 is 1m30s ahead
		{"one minute ahead", time.Date(2026, 11, 2, 9, 1, 0, 0, time.UTC), false},                                     //
		{"in the past", time.Date(2026, 11, 2, 8, 0, 0, 0, time.UTC), false},                                          //
		{"exactly the horizon (truncated)", now.Add(1440 * time.Hour), true},                                          // 60 d
		{"a minute beyond the horizon", now.Add(1440*time.Hour + time.Minute), false},                                 //
		{"far future", time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC), false},                                            //
		{"non-UTC zone is the same instant", time.Date(2026, 11, 2, 15, 0, 0, 0, time.FixedZone("IST", 19800)), true}, // 09:30Z
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			e.clock = now
			_, err := e.schedule(e.validIn(func(i *ScheduleInput) { i.PublishAt = tt.at }))
			if tt.ok {
				if err != nil {
					t.Fatalf("want ok, got %v", err)
				}
				return
			}
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "publish_at" {
				t.Errorf("field = %q, want publish_at", ae.Metadata["field"])
			}
			// Only the replay lookup ran: no counts, no transaction.
			if e.repo.gets != 1 || e.repo.pendingCounts != 0 || e.repo.creates != 0 {
				t.Errorf("lookups %d pending counts %d creates %d, want 1, 0, 0: a bounds failure must stop after the replay lookup", e.repo.gets, e.repo.pendingCounts, e.repo.creates)
			}
		})
	}
}

func TestSchedule_PendingCap(t *testing.T) {
	pending := func(e *schedSvcEnv, n int) {
		for i := 0; i < n; i++ {
			e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(i, e.clock.Add(72*time.Hour+time.Duration(i)*time.Hour)))
		}
	}
	tests := []struct {
		name    string
		max     int
		pending int
		ok      bool
	}{
		{"24 of 25", 25, 24, true},
		{"25 of 25", 25, 25, false},
		{"hard max 50", 50, 49, true},
		{"hard max 50 reached", 50, 50, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			e.svc.schedule.MaxPending = tt.max
			pending(e, tt.pending)
			// FAILED, PUBLISHED and another user's items never count.
			e.repo.docs[schedUID] = append(e.repo.docs[schedUID], newSched(t, schedUID, 500, ScheduledFailed), newSched(t, schedUID, 501, ScheduledPublished))
			e.repo.docs["uid-bob"] = []*ScheduledPost{newSched(t, "uid-bob", 502, ScheduledPending)}
			_, err := e.schedule(e.validIn())
			if tt.ok {
				if err != nil {
					t.Fatalf("want ok, got %v", err)
				}
				return
			}
			ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
			if ae.Metadata["limit"] != "scheduled_pending" {
				t.Errorf("limit = %q", ae.Metadata["limit"])
			}
			// The replay lookup and the pending count ran; the window and the transaction did not.
			if e.repo.gets != 1 || e.repo.pendingCounts != 1 || e.repo.lastPendingLimit != tt.max+1 || e.repo.windowEvals != 0 || e.repo.creates != 0 {
				t.Errorf("lookups %d pending counts %d limit %d windowEvals %d creates %d", e.repo.gets, e.repo.pendingCounts, e.repo.lastPendingLimit, e.repo.windowEvals, e.repo.creates)
			}
		})
	}
}

// The window tests below run against fakeSchedRepo, which models the repository's contract (ErrScheduledWindowFull,
// ErrScheduledExists, the order of the checks). They prove what the SERVICE does with that contract: it passes
// WindowCap and the stored minute, maps ErrScheduledWindowFull to LIMIT_REACHED(scheduled_window) and ErrScheduledExists
// to a replay. They say nothing about whether the cap is exact: the evidence for that is the
// emulator tests (TestSchedulerIT_ConcurrentWindowCap, TestScheduled_Integration_WindowCap* and WindowFullByTheSameKey).
func TestSchedule_WindowCap(t *testing.T) {
	target := schedClock.Add(time.Hour) // the request's publish_at
	at := func(d time.Duration) time.Time { return target.Add(d) }
	tests := []struct {
		name  string
		items []time.Time
		ok    bool
	}{
		{"two inside", []time.Time{at(0), at(time.Minute)}, true},
		{"three inside", []time.Time{at(-time.Minute), at(0), at(time.Minute)}, false},
		{"+4 min is inside (inclusive)", []time.Time{at(4 * time.Minute), at(4 * time.Minute), at(4 * time.Minute)}, false},
		{"-4 min is inside (inclusive)", []time.Time{at(-4 * time.Minute), at(-4 * time.Minute), at(-4 * time.Minute)}, false},
		{"+5 min is outside", []time.Time{at(5 * time.Minute), at(5 * time.Minute), at(5 * time.Minute)}, true},
		{"-5 min is outside", []time.Time{at(-5 * time.Minute), at(-5 * time.Minute), at(-5 * time.Minute)}, true},
		{"two inside and one outside", []time.Time{at(0), at(time.Minute), at(10 * time.Minute)}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			for n, when := range tt.items {
				e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(n, when))
			}
			// A FAILED item in the window does not count.
			failed := e.pendingAt(90, at(0))
			failed.Status = ScheduledFailed
			e.repo.docs[schedUID] = append(e.repo.docs[schedUID], failed)
			_, err := e.schedule(e.validIn())
			if tt.ok {
				if err != nil {
					t.Fatalf("want ok, got %v", err)
				}
				return
			}
			ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
			if ae.Metadata["limit"] != "scheduled_window" {
				t.Errorf("limit = %q", ae.Metadata["limit"])
			}
			// The replay lookup and the pending count run outside the transaction; the window is decided inside it.
			if e.repo.gets != 1 || e.repo.pendingCounts != 1 || e.repo.creates != 1 || e.repo.windowEvals != 1 {
				t.Errorf("lookups %d pending counts %d transactions %d window counts %d, want 1 each: the window is decided inside the transaction", e.repo.gets, e.repo.pendingCounts, e.repo.creates, e.repo.windowEvals)
			}
			// The rejection wrote nothing: the seeded items and the FAILED one are all there is, and no quota was charged.
			if got := len(e.repo.docs[schedUID]); got != len(tt.items)+1 || e.repo.schedules[schedUID] != 0 {
				t.Errorf("documents %d (seeded %d + 1 failed), schedules %d: a rejected call must write nothing", got, len(tt.items), e.repo.schedules[schedUID])
			}
		})
	}
}

// TestSchedule_WindowFullAfterARetryIsLimitReached: when the repository retried the transaction (the fake models a
// concurrent winner committing during attempt 1) and the second attempt found the window full, the service answers
// LIMIT_REACHED(scheduled_window) and writes nothing. That the real closure
// counts again on every attempt is proven by TestScheduled_Integration_WindowCapIsEvaluatedPerAttempt, not here.
func TestSchedule_WindowFullAfterARetryIsLimitReached(t *testing.T) {
	e := newSchedSvcEnv()
	at := e.clock.Add(time.Hour)
	e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(0, at), e.pendingAt(1, at.Add(time.Minute)))
	e.repo.attemptWinners = map[int]*ScheduledPost{1: e.pendingAt(2, at)}

	_, err := e.schedule(e.validIn())
	ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if ae.Metadata["limit"] != "scheduled_window" {
		t.Errorf("limit = %q, want scheduled_window", ae.Metadata["limit"])
	}
	if e.repo.windowEvals != 2 {
		t.Errorf("window counts = %d, want 2: the second attempt must count again", e.repo.windowEvals)
	}
	if got := len(e.repo.docs[schedUID]); got != 3 || e.repo.schedules[schedUID] != 0 {
		t.Errorf("documents = %d (2 seeded + the winner), schedules = %d: the loser must write nothing", got, e.repo.schedules[schedUID])
	}

	// The control: the same winner on a window with room afterwards (cap 4) lets the retry succeed, so the first attempt's
	// answer is not what decides.
	e = newSchedSvcEnv()
	e.svc.schedule.WindowCap = 4
	e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(0, at), e.pendingAt(1, at.Add(time.Minute)))
	e.repo.attemptWinners = map[int]*ScheduledPost{1: e.pendingAt(2, at)}
	if _, err = e.schedule(e.validIn()); err != nil {
		t.Fatalf("with room for the retry: %v", err)
	}
	if e.repo.windowEvals != 2 || len(e.repo.docs[schedUID]) != 4 {
		t.Errorf("window counts %d documents %d, want 2 and 4", e.repo.windowEvals, len(e.repo.docs[schedUID]))
	}
}

// TestSchedule_ExistsFromAFullWindowAnswersAReplay: when the repository reports ErrScheduledExists for a full window (a
// duplicate of a call that just committed; the fake models the winner's commit), the service answers from the winner's
// document, not LIMIT_REACHED, after reading that document again. The repository side is proven by
// TestScheduled_Integration_WindowFullByTheSameKey.
func TestSchedule_ExistsFromAFullWindowAnswersAReplay(t *testing.T) {
	e := newSchedSvcEnv()
	in := e.validIn()
	winner, err := newSchedSvcEnv().schedule(in) // what the winning call stored
	if err != nil {
		t.Fatal(err)
	}
	at := e.clock.Add(time.Hour)
	e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(0, at), e.pendingAt(1, at)) // cap 3: one more fits
	e.repo.attemptWinners = map[int]*ScheduledPost{1: winner}                                     // commits during attempt 1

	got, err := e.schedule(in)
	if err != nil || got.ID != winner.ID {
		t.Fatalf("got %+v, %v; want the winner's item", got, err)
	}
	// The replay lookup, then the winner's document once the repository reported ErrScheduledExists.
	if e.repo.gets != 2 {
		t.Errorf("document lookups = %d, want 2", e.repo.gets)
	}
}

// TestSchedule_WindowFullIsReportedWhenBothCapsAreHit: the service maps a window-full answer even when the daily cap is
// spent too, so a caller over both hears LIMIT_REACHED. The real check order (window before daily cap) is asserted
// against the repository in TestScheduled_Integration_WindowCap.
func TestSchedule_WindowFullIsReportedWhenBothCapsAreHit(t *testing.T) {
	e := newSchedSvcEnv()
	at := e.clock.Add(time.Hour)
	for n := 0; n < 3; n++ {
		e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(n, at))
	}
	e.repo.schedules[schedUID] = 50 // the daily cap is spent too
	_, err := e.schedule(e.validIn())
	ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if ae.Metadata["limit"] != "scheduled_window" {
		t.Errorf("limit = %q, want scheduled_window", ae.Metadata["limit"])
	}
}

// TestSchedule_RepoRefusalOfAWindowCapBelowOneIsInternal: a misconfigured limit comes back from the repository as an
// error and the service keeps it internal, never "no window cap". The repository's refusal itself is asserted in
// TestScheduled_Integration_WindowCap (cap 0).
func TestSchedule_RepoRefusalOfAWindowCapBelowOneIsInternal(t *testing.T) {
	e := newSchedSvcEnv()
	e.svc.schedule.WindowCap = 0
	_, err := e.schedule(e.validIn())
	if err == nil || errors.As(err, new(*apierr.Error)) {
		t.Fatalf("err = %v, want an unshaped internal error", err)
	}
	if len(e.repo.docs[schedUID]) != 0 {
		t.Error("something was stored")
	}
}

func TestSchedule_DailyQuotaTiers(t *testing.T) {
	tests := []struct {
		name      string
		created   time.Duration // account age
		used      int64
		media     int
		wantLimit int64
		ok        bool
	}{
		{"established, 49 used", 72 * time.Hour, 49, 0, 50, true},
		{"established, 50 used", 72 * time.Hour, 50, 0, 50, false},
		{"new account, 9 used", time.Hour, 9, 0, 10, true},
		{"new account, 10 used", time.Hour, 10, 0, 10, false},
		{"just past the window is established", 24*time.Hour + time.Second, 10, 0, 50, true},
		{"cap with four images is decided before the media load", 72 * time.Hour, 50, 4, 50, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			prof := e.dir.profiles[schedUID]
			prof.CreatedAt = e.clock.Add(-tt.created)
			e.dir.profiles[schedUID] = prof
			e.repo.schedules[schedUID] = tt.used
			e.repo.mediaNotReady = tt.media > 0 // the daily cap is decided before the media load, so this never surfaces
			_, err := e.schedule(e.validIn(func(i *ScheduleInput) {
				if tt.media > 0 {
					i.MediaIDs = mediaIDs(tt.media)
				}
			}))
			if e.repo.lastCreate.QuotaLimit != tt.wantLimit {
				t.Errorf("quota limit = %d, want %d", e.repo.lastCreate.QuotaLimit, tt.wantLimit)
			}
			if tt.ok {
				if err != nil {
					t.Fatalf("want ok, got %v", err)
				}
				return
			}
			ae := wantAPIError(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
			if ae.Metadata["quota"] != "schedules" || ae.RetryAfter <= 0 {
				t.Errorf("meta %v retry-after %v", ae.Metadata, ae.RetryAfter)
			}
		})
	}
}

func TestSchedule_MediaNotReady(t *testing.T) {
	e := newSchedSvcEnv()
	e.repo.mediaNotReady = true
	_, err := e.schedule(e.validIn(func(i *ScheduleInput) { i.MediaIDs = mediaIDs(2) }))
	_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
	if len(e.repo.docs[schedUID]) != 0 || e.repo.schedules[schedUID] != 0 {
		t.Error("something was stored")
	}
}

func TestSchedule_ConcurrentDuplicateAnswersFromTheWinner(t *testing.T) {
	in := func(e *schedSvcEnv) ScheduleInput { return e.validIn() }
	t.Run("same request: a replay", func(t *testing.T) {
		e := newSchedSvcEnv()
		winner, err := newSchedSvcEnv().schedule(in(e)) // what the winning call would have stored
		if err != nil {
			t.Fatal(err)
		}
		e.repo.raceDoc = winner
		got, err := e.schedule(in(e))
		if err != nil || got.ID != winner.ID {
			t.Fatalf("got %+v, %v; want the winner's item", got, err)
		}
		// The replay lookup, then the winner's document once the repository reported ErrScheduledExists.
		if e.repo.gets != 2 {
			t.Errorf("document lookups = %d, want 2", e.repo.gets)
		}
	})
	t.Run("different request: key reused", func(t *testing.T) {
		e := newSchedSvcEnv()
		winner, _ := newSchedSvcEnv().schedule(in(e))
		winner.RequestHash = "another-body"
		e.repo.raceDoc = winner
		_, err := e.schedule(in(e))
		_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	})
	t.Run("the winner vanished: an internal error, not a loop", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.createErr = ErrScheduledExists
		_, err := e.schedule(in(e))
		if err == nil || errors.As(err, new(*apierr.Error)) {
			t.Fatalf("err = %v, want an unshaped internal error", err)
		}
	})
}

func TestSchedule_ProfileRequired(t *testing.T) {
	e := newSchedSvcEnv()
	delete(e.dir.profiles, schedUID)
	_, err := e.schedule(e.validIn())
	_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED)
	if e.repo.creates != 0 {
		t.Error("created without a profile")
	}
}

// TestSchedule_UnexpectedErrorsAreScrubbed: a store error is never an *apierr.Error (the client sees a generic
// INTERNAL; mw.ErrorMapping logs it to Error Reporting) and its text carries neither the uid nor a document path.
func TestSchedule_UnexpectedErrorsAreScrubbed(t *testing.T) {
	leak := fmt.Errorf("rpc error: code = Unavailable desc = documents/users/%s/scheduled/abc: %w", schedUID, errBoom)
	tests := []struct {
		name string
		set  func(*schedSvcEnv)
	}{
		{"replay lookup", func(e *schedSvcEnv) { e.repo.getErr = leak }},
		{"pending count", func(e *schedSvcEnv) { e.repo.countPendingErr = leak }},
		{"window count (in the transaction)", func(e *schedSvcEnv) { e.repo.windowErr = leak }},
		{"transaction", func(e *schedSvcEnv) { e.repo.createErr = leak }},
		{"profile", func(e *schedSvcEnv) { e.dir.profileErr = leak }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			tt.set(e)
			_, err := e.schedule(e.validIn())
			if err == nil {
				t.Fatal("want an error")
			}
			if errors.As(err, new(*apierr.Error)) {
				t.Fatalf("err %v is client-shaped; an unexpected failure must stay internal", err)
			}
			if !errors.Is(err, errBoom) {
				t.Error("errors.Is no longer reaches the cause")
			}
			if msg := logger.CauseChain(err); strings.Contains(msg, schedUID) || strings.Contains(msg, "documents/") {
				t.Errorf("log text leaks an identifier: %q", msg)
			}
			if apierr.ToConnect(err).Code() != connect.CodeInternal {
				t.Errorf("code = %v, want internal", apierr.ToConnect(err).Code())
			}
		})
	}
}

func TestScheduler_UnconfiguredRepoFails(t *testing.T) {
	svc := New(Deps{Repo: newFakeRepo(), Cache: NewCache(time.Minute, 0, 0)}).(*service)
	ctx := googleCtx(context.Background(), schedUID)
	if _, err := svc.Schedule(ctx, schedUID, ScheduleInput{}); !errors.Is(err, errNoScheduledRepo) {
		t.Errorf("Schedule: %v", err)
	}
	if _, err := svc.ListScheduled(ctx, schedUID, 0, ""); !errors.Is(err, errNoScheduledRepo) {
		t.Errorf("ListScheduled: %v", err)
	}
	if _, err := svc.CancelScheduled(ctx, schedUID, schedKeyFor(1), strings.Repeat("a", 32)); !errors.Is(err, errNoScheduledRepo) {
		t.Errorf("CancelScheduled: %v", err)
	}
}

func TestSchedule_LogsOutcomeAndLimit(t *testing.T) {
	e := newSchedSvcEnv()
	ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), schedUID))
	if _, err := e.svc.Schedule(ctx, schedUID, e.validIn()); err != nil {
		t.Fatal(err)
	}
	if v, _ := info.Get("outcome"); v != "scheduled" {
		t.Errorf("outcome = %v", v)
	}
	if v, _ := info.Get("posts_op"); v != "schedule" {
		t.Errorf("posts_op = %v", v)
	}
	if v, _ := info.Get("text_len"); fmt.Sprint(v) != "11" {
		t.Errorf("text_len = %v", v)
	}

	e.svc.schedule.MaxPending = 1
	ctx, info = logger.WithRequestInfo(googleCtx(context.Background(), schedUID))
	if _, err := e.svc.Schedule(ctx, schedUID, e.validIn(func(i *ScheduleInput) { i.IdempotencyKey = schedKeyFor(2) })); err == nil {
		t.Fatal("want LIMIT_REACHED")
	}
	if v, _ := info.Get("outcome"); v != "rejected:limit_reached" {
		t.Errorf("outcome = %v, want rejected:limit_reached", v)
	}
	if v, _ := info.Get("limit"); v != "scheduled_pending" {
		t.Errorf("limit = %v", v)
	}
}

func TestListScheduled(t *testing.T) {
	seed := func(e *schedSvcEnv, n int) {
		for i := 0; i < n; i++ {
			e.repo.docs[schedUID] = append(e.repo.docs[schedUID], newSched(t, schedUID, i, ScheduledPending))
		}
	}
	list := func(e *schedSvcEnv, uid string, size int, tok string) (ScheduledPage, error) {
		return e.svc.ListScheduled(googleCtx(context.Background(), uid), uid, size, tok)
	}

	t.Run("PENDING and FAILED only, publish_at ascending, own items only", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.docs[schedUID] = []*ScheduledPost{
			newSched(t, schedUID, 3, ScheduledPending), newSched(t, schedUID, 1, ScheduledFailed), newSched(t, schedUID, 2, ScheduledPending),
			newSched(t, schedUID, 4, ScheduledPublished), newSched(t, schedUID, 5, ScheduledCancelled),
		}
		e.repo.docs["uid-bob"] = []*ScheduledPost{newSched(t, "uid-bob", 0, ScheduledPending)}
		page, err := list(e, schedUID, 0, "")
		if err != nil {
			t.Fatal(err)
		}
		var got []time.Time
		for _, p := range page.Items {
			if p.UID != schedUID || (p.Status != ScheduledPending && p.Status != ScheduledFailed) {
				t.Errorf("unexpected item %+v", p)
			}
			got = append(got, p.PublishAt)
		}
		if len(got) != 3 || !got[0].Before(got[1]) || !got[1].Before(got[2]) {
			t.Errorf("order = %v", got)
		}
		if page.NextPageToken != "" {
			t.Error("a short page must not carry a token")
		}
	})
	t.Run("an empty list is an empty page", func(t *testing.T) {
		e := newSchedSvcEnv()
		page, err := list(e, schedUID, 0, "")
		if err != nil || len(page.Items) != 0 || page.NextPageToken != "" {
			t.Fatalf("page = %+v, %v; want empty with no token", page, err)
		}
	})
	t.Run("page size 0 is 20, over 50 is 50", func(t *testing.T) {
		e := newSchedSvcEnv()
		seed(e, 60)
		page, err := list(e, schedUID, 0, "")
		if err != nil || len(page.Items) != 20 || page.NextPageToken == "" {
			t.Fatalf("default page = %d items, token %q, %v", len(page.Items), page.NextPageToken, err)
		}
		page, err = list(e, schedUID, 500, "")
		if err != nil || len(page.Items) != 50 {
			t.Fatalf("max page = %d items, %v", len(page.Items), err)
		}
	})
	t.Run("pagination walks every item once", func(t *testing.T) {
		e := newSchedSvcEnv()
		seed(e, 7)
		seen := map[string]bool{}
		tok := ""
		for pages := 0; ; pages++ {
			if pages > 4 {
				t.Fatal("pagination does not terminate")
			}
			page, err := list(e, schedUID, 3, tok)
			if err != nil {
				t.Fatal(err)
			}
			for _, p := range page.Items {
				if seen[p.ID] {
					t.Errorf("duplicate %s", p.ID)
				}
				seen[p.ID] = true
			}
			if tok = page.NextPageToken; tok == "" {
				break
			}
		}
		if len(seen) != 7 {
			t.Errorf("saw %d of 7", len(seen))
		}
	})
	t.Run("a token is bound to its caller and to the key", func(t *testing.T) {
		e := newSchedSvcEnv()
		seed(e, 5)
		page, err := list(e, schedUID, 2, "")
		if err != nil || page.NextPageToken == "" {
			t.Fatal(err)
		}
		for name, tok := range map[string]string{"foreign": page.NextPageToken, "garbage": "not-a-token", "tampered": page.NextPageToken + "x"} {
			uid := "uid-bob"
			if name != "foreign" {
				uid = schedUID
			}
			e.repo.docs["uid-bob"] = []*ScheduledPost{newSched(t, "uid-bob", 0, ScheduledPending)}
			callsBefore := e.repo.calls
			_, err := list(e, uid, 2, tok)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "page_token" {
				t.Errorf("%s: field = %q", name, ae.Metadata["field"])
			}
			if e.repo.calls != callsBefore {
				t.Errorf("%s: a rejected token queried the store", name)
			}
		}
	})
	t.Run("a store failure is internal and scrubbed", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.err = fmt.Errorf("documents/users/%s/scheduled: %w", schedUID, errBoom)
		_, err := list(e, schedUID, 0, "")
		if err == nil || errors.As(err, new(*apierr.Error)) || strings.Contains(logger.CauseChain(err), schedUID) {
			t.Fatalf("err = %v", err)
		}
	})
}

func TestCancelScheduled(t *testing.T) {
	id := func(n int) string { v, _ := ScheduledID(schedUID, schedKeyFor(n)); return v }
	cancel := func(e *schedSvcEnv, uid, key, sid string) (*ScheduledPost, error) {
		return e.svc.CancelScheduled(googleCtx(context.Background(), uid), uid, key, sid)
	}

	tests := []struct {
		name        string
		from        ScheduledStatus
		wantStatus  ScheduledStatus
		wantWrite   bool // the document is rewritten
		wantOutcome string
	}{
		{"PENDING is cancelled", ScheduledPending, ScheduledCancelled, true, "cancelled"},
		{"FAILED is dismissed (founder decision)", ScheduledFailed, ScheduledCancelled, true, "cancelled"},
		{"PUBLISHED is too late, unchanged", ScheduledPublished, ScheduledPublished, false, "unchanged"},
		{"CANCELLED stays cancelled", ScheduledCancelled, ScheduledCancelled, false, "unchanged"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := newSched(t, schedUID, 1, tt.from)
			if tt.from == ScheduledPublished {
				p.PostID = "1700000000000000001"
			}
			e := newSchedSvcEnv(p)
			ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), schedUID))
			got, err := e.svc.CancelScheduled(ctx, schedUID, schedKeyFor(77), id(1))
			if err != nil {
				t.Fatal(err)
			}
			if got.Status != tt.wantStatus || got.Draft != nil || got.ID != id(1) {
				t.Errorf("got %+v, want status %s without a draft", got, tt.wantStatus)
			}
			if tt.from == ScheduledPublished && got.PostID == "" {
				t.Error("the post id of a PUBLISHED item must be returned")
			}
			if v, _ := info.Get("outcome"); v != tt.wantOutcome {
				t.Errorf("outcome = %v, want %s", v, tt.wantOutcome)
			}
			stored := e.repo.stored(schedUID, id(1))
			if tt.wantWrite {
				if stored.Draft != nil || stored.ExpireAt == nil || !stored.ExpireAt.Equal(e.clock.Add(168*time.Hour)) {
					t.Errorf("stored = %+v, want the draft cleared and expireAt = now + TERMINAL_TTL", stored)
				}
			} else if stored.Status != tt.from || stored.ExpireAt != nil {
				t.Errorf("stored = %+v, want the %s item untouched", stored, tt.from)
			}
		})
	}

	t.Run("a second cancel is a no-op", func(t *testing.T) {
		e := newSchedSvcEnv(newSched(t, schedUID, 1, ScheduledPending))
		if _, err := cancel(e, schedUID, schedKeyFor(1), id(1)); err != nil {
			t.Fatal(err)
		}
		ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), schedUID))
		got, err := e.svc.CancelScheduled(ctx, schedUID, schedKeyFor(1), id(1))
		if err != nil || got.Status != ScheduledCancelled {
			t.Fatalf("second cancel = %+v, %v", got, err)
		}
		if v, _ := info.Get("outcome"); v != "unchanged" {
			t.Errorf("outcome = %v, want unchanged", v)
		}
	})
	t.Run("unknown id is NOT_FOUND", func(t *testing.T) {
		e := newSchedSvcEnv()
		_, err := cancel(e, schedUID, schedKeyFor(1), strings.Repeat("a", 32))
		_ = wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	})
	t.Run("another user's id is NOT_FOUND and the item is untouched", func(t *testing.T) {
		bobs := newSched(t, "uid-bob", 1, ScheduledPending)
		e := newSchedSvcEnv(bobs)
		_, err := cancel(e, schedUID, schedKeyFor(1), bobs.ID)
		ae := wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
		_, err2 := cancel(e, schedUID, schedKeyFor(1), strings.Repeat("b", 32))
		ae2 := wantAPIError(t, err2, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
		if ae.Message != ae2.Message {
			t.Errorf("messages differ (an existence oracle): %q vs %q", ae.Message, ae2.Message)
		}
		if got := e.repo.stored("uid-bob", bobs.ID); got.Status != ScheduledPending || got.Draft == nil {
			t.Errorf("bob's item changed: %+v", got)
		}
	})
	t.Run("malformed ids and keys are VALIDATION before the repository", func(t *testing.T) {
		e := newSchedSvcEnv(newSched(t, schedUID, 1, ScheduledPending))
		for _, tc := range []struct{ name, key, sid, field string }{
			{"upper-case id", schedKeyFor(1), strings.ToUpper(id(1)), "scheduled_id"},
			{"short id", schedKeyFor(1), id(1)[:31], "scheduled_id"},
			{"long id", schedKeyFor(1), id(1) + "a", "scheduled_id"},
			{"empty id", schedKeyFor(1), "", "scheduled_id"},
			{"path traversal", schedKeyFor(1), "../" + id(1)[:29], "scheduled_id"},
			{"non-hex id", schedKeyFor(1), strings.Repeat("g", 32), "scheduled_id"},
			{"short key", "short", id(1), "idempotency_key"},
			{"empty key", "", id(1), "idempotency_key"},
			{"key with a slash", "0123456789/abcdef", id(1), "idempotency_key"},
		} {
			_, err := cancel(e, schedUID, tc.key, tc.sid)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != tc.field {
				t.Errorf("%s: field = %q, want %q", tc.name, ae.Metadata["field"], tc.field)
			}
		}
		if e.repo.cancels != 0 || e.repo.gets != 0 {
			t.Error("the repository was reached")
		}
	})
	t.Run("a store failure is internal and scrubbed", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.cancelErr = fmt.Errorf("documents/users/%s/scheduled/x: %w", schedUID, errBoom)
		_, err := cancel(e, schedUID, schedKeyFor(1), id(1))
		if err == nil || errors.As(err, new(*apierr.Error)) || strings.Contains(logger.CauseChain(err), schedUID) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("the TTL passed on is SCHEDULED_TERMINAL_TTL", func(t *testing.T) {
		e := newSchedSvcEnv(newSched(t, schedUID, 1, ScheduledPending))
		e.svc.schedule.TerminalTTL = 24 * time.Hour
		if _, err := cancel(e, schedUID, schedKeyFor(1), id(1)); err != nil {
			t.Fatal(err)
		}
		if e.repo.lastCancelTTL != 24*time.Hour {
			t.Errorf("ttl = %v", e.repo.lastCancelTTL)
		}
	})
}

func TestScheduledRequestHash(t *testing.T) {
	at := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)
	base := scheduledRequestHash("t", nil, nil, ReplyPolicyEveryone, false, false, at)
	if base == requestHash("t", "", "", nil, nil, ReplyPolicyEveryone, false, false) {
		t.Error("a scheduled hash must not equal the CreatePost hash of the same body")
	}
	if scheduledRequestHash("t", nil, nil, ReplyPolicyEveryone, false, false, at.Add(time.Minute)) == base {
		t.Error("the publish time is not part of the hash")
	}
	// CreatePost's hash must stay byte-identical after the base split (a retry across a deploy still replays).
	want := idempotency.HashRequest("v1|text=\"t\"|media=\"\"|alts=\"\"|reply=\"\"|quote=\"\"")
	if got := requestHash("t", "", "", nil, nil, ReplyPolicyEveryone, false, false); got != want {
		t.Errorf("requestHash changed: %s, want %s", got, want)
	}
}
