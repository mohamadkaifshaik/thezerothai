//go:build integration

package posts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const itTTL = 168 * time.Hour

// itMedia is a MediaAttacher over media/{id} docs: it reads them inside the transaction (one read each, as the real
// one does), requires the owner to match, and records any Attach call (a scheduled post must never attach).
type itMedia struct {
	client   *firestore.Client
	attached int
}

func (m *itMedia) LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (MediaClaim, error) {
	refs := make([]*firestore.DocumentRef, len(ids))
	for i, id := range ids {
		refs[i] = m.client.Collection("media").Doc(id)
	}
	snaps, err := tx.GetAll(refs)
	budget.FromContext(ctx).AddReads(int64(len(ids)))
	if err != nil {
		return nil, err
	}
	out := &itClaim{m: m}
	for i, s := range snaps {
		if !s.Exists() {
			return nil, ErrMediaNotReady
		}
		if owner, _ := s.DataAt("ownerId"); owner != uid {
			return nil, ErrMediaNotReady
		}
		out.refs = append(out.refs, MediaRef{ID: ids[i], URL: "https://cdn.example/m/" + ids[i], ThumbURL: "https://cdn.example/t/" + ids[i], Width: 10, Height: 20})
	}
	return out, nil
}

type itClaim struct {
	refs []MediaRef
	m    *itMedia
}

func (c *itClaim) Refs() []MediaRef           { return c.refs }
func (c *itClaim) Attach(store.Batch, string) { c.m.attached++ }

type schedEnv struct {
	client *firestore.Client
	repo   *FirestoreRepo
	media  *itMedia
	quotas *quota.Store
}

func newSchedEnv(t *testing.T) *schedEnv {
	t.Helper()
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	media := &itMedia{client: client}
	quotas := quota.New(client)
	repo.SetWriters(WriteDeps{Quotas: quotas, Media: media})
	return &schedEnv{client: client, repo: repo, media: media, quotas: quotas}
}

func (e *schedEnv) seed(t *testing.T, p *ScheduledPost) {
	t.Helper()
	ref := e.client.Collection("users").Doc(p.UID).Collection("scheduled").Doc(p.ID)
	if _, err := ref.Set(context.Background(), toScheduledDoc(p)); err != nil {
		t.Fatalf("seed %s: %v", p.ID, err)
	}
}

func (e *schedEnv) raw(t *testing.T, uid, id string) map[string]any {
	t.Helper()
	snap, err := e.client.Collection("users").Doc(uid).Collection("scheduled").Doc(id).Get(context.Background())
	if err != nil {
		t.Fatalf("raw get: %v", err)
	}
	return snap.Data()
}

func (e *schedEnv) schedules(t *testing.T, uid string) int64 {
	t.Helper()
	snap, err := e.quotas.Ref(uid).Get(context.Background())
	if err != nil {
		return 0
	}
	var rec quota.Record
	if err := snap.DataTo(&rec); err != nil {
		t.Fatal(err)
	}
	return rec.Schedules
}

func (e *schedEnv) params(t *testing.T, uid string, n int, publishAt time.Time) ScheduledCreateParams {
	t.Helper()
	id, err := ScheduledID(uid, schedKeyFor(n))
	if err != nil {
		t.Fatal(err)
	}
	return ScheduledCreateParams{
		UID: uid, ID: id, PublishAt: publishAt, RequestHash: "hash", Now: schedNow, QuotaLimit: 50,
		Draft: ScheduledDraft{Text: "hello", ReplyPolicy: ReplyPolicyMentionedOnly, MadeWithAI: true},
	}
}

func counted() (context.Context, *budget.Counter) { return budget.WithCounter(context.Background()) }

// TestScheduled_Integration_CreateAndReplay: the schedule transaction stores the documented shape in 1 read and 2
// writes, a repeat of the id is ErrScheduledExists with nothing written and the stored draft untouched (Create
// precondition), and the daily cap rejects with QUOTA_EXCEEDED quota=schedules and nothing written.
func TestScheduled_Integration_CreateAndReplay(t *testing.T) {
	e := newSchedEnv(t)
	p := e.params(t, "alice", 1, schedBase.Add(30*time.Second)) // not on a whole minute: stored truncated

	ctx, c := counted()
	got, err := e.repo.CreateScheduled(ctx, p)
	if err != nil {
		t.Fatalf("CreateScheduled: %v", err)
	}
	budgettest.Assert(t, "CreateScheduled", c, budgettest.Budget{Reads: 1, Writes: 2})
	if c.Reads() != 1 || c.Writes() != 2 {
		t.Errorf("CreateScheduled cost = %d reads %d writes, want 1 and 2", c.Reads(), c.Writes())
	}
	if !got.PublishAt.Equal(schedBase) || got.Status != ScheduledPending {
		t.Errorf("created = %+v, want PENDING at %v", got, schedBase)
	}

	raw := e.raw(t, "alice", p.ID)
	for _, absent := range []string{"expireAt", "failure", "postId"} {
		if _, has := raw[absent]; has {
			t.Errorf("a PENDING document must not carry %s: %v", absent, raw)
		}
	}
	draft, _ := raw["draft"].(map[string]any)
	if raw["status"] != "PENDING" || raw["schemaVersion"] != int64(1) || raw["attempts"] != int64(0) || raw["requestHash"] != "hash" ||
		draft["text"] != "hello" || draft["replyPolicy"] != "MENTIONED_ONLY" || draft["madeWithAi"] != true {
		t.Errorf("stored document = %v", raw)
	}
	if _, has := draft["paidPartnership"]; has {
		t.Errorf("a false disclosure label must be omitted: %v", draft)
	}
	if e.schedules(t, "alice") != 1 {
		t.Errorf("quotas.schedules = %d, want 1", e.schedules(t, "alice"))
	}

	rd, rc := counted()
	read, err := e.repo.GetScheduled(rd, "alice", p.ID)
	if err != nil || rc.Reads() != 1 || read.UpdateTime.IsZero() || read.Draft == nil || read.Draft.Text != "hello" || read.UID != "alice" {
		t.Fatalf("GetScheduled = %+v err=%v reads=%d", read, err, rc.Reads())
	}

	// A replay (same id, even with a different body) never overwrites.
	again := p
	again.Draft = ScheduledDraft{Text: "overwritten?"}
	rctx, rcnt := counted()
	if _, err := e.repo.CreateScheduled(rctx, again); !errors.Is(err, ErrScheduledExists) {
		t.Fatalf("replay err = %v, want ErrScheduledExists", err)
	}
	if rcnt.Writes() != 0 {
		t.Errorf("a replay wrote %d documents", rcnt.Writes())
	}
	if after := e.raw(t, "alice", p.ID); after["draft"].(map[string]any)["text"] != "hello" {
		t.Errorf("the replay changed the stored draft: %v", after)
	}
	if e.schedules(t, "alice") != 1 {
		t.Errorf("a replay charged the quota: schedules = %d", e.schedules(t, "alice"))
	}

	t.Run("daily cap", func(t *testing.T) {
		capped := e.params(t, "alice", 2, schedBase.Add(time.Hour))
		capped.QuotaLimit = 1
		cctx, cc := counted()
		_, err := e.repo.CreateScheduled(cctx, capped)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Metadata["quota"] != "schedules" {
			t.Fatalf("err = %v, want QUOTA_EXCEEDED quota=schedules", err)
		}
		if cc.Writes() != 0 {
			t.Errorf("a rejected call wrote %d documents", cc.Writes())
		}
		if _, err := e.repo.GetScheduled(context.Background(), "alice", capped.ID); !errors.Is(err, ErrScheduledNotFound) {
			t.Errorf("the capped document exists: %v", err)
		}
	})
}

// TestScheduled_Integration_CreateWithMedia: media are validated (1 read each) and copied with their alt texts, never
// attached; a missing or foreign image is ErrMediaNotReady with nothing written.
func TestScheduled_Integration_CreateWithMedia(t *testing.T) {
	e := newSchedEnv(t)
	ctx := context.Background()
	for _, m := range []struct{ id, owner string }{{"m1", "alice"}, {"m2", "alice"}, {"m3", "bob"}} {
		if _, err := e.client.Collection("media").Doc(m.id).Set(ctx, map[string]any{"ownerId": m.owner}); err != nil {
			t.Fatal(err)
		}
	}
	p := e.params(t, "alice", 1, schedBase)
	p.MediaIDs, p.MediaAlts = []string{"m1", "m2"}, []string{"first", ""}
	cctx, c := counted()
	got, err := e.repo.CreateScheduled(cctx, p)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "CreateScheduled with 2 images", c, budgettest.Budget{Reads: 1 + 2, Writes: 2})
	if c.Reads() != 3 || e.media.attached != 0 {
		t.Errorf("reads = %d, attached = %d, want 3 and 0 (validated, not reserved)", c.Reads(), e.media.attached)
	}
	if len(got.Draft.Media) != 2 || got.Draft.Media[0].AltText != "first" || got.Draft.Media[0].URL == "" {
		t.Errorf("draft media = %+v", got.Draft.Media)
	}
	stored, err := e.repo.GetScheduled(ctx, "alice", p.ID)
	if err != nil || len(stored.Draft.Media) != 2 || stored.Draft.Media[0].ID != "m1" || stored.Draft.Media[0].AltText != "first" {
		t.Fatalf("stored media = %+v err=%v", stored, err)
	}

	for name, ids := range map[string][]string{"someone else's image": {"m3"}, "an unknown image": {"nope"}} {
		bad := e.params(t, "alice", 2, schedBase.Add(time.Hour))
		bad.MediaIDs = ids
		bctx, bc := counted()
		if _, err := e.repo.CreateScheduled(bctx, bad); !errors.Is(err, ErrMediaNotReady) {
			t.Errorf("%s: err = %v, want ErrMediaNotReady", name, err)
		}
		if bc.Writes() != 0 {
			t.Errorf("%s: wrote %d documents", name, bc.Writes())
		}
	}
	if e.schedules(t, "alice") != 1 {
		t.Errorf("schedules = %d, want 1: only the successful call is charged", e.schedules(t, "alice"))
	}
}

// TestScheduled_Integration_ListPagination: PENDING and FAILED items interleaved by publishAt page across the status
// boundary in (publishAt, id) order, PUBLISHED and CANCELLED never appear, another user's items never appear, and a
// page costs one read per item.
func TestScheduled_Integration_ListPagination(t *testing.T) {
	e := newSchedEnv(t)
	var want []string
	statuses := []ScheduledStatus{ScheduledPending, ScheduledFailed, ScheduledPublished, ScheduledPending, ScheduledCancelled, ScheduledFailed, ScheduledPending}
	for n, st := range statuses {
		p := newSched(t, "alice", n, st)
		e.seed(t, p)
		if st == ScheduledPending || st == ScheduledFailed {
			want = append(want, p.ID)
		}
	}
	// Two items share one publishAt: the id breaks the tie.
	t1, t2 := newSched(t, "alice", 100, ScheduledPending), newSched(t, "alice", 101, ScheduledFailed)
	t2.PublishAt = t1.PublishAt
	e.seed(t, t1)
	e.seed(t, t2)
	if t1.ID < t2.ID {
		want = append(want, t1.ID, t2.ID)
	} else {
		want = append(want, t2.ID, t1.ID)
	}
	e.seed(t, newSched(t, "bob", 0, ScheduledPending))

	var got []string
	token := ""
	for pages := 0; pages < 10; pages++ {
		ctx, c := counted()
		page, err := ListScheduledPage(ctx, e.repo, schedKey, "alice", 3, token, schedNow)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "ListScheduledPosts page", c, budgettest.Budget{Reads: 3})
		if c.Reads() != int64(max(len(page.Items), 1)) || c.Writes() != 0 {
			t.Errorf("page cost = %d reads %d writes for %d items", c.Reads(), c.Writes(), len(page.Items))
		}
		for _, p := range page.Items {
			got = append(got, p.ID)
			if p.Status != ScheduledPending && p.Status != ScheduledFailed {
				t.Errorf("a %s item in the list", p.Status)
			}
		}
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("listed %v\nwant   %v", got, want)
	}

	// A token from alice opens nothing for bob.
	first, _ := ListScheduledPage(context.Background(), e.repo, schedKey, "alice", 2, "", schedNow)
	if _, err := ListScheduledPage(context.Background(), e.repo, schedKey, "bob", 2, first.NextPageToken, schedNow); !errors.Is(err, ErrInvalidScheduledToken) {
		t.Errorf("foreign token: %v", err)
	}
	// An empty list costs one read.
	ctx, c := counted()
	if page, err := ListScheduledPage(ctx, e.repo, schedKey, "carol", 20, "", schedNow); err != nil || len(page.Items) != 0 || c.Reads() != 1 {
		t.Errorf("empty list = %d items err=%v reads=%d, want 0 items and 1 read", len(page.Items), err, c.Reads())
	}
}

// TestScheduled_Integration_Counts: the pending count stops at its limit, the window count covers +/-4 min inclusive
// and only PENDING items of the caller, and each costs one read.
func TestScheduled_Integration_Counts(t *testing.T) {
	e := newSchedEnv(t)
	for n := 0; n < 5; n++ {
		e.seed(t, newSched(t, "alice", n, ScheduledPending))
	}
	e.seed(t, newSched(t, "alice", 20, ScheduledFailed))
	e.seed(t, newSched(t, "alice", 21, ScheduledPublished))
	e.seed(t, newSched(t, "bob", 0, ScheduledPending))

	for limit, want := range map[int]int64{26: 5, 5: 5, 3: 3, 1: 1} {
		ctx, c := counted()
		got, err := e.repo.CountPending(ctx, "alice", limit)
		if err != nil || got != want || c.Reads() != 1 {
			t.Errorf("CountPending(limit %d) = %d err=%v reads=%d, want %d and 1 read", limit, got, err, c.Reads(), want)
		}
	}

	w := newSched(t, "carol", 0, ScheduledPending).PublishAt // the centre
	offsets := []time.Duration{-5 * time.Minute, -4 * time.Minute, -time.Minute, 0, 4 * time.Minute, 5 * time.Minute}
	for i, off := range offsets {
		p := newSched(t, "carol", 50+i, ScheduledPending)
		p.PublishAt = w.Add(off)
		e.seed(t, p)
	}
	failedInside := newSched(t, "carol", 60, ScheduledFailed)
	failedInside.PublishAt = w
	e.seed(t, failedInside)
	otherUser := newSched(t, "dave", 61, ScheduledPending)
	otherUser.PublishAt = w
	e.seed(t, otherUser)

	for limit, want := range map[int]int64{4: 4, 3: 3, 2: 2} {
		ctx, c := counted()
		got, err := e.repo.CountWindow(ctx, "carol", w, limit)
		if err != nil || got != want || c.Reads() != 1 {
			t.Errorf("CountWindow(limit %d) = %d err=%v reads=%d, want %d and 1 read", limit, got, err, c.Reads(), want)
		}
	}
	// Four PENDING items are inside [-4m, +4m]: -4, -1, 0, +4. The -5 and +5 items, the FAILED one and dave's are not.
	if got, err := e.repo.CountWindow(context.Background(), "carol", w, 26); err != nil || got != 4 {
		t.Errorf("CountWindow = %d err=%v, want 4", got, err)
	}
	if got, err := e.repo.CountWindow(context.Background(), "carol", w.Add(24*time.Hour), 26); err != nil || got != 0 {
		t.Errorf("CountWindow far away = %d err=%v, want 0", got, err)
	}
}

// TestScheduled_Integration_Cancel: PENDING and FAILED become CANCELLED in 1 read and 1 write, clearing the draft;
// PUBLISHED and CANCELLED are returned unchanged with 0 writes; another user's id is not found.
func TestScheduled_Integration_Cancel(t *testing.T) {
	e := newSchedEnv(t)
	pending, failed, published := newSched(t, "alice", 1, ScheduledPending), newSched(t, "alice", 2, ScheduledFailed), newSched(t, "alice", 3, ScheduledPublished)
	failed.Failure = FailureMediaUnavailable
	published.PostID = "1234567890123456789"
	for _, p := range []*ScheduledPost{pending, failed, published} {
		e.seed(t, p)
	}

	for _, p := range []*ScheduledPost{pending, failed} {
		ctx, c := counted()
		got, changed, err := e.repo.CancelScheduled(ctx, "alice", p.ID, schedNow, itTTL)
		if err != nil || !changed || got.Status != ScheduledCancelled || got.Draft != nil {
			t.Fatalf("cancel %s = %+v changed=%v err=%v", p.Status, got, changed, err)
		}
		budgettest.Assert(t, "CancelScheduled", c, budgettest.Budget{Reads: 2, Writes: 1})
		if c.Reads() != 1 || c.Writes() != 1 {
			t.Errorf("cancel cost = %d reads %d writes, want 1 and 1", c.Reads(), c.Writes())
		}
		raw := e.raw(t, "alice", p.ID)
		exp, _ := raw["expireAt"].(time.Time)
		if _, has := raw["draft"]; has || raw["status"] != "CANCELLED" || !exp.Equal(schedNow.Add(itTTL)) || raw["requestHash"] != "h" {
			t.Errorf("stored after cancel = %v", raw)
		}
	}
	if raw := e.raw(t, "alice", failed.ID); raw["failure"] != "MEDIA_UNAVAILABLE" {
		t.Errorf("a dismissed FAILED item keeps its failure: %v", raw)
	}

	for name, id := range map[string]string{"already cancelled": pending.ID, "published (too late)": published.ID} {
		ctx, c := counted()
		got, changed, err := e.repo.CancelScheduled(ctx, "alice", id, schedNow.Add(time.Hour), itTTL)
		if err != nil || changed || c.Writes() != 0 || c.Reads() != 1 {
			t.Errorf("%s: changed=%v err=%v reads=%d writes=%d, want unchanged, 1 read, 0 writes", name, changed, err, c.Reads(), c.Writes())
		}
		if got.Draft != nil {
			t.Errorf("%s: the draft came back", name)
		}
	}
	if got, _, _ := e.repo.CancelScheduled(context.Background(), "alice", published.ID, schedNow, itTTL); got.Status != ScheduledPublished || got.PostID != published.PostID {
		t.Errorf("a cancel of a PUBLISHED item must report PUBLISHED with its post: %+v", got)
	}

	if _, _, err := e.repo.CancelScheduled(context.Background(), "bob", pending.ID, schedNow, itTTL); !errors.Is(err, ErrScheduledNotFound) {
		t.Errorf("another user's id: %v, want ErrScheduledNotFound", err)
	}
	missing, _ := ScheduledID("alice", schedKeyFor(999))
	if _, _, err := e.repo.CancelScheduled(context.Background(), "alice", missing, schedNow, itTTL); !errors.Is(err, ErrScheduledNotFound) {
		t.Errorf("unknown id: %v", err)
	}
	if _, _, err := e.repo.CancelScheduled(context.Background(), "alice", "../users/bob", schedNow, itTTL); !errors.Is(err, ErrInvalidScheduledID) {
		t.Errorf("malformed id: %v", err)
	}
	if _, _, err := e.repo.CancelScheduled(context.Background(), "a/b", pending.ID, schedNow, itTTL); !errors.Is(err, ErrInvalidScheduledID) {
		t.Errorf("malformed uid: %v", err)
	}
	if _, err := e.client.Collection("users").Doc("alice").Collection("scheduled").Doc(missing).Get(context.Background()); err == nil {
		t.Error("a cancel of an unknown id created a document")
	}
}

// TestScheduled_Integration_Transitions: sweep-side writes are conditional on the snapshot they were read from. A
// stale reference, a document that moved on, or one the eraser deleted yields applied=false and writes nothing, and
// nothing is ever recreated.
func TestScheduled_Integration_Transitions(t *testing.T) {
	e := newSchedEnv(t)
	ctx := context.Background()
	mk := func(n int) *ScheduledPost {
		p := newSched(t, "alice", n, ScheduledPending)
		e.seed(t, p)
		got, err := e.repo.GetScheduled(ctx, "alice", p.ID)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}

	t.Run("fail clears the draft and stamps the ttl", func(t *testing.T) {
		p := mk(1)
		wctx, c := counted()
		next, applied, err := e.repo.TransitionScheduled(wctx, p.Ref(), ScheduledTransition{To: ScheduledFailed, Failure: FailureExpired}, schedNow, itTTL)
		if err != nil || !applied || next.UpdateTime.IsZero() || next.UpdateTime.Equal(p.UpdateTime) {
			t.Fatalf("applied=%v err=%v next=%+v", applied, err, next)
		}
		budgettest.Assert(t, "TransitionScheduled", c, budgettest.Budget{Reads: 0, Writes: 1})
		if c.Reads() != 0 || c.Writes() != 1 {
			t.Errorf("cost = %d reads %d writes, want 0 and 1", c.Reads(), c.Writes())
		}
		raw := e.raw(t, "alice", p.ID)
		exp, _ := raw["expireAt"].(time.Time)
		if raw["status"] != "FAILED" || raw["failure"] != "EXPIRED" || raw["draft"] != nil || !exp.Equal(schedNow.Add(itTTL)) {
			t.Errorf("stored = %v", raw)
		}
		// The old reference is now stale: a second write with it is a no-op.
		if _, again, err := e.repo.TransitionScheduled(ctx, p.Ref(), ScheduledTransition{To: ScheduledCancelled}, schedNow, itTTL); err != nil || again {
			t.Errorf("stale reference applied=%v err=%v, want false", again, err)
		}
		// The new reference is current.
		if _, ok, err := e.repo.TransitionScheduled(ctx, next, ScheduledTransition{To: ScheduledCancelled}, schedNow, itTTL); err != nil || !ok {
			t.Errorf("current reference applied=%v err=%v, want true", ok, err)
		}
	})

	t.Run("published clears the draft and sets the post id", func(t *testing.T) {
		p := mk(2)
		if _, ok, err := e.repo.TransitionScheduled(ctx, p.Ref(), ScheduledTransition{To: ScheduledPublished, PostID: "1234567890123456789"}, schedNow, itTTL); err != nil || !ok {
			t.Fatalf("applied=%v err=%v", ok, err)
		}
		raw := e.raw(t, "alice", p.ID)
		if _, has := raw["draft"]; has || raw["postId"] != "1234567890123456789" || raw["status"] != "PUBLISHED" {
			t.Errorf("stored = %v", raw)
		}
	})

	t.Run("attempts", func(t *testing.T) {
		p := mk(3)
		cur := p.Ref()
		for i := 1; i <= 2; i++ {
			wctx, c := counted()
			next, ok, err := e.repo.BumpScheduledAttempts(wctx, cur, schedNow)
			if err != nil || !ok || c.Reads() != 0 || c.Writes() != 1 {
				t.Fatalf("bump %d: applied=%v err=%v reads=%d writes=%d", i, ok, err, c.Reads(), c.Writes())
			}
			cur = next
			if got, _ := e.repo.GetScheduled(ctx, "alice", p.ID); got.Attempts != i || got.Status != ScheduledPending || got.Draft == nil {
				t.Errorf("after bump %d: %+v", i, got)
			}
		}
		if _, ok, _ := e.repo.BumpScheduledAttempts(ctx, p.Ref(), schedNow); ok {
			t.Error("a bump through a stale reference was applied")
		}
		// FAILED after the attempts limit goes through the fresh reference the bump returned.
		if _, ok, err := e.repo.TransitionScheduled(ctx, cur, ScheduledTransition{To: ScheduledFailed, Failure: FailureInternal}, schedNow, itTTL); err != nil || !ok {
			t.Errorf("fail after bumps: applied=%v err=%v", ok, err)
		}
	})

	t.Run("a document the eraser deleted is not recreated", func(t *testing.T) {
		p := mk(4)
		ref := p.Ref()
		if _, err := e.repo.PurgeScheduledPage(ctx, "alice"); err != nil {
			t.Fatal(err)
		}
		for name, run := range map[string]func() (bool, error){
			"transition": func() (bool, error) {
				_, ok, err := e.repo.TransitionScheduled(ctx, ref, ScheduledTransition{To: ScheduledFailed, Failure: FailureInternal}, schedNow, itTTL)
				return ok, err
			},
			"bump": func() (bool, error) { _, ok, err := e.repo.BumpScheduledAttempts(ctx, ref, schedNow); return ok, err },
		} {
			if ok, err := run(); err != nil || ok {
				t.Errorf("%s after the eraser: applied=%v err=%v, want false and no error", name, ok, err)
			}
		}
		if _, err := e.repo.GetScheduled(ctx, "alice", p.ID); !errors.Is(err, ErrScheduledNotFound) {
			t.Errorf("the eraser's document came back: %v", err)
		}
		if _, _, err := e.repo.CancelScheduled(ctx, "alice", p.ID, schedNow, itTTL); !errors.Is(err, ErrScheduledNotFound) {
			t.Errorf("cancel after the eraser: %v", err)
		}
	})

	t.Run("invalid inputs", func(t *testing.T) {
		p := mk(5)
		if _, _, err := e.repo.TransitionScheduled(ctx, ScheduledRef{UID: "alice", ID: p.ID}, ScheduledTransition{To: ScheduledCancelled}, schedNow, itTTL); err == nil {
			t.Error("a reference without an update time was accepted")
		}
		if _, _, err := e.repo.TransitionScheduled(ctx, p.Ref(), ScheduledTransition{To: ScheduledPublished}, schedNow, itTTL); !errors.Is(err, errScheduledTransition) {
			t.Errorf("PUBLISHED without a post id: %v", err)
		}
	})

	t.Run("inside the publish transaction", func(t *testing.T) {
		p := mk(6)
		run := func() (*ScheduledPost, error) {
			var seen *ScheduledPost
			_, err := store.RunTransaction(ctx, e.client, func(ctx context.Context, tx *firestore.Transaction) error {
				cur, err := e.repo.GetScheduledInTx(ctx, tx, "alice", p.ID)
				if err != nil {
					return err
				}
				seen = cur
				if cur.Status != ScheduledPending {
					return nil // the publish transaction ends here: another run, a cancel or the eraser won
				}
				b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
				if err := e.repo.StageScheduledTransition(b, "alice", p.ID, ScheduledTransition{To: ScheduledPublished, PostID: "1234567890123456789"}, schedNow, itTTL); err != nil {
					return err
				}
				return b.Err()
			})
			return seen, err
		}
		first, err := run()
		if err != nil || first.Status != ScheduledPending {
			t.Fatalf("first run: %+v %v", first, err)
		}
		second, err := run()
		if err != nil || second.Status != ScheduledPublished || second.Draft != nil || second.PostID != "1234567890123456789" {
			t.Fatalf("second run saw %+v %v, want PUBLISHED without a draft", second, err)
		}
		missing, _ := ScheduledID("alice", schedKeyFor(998))
		_, err = store.RunTransaction(ctx, e.client, func(ctx context.Context, tx *firestore.Transaction) error {
			_, err := e.repo.GetScheduledInTx(ctx, tx, "alice", missing)
			return err
		})
		if !errors.Is(err, ErrScheduledNotFound) {
			t.Errorf("unknown id in a transaction: %v", err)
		}
	})
}

// TestScheduled_Integration_DueQuery: the collection-group query returns PENDING documents due at or before now in
// (publishAt, path) order, carries the UpdateTime for preconditions, takes the uid from the path, and skips every
// result whose path is not exactly users/{uid}/scheduled/{32 hex}.
func TestScheduled_Integration_DueQuery(t *testing.T) {
	e := newSchedEnv(t)
	ctx := context.Background()
	now := schedBase.Add(10 * time.Minute)

	for _, c := range []struct {
		uid string
		n   int
	}{{"alice", 3}, {"bob", 1}, {"alice", 2}, {"carol", 5}} {
		p := newSched(t, c.uid, c.n, ScheduledPending)
		e.seed(t, p)
	}
	// Not due, or not PENDING: never returned.
	e.seed(t, newSched(t, "alice", 30, ScheduledPending)) // publishAt in the future
	e.seed(t, newSched(t, "alice", 4, ScheduledPublished))
	e.seed(t, newSched(t, "bob", 5, ScheduledFailed))
	e.seed(t, newSched(t, "bob", 6, ScheduledCancelled))
	// Misplaced documents that match the filters: all must be skipped by the path-shape check.
	hex := "0123456789abcdef0123456789abcdef"
	bad := []string{
		"users/alice/scheduled/not-a-scheduled-id",
		"other/x/scheduled/" + hex,
		"users/alice/scheduled/" + hex + "/scheduled/" + hex,
		"users/alice/folder/sub/scheduled/" + hex,
	}
	for _, path := range bad {
		doc := toScheduledDoc(newSched(t, "alice", 1, ScheduledPending))
		if _, err := e.client.Doc(path).Set(ctx, doc); err != nil {
			t.Fatalf("seed %s: %v", path, err)
		}
	}

	dctx, c := counted()
	page, err := e.repo.DueScheduled(dctx, now, 50, nil)
	if err != nil {
		t.Fatal(err)
	}
	if page.SkippedBadPath != len(bad) || page.Undecodable != 0 || page.Next != nil {
		t.Errorf("skipped %d (want %d), undecodable %d, next %v", page.SkippedBadPath, len(bad), page.Undecodable, page.Next)
	}
	// 4 valid + 4 misplaced results, read once each.
	if c.Reads() != int64(len(page.Items)+len(bad)) || c.Writes() != 0 {
		t.Errorf("reads = %d writes = %d, want %d and 0", c.Reads(), c.Writes(), len(page.Items)+len(bad))
	}
	var gotUIDs []string
	prev := time.Time{}
	for _, p := range page.Items {
		gotUIDs = append(gotUIDs, p.UID)
		if p.UpdateTime.IsZero() || p.Status != ScheduledPending || p.PublishAt.After(now) || p.PublishAt.Before(prev) || !ValidScheduledID(p.ID) {
			t.Errorf("bad item %+v", p)
		}
		prev = p.PublishAt
	}
	if len(page.Items) != 4 {
		t.Fatalf("items = %v, want 4 valid ones", gotUIDs)
	}
	for _, p := range page.Items {
		if p.UID == "" || p.Draft == nil {
			t.Errorf("item without uid or draft: %+v", p)
		}
	}

	t.Run("paging resumes after the last raw result", func(t *testing.T) {
		var ids []string
		var cursor *ScheduledDueCursor
		pages := 0
		skipped := 0
		for {
			pg, err := e.repo.DueScheduled(ctx, now, 3, cursor)
			if err != nil {
				t.Fatal(err)
			}
			pages++
			skipped += pg.SkippedBadPath
			for _, p := range pg.Items {
				ids = append(ids, p.ID)
			}
			if pg.Next == nil {
				break
			}
			cursor = pg.Next
			if pages > 10 {
				t.Fatal("paging does not terminate")
			}
		}
		seen := map[string]bool{}
		for _, id := range ids {
			if seen[id] {
				t.Errorf("%s returned twice across pages", id)
			}
			seen[id] = true
		}
		if len(ids) != 4 || skipped != len(bad) {
			t.Errorf("paged items = %d (want 4), skipped = %d (want %d)", len(ids), skipped, len(bad))
		}
	})

	t.Run("a precondition write through a due item", func(t *testing.T) {
		item := page.Items[0]
		if _, ok, err := e.repo.TransitionScheduled(ctx, item.Ref(), ScheduledTransition{To: ScheduledFailed, Failure: FailureExpired}, schedNow, itTTL); err != nil || !ok {
			t.Fatalf("applied=%v err=%v", ok, err)
		}
		again, err := e.repo.DueScheduled(ctx, now, 50, nil)
		if err != nil || len(again.Items) != 3 {
			t.Errorf("after failing one item: %d items err=%v, want 3", len(again.Items), err)
		}
	})
}

// TestScheduled_Integration_EraseAndExport: the export lists every document with the draft where one is held; the
// eraser deletes the owner's documents only, in pages, and the same call on an empty account is done after 1 read.
func TestScheduled_Integration_EraseAndExport(t *testing.T) {
	e := newSchedEnv(t)
	ctx := context.Background()
	pending, failed := newSched(t, "alice", 1, ScheduledPending), newSched(t, "alice", 2, ScheduledFailed)
	failed.Failure = FailureInvalidContent
	published, cancelled := newSched(t, "alice", 3, ScheduledPublished), newSched(t, "alice", 4, ScheduledCancelled)
	published.PostID = "1234567890123456789"
	bobs := newSched(t, "bob", 1, ScheduledPending)
	for _, p := range []*ScheduledPost{pending, failed, published, cancelled, bobs} {
		e.seed(t, p)
	}

	var buf bytes.Buffer
	xctx, xc := counted()
	if err := NewScheduledExporter(e.repo).ExportUser(xctx, "alice", &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		UserID    string `json:"userId"`
		Scheduled []struct {
			ID     string         `json:"id"`
			Status string         `json:"status"`
			Draft  map[string]any `json:"draft"`
			PostID string         `json:"postId"`
		} `json:"scheduled"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil || out.UserID != "alice" || len(out.Scheduled) != 4 {
		t.Fatalf("export = %s err=%v", buf.String(), err)
	}
	if xc.Reads() != 4 || xc.Writes() != 0 {
		t.Errorf("export cost = %d reads %d writes, want 4 and 0", xc.Reads(), xc.Writes())
	}
	for _, it := range out.Scheduled {
		wantDraft := it.Status == "PENDING" || it.Status == "FAILED"
		if (it.Draft != nil) != wantDraft {
			t.Errorf("%s item: draft present = %v, want %v", it.Status, it.Draft != nil, wantDraft)
		}
		if wantDraft && it.Draft["text"] == "" {
			t.Errorf("%s item lost its draft text", it.Status)
		}
	}

	eraser := NewScheduledEraser(e.repo)
	ectx, ec := counted()
	cp, done, err := eraser.PurgeUser(ectx, "alice", ScheduledCheckpoint{})
	if err != nil || !done || cp.Deleted != 4 {
		t.Fatalf("erase = %+v done=%v err=%v, want 4 deleted and done", cp, done, err)
	}
	budgettest.Assert(t, "scheduled erase", ec, budgettest.Budget{Reads: 4, Deletes: 4})
	if ec.Reads() != 4 || ec.Deletes() != 4 || ec.Writes() != 0 {
		t.Errorf("erase cost = %d reads %d deletes %d writes, want 4, 4 and 0", ec.Reads(), ec.Deletes(), ec.Writes())
	}
	if _, err := e.repo.GetScheduled(ctx, "alice", pending.ID); !errors.Is(err, ErrScheduledNotFound) {
		t.Errorf("alice's document survived: %v", err)
	}
	if _, err := e.repo.GetScheduled(ctx, "bob", bobs.ID); err != nil {
		t.Errorf("bob's document was erased: %v", err)
	}
	// An empty account: done, 1 read.
	zctx, zc := counted()
	if cp, done, err := eraser.PurgeUser(zctx, "alice", ScheduledCheckpoint{}); err != nil || !done || cp.Deleted != 0 || zc.Reads() != 1 || zc.Deletes() != 0 {
		t.Errorf("erase of an empty account = %+v done=%v err=%v reads=%d deletes=%d", cp, done, err, zc.Reads(), zc.Deletes())
	}
	// The export of an erased account is a valid empty section.
	buf.Reset()
	if err := NewScheduledExporter(e.repo).ExportUser(ctx, "alice", &buf); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil || len(out.Scheduled) != 0 {
		t.Errorf("export after erase = %s err=%v", buf.String(), err)
	}
}
