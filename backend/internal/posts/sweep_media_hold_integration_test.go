//go:build integration

package posts

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

// TestSweepIT_MediaHold runs the real Sweep over the real repository: while FEATURE_MEDIA is globally off an
// item with an image stays exactly as the query read it (no write, no transaction, no media read, no attempt), and once the
// flag is back on the next run publishes it like any other.
func TestSweepIT_MediaHold(t *testing.T) {
	fl := sweepFlags{mediaFlagName: true} // FEATURE_MEDIA is off for everyone
	e := newSweepIT(t, func(d *Deps) { d.Sweep.Flags = fl })
	var txns atomic.Int32
	e.fault.beforePublish = func(PublishParams) { txns.Add(1) }
	e.signUp("uid-alice", "alice")
	e.seedMedia("uid-alice", nil, 1)
	it := e.seedDue("uid-alice", 1, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{Text: "a picture", Media: []MediaRef{{ID: sweepMediaID(1), AltText: "an alt"}}}
	})
	updateTime := func() time.Time {
		snap, err := e.client.Collection("users").Doc(it.UID).Collection("scheduled").Doc(it.ID).Get(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		return snap.UpdateTime
	}
	before := updateTime()

	// Media off: held. The run's whole cost is the due query's one read.
	res, c := e.sweep()
	if res.Outcome != SweepOK || res.Due != 1 || res.HeldMedia != 1 || res.Published != 0 || res.Deferred != 0 || res.Transient != 0 ||
		res.Noop != 0 || res.WriteFailed != 0 || len(res.Failed) != 0 {
		t.Fatalf("held run: res = %+v, want 1 due and 1 held", res)
	}
	assertCost(t, "held run", c, 1, 0)
	if n := txns.Load(); n != 0 {
		t.Errorf("%d publish transactions for a held item, want 0", n)
	}
	if n := e.media.loadCount(); n != 0 {
		t.Errorf("%d media loads for a held item, want 0", n)
	}
	if got := updateTime(); !got.Equal(before) {
		t.Errorf("the scheduled doc was written (UpdateTime %v -> %v)", before, got)
	}
	doc := e.raw(it)
	if doc["status"] != "PENDING" || doc["draft"] == nil || doc["postId"] != nil || doc["failure"] != nil {
		t.Errorf("scheduled doc = %v, want PENDING with its draft and no post", doc)
	}
	if n, _ := doc["attempts"].(int64); n != 0 {
		t.Errorf("attempts = %v, want 0: a hold is not a failure", doc["attempts"])
	}
	if got, _ := e.mediaDoc(1)["postId"].(string); got != "" {
		t.Errorf("the image was attached to %q while media was off", got)
	}
	if p := e.postsOf("uid-alice"); len(p) != 0 || e.postsCount("uid-alice") != 0 || e.quotaPosts("uid-alice") != 0 {
		t.Errorf("posts %d postsCount %d quota posts %d, want none", len(p), e.postsCount("uid-alice"), e.quotaPosts("uid-alice"))
	}

	// A second held run is the same: nothing accumulates.
	res, c = e.sweep()
	if res.HeldMedia != 1 || res.Published != 0 {
		t.Fatalf("second held run: res = %+v", res)
	}
	assertCost(t, "second held run", c, 1, 0)

	// Media on again: no special handling, the next run publishes it with its image.
	delete(fl, mediaFlagName)
	res, c = e.sweep()
	if res.Outcome != SweepOK || res.Published != 1 || res.HeldMedia != 0 || len(res.Failed) != 0 {
		t.Fatalf("run after the flag returned: res = %+v, want 1 published", res)
	}
	// due query 1 + scheduled 1 + users 1 + quotas 1 + media 1 = 5 reads; post, postsCount, quotas, scheduled, media = 5 writes.
	assertCost(t, "publish after the hold", c, 5, 5)
	if n := txns.Load(); n != 1 {
		t.Errorf("publish transactions = %d, want 1", n)
	}
	doc = e.raw(it)
	postID, _ := doc["postId"].(string)
	if doc["status"] != "PUBLISHED" || postID == "" || doc["draft"] != nil {
		t.Fatalf("scheduled doc = %v, want PUBLISHED with a postId and no draft", doc)
	}
	if posts := e.postsOf("uid-alice"); len(posts) != 1 || len(posts[0].Media) != 1 || posts[0].Media[0].AltText != "an alt" {
		t.Errorf("posts = %+v, want one post carrying the image and its alt text", posts)
	}
	if got, _ := e.mediaDoc(1)["postId"].(string); got != postID {
		t.Errorf("the image is attached to %q, want %q", got, postID)
	}
}
