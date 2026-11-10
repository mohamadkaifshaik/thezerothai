//go:build integration

package posts

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"
)

// holdItem is a scheduled document of uid with the given status and draft images (no draft unless PENDING).
func holdItem(uid string, n int, status ScheduledStatus, mediaIDs ...string) *ScheduledPost {
	p := &ScheduledPost{
		ID: fmt.Sprintf("%032x", n), UID: uid, SchemaVersion: ScheduledSchemaVersion, Status: status,
		PublishAt: schedBase.Add(time.Duration(n) * time.Minute), RequestHash: "h", CreatedAt: schedNow, UpdatedAt: schedNow,
	}
	if status == ScheduledPending {
		p.Draft = &ScheduledDraft{Text: "t"}
		for _, id := range mediaIDs {
			p.Draft.Media = append(p.Draft.Media, MediaRef{ID: id, URL: "https://cdn.example/m/" + id})
		}
	}
	return p
}

// TestScheduled_Integration_PendingMediaHolds: only the owner's PENDING drafts hold; terminal items (no draft) and another
// user's drafts never do; an empty request reads nothing.
func TestScheduled_Integration_PendingMediaHolds(t *testing.T) {
	e := newSchedEnv(t)
	ctx := context.Background()
	const m1, m2, m3, m4 = "1000000000000000001", "1000000000000000002", "1000000000000000003", "1000000000000000004"
	e.seed(t, holdItem("alice", 1, ScheduledPending, m1, m2))
	e.seed(t, holdItem("alice", 2, ScheduledPending))
	e.seed(t, holdItem("alice", 3, ScheduledCancelled))
	e.seed(t, holdItem("alice", 4, ScheduledFailed))
	e.seed(t, holdItem("bob", 5, ScheduledPending, m3))

	got, err := e.repo.PendingScheduledMediaHolds(ctx, "alice", []string{m1, m3, m4})
	if err != nil {
		t.Fatal(err)
	}
	if want := map[string]bool{m1: true}; !reflect.DeepEqual(got, want) {
		t.Fatalf("holds = %v, want %v (bob's draft and unrelated ids never count)", got, want)
	}
	if got, err := e.repo.PendingScheduledMediaHolds(ctx, "alice", nil); err != nil || len(got) != 0 {
		t.Fatalf("empty request = %v, %v", got, err)
	}
	if _, err := e.repo.PendingScheduledMediaHolds(ctx, "bad/uid", []string{m1}); err == nil {
		t.Fatal("an invalid uid must be refused before any read")
	}
}

// TestScheduled_Integration_PendingMediaHoldsPages: a hold on the second page is found (pages resume after the last id).
func TestScheduled_Integration_PendingMediaHoldsPages(t *testing.T) {
	e := newSchedEnv(t)
	ctx := context.Background()
	const held = "1000000000000000009"
	for n := range scheduledHoldPage {
		e.seed(t, holdItem("carol", n+1, ScheduledPending))
	}
	e.seed(t, holdItem("carol", scheduledHoldPage+1, ScheduledPending, held)) // the highest id: on page 2
	got, err := e.repo.PendingScheduledMediaHolds(ctx, "carol", []string{held})
	if err != nil || !got[held] {
		t.Fatalf("holds = %v, %v, want the second page's image", got, err)
	}
}
