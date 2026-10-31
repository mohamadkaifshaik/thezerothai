//go:build integration

package posts

import "testing"

// TestSweepIT_GIFDraftIsUnavailableNotPublished (W6-18, ADR-0029 F10): SchedulePost refuses a GIF, so no draft should hold
// one, but a draft that somehow does (a hand-written document, an older revision) must end FAILED / MEDIA_UNAVAILABLE at the
// sweep: no post, nothing attached, no post quota charged. The photo draft next to it still publishes.
func TestSweepIT_GIFDraftIsUnavailableNotPublished(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	e.seedMedia("uid-alice", map[string]any{"contentType": "image/gif"}, 1)
	e.seedMedia("uid-alice", map[string]any{"contentType": "image/jpeg"}, 2)
	gifItem := e.seedDue("uid-alice", 1, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{Text: "a gif", Media: []MediaRef{{ID: sweepMediaID(1)}}}
	})
	photoItem := e.seedDue("uid-alice", 2, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{Text: "a photo", Media: []MediaRef{{ID: sweepMediaID(2)}}}
	})

	res, _ := e.sweep()
	if res.Published != 1 || res.Failed[FailureMediaUnavailable] != 1 {
		t.Fatalf("res = %+v, want 1 published and 1 FAILED MEDIA_UNAVAILABLE", res)
	}
	if doc := e.raw(gifItem); doc["status"] != "FAILED" || doc["failure"] != string(FailureMediaUnavailable) {
		t.Fatalf("gif item = %v, want FAILED MEDIA_UNAVAILABLE", doc)
	}
	if doc := e.raw(photoItem); doc["status"] != "PUBLISHED" {
		t.Fatalf("photo item = %v, want PUBLISHED", doc)
	}
	if posts := e.postsOf("uid-alice"); len(posts) != 1 || posts[0].Text != "a photo" {
		t.Fatalf("posts = %+v, want only the photo post", posts)
	}
	if got, _ := e.mediaDoc(1)["postId"].(string); got != "" {
		t.Errorf("the GIF was attached to post %q", got)
	}
	if e.quotaPosts("uid-alice") != 1 || e.postsCount("uid-alice") != 1 {
		t.Errorf("quota posts %d postsCount %d, want 1 and 1 (the refused GIF is not charged)", e.quotaPosts("uid-alice"), e.postsCount("uid-alice"))
	}
}
