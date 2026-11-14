package notifications

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func TestPickShownActors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		rows      [][]string // each row's ActorIDs, oldest first (foldActor appends the newest)
		budget    int
		wantPicks [][]string
		wantIDs   []string
	}{
		{"single actor", [][]string{{"a"}}, 49, [][]string{{"a"}}, []string{"a"}},
		{"no actor ids leaves the row empty", [][]string{nil, {}}, 49, [][]string{nil, nil}, nil},
		{"newest first from the tail", [][]string{{"a", "b"}}, 49, [][]string{{"b", "a"}}, []string{"b", "a"}},
		{"capped at three", [][]string{{"a", "b", "c", "d", "e"}}, 49, [][]string{{"e", "d", "c"}}, []string{"e", "d", "c"}},
		{"distinct and no empty ids", [][]string{{"a", "", "b", "b"}}, 49, [][]string{{"b", "a"}}, []string{"b", "a"}},
		{"shared actors are looked up once", [][]string{{"a", "b"}, {"b", "c"}}, 49, [][]string{{"b", "a"}, {"c", "b"}}, []string{"b", "c", "a"}},
		{
			"budget keeps every row's newest before older faces",
			[][]string{{"a", "b", "c"}, {"d", "e", "f"}}, 3,
			[][]string{{"c", "b"}, {"f"}}, []string{"c", "f", "b"},
		},
		{"zero budget picks nothing", [][]string{{"a"}}, 0, [][]string{nil}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			rows := make([]Notification, len(tt.rows))
			for i, ids := range tt.rows {
				rows[i] = Notification{ID: fmt.Sprint(i), ActorIDs: ids}
			}
			picks, ids := pickShownActors(rows, tt.budget)
			if fmt.Sprint(picks) != fmt.Sprint(tt.wantPicks) || fmt.Sprint(ids) != fmt.Sprint(tt.wantIDs) {
				t.Errorf("picks=%v ids=%v, want picks=%v ids=%v", picks, ids, tt.wantPicks, tt.wantIDs)
			}
		})
	}
}

func actorUIDs(as []LiveActor) []string {
	out := make([]string, len(as))
	for i, a := range as {
		out[i] = a.UserID
	}
	return out
}

// List hydrates up to three visible actors per row, newest first, after the block/mute pruning, with one Directory
// lookup per page that also serves seen_at.
func TestList_ActorsAfterPruningNewestFirstOneLookup(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		actorIDs  []string
		count     int
		snap      graph.Snapshot
		gone      []string // actors with no ACTIVE profile
		wantFaces []string
		wantCount int
	}{
		{"single actor", []string{"a"}, 1, graph.Snapshot{}, nil, []string{"a"}, 1},
		{"legacy row without ids", nil, 0, graph.Snapshot{}, nil, []string{}, 0},
		{"newest three of five", []string{"a", "b", "c", "d", "e"}, 7, graph.Snapshot{}, nil, []string{"e", "d", "c"}, 7},
		{"muted actor is never listed", []string{"a", "b", "c", "d", "e"}, 5, graph.Snapshot{Muted: map[string]bool{"d": true}}, nil, []string{"e", "c", "b"}, 4},
		{"blocked and blocked-by pruned", []string{"a", "b", "c", "e"}, 4, graph.Snapshot{Blocked: map[string]bool{"c": true}, BlockedBy: map[string]bool{"b": true}}, nil, []string{"e", "a"}, 2},
		{"inactive folded actor is left out and pruned from the count", []string{"a", "b", "e"}, 3, graph.Snapshot{}, []string{"b"}, []string{"e", "a"}, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			dir := newDirectory("me", "a", "b", "c", "d", "e")
			for _, g := range tt.gone {
				delete(dir.profiles, g)
			}
			repo.rows["me"] = map[string]Notification{"like_1": {
				ID: "like_1", Type: TypeLike, Actor: Actor{UserID: "e"}, ActorIDs: tt.actorIDs, ActorCount: tt.count,
				PostID: "p1", CreatedAt: t0.Add(-time.Minute),
			}}
			social := &fakeSocial{snaps: map[string]graph.Snapshot{"me": tt.snap}}
			svc := newServiceWithSocial(repo, dir, &fakeSeen{}, func() time.Time { return t0 }, social)
			res, err := svc.List(context.Background(), "me", ListInput{})
			if err != nil || len(res.Notifications) != 1 {
				t.Fatalf("List = %v, %v", res.Notifications, err)
			}
			n := res.Notifications[0]
			if got := actorUIDs(n.Actors); !slices.Equal(got, tt.wantFaces) {
				t.Errorf("actors = %v, want %v", got, tt.wantFaces)
			}
			if n.ActorCount != tt.wantCount {
				t.Errorf("actor_count = %d, want %d", n.ActorCount, tt.wantCount)
			}
			if len(dir.lookups) != 1 || dir.lookups[0][0] != "me" {
				t.Errorf("directory lookups = %v, want one, caller first", dir.lookups)
			}
			wire := ToProto(n)
			if len(wire.GetActors()) != len(tt.wantFaces) {
				t.Errorf("wire actors = %v, want %d", wire.GetActors(), len(tt.wantFaces))
			}
		})
	}
}

func TestList_ActorsFromTheLiveProfile(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	dir := newDirectory("me")
	dir.profiles["p"] = identity.Profile{UserID: "p", Handle: "P", DisplayName: "Pia", AvatarURL: "https://x/full", AvatarThumbURL: "https://x/thumb", Verified: true, IsPrivate: true, Status: identity.AccountStatusActive}
	dir.profiles["q"] = identity.Profile{UserID: "q", Handle: "q", AvatarURL: "https://x/q-full", Status: identity.AccountStatusActive}
	repo.rows["me"] = map[string]Notification{"like_1": {ID: "like_1", Type: TypeLike, Actor: Actor{UserID: "q"}, ActorIDs: []string{"p", "q"}, ActorCount: 2, CreatedAt: t0.Add(-time.Minute)}}
	svc := newService(repo, dir, &fakeSeen{}, func() time.Time { return t0 })
	res, err := svc.List(context.Background(), "me", ListInput{})
	if err != nil || len(res.Notifications) != 1 {
		t.Fatalf("List = %v, %v", res.Notifications, err)
	}
	got := ToProto(res.Notifications[0]).GetActors()
	if len(got) != 2 {
		t.Fatalf("actors = %v", got)
	}
	q, p := got[0], got[1]
	if q.GetUserId() != "q" || q.GetAvatarUrl() != "https://x/q-full" || q.GetIsPrivate() {
		t.Errorf("newest actor = %v, want q with the full avatar as fallback", q)
	}
	if p.GetUserId() != "p" || p.GetHandle() != "P" || p.GetDisplayName() != "Pia" || p.GetAvatarUrl() != "https://x/thumb" || !p.GetVerified() || !p.GetIsPrivate() {
		t.Errorf("older actor = %v, want the live thumb, verified and is_private", p)
	}
}

// A failing lookup fails the page: the actor's account status is unknown, so the row is not shown (it used to degrade
// to a page without faces, which would show a suspended actor's row).
func TestList_ActorsLookupFailureFailsPage(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	dir := newDirectory("me", "a")
	dir.err = errBoom
	repo.rows["me"] = map[string]Notification{"follow_1": {ID: "follow_1", Type: TypeFollow, Actor: Actor{UserID: "a"}, ActorIDs: []string{"a"}, ActorCount: 1, CreatedAt: t0.Add(-time.Minute)}}
	svc := newService(repo, dir, &fakeSeen{}, func() time.Time { return t0 })
	res, err := svc.List(context.Background(), "me", ListInput{})
	if err == nil || len(res.Notifications) != 0 {
		t.Fatalf("List = %v, %v; want an error and no rows", res.Notifications, err)
	}
}

// A full page of folded rows with 50 distinct displayed actors needs the caller plus 50 status checks: two lookups,
// each of at most MaxPageProfileLookup ids, the caller first in the first, and no extra call for the faces.
func TestList_ActorsLookupBounded(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	dir := newDirectory("me")
	repo.rows["me"] = map[string]Notification{}
	for i := 0; i < MaxPageSize; i++ {
		ids := []string{fmt.Sprintf("x%02d", i), fmt.Sprintf("y%02d", i), fmt.Sprintf("z%02d", i)}
		for _, id := range ids {
			dir.profiles[id] = identity.Profile{UserID: id, Status: identity.AccountStatusActive}
		}
		id := fmt.Sprintf("like_%02d", i)
		repo.rows["me"][id] = Notification{ID: id, Type: TypeLike, Actor: Actor{UserID: ids[2]}, ActorIDs: ids, ActorCount: 3, CreatedAt: t0.Add(-time.Duration(i+1) * time.Minute)}
	}
	svc := newService(repo, dir, &fakeSeen{}, func() time.Time { return t0 })
	res, err := svc.List(context.Background(), "me", ListInput{PageSize: MaxPageSize})
	if err != nil || len(res.Notifications) != MaxPageSize {
		t.Fatalf("List = %d rows, %v", len(res.Notifications), err)
	}
	if len(dir.lookups) != 2 || dir.lookups[0][0] != "me" {
		t.Fatalf("lookups = %d (first %v); want two, caller first", len(dir.lookups), dir.lookups)
	}
	for i, l := range dir.lookups {
		if len(l) > MaxPageProfileLookup {
			t.Errorf("lookup %d has %d ids, want at most %d", i, len(l), MaxPageProfileLookup)
		}
	}
	for i, n := range res.Notifications { // every displayed actor was looked up for its status, so every row has its face
		if len(n.Actors) == 0 || n.Actors[0].UserID != n.ActorIDs[len(n.ActorIDs)-1] {
			t.Errorf("row %d actors = %v, want its newest actor first", i, actorUIDs(n.Actors))
		}
	}
}
