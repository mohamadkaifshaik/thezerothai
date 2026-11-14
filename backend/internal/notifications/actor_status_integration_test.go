//go:build integration

package notifications

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// TestIntegration_ListHidesInactiveActorsAtReadTime is the actor-status rule end to end on the emulator, through the
// real identity Directory (cache-first, one GetAll for misses): rows written while their actors were ACTIVE disappear
// once the actor's users doc says SUSPENDED or DELETING, or is gone; a suspended folded face leaves a collapsed row's
// count; paging past a page the rule emptied still reaches the older rows; unsuspending brings the row back.
func TestIntegration_ListHidesInactiveActorsAtReadTime(t *testing.T) {
	client := newTestClient(t) // a fresh random project per test: unique ids, no shared emulator state
	ctx := context.Background()
	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	me, act, sus, del, gone := "stMe"+suffix, "stAct"+suffix, "stSus"+suffix, "stDel"+suffix, "stGone"+suffix
	setStatus := func(uid, status string) {
		t.Helper()
		_, err := client.Collection("users").Doc(uid).Set(ctx, map[string]any{
			"handle": "h" + uid, "handleLower": strings.ToLower("h" + uid), "displayName": "N", "status": status, "createdAt": t0,
		})
		mustNoErr(t, err)
	}
	setStatus(me, "ACTIVE")
	setStatus(act, "ACTIVE")
	setStatus(sus, "SUSPENDED")
	setStatus(del, "DELETING")
	// gone has no users doc at all.

	repo := NewFirestoreRepo(client)
	for _, n := range []Notification{
		row("follow_"+sus, TypeFollow, sus, t0.Add(5*time.Minute)),
		row("follow_"+del, TypeFollow, del, t0.Add(4*time.Minute)),
		row("follow_"+gone, TypeFollow, gone, t0.Add(3*time.Minute)),
		{ID: "like_" + act, Type: TypeLike, Actor: Actor{UserID: act, Handle: "h" + act}, ActorIDs: []string{sus, act}, ActorCount: 2, PostID: postA, CreatedAt: t0.Add(2 * time.Minute)},
		row("follow_"+act, TypeFollow, act, t0.Add(time.Minute)),
	} {
		created, err := repo.Create(ctx, me, n)
		mustNoErr(t, err)
		if !created {
			t.Fatalf("seed %s not created", n.ID)
		}
	}

	newSvc := func() Service {
		// A fresh identity cache per read, as on a cold instance, so the status is what Firestore holds now.
		dir := identity.New(identity.NewFirestoreRepo(client, nil), identity.NewCache(time.Minute), time.Hour).(identity.Directory)
		return NewService(Deps{Repo: repo, Directory: dir, Social: &fakeSocial{}, Seen: &fakeSeen{},
			CursorKey: testKey, Now: func() time.Time { return t0.Add(time.Hour) }})
	}

	// Page 1 (3 raw rows) is all inactive actors: empty, but it must point at page 2.
	p1, err := newSvc().List(ctx, me, ListInput{PageSize: 3})
	mustNoErr(t, err)
	if len(p1.Notifications) != 0 || p1.NextPageToken == "" {
		t.Fatalf("page 1 = %v next=%q, want empty with a next token", idsOf(p1.Notifications), p1.NextPageToken)
	}
	p2, err := newSvc().List(ctx, me, ListInput{PageSize: 3, PageToken: p1.NextPageToken})
	mustNoErr(t, err)
	if got := strings.Join(idsOf(p2.Notifications), ","); got != "like_"+act+",follow_"+act {
		t.Fatalf("page 2 = %s, want the active actor's two rows", got)
	}
	like := p2.Notifications[0]
	if like.ActorCount != 1 || ToProto(like).GetActorCount() != 1 || len(like.ActorIDs) != 1 || like.ActorIDs[0] != act {
		t.Errorf("collapsed row count=%d wire=%d ids=%v, want the suspended face subtracted", like.ActorCount, ToProto(like).GetActorCount(), like.ActorIDs)
	}
	if len(like.Actors) != 1 || like.Actors[0].UserID != act {
		t.Errorf("faces = %v, want only the active actor", actorUIDs(like.Actors))
	}

	// Unsuspend: the row is back on the next read (identity's cache bound aside), nothing was deleted.
	setStatus(sus, "ACTIVE")
	back, err := newSvc().List(ctx, me, ListInput{PageSize: 10})
	mustNoErr(t, err)
	ids := idsOf(back.Notifications)
	if len(ids) != 3 || ids[0] != "follow_"+sus {
		t.Fatalf("after unsuspend = %v, want follow_%s first and 3 rows", ids, sus)
	}
	if n := back.Notifications[1]; ToProto(n).GetActorCount() != 2 {
		t.Errorf("collapsed row wire count after unsuspend = %d, want 2", ToProto(n).GetActorCount())
	}
}
