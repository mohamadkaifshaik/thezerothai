//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Emulator tests of the Scheduler over the real FirestoreRepo.

type schedSvcIT struct {
	*schedEnv
	svc   *service
	clock time.Time
}

func newSchedSvcIT(t *testing.T, mut ...func(*ScheduleLimits)) *schedSvcIT {
	t.Helper()
	e := newSchedEnv(t)
	limits := defaultScheduleLimits()
	for _, m := range mut {
		m(&limits)
	}
	dir := &fakeDirectory{profiles: map[string]identity.Profile{
		"alice": {UserID: "alice", Handle: "Alice", Status: identity.AccountStatusActive, CreatedAt: schedNow.Add(-72 * time.Hour)},
		"bob":   {UserID: "bob", Handle: "Bob", Status: identity.AccountStatusActive, CreatedAt: schedNow.Add(-72 * time.Hour)},
	}}
	return &schedSvcIT{
		schedEnv: e, clock: schedNow,
		svc: New(Deps{
			Repo: e.repo, Cache: NewCache(time.Minute, 0, 0), Directory: dir,
			CursorKey: schedKey, Scheduled: e.repo, Schedule: limits, Now: func() time.Time { return schedNow },
		}).(*service),
	}
}

func (e *schedSvcIT) ctx(uid string) context.Context {
	return googleCtx(context.Background(), uid)
}

// in builds a request for a distinct key n at schedNow + 1h + n*10min (outside every other item's +/-4 min window).
func (e *schedSvcIT) in(n int, mut ...func(*ScheduleInput)) ScheduleInput {
	in := ScheduleInput{
		IdempotencyKey: schedKeyFor(n), Text: fmt.Sprintf("later %d", n), PublishAt: e.clock.Add(time.Hour + time.Duration(n)*10*time.Minute),
		MediaEnabled: true, ReplyAudienceEnabled: true, DisclosureEnabled: true,
	}
	for _, m := range mut {
		m(&in)
	}
	return in
}

func (e *schedSvcIT) mustSchedule(t *testing.T, uid string, in ScheduleInput) *ScheduledPost {
	t.Helper()
	ctx := e.ctx(uid)
	p, err := e.svc.Schedule(ctx, uid, in)
	if err != nil {
		t.Fatalf("Schedule(%s): %v", in.IdempotencyKey, err)
	}
	return p
}

func itMediaID(n int) string { return fmt.Sprintf("%019d", n) }

func (e *schedSvcIT) seedMedia(t *testing.T, owner string, ns ...int) {
	t.Helper()
	for _, n := range ns {
		if _, err := e.client.Collection("media").Doc(itMediaID(n)).Set(context.Background(), map[string]any{"ownerId": owner}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSchedulerIT_ScheduleReplayAndKeyReuse(t *testing.T) {
	e := newSchedSvcIT(t)
	ctx := e.ctx("alice")
	in := e.in(1, func(i *ScheduleInput) { i.PublishAt = i.PublishAt.Add(37 * time.Second) })
	p, err := e.svc.Schedule(ctx, "alice", in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Status != ScheduledPending || !p.PublishAt.Equal(p.PublishAt.Truncate(time.Minute)) {
		t.Errorf("item = %+v", p)
	}
	raw := e.raw(t, "alice", p.ID)
	if raw["status"] != "PENDING" || raw["schemaVersion"] != int64(1) || raw["requestHash"] == "" {
		t.Errorf("stored doc = %v", raw)
	}
	if _, hasExpire := raw["expireAt"]; hasExpire {
		t.Error("a PENDING doc must not carry expireAt")
	}

	// A replay, even after the lead time passed: the stored item.
	late := e.svc
	late.now = func() time.Time { return schedNow.Add(24 * time.Hour) }
	rctx := e.ctx("alice")
	again, err := late.Schedule(rctx, "alice", in)
	if err != nil || again.ID != p.ID {
		t.Fatalf("replay = %+v, %v", again, err)
	}
	late.now = func() time.Time { return schedNow }

	// The same key with another effective body is IDEMPOTENCY_KEY_REUSED (a minute later; another text).
	for _, mut := range map[string]func(*ScheduleInput){
		"another minute": func(i *ScheduleInput) { i.PublishAt = i.PublishAt.Add(time.Minute) },
		"another text":   func(i *ScheduleInput) { i.Text = "different" },
	} {
		kctx := e.ctx("alice")
		_, err := e.svc.Schedule(kctx, "alice", e.in(1, mut))
		_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	}

	// Another user cannot see the item.
	lctx := e.ctx("bob")
	if page, err := e.svc.ListScheduled(lctx, "bob", 0, ""); err != nil || len(page.Items) != 0 {
		t.Errorf("bob's list = %+v, %v", page, err)
	}
}

func TestSchedulerIT_MediaAndNoDailyCap(t *testing.T) {
	e := newSchedSvcIT(t)
	e.seedMedia(t, "alice", 1, 2, 3, 4)
	e.seedMedia(t, "bob", 9)

	ctx := e.ctx("alice")
	p, err := e.svc.Schedule(ctx, "alice", e.in(1, func(i *ScheduleInput) {
		i.MediaIDs, i.MediaAltTexts = []string{itMediaID(1), itMediaID(2), itMediaID(3), itMediaID(4)}, []string{"a", "", "c", ""}
	}))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Draft.Media) != 4 || p.Draft.Media[0].AltText != "a" || e.media.attached != 0 {
		t.Errorf("media = %+v attached = %d (validated, never reserved)", p.Draft.Media, e.media.attached)
	}

	// Someone else's and unknown images are MEDIA_NOT_READY with nothing written.
	for _, id := range map[string]string{"someone else's": itMediaID(9), "unknown": itMediaID(77)} {
		mctx := e.ctx("alice")
		_, err := e.svc.Schedule(mctx, "alice", e.in(2, func(i *ScheduleInput) { i.MediaIDs = []string{id} }))
		_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
	}
	// No daily cap: the old limit was 50 a day (10 for a new account); a third and fourth schedule go through.
	e.mustSchedule(t, "alice", e.in(3))
	e.mustSchedule(t, "alice", e.in(4))
	e.mustSchedule(t, "bob", e.in(1))
}

func TestSchedulerIT_PendingAndWindowCaps(t *testing.T) {
	e := newSchedSvcIT(t, func(l *ScheduleLimits) { l.MaxPending = 4 })
	base := e.clock.Add(2 * time.Hour)
	at := func(m int) func(*ScheduleInput) {
		return func(i *ScheduleInput) { i.PublishAt = base.Add(time.Duration(m) * time.Minute) }
	}

	// Three items within +/-4 min of the fourth's time fill the window cap (3).
	e.mustSchedule(t, "alice", e.in(1, at(0)))
	e.mustSchedule(t, "alice", e.in(2, at(1)))
	e.mustSchedule(t, "alice", e.in(3, at(2)))
	wctx := e.ctx("alice")
	_, err := e.svc.Schedule(wctx, "alice", e.in(4, at(3)))
	ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if ae.Metadata["limit"] != "scheduled_window" {
		t.Errorf("limit = %q", ae.Metadata["limit"])
	}
	// doc 1 + pending count 1 + quotas (the serialization read) 1 + window count 1 + the document of this key 1 (a full window is checked for a
	// concurrent duplicate); documented 6 with the interceptor.
	// +5 min from the last is outside every window; -4 min inclusive is inside.
	octx := e.ctx("alice")
	if _, err := e.svc.Schedule(octx, "alice", e.in(5, at(7))); err != nil { // 4th pending item; 7 is 5 min after 2
		t.Fatalf("outside the window: %v", err)
	}

	// 4 pending = SCHEDULED_MAX_PENDING: the next one, far away from the others, hits the pending cap first.
	pctx := e.ctx("alice")
	_, err = e.svc.Schedule(pctx, "alice", e.in(6, at(600)))
	ae = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if ae.Metadata["limit"] != "scheduled_pending" {
		t.Errorf("limit = %q", ae.Metadata["limit"])
	}

	// A replay of an existing key still answers with the caps full (L-6); a cancelled slot is free again.
	rctx := e.ctx("alice")
	if again, err := e.svc.Schedule(rctx, "alice", e.in(1, at(0))); err != nil || again.Status != ScheduledPending {
		t.Fatalf("replay with caps full = %+v, %v", again, err)
	}
	id1, _ := ScheduledID("alice", schedKeyFor(1))
	cctx := e.ctx("alice")
	if _, err := e.svc.CancelScheduled(cctx, "alice", schedKeyFor(90), id1); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Schedule(e.ctx("alice"), "alice", e.in(6, at(600))); err != nil {
		t.Fatalf("after freeing a slot: %v", err)
	}
}

func TestSchedulerIT_ListPagination(t *testing.T) {
	e := newSchedSvcIT(t)
	var want []string
	for n := 1; n <= 5; n++ {
		want = append(want, e.mustSchedule(t, "alice", e.in(n)).ID)
	}
	// A FAILED item between #2 and #3 is listed; PUBLISHED and CANCELLED items and another user's are not.
	failed := newSched(t, "alice", 50, ScheduledFailed)
	failed.Draft, failed.Failure, failed.PublishAt = nil, FailureMediaUnavailable, e.clock.Add(time.Hour+25*time.Minute)
	e.seed(t, failed)
	published := newSched(t, "alice", 51, ScheduledPublished)
	published.PublishAt = e.clock.Add(time.Hour + 5*time.Minute)
	e.seed(t, published)
	cancelled := newSched(t, "alice", 52, ScheduledCancelled)
	cancelled.PublishAt = e.clock.Add(time.Hour + 6*time.Minute)
	e.seed(t, cancelled)
	e.mustSchedule(t, "bob", e.in(1))
	want = append(want[:2], append([]string{failed.ID}, want[2:]...)...)

	var got []string
	token := ""
	for page := 0; page < 5; page++ {
		ctx := e.ctx("alice")
		res, err := e.svc.ListScheduled(ctx, "alice", 2, token)
		if err != nil {
			t.Fatalf("page %d: %v", page, err)
		}
		for _, p := range res.Items {
			got = append(got, p.ID)
		}
		if token = res.NextPageToken; token == "" {
			break
		}
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("listed %v, want %v (publishAt ascending, PENDING and FAILED only, own items only)", got, want)
	}

	// A token of another user, a garbage token, and a page_size over the maximum.
	ctx := e.ctx("alice")
	first, err := e.svc.ListScheduled(ctx, "alice", 2, "")
	if err != nil || first.NextPageToken == "" {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct{ uid, tok string }{"foreign": {"bob", first.NextPageToken}, "garbage": {"alice", "zzz"}} {
		fctx := e.ctx(tc.uid)
		_, err := e.svc.ListScheduled(fctx, tc.uid, 2, tc.tok)
		ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if ae.Metadata["field"] != "page_token" {
			t.Errorf("%s: field %q", name, ae.Metadata["field"])
		}
	}
	big, err := e.svc.ListScheduled(ctx, "alice", 5000, "")
	if err != nil || len(big.Items) != 6 || big.NextPageToken != "" {
		t.Errorf("clamped page = %d items, token %q, %v", len(big.Items), big.NextPageToken, err)
	}
}

func TestSchedulerIT_Cancel(t *testing.T) {
	e := newSchedSvcIT(t)
	pending := e.mustSchedule(t, "alice", e.in(1))
	failed := newSched(t, "alice", 50, ScheduledFailed)
	failed.Failure = FailureQuotaExceeded
	e.seed(t, failed)
	published := newSched(t, "alice", 51, ScheduledPublished)
	published.PostID = "1700000000000000001"
	e.seed(t, published)
	bobs := e.mustSchedule(t, "bob", e.in(1))

	cancel := func(uid, id string) (*ScheduledPost, error) {
		return e.svc.CancelScheduled(e.ctx(uid), uid, schedKeyFor(99), id)
	}

	// PENDING -> CANCELLED: draft gone, TTL stamped.
	got, err := cancel("alice", pending.ID)
	if err != nil || got.Status != ScheduledCancelled || got.Draft != nil {
		t.Fatalf("cancel pending = %+v, %v", got, err)
	}
	raw := e.raw(t, "alice", pending.ID)
	if raw["status"] != "CANCELLED" || raw["expireAt"] == nil {
		t.Errorf("stored = %v", raw)
	}
	if _, has := raw["draft"]; has {
		t.Error("the draft survived the cancel")
	}

	// Again: idempotent by state.
	got, err = cancel("alice", pending.ID)
	if err != nil || got.Status != ScheduledCancelled {
		t.Fatalf("second cancel = %+v, %v", got, err)
	}

	// FAILED is dismissed (founder decision), PUBLISHED is returned unchanged with its post id.
	if got, err = cancel("alice", failed.ID); err != nil || got.Status != ScheduledCancelled {
		t.Fatalf("cancel failed = %+v, %v", got, err)
	}
	got, err = cancel("alice", published.ID)
	if err != nil || got.Status != ScheduledPublished || got.PostID != published.PostID {
		t.Fatalf("cancel published = %+v, %v", got, err)
	}
	if e.raw(t, "alice", published.ID)["status"] != "PUBLISHED" {
		t.Error("a PUBLISHED item changed")
	}

	// Unknown and another user's id are the same NOT_FOUND; bob's item is untouched.
	_, errUnknown := cancel("alice", "0123456789abcdef0123456789abcdef")
	_, errForeign := cancel("alice", bobs.ID)
	a := wantAPIError(t, errUnknown, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	b := wantAPIError(t, errForeign, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	if a.Message != b.Message {
		t.Errorf("messages differ: %q vs %q", a.Message, b.Message)
	}
	if raw := e.raw(t, "bob", bobs.ID); raw["status"] != "PENDING" {
		t.Errorf("bob's item = %v", raw)
	}

	// Malformed input never reaches Firestore.
	for _, tc := range []struct{ key, id string }{{schedKeyFor(1), "NOT-HEX"}, {"short", pending.ID}} {
		ctx := e.ctx("alice")
		_, err := e.svc.CancelScheduled(ctx, "alice", tc.key, tc.id)
		_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	}
}

// TestSchedulerIT_ConcurrentDuplicates: several simultaneous first calls of one key end with one document, one quota
// charge and the same item for every caller (the loser answers from the winner's doc).
func TestSchedulerIT_ConcurrentDuplicates(t *testing.T) {
	e := newSchedSvcIT(t)
	const callers = 2 // two keep the emulator well inside the 5 s create-transaction timeout; more only add contention
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		ids     []string
		failure error
	)
	in := e.in(1)
	start := make(chan struct{}) // released together so both calls overlap
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			ctx := e.ctx("alice")
			p, err := e.svc.Schedule(ctx, "alice", in)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				failure = errors.Join(failure, err)
				return
			}
			ids = append(ids, p.ID)
		}()
	}
	close(start)
	wg.Wait()
	if failure != nil {
		var ae *apierr.Error
		t.Fatalf("a concurrent duplicate failed: %v (%v)", failure, errors.As(failure, &ae))
	}
	want, _ := ScheduledID("alice", in.IdempotencyKey)
	for _, id := range ids {
		if id != want {
			t.Errorf("id = %s, want %s", id, want)
		}
	}
	docs, err := e.client.Collection("users").Doc("alice").Collection("scheduled").Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 1 {
		t.Errorf("documents = %d, %v; want 1", len(docs), err)
	}
}
