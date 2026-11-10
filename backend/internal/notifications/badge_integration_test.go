//go:build integration

package notifications

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// TestIntegration_UnreadStoreReads pins the two badge queries on the emulator: createdAt strictly after since,
// newest first, Limit honoured, the projection carrying the displayed actor id.
func TestIntegration_UnreadStoreReads(t *testing.T) {
	client := newTestClient(t) // a fresh random project per test: no shared emulator state
	ctx := context.Background()
	repo := NewFirestoreRepo(client)
	uid := fmt.Sprintf("badgeR%d", time.Now().UnixNano())
	since := t0.Add(time.Hour)
	// One row exactly at since (not unseen), one before, and UnreadBadgeCap+5 after.
	seed := []Notification{row("at_since", TypeFollow, "old0", since), row("before", TypeFollow, "old1", since.Add(-time.Minute))}
	for i := 0; i < UnreadBadgeCap+5; i++ {
		seed = append(seed, row(fmt.Sprintf("n%03d", i), TypeFollow, fmt.Sprintf("a%03d", i), since.Add(time.Duration(i+1)*time.Second)))
	}
	bw := client.BulkWriter(ctx)
	for _, n := range seed {
		if _, err := bw.Create(repo.notifications(uid).Doc(n.ID), notificationDoc{
			Type: string(n.Type), Actor: toActorDoc(n.Actor), ActorIDs: n.ActorIDs, ActorCount: 1, CreatedAt: n.CreatedAt, ExpireAt: n.CreatedAt.Add(TTL),
		}); err != nil {
			t.Fatal(err)
		}
	}
	bw.End()

	n, err := repo.CountUnread(ctx, uid, since, UnreadBadgeCap)
	mustNoErr(t, err)
	if n != UnreadBadgeCap {
		t.Errorf("CountUnread = %d, want the cap %d", n, UnreadBadgeCap)
	}
	if n, err := repo.CountUnread(ctx, uid, since, 1000); err != nil || n != UnreadBadgeCap+5 {
		t.Errorf("CountUnread(limit 1000) = %d, %v; want %d (strictly after since)", n, err, UnreadBadgeCap+5)
	}
	actors, err := repo.UnreadActors(ctx, uid, since, UnreadBadgeCap)
	mustNoErr(t, err)
	if len(actors) != UnreadBadgeCap {
		t.Fatalf("UnreadActors = %d ids, want %d", len(actors), UnreadBadgeCap)
	}
	// Newest first: a104 down to a005; the five oldest unseen rows and the seen ones are outside the window.
	if actors[0] != fmt.Sprintf("a%03d", UnreadBadgeCap+4) || actors[len(actors)-1] != "a005" {
		t.Errorf("window = %s..%s, want a%03d..a005", actors[0], actors[len(actors)-1], UnreadBadgeCap+4)
	}
	if slices.Contains(actors, "old0") || slices.Contains(actors, "old1") {
		t.Error("a row at or before since was returned")
	}
	if none, err := repo.UnreadActors(ctx, "nobody"+uid, since, UnreadBadgeCap); err != nil || len(none) != 0 {
		t.Errorf("UnreadActors(no rows) = %v, %v; want empty", none, err)
	}
}

// TestIntegration_UnreadBadgeExcludesHiddenActors is the badge end to end on the emulator with the real graph
// service: rows from an actor the caller blocks, mutes, or is blocked by are not counted; rows from anyone else are.
func TestIntegration_UnreadBadgeExcludesHiddenActors(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	sfx := fmt.Sprintf("%d", time.Now().UnixNano())
	me, blocked, muted, blocker, friend := "bgMe"+sfx, "bgBlk"+sfx, "bgMut"+sfx, "bgBy"+sfx, "bgF"+sfx
	empty := []string{}
	_, err := client.Collection("graph").Doc(me).Set(ctx, map[string]any{
		"following": empty, "blocked": []string{blocked}, "muted": []string{muted}, "requested": empty,
		"blockedBy": []string{blocker}, "blockedByOverflow": false, "updatedAt": t0,
	})
	mustNoErr(t, err)
	repo := NewFirestoreRepo(client)
	since := t0
	for i, actor := range []string{blocked, muted, blocker, friend} {
		_, err := repo.Create(ctx, me, row("r"+actor, TypeFollow, actor, since.Add(time.Duration(i+1)*time.Minute)))
		mustNoErr(t, err)
	}
	// A collapsed row shown by friend with the blocked actor folded in still counts once: only the shown actor decides.
	_, err = repo.Create(ctx, me, Notification{ID: "like_" + friend, Type: TypeLike, Actor: Actor{UserID: friend}, ActorIDs: []string{blocked, friend}, ActorCount: 2, PostID: postA, CreatedAt: since.Add(10 * time.Minute)})
	mustNoErr(t, err)

	graphSvc := graph.New(graph.Deps{Repo: graph.NewFirestoreRepo(client), Cache: graph.NewCache(time.Minute)})
	n, err := NewUnreadBadge(repo, graphSvc, graphSvc).UnreadNotifications(ctx, me, since)
	mustNoErr(t, err)
	if n != 2 {
		t.Errorf("badge = %d, want 2 (friend's follow and like; blocked, muted and blocked-by rows excluded)", n)
	}
	// The raw count the badge replaces would have said 5.
	if raw, err := repo.CountUnread(ctx, me, since, UnreadBadgeCap); err != nil || raw != 5 {
		t.Errorf("raw count = %d, %v; want 5", raw, err)
	}
}

// seedBadRow writes a row whose actor.userId is not a string: neither List nor the badge can decode it.
func seedBadRow(t *testing.T, client *firestore.Client, uid, id string, at time.Time) {
	t.Helper()
	_, err := client.Collection("users").Doc(uid).Collection("notifications").Doc(id).Set(context.Background(), map[string]any{
		"type": "follow", "actor": map[string]any{"userId": 12345}, "actorIds": []string{"x"}, "actorCount": 1,
		"createdAt": at, "expireAt": at.Add(TTL),
	})
	mustNoErr(t, err)
}

// M1 + L2 (security audit): one undecodable row must not fail the badge (it would fail GetMe on every cache miss until
// the row's TTL). It is skipped, which never counts a hidden row, with a WARN that names the row by hash only (row ids
// embed other users' uids). The other rows are counted by the usual rule.
func TestIntegration_UnreadBadgeSkipsUndecodableRow(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	sfx := fmt.Sprintf("%d", time.Now().UnixNano())
	me, blocked, friend, other := "skMe"+sfx, "skBlk"+sfx, "skF"+sfx, "skOther"+sfx
	empty := []string{}
	_, err := client.Collection("graph").Doc(me).Set(ctx, map[string]any{
		"following": empty, "blocked": []string{blocked}, "muted": empty, "requested": empty,
		"blockedBy": empty, "blockedByOverflow": false, "updatedAt": t0,
	})
	mustNoErr(t, err)
	var buf bytes.Buffer
	repo := NewFirestoreRepo(client).WithLogger(slog.New(slog.NewJSONHandler(&buf, nil)))
	for i, actor := range []string{blocked, friend} {
		_, err := repo.Create(ctx, me, row("follow_"+actor, TypeFollow, actor, t0.Add(time.Duration(i+1)*time.Minute)))
		mustNoErr(t, err)
	}
	badID := "follow_" + other
	seedBadRow(t, client, me, badID, t0.Add(5*time.Minute))

	graphSvc := graph.New(graph.Deps{Repo: graph.NewFirestoreRepo(client), Cache: graph.NewCache(time.Minute)})
	n, err := NewUnreadBadge(repo, graphSvc, graphSvc).UnreadNotifications(ctx, me, t0)
	if err != nil {
		t.Fatalf("badge failed on one bad row: %v", err)
	}
	if n != 1 {
		t.Errorf("badge = %d, want 1 (friend counted, blocked hidden, the bad row skipped)", n)
	}
	out := buf.String()
	if !strings.Contains(out, `"level":"WARN"`) || !strings.Contains(out, logger.HashUID(badID)) {
		t.Errorf("no WARN naming the hashed row id: %s", out)
	}
	if strings.Contains(out, other) {
		t.Errorf("the WARN carries another user's raw uid: %s", out)
	}
}

// L2: List's decode error names the row by hash, never by its raw id (which embeds another user's uid).
func TestIntegration_ListDecodeErrorHashesTheRowID(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	sfx := fmt.Sprintf("%d", time.Now().UnixNano())
	me, other := "ldMe"+sfx, "ldOther"+sfx
	badID := "follow_" + other
	seedBadRow(t, client, me, badID, t0)
	_, err := NewFirestoreRepo(client).List(ctx, me, ListQuery{Limit: 10})
	if err == nil {
		t.Fatal("List decoded a row whose actor.userId is a number")
	}
	if msg := logger.CauseChain(err); strings.Contains(msg, other) || !strings.Contains(msg, logger.HashUID(badID)) {
		t.Errorf("List error = %q, want the hashed row id and no raw uid", msg)
	}
}
