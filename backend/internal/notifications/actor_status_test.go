package notifications

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// statusDirectory is a directory with "me" and the ACTIVE actors, plus the given actors stored with a non-ACTIVE status
// (the fake returns them as they are, so List itself must check the status). Any other uid has no profile.
func statusDirectory(active []string, other map[string]identity.AccountStatus) *fakeDirectory {
	d := newDirectory(append([]string{"me"}, active...)...)
	for uid, st := range other {
		d.profiles[uid] = identity.Profile{UserID: uid, Handle: "h_" + uid, Status: st}
	}
	return d
}

// List hides a row whose displayed actor is not ACTIVE at read time, and prunes a folded actor it proved not ACTIVE
// from the ids and the count (follow-up "ListNotifications does not check actor status at read time").
func TestList_ActorStatusAtReadTime(t *testing.T) {
	t.Parallel()
	inactive := map[string]identity.AccountStatus{
		"sus": identity.AccountStatusSuspended,
		"del": identity.AccountStatusDeleting,
		"uns": identity.AccountStatusUnspecified,
	}
	tests := []struct {
		name      string
		row       Notification
		wantShown bool
		wantIDs   []string
		wantCount int32 // wire actor_count
		wantFaces []string
	}{
		{"active actor shows", Notification{Type: TypeFollow, Actor: Actor{UserID: "a"}, ActorIDs: []string{"a"}, ActorCount: 1}, true, []string{"a"}, 1, []string{"a"}},
		{"suspended actor hides the row", Notification{Type: TypeFollow, Actor: Actor{UserID: "sus"}, ActorIDs: []string{"sus"}, ActorCount: 1}, false, nil, 0, nil},
		{"deleting actor hides the row", Notification{Type: TypeReply, PostID: "p", Actor: Actor{UserID: "del"}, ActorIDs: []string{"del"}, ActorCount: 1}, false, nil, 0, nil},
		{"unspecified status hides the row", Notification{Type: TypeMention, PostID: "p", Actor: Actor{UserID: "uns"}, ActorIDs: []string{"uns"}, ActorCount: 1}, false, nil, 0, nil},
		{"actor with no users doc hides the row", Notification{Type: TypeFollow, Actor: Actor{UserID: "gone"}, ActorIDs: []string{"gone"}, ActorCount: 1}, false, nil, 0, nil},
		{"a row without actor ids is judged by its displayed actor", Notification{Type: TypeFollow, Actor: Actor{UserID: "sus"}}, false, nil, 0, nil},
		{
			"suspended newest actor of a collapsed row hides it, as a block does",
			Notification{Type: TypeLike, PostID: "p", Actor: Actor{UserID: "sus"}, ActorIDs: []string{"a", "b", "sus"}, ActorCount: 3},
			false, nil, 0, nil,
		},
		{
			"suspended folded face is pruned from ids and count",
			Notification{Type: TypeLike, PostID: "p", Actor: Actor{UserID: "c"}, ActorIDs: []string{"a", "sus", "c"}, ActorCount: 3},
			true, []string{"a", "c"}, 2, []string{"c", "a"},
		},
		{
			"every inactive face is pruned; a stored count beyond the ids keeps the rest",
			Notification{Type: TypeLike, PostID: "p", Actor: Actor{UserID: "c"}, ActorIDs: []string{"del", "sus", "c"}, ActorCount: 30},
			true, []string{"c"}, 28, []string{"c"},
		},
		{
			// Only the faces (the newest three) are looked up: an older folded actor keeps counting, unverified, rather
			// than every popular row collapsing to the few actors checked.
			"an inactive folded actor older than the faces is not looked up and keeps counting",
			Notification{Type: TypeLike, PostID: "p", Actor: Actor{UserID: "c"}, ActorIDs: []string{"sus", "a", "b", "c"}, ActorCount: 4},
			true, []string{"sus", "a", "b", "c"}, 4, []string{"c", "b", "a"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			tt.row.ID, tt.row.CreatedAt = "row", t0.Add(-time.Minute)
			stored := slices.Clone(tt.row.ActorIDs)
			repo.rows["me"] = map[string]Notification{"row": tt.row}
			dir := statusDirectory([]string{"a", "b", "c"}, inactive)
			svc := newService(repo, dir, &fakeSeen{}, func() time.Time { return t0 })
			res, err := svc.List(context.Background(), "me", ListInput{})
			mustNoErr(t, err)
			if len(dir.lookups) != 1 || dir.lookups[0][0] != "me" {
				t.Errorf("lookups = %v, want one, caller first", dir.lookups)
			}
			if !slices.Equal(repo.rows["me"]["row"].ActorIDs, stored) {
				t.Errorf("stored ActorIDs changed to %v", repo.rows["me"]["row"].ActorIDs)
			}
			if !tt.wantShown {
				if len(res.Notifications) != 0 {
					t.Fatalf("rows = %v, want the row hidden", idsOf(res.Notifications))
				}
				return
			}
			if len(res.Notifications) != 1 {
				t.Fatalf("rows = %v, want the row shown", idsOf(res.Notifications))
			}
			n := res.Notifications[0]
			if !slices.Equal(n.ActorIDs, tt.wantIDs) {
				t.Errorf("actor ids = %v, want %v", n.ActorIDs, tt.wantIDs)
			}
			if got := ToProto(n).GetActorCount(); got != tt.wantCount {
				t.Errorf("wire actor_count = %d, want %d", got, tt.wantCount)
			}
			if got := actorUIDs(n.Actors); !slices.Equal(got, tt.wantFaces) {
				t.Errorf("faces = %v, want %v", got, tt.wantFaces)
			}
		})
	}
}

// A page every row of which has an inactive actor comes back empty but keeps its next_page_token, and following it
// reaches the older rows: the filter never ends the stream early.
func TestList_ActorStatusAllInactivePageStillPages(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{
		"s2":  {ID: "s2", Type: TypeFollow, Actor: Actor{UserID: "sus"}, ActorIDs: []string{"sus"}, CreatedAt: t0.Add(-1 * time.Minute)},
		"s1":  {ID: "s1", Type: TypeFollow, Actor: Actor{UserID: "del"}, ActorIDs: []string{"del"}, CreatedAt: t0.Add(-2 * time.Minute)},
		"old": {ID: "old", Type: TypeFollow, Actor: Actor{UserID: "a"}, ActorIDs: []string{"a"}, CreatedAt: t0.Add(-time.Hour)},
	}
	dir := statusDirectory([]string{"a"}, map[string]identity.AccountStatus{"sus": identity.AccountStatusSuspended, "del": identity.AccountStatusDeleting})
	svc := newService(repo, dir, &fakeSeen{}, func() time.Time { return t0 })
	p1, err := svc.List(context.Background(), "me", ListInput{PageSize: 2})
	mustNoErr(t, err)
	if len(p1.Notifications) != 0 || p1.NextPageToken == "" || p1.SinceToken == "" {
		t.Fatalf("page 1 = %v next=%q since=%q: want empty with both tokens", idsOf(p1.Notifications), p1.NextPageToken, p1.SinceToken)
	}
	p2, err := svc.List(context.Background(), "me", ListInput{PageSize: 2, PageToken: p1.NextPageToken})
	mustNoErr(t, err)
	if got := strings.Join(idsOf(p2.Notifications), ","); got != "old" || p2.NextPageToken != "" {
		t.Fatalf("page 2 = %s next=%q, want old and the end", got, p2.NextPageToken)
	}
}

// A refresh whose only new row has a suspended actor shows nothing but still moves since_token to that row, so the
// next refresh does not start from the old position again.
func TestList_ActorStatusRefreshAdvances(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{
		"old": {ID: "old", Type: TypeFollow, Actor: Actor{UserID: "a"}, ActorIDs: []string{"a"}, CreatedAt: t0.Add(-time.Hour)},
	}
	dir := statusDirectory([]string{"a"}, map[string]identity.AccountStatus{"sus": identity.AccountStatusSuspended})
	clock := t0
	svc := newService(repo, dir, &fakeSeen{}, func() time.Time { return clock })
	first, err := svc.List(context.Background(), "me", ListInput{})
	mustNoErr(t, err)
	if len(first.Notifications) != 1 {
		t.Fatalf("cold open = %v", idsOf(first.Notifications))
	}
	repo.rows["me"]["new"] = Notification{ID: "new", Type: TypeFollow, Actor: Actor{UserID: "sus"}, ActorIDs: []string{"sus"}, CreatedAt: t0.Add(time.Minute)}
	clock = t0.Add(2 * time.Minute)
	ref, err := svc.List(context.Background(), "me", ListInput{SinceToken: first.SinceToken})
	mustNoErr(t, err)
	// The settle window may return "old" again (the client dedupes by id); the new row must not show.
	if slices.Contains(idsOf(ref.Notifications), "new") {
		t.Fatalf("refresh = %v, want the suspended actor's row hidden", idsOf(ref.Notifications))
	}
	if ref.SinceToken == "" || ref.SinceToken == first.SinceToken {
		t.Fatalf("since token did not advance past the hidden row")
	}
	// The next refresh starts from the hidden row (minus the settle window), past the old row.
	again, err := svc.List(context.Background(), "me", ListInput{SinceToken: ref.SinceToken})
	mustNoErr(t, err)
	if len(again.Notifications) != 0 {
		t.Errorf("second refresh = %v, want nothing", idsOf(again.Notifications))
	}
}

// The status rule composes with the block rule: a row hidden by a block costs no status lookup, and the rest are judged
// by status.
func TestList_ActorStatusAfterBlocks(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.rows["me"] = map[string]Notification{
		"blk": {ID: "blk", Type: TypeFollow, Actor: Actor{UserID: "blocked"}, ActorIDs: []string{"blocked"}, CreatedAt: t0.Add(-1 * time.Minute)},
		"sus": {ID: "sus", Type: TypeFollow, Actor: Actor{UserID: "sus"}, ActorIDs: []string{"sus"}, CreatedAt: t0.Add(-2 * time.Minute)},
		"ok":  {ID: "ok", Type: TypeFollow, Actor: Actor{UserID: "a"}, ActorIDs: []string{"a"}, CreatedAt: t0.Add(-3 * time.Minute)},
	}
	dir := statusDirectory([]string{"a", "blocked"}, map[string]identity.AccountStatus{"sus": identity.AccountStatusSuspended})
	social := &fakeSocial{snaps: map[string]graphSnap{"me": {Blocked: map[string]bool{"blocked": true}}}}
	svc := newServiceWithSocial(repo, dir, &fakeSeen{}, func() time.Time { return t0 }, social)
	res, err := svc.List(context.Background(), "me", ListInput{})
	mustNoErr(t, err)
	if got := strings.Join(idsOf(res.Notifications), ","); got != "ok" {
		t.Fatalf("rows = %s, want ok", got)
	}
	if len(dir.lookups) != 1 || slices.Contains(dir.lookups[0], "blocked") {
		t.Errorf("lookups = %v, want one without the blocked actor", dir.lookups)
	}
}
