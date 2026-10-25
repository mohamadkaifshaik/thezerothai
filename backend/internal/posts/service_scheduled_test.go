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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Reads in these tests are the Scheduler's own: the account-status interceptor's profile read (1, cached) is not
// part of the service, so every number is the documented budget minus 1 (SchedulePost proto: 9 worst = interceptor 1
// + scheduled doc 1 + pending count 1 + window count 1 + quotas 1 + media <= 4).

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

func (e *schedSvcEnv) schedule(in ScheduleInput) (*ScheduledPost, *budget.Counter, error) {
	ctx, c := budget.WithCounter(googleCtx(context.Background(), schedUID))
	p, err := e.svc.Schedule(ctx, schedUID, in)
	return p, c, err
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

func wantReads(t *testing.T, c *budget.Counter, reads, writes int64) {
	t.Helper()
	if c.Reads() != reads || c.Writes() != writes {
		t.Errorf("reads/writes = %d/%d, want %d/%d", c.Reads(), c.Writes(), reads, writes)
	}
}

func TestSchedule_StoresTheDocumentedItem(t *testing.T) {
	e := newSchedSvcEnv()
	in := e.validIn(func(i *ScheduleInput) {
		i.PublishAt = e.clock.Add(time.Hour + 59*time.Second) // truncated to the whole minute
		i.Text = "Hello @bob #Go"
		i.ReplyPolicy = int32(postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY)
		i.PaidPartnership, i.MadeWithAI = true, true
	})
	p, c, err := e.schedule(in)
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
	// scheduled doc 1 + pending count 1 + window count 1 + quotas 1; writes: doc + quotas.schedules.
	wantReads(t, c, 4, 2)
	if e.repo.lastPendingLimit != 26 || e.repo.lastWindowLimit != 4 {
		t.Errorf("count limits = %d / %d, want 26 / 4 (every query has a Limit)", e.repo.lastPendingLimit, e.repo.lastWindowLimit)
	}
	if !e.repo.lastWindowCenter.Equal(p.PublishAt) {
		t.Errorf("window centre = %v, want the stored minute %v", e.repo.lastWindowCenter, p.PublishAt)
	}
}

func TestSchedule_MediaIsPassedThroughAndCostsOneReadEach(t *testing.T) {
	e := newSchedSvcEnv()
	ids := mediaIDs(4)
	p, c, err := e.schedule(e.validIn(func(i *ScheduleInput) {
		i.MediaIDs, i.MediaAltTexts, i.Text = ids, []string{"a", "", "c", "d"}, ""
	}))
	if err != nil {
		t.Fatalf("Schedule: %v", err)
	}
	if len(p.Draft.Media) != 4 || p.Draft.Media[0].AltText != "a" || p.Draft.Media[2].AltText != "c" || p.Draft.Text != "" {
		t.Errorf("draft media = %+v text %q", p.Draft.Media, p.Draft.Text)
	}
	wantReads(t, c, 8, 2) // the documented 9 worst minus the interceptor's read
}

func TestSchedule_FlagsFirstWithNoReads(t *testing.T) {
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
			_, c, err := e.schedule(e.validIn(tt.mut))
			ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if ae.Metadata["feature"] != tt.wantFeature {
				t.Errorf("feature = %q, want %q", ae.Metadata["feature"], tt.wantFeature)
			}
			wantReads(t, c, 0, 0)
			if e.repo.gets+e.repo.creates != 0 {
				t.Error("the repository was touched")
			}
		})
	}
}

func TestSchedule_ShapeErrorsNeedNoReads(t *testing.T) {
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
			ctx, c := budget.WithCounter(googleCtx(context.Background(), schedUID))
			if tt.anonymous {
				ctx, c = budget.WithCounter(authn.WithClaims(context.Background(), authn.Claims{UID: schedUID, SignInProvider: authn.SignInProviderAnonymous}))
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
			wantReads(t, c, 0, 0)
			if e.repo.gets != 0 {
				t.Error("the replay lookup ran before the shape checks")
			}
		})
	}
}

func TestSchedule_ImageOnlyPostIsValid(t *testing.T) {
	e := newSchedSvcEnv()
	if _, _, err := e.schedule(e.validIn(func(i *ScheduleInput) { i.Text, i.MediaIDs = "", mediaIDs(1) })); err != nil {
		t.Fatalf("image-only post: %v", err)
	}
}

func TestSchedule_ReplayReturnsTheStoredItemForFree(t *testing.T) {
	e := newSchedSvcEnv()
	in := e.validIn()
	first, _, err := e.schedule(in)
	if err != nil {
		t.Fatal(err)
	}
	ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), schedUID))
	ctx, c := budget.WithCounter(ctx)
	again, err := e.svc.Schedule(ctx, schedUID, in)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if again.ID != first.ID || e.repo.creates != 1 || e.repo.schedules[schedUID] != 1 {
		t.Errorf("replay created again: id %s/%s creates %d quota %d", again.ID, first.ID, e.repo.creates, e.repo.schedules[schedUID])
	}
	wantReads(t, c, 1, 0) // the documented replay 2 minus the interceptor's read
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
			first, _, err := e.schedule(in)
			if err != nil {
				t.Fatal(err)
			}
			tt.after(e)
			again, c, err := e.schedule(in)
			if err != nil || again.ID != first.ID {
				t.Fatalf("replay = %+v, %v; want the stored item", again, err)
			}
			wantReads(t, c, 1, 0)
			if e.repo.pendingCounts != 1 || e.repo.windowCounts != 1 || e.repo.creates != 1 {
				t.Errorf("the replay ran counts or a create: pending %d window %d creates %d", e.repo.pendingCounts, e.repo.windowCounts, e.repo.creates)
			}
		})
	}
}

func TestSchedule_ReplayOfATerminalItemCarriesNoDraft(t *testing.T) {
	for _, st := range []ScheduledStatus{ScheduledPublished, ScheduledCancelled} {
		t.Run(string(st), func(t *testing.T) {
			e := newSchedSvcEnv()
			in := e.validIn()
			p, _, err := e.schedule(in)
			if err != nil {
				t.Fatal(err)
			}
			doc := e.repo.stored(schedUID, p.ID)
			doc.Status, doc.Draft = st, nil
			again, _, err := e.schedule(in)
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
			first, _, err := e.schedule(e.validIn(tt.first))
			if err != nil {
				t.Fatal(err)
			}
			_, c, err := e.schedule(e.validIn(tt.first, tt.second))
			if tt.wantReplay {
				if err != nil {
					t.Fatalf("want a replay, got %v", err)
				}
				wantReads(t, c, 1, 0)
				return
			}
			_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
			wantReads(t, c, 1, 0)
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
			_, c, err := e.schedule(e.validIn(func(i *ScheduleInput) { i.PublishAt = tt.at }))
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
			wantReads(t, c, 1, 0)
			if e.repo.pendingCounts != 0 || e.repo.creates != 0 {
				t.Error("a bounds failure reached the caps or the transaction")
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
			_, c, err := e.schedule(e.validIn())
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
			wantReads(t, c, 2, 0) // replay lookup + pending count (documented 3 with the interceptor)
			if e.repo.lastPendingLimit != tt.max+1 || e.repo.windowCounts != 0 || e.repo.creates != 0 {
				t.Errorf("limit %d windowCounts %d creates %d", e.repo.lastPendingLimit, e.repo.windowCounts, e.repo.creates)
			}
		})
	}
}

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
			_, c, err := e.schedule(e.validIn())
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
			wantReads(t, c, 3, 0) // replay lookup + pending + window (documented 4 with the interceptor)
			if e.repo.creates != 0 {
				t.Error("the transaction ran")
			}
		})
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
		{"cap with four images still reads 1 for the quota", 72 * time.Hour, 50, 4, 50, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			prof := e.dir.profiles[schedUID]
			prof.CreatedAt = e.clock.Add(-tt.created)
			e.dir.profiles[schedUID] = prof
			e.repo.schedules[schedUID] = tt.used
			_, c, err := e.schedule(e.validIn(func(i *ScheduleInput) {
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
			wantReads(t, c, 4, 0) // replay lookup, pending, window, quotas: the documented 5 minus the interceptor; no media reads
		})
	}
}

func TestSchedule_MediaNotReady(t *testing.T) {
	e := newSchedSvcEnv()
	e.repo.mediaNotReady = true
	_, c, err := e.schedule(e.validIn(func(i *ScheduleInput) { i.MediaIDs = mediaIDs(2) }))
	_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
	wantReads(t, c, 6, 0)
	if len(e.repo.docs[schedUID]) != 0 || e.repo.schedules[schedUID] != 0 {
		t.Error("something was stored")
	}
}

func TestSchedule_ConcurrentDuplicateAnswersFromTheWinner(t *testing.T) {
	in := func(e *schedSvcEnv) ScheduleInput { return e.validIn() }
	t.Run("same request: a replay", func(t *testing.T) {
		e := newSchedSvcEnv()
		winner, _, err := newSchedSvcEnv().schedule(in(e)) // what the winning call would have stored
		if err != nil {
			t.Fatal(err)
		}
		e.repo.raceDoc = winner
		got, c, err := e.schedule(in(e))
		if err != nil || got.ID != winner.ID {
			t.Fatalf("got %+v, %v; want the winner's item", got, err)
		}
		wantReads(t, c, 5, 0) // get, pending, window, quotas, the winner's doc again (documented: 9 worst + 1)
	})
	t.Run("different request: key reused", func(t *testing.T) {
		e := newSchedSvcEnv()
		winner, _, _ := newSchedSvcEnv().schedule(in(e))
		winner.RequestHash = "another-body"
		e.repo.raceDoc = winner
		_, _, err := e.schedule(in(e))
		_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	})
	t.Run("the winner vanished: an internal error, not a loop", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.createErr = ErrScheduledExists
		_, _, err := e.schedule(in(e))
		if err == nil || errors.As(err, new(*apierr.Error)) {
			t.Fatalf("err = %v, want an unshaped internal error", err)
		}
	})
}

func TestSchedule_ProfileRequired(t *testing.T) {
	e := newSchedSvcEnv()
	delete(e.dir.profiles, schedUID)
	_, _, err := e.schedule(e.validIn())
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
		{"window count", func(e *schedSvcEnv) { e.repo.countWindowErr = leak }},
		{"transaction", func(e *schedSvcEnv) { e.repo.createErr = leak }},
		{"profile", func(e *schedSvcEnv) { e.dir.profileErr = leak }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newSchedSvcEnv()
			tt.set(e)
			_, _, err := e.schedule(e.validIn())
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
	list := func(e *schedSvcEnv, uid string, size int, tok string) (ScheduledPage, *budget.Counter, error) {
		ctx, c := budget.WithCounter(googleCtx(context.Background(), uid))
		p, err := e.svc.ListScheduled(ctx, uid, size, tok)
		return p, c, err
	}

	t.Run("PENDING and FAILED only, publish_at ascending, own items only", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.docs[schedUID] = []*ScheduledPost{
			newSched(t, schedUID, 3, ScheduledPending), newSched(t, schedUID, 1, ScheduledFailed), newSched(t, schedUID, 2, ScheduledPending),
			newSched(t, schedUID, 4, ScheduledPublished), newSched(t, schedUID, 5, ScheduledCancelled),
		}
		e.repo.docs["uid-bob"] = []*ScheduledPost{newSched(t, "uid-bob", 0, ScheduledPending)}
		page, c, err := list(e, schedUID, 0, "")
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
		wantReads(t, c, 3, 0)
	})
	t.Run("empty list costs one read", func(t *testing.T) {
		e := newSchedSvcEnv()
		_, c, err := list(e, schedUID, 0, "")
		if err != nil {
			t.Fatal(err)
		}
		wantReads(t, c, 1, 0)
	})
	t.Run("page size 0 is 20, over 50 is 50", func(t *testing.T) {
		e := newSchedSvcEnv()
		seed(e, 60)
		page, c, err := list(e, schedUID, 0, "")
		if err != nil || len(page.Items) != 20 || page.NextPageToken == "" {
			t.Fatalf("default page = %d items, token %q, %v", len(page.Items), page.NextPageToken, err)
		}
		wantReads(t, c, 20, 0) // documented 21 with the interceptor
		page, c, err = list(e, schedUID, 500, "")
		if err != nil || len(page.Items) != 50 {
			t.Fatalf("max page = %d items, %v", len(page.Items), err)
		}
		wantReads(t, c, 50, 0)
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
			page, _, err := list(e, schedUID, 3, tok)
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
		page, _, err := list(e, schedUID, 2, "")
		if err != nil || page.NextPageToken == "" {
			t.Fatal(err)
		}
		for name, tok := range map[string]string{"foreign": page.NextPageToken, "garbage": "not-a-token", "tampered": page.NextPageToken + "x"} {
			uid := "uid-bob"
			if name != "foreign" {
				uid = schedUID
			}
			e.repo.docs["uid-bob"] = []*ScheduledPost{newSched(t, "uid-bob", 0, ScheduledPending)}
			_, c, err := list(e, uid, 2, tok)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != "page_token" {
				t.Errorf("%s: field = %q", name, ae.Metadata["field"])
			}
			wantReads(t, c, 0, 0)
		}
	})
	t.Run("a store failure is internal and scrubbed", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.err = fmt.Errorf("documents/users/%s/scheduled: %w", schedUID, errBoom)
		_, _, err := list(e, schedUID, 0, "")
		if err == nil || errors.As(err, new(*apierr.Error)) || strings.Contains(logger.CauseChain(err), schedUID) {
			t.Fatalf("err = %v", err)
		}
	})
}

func TestCancelScheduled(t *testing.T) {
	id := func(n int) string { v, _ := ScheduledID(schedUID, schedKeyFor(n)); return v }
	cancel := func(e *schedSvcEnv, uid, key, sid string) (*ScheduledPost, *budget.Counter, error) {
		ctx, c := budget.WithCounter(googleCtx(context.Background(), uid))
		p, err := e.svc.CancelScheduled(ctx, uid, key, sid)
		return p, c, err
	}

	tests := []struct {
		name        string
		from        ScheduledStatus
		wantStatus  ScheduledStatus
		wantWrites  int64
		wantOutcome string
	}{
		{"PENDING is cancelled", ScheduledPending, ScheduledCancelled, 1, "cancelled"},
		{"FAILED is dismissed (founder decision)", ScheduledFailed, ScheduledCancelled, 1, "cancelled"},
		{"PUBLISHED is too late, unchanged", ScheduledPublished, ScheduledPublished, 0, "unchanged"},
		{"CANCELLED stays cancelled", ScheduledCancelled, ScheduledCancelled, 0, "unchanged"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := newSched(t, schedUID, 1, tt.from)
			if tt.from == ScheduledPublished {
				p.PostID = "1700000000000000001"
			}
			e := newSchedSvcEnv(p)
			ctx, info := logger.WithRequestInfo(googleCtx(context.Background(), schedUID))
			ctx, c := budget.WithCounter(ctx)
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
			wantReads(t, c, 1, tt.wantWrites) // documented 2 worst / 1 typical, the interceptor's read excluded
			if v, _ := info.Get("outcome"); v != tt.wantOutcome {
				t.Errorf("outcome = %v, want %s", v, tt.wantOutcome)
			}
			if tt.wantWrites == 1 {
				stored := e.repo.stored(schedUID, id(1))
				if stored.Draft != nil || stored.ExpireAt == nil || !stored.ExpireAt.Equal(e.clock.Add(168*time.Hour)) {
					t.Errorf("stored = %+v, want the draft cleared and expireAt = now + TERMINAL_TTL", stored)
				}
			}
		})
	}

	t.Run("a second cancel is a no-op with 0 writes", func(t *testing.T) {
		e := newSchedSvcEnv(newSched(t, schedUID, 1, ScheduledPending))
		if _, _, err := cancel(e, schedUID, schedKeyFor(1), id(1)); err != nil {
			t.Fatal(err)
		}
		got, c, err := cancel(e, schedUID, schedKeyFor(1), id(1))
		if err != nil || got.Status != ScheduledCancelled {
			t.Fatalf("second cancel = %+v, %v", got, err)
		}
		wantReads(t, c, 1, 0)
	})
	t.Run("unknown id is NOT_FOUND", func(t *testing.T) {
		e := newSchedSvcEnv()
		_, _, err := cancel(e, schedUID, schedKeyFor(1), strings.Repeat("a", 32))
		_ = wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	})
	t.Run("another user's id is NOT_FOUND and the item is untouched", func(t *testing.T) {
		bobs := newSched(t, "uid-bob", 1, ScheduledPending)
		e := newSchedSvcEnv(bobs)
		_, _, err := cancel(e, schedUID, schedKeyFor(1), bobs.ID)
		ae := wantAPIError(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
		_, _, err2 := cancel(e, schedUID, schedKeyFor(1), strings.Repeat("b", 32))
		ae2 := wantAPIError(t, err2, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
		if ae.Message != ae2.Message {
			t.Errorf("messages differ (an existence oracle): %q vs %q", ae.Message, ae2.Message)
		}
		if got := e.repo.stored("uid-bob", bobs.ID); got.Status != ScheduledPending || got.Draft == nil {
			t.Errorf("bob's item changed: %+v", got)
		}
	})
	t.Run("malformed ids and keys are VALIDATION with no reads", func(t *testing.T) {
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
			_, c, err := cancel(e, schedUID, tc.key, tc.sid)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != tc.field {
				t.Errorf("%s: field = %q, want %q", tc.name, ae.Metadata["field"], tc.field)
			}
			wantReads(t, c, 0, 0)
		}
		if e.repo.cancels != 0 {
			t.Error("the repository was reached")
		}
	})
	t.Run("a store failure is internal and scrubbed", func(t *testing.T) {
		e := newSchedSvcEnv()
		e.repo.cancelErr = fmt.Errorf("documents/users/%s/scheduled/x: %w", schedUID, errBoom)
		_, _, err := cancel(e, schedUID, schedKeyFor(1), id(1))
		if err == nil || errors.As(err, new(*apierr.Error)) || strings.Contains(logger.CauseChain(err), schedUID) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("the TTL passed on is SCHEDULED_TERMINAL_TTL", func(t *testing.T) {
		e := newSchedSvcEnv(newSched(t, schedUID, 1, ScheduledPending))
		e.svc.schedule.TerminalTTL = 24 * time.Hour
		if _, _, err := cancel(e, schedUID, schedKeyFor(1), id(1)); err != nil {
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
