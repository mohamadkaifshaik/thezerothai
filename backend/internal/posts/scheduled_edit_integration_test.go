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

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// Emulator tests of Post now (F10) and Edit (F11) over the real FirestoreRepo and the real publish transaction.

func newEditIT(t *testing.T) *sweepIT {
	t.Helper()
	e := newSweepIT(t)
	w := e.repo.w
	w.Quotas = quota.New(e.client) // UpdateScheduled serialises a time move on quotas/{uid}, like CreateScheduled
	e.repo.SetWriters(w)
	return e
}

// seedFuture stores a PENDING item of uid for publish time at, n distinguishing its id.
func (e *sweepIT) seedFuture(uid string, n int, at time.Time, mut ...func(*ScheduledPost)) *ScheduledPost {
	e.t.Helper()
	return e.seedDue(uid, n, append([]func(*ScheduledPost){func(p *ScheduledPost) { p.PublishAt = at.UTC().Truncate(time.Minute) }}, mut...)...)
}

func (e *sweepIT) editCtx(uid string) context.Context { return googleCtx(context.Background(), uid) }

func codeOf(err error) connect.Code {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.Code
	}
	return connect.CodeOf(err)
}

func TestScheduledEditIT_UpdateWritesAndReplays(t *testing.T) {
	e := newEditIT(t)
	e.signUp("alice", "alice")
	at := time.Now().Add(3 * time.Hour)
	item := e.seedFuture("alice", 1, at, func(p *ScheduledPost) { p.Draft.ReplyPolicy = ReplyPolicyFollowing })
	txt, pol := "edited text", int32(0)
	in := UpdateScheduledInput{
		IdempotencyKey: schedKeyFor(50), ScheduledID: item.ID, Text: &txt, ReplyPolicy: &pol,
		PublishAt: at.Add(40 * time.Minute), HasPublishAt: true,
	}
	got, err := e.svc.UpdateScheduled(e.editCtx("alice"), "alice", in)
	if err != nil {
		t.Fatal(err)
	}
	raw := e.raw(item)
	draft, _ := raw["draft"].(map[string]any)
	if got.Draft.Text != txt || draft["text"] != txt {
		t.Errorf("text: item %q stored %v", got.Draft.Text, draft["text"])
	}
	if _, has := draft["replyPolicy"]; has {
		t.Errorf("EVERYONE must delete draft.replyPolicy, stored %v", draft)
	}
	if want := at.Add(40 * time.Minute).UTC().Truncate(time.Minute); !got.PublishAt.Equal(want) {
		t.Errorf("PublishAt = %v, want %v", got.PublishAt, want)
	}
	if raw["status"] != "PENDING" || raw["requestHash"] != "h" {
		t.Errorf("status/requestHash changed: %v", raw)
	}
	before := raw["updatedAt"]

	// Replay: same key and values -> same item, no write (updatedAt untouched).
	again, err := e.svc.UpdateScheduled(e.editCtx("alice"), "alice", in)
	if err != nil || again.Draft.Text != txt || !again.PublishAt.Equal(got.PublishAt) {
		t.Fatalf("replay = %+v, %v", again, err)
	}
	if after := e.raw(item)["updatedAt"]; after != before {
		t.Errorf("a replay wrote: updatedAt %v -> %v", before, after)
	}
	// Near the new time the same edit is still a replay: the stored minute is unchanged, so the bounds are not applied.
	late := New(e.deps).(*service)
	late.now = func() time.Time { return got.PublishAt.Add(-30 * time.Second) }
	if again, err := late.UpdateScheduled(e.editCtx("alice"), "alice", in); err != nil || again.Draft.Text != txt {
		t.Errorf("replay inside the lockout = %+v, %v", again, err)
	}
	// The sweep does not see it as due (it moved into the future and is PENDING).
	if res := e.sweep(); res.Published != 0 {
		t.Errorf("sweep published %d", res.Published)
	}
}

func TestScheduledEditIT_Refusals(t *testing.T) {
	e := newEditIT(t)
	e.signUp("alice", "alice")
	e.signUp("bob", "bob")
	txt := "new"
	upd := func(uid string, p *ScheduledPost) error {
		_, err := e.svc.UpdateScheduled(e.editCtx(uid), uid, UpdateScheduledInput{IdempotencyKey: schedKeyFor(60), ScheduledID: p.ID, Text: &txt})
		return err
	}
	locked := e.seedFuture("alice", 1, time.Now().Add(30*time.Second))
	published := e.seedFuture("alice", 2, time.Now().Add(2*time.Hour), func(p *ScheduledPost) { p.Status, p.Draft, p.PostID = ScheduledPublished, nil, "9" })
	cancelled := e.seedFuture("alice", 3, time.Now().Add(2*time.Hour), func(p *ScheduledPost) { p.Status, p.Draft = ScheduledCancelled, nil })
	mine := e.seedFuture("alice", 4, time.Now().Add(2*time.Hour))
	tests := []struct {
		name string
		err  error
		want connect.Code
	}{
		{"within 60 s", upd("alice", locked), connect.CodeFailedPrecondition},
		{"after publish", upd("alice", published), connect.CodeFailedPrecondition},
		{"cancelled", upd("alice", cancelled), connect.CodeFailedPrecondition},
		{"another user's item", upd("bob", mine), connect.CodeNotFound},
	}
	for _, tt := range tests {
		if codeOf(tt.err) != tt.want {
			t.Errorf("%s: %v, want %v", tt.name, tt.err, tt.want)
		}
	}
	if d, _ := e.raw(mine)["draft"].(map[string]any); d["text"] == txt {
		t.Error("another user's edit wrote")
	}
	// Equal values inside the lockout are the replay of an applied edit: the stored item, no error.
	same := "hello 1"
	if _, err := e.svc.UpdateScheduled(e.editCtx("alice"), "alice", UpdateScheduledInput{IdempotencyKey: schedKeyFor(61), ScheduledID: locked.ID, Text: &same}); err != nil {
		t.Errorf("equal values inside the lockout: %v", err)
	}
}

func TestScheduledEditIT_WindowCapExcludesTheItemItself(t *testing.T) {
	e := newEditIT(t)
	e.signUp("alice", "alice")
	base := time.Now().Add(5 * time.Hour).Truncate(time.Minute)
	self := e.seedFuture("alice", 1, base)
	e.seedFuture("alice", 2, base.Add(time.Minute))
	e.seedFuture("alice", 3, base.Add(2*time.Minute))
	// 3 in the window including itself (cap 3): moving it one minute inside the window is allowed, it is not counted twice.
	move := func(at time.Time) error {
		_, err := e.svc.UpdateScheduled(e.editCtx("alice"), "alice", UpdateScheduledInput{IdempotencyKey: schedKeyFor(70), ScheduledID: self.ID, PublishAt: at, HasPublishAt: true})
		return err
	}
	if err := move(base.Add(30 * time.Second)); err != nil { // truncates to base: equal, a no-op
		t.Errorf("same minute: %v", err)
	}
	if err := move(base.Add(3 * time.Minute)); err != nil {
		t.Errorf("move inside the same window: %v", err)
	}
	// A 4th item in the window of the target is refused with LIMIT_REACHED.
	other := e.seedFuture("alice", 4, base.Add(3*time.Hour))
	_, err := e.svc.UpdateScheduled(e.editCtx("alice"), "alice", UpdateScheduledInput{IdempotencyKey: schedKeyFor(71), ScheduledID: other.ID, PublishAt: base.Add(2 * time.Minute), HasPublishAt: true})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["limit"] != limitScheduledWindow {
		t.Errorf("full window: %v, want LIMIT_REACHED scheduled_window", err)
	}
	if got := e.raw(other)["publishAt"]; got == nil {
		t.Error("lost publishAt")
	}
}

func TestScheduledEditIT_PublishNow(t *testing.T) {
	e := newEditIT(t)
	e.signUp("alice", "alice")
	item := e.seedFuture("alice", 1, time.Now().Add(6*time.Hour))
	got, err := e.svc.PublishScheduledNow(e.editCtx("alice"), "alice", schedKeyFor(80), item.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != ScheduledPublished || got.PostID == "" || got.Draft != nil {
		t.Fatalf("item = %+v", got)
	}
	posts := e.postsOf("alice")
	if len(posts) != 1 || e.postsCount("alice") != 1 {
		t.Fatalf("posts = %d, postsCount %d, want 1 and 1", len(posts), e.postsCount("alice"))
	}
	if e.raw(item)["status"] != "PUBLISHED" || e.raw(item)["expireAt"] == nil {
		t.Errorf("stored = %v", e.raw(item))
	}
	if len(e.events.created) != 1 {
		t.Errorf("created events = %d, want 1", len(e.events.created))
	}

	// Idempotent replay: same item, still one post.
	again, err := e.svc.PublishScheduledNow(e.editCtx("alice"), "alice", schedKeyFor(80), item.ID, true)
	if err != nil || again.PostID != got.PostID || len(e.postsOf("alice")) != 1 {
		t.Fatalf("replay = %+v, %v, posts %d", again, err, len(e.postsOf("alice")))
	}
	// Edit after publish and cancel-then-now are FAILED_PRECONDITION.
	txt := "late"
	_, err = e.svc.UpdateScheduled(e.editCtx("alice"), "alice", UpdateScheduledInput{IdempotencyKey: schedKeyFor(81), ScheduledID: item.ID, Text: &txt})
	if codeOf(err) != connect.CodeFailedPrecondition {
		t.Errorf("edit after publish: %v", err)
	}
	cancelled := e.seedFuture("alice", 2, time.Now().Add(6*time.Hour), func(p *ScheduledPost) { p.Status, p.Draft = ScheduledCancelled, nil })
	if _, err := e.svc.PublishScheduledNow(e.editCtx("alice"), "alice", schedKeyFor(82), cancelled.ID, true); codeOf(err) != connect.CodeFailedPrecondition {
		t.Errorf("cancelled: %v", err)
	}
	if len(e.postsOf("alice")) != 1 {
		t.Error("a refused Post now created a post")
	}
}

// TestScheduledEditIT_PublishNowRacesTheSweep: for items that are DUE, the sweep and Post now run at the same time on two
// instances; every item is published exactly once whichever wins, and both callers get a consistent answer.
func TestScheduledEditIT_PublishNowRacesTheSweep(t *testing.T) {
	e := newEditIT(t)
	const authors = 4
	items := make([]*ScheduledPost, authors)
	for a := 0; a < authors; a++ {
		uid := fmt.Sprintf("uid-r%d", a)
		e.signUp(uid, fmt.Sprintf("racer%d", a))
		items[a] = e.seedDue(uid, 1)
	}
	other := e.second()

	var wg sync.WaitGroup
	errs := make([]error, authors)
	got := make([]*ScheduledPost, authors)
	var sweepErr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, sweepErr = other.Sweep(context.Background())
	}()
	for a := 0; a < authors; a++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			uid := items[a].UID
			got[a], errs[a] = e.svc.PublishScheduledNow(e.editCtx(uid), uid, schedKeyFor(90+a), items[a].ID, true)
		}()
	}
	wg.Wait()
	if sweepErr != nil {
		t.Fatalf("sweep: %v", sweepErr)
	}
	for a, p := range items {
		if errs[a] != nil || got[a].Status != ScheduledPublished || got[a].PostID == "" {
			t.Errorf("author %d: %+v, %v", a, got[a], errs[a])
		}
		if n := len(e.postsOf(p.UID)); n != 1 {
			t.Errorf("author %d has %d posts, want exactly 1", a, n)
		}
		if e.postsCount(p.UID) != 1 {
			t.Errorf("author %d postsCount = %d, want 1", a, e.postsCount(p.UID))
		}
	}
}

// TestScheduledEditIT_StaleDraftIsNeverPublished: an edit that lands between Post now reading the draft and the publish
// transaction makes the transaction a no-op (ExpectUpdateTime); Post now then publishes the edited draft.
func TestScheduledEditIT_StaleDraftIsNeverPublished(t *testing.T) {
	e := newEditIT(t)
	e.signUp("alice", "alice")
	item := e.seedFuture("alice", 1, time.Now().Add(6*time.Hour))
	cur, err := e.repo.GetScheduled(context.Background(), "alice", item.ID)
	if err != nil {
		t.Fatal(err)
	}
	edited := "edited after read"
	if _, err := e.svc.UpdateScheduled(e.editCtx("alice"), "alice", UpdateScheduledInput{IdempotencyKey: schedKeyFor(83), ScheduledID: item.ID, Text: &edited}); err != nil {
		t.Fatal(err)
	}
	params, ok := e.svc.publishParams(cur)
	if !ok {
		t.Fatal("draft does not parse")
	}
	params.ExpectUpdateTime = cur.UpdateTime
	res, err := e.repo.PublishScheduled(context.Background(), params)
	if err != nil || res.Outcome != PublishNoop {
		t.Fatalf("stale publish = %+v, %v, want PublishNoop", res, err)
	}
	if n := len(e.postsOf("alice")); n != 0 {
		t.Fatalf("a stale draft was published (%d posts)", n)
	}
	if _, err := e.svc.PublishScheduledNow(e.editCtx("alice"), "alice", schedKeyFor(84), item.ID, true); err != nil {
		t.Fatal(err)
	}
	posts := e.postsOf("alice")
	if len(posts) != 1 || posts[0].Text != edited {
		t.Errorf("posts = %+v, want one with the edited text", posts)
	}
}
