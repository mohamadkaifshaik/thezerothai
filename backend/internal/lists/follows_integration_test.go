//go:build integration

package lists

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"slices"
	"sort"
	"sync/atomic"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
)

// feEnv is one emulator project with the follow lifecycle wired: a real Firestore repository, the service
// with a fake directory and a settable graph (the block cases), and a snowflake node for list ids.
type feEnv struct {
	client *firestore.Client
	repo   *FirestoreRepo
	svc    *service
	node   *snowflake.Node
	g      *fakeGraph
}

const (
	feOwner   = "owner"
	feViewer  = "viewer"
	feViewer2 = "viewer2"
)

var feSeq atomic.Int64

// fk is a fresh idempotency key (16-64 characters of [A-Za-z0-9_-]).
func fk() string { return fmt.Sprintf("follow-key-%012d", feSeq.Add(1)) }

func newFollowEnv(t *testing.T) *feEnv {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-follows-%d", rand.Int63()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	repo := NewFirestoreRepo(client, quota.New(client), idempotency.New(client))
	profs := map[string]identity.Profile{}
	for _, u := range []string{feOwner, feViewer, feViewer2, "stranger"} {
		profs[u] = active(u, false)
	}
	g := &fakeGraph{snaps: map[string]graph.Snapshot{}}
	svc := New(Deps{
		Repo: repo, Directory: fakeDirectory{profiles: profs}, Graph: g, IDs: node,
		Now: time.Now, Limits: Limits{MaxPerUser: 20, MaxMembers: 150, CacheEntries: 100},
		CursorKey: []byte("0123456789abcdef0123456789abcdef"),
	}).(*service)
	return &feEnv{client: client, repo: repo, svc: svc, node: node, g: g}
}

// publicList creates a public list owned by owner through the service.
func (e *feEnv) publicList(t *testing.T) string {
	t.Helper()
	v, err := e.svc.CreateList(context.Background(), feOwner, CreateInput{Key: fk(), Name: "Friends", IsPrivate: ptr(false)})
	if err != nil {
		t.Fatalf("create list: %v", err)
	}
	return v.Header.ID
}

func (e *feEnv) stored(t *testing.T, id string) int {
	t.Helper()
	l, err := e.repo.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("get list %s: %v", id, err)
	}
	return l.FollowerCount
}

func (e *feEnv) markersFor(t *testing.T, listID string) int {
	t.Helper()
	docs, err := e.client.Collection(followsCollection).Where("listId", "==", listID).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

func (e *feEnv) markersOf(t *testing.T, uid string) int {
	t.Helper()
	docs, err := e.client.Collection(followsCollection).Where("uid", "==", uid).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

func (e *feEnv) follow(t *testing.T, uid, id string) {
	t.Helper()
	if _, err := e.svc.FollowList(context.Background(), uid, fk(), id); err != nil {
		t.Fatalf("follow %s by %s: %v", id, uid, err)
	}
}

func TestFollowsIntegration_FollowUnfollowCount(t *testing.T) {
	e := newFollowEnv(t)
	ctx := context.Background()
	id := e.publicList(t)

	e.follow(t, feViewer, id)
	if got := e.stored(t, id); got != 1 {
		t.Fatalf("after one follow: followerCount %d, want 1", got)
	}
	// A replayed key writes nothing; a second follow by the same account is a no-op.
	key := fk()
	for range 2 {
		if _, err := e.svc.FollowList(ctx, feViewer2, key, id); err != nil {
			t.Fatalf("follow with a replayed key: %v", err)
		}
	}
	e.follow(t, feViewer2, id)
	if got := e.stored(t, id); got != 2 {
		t.Fatalf("after two followers: followerCount %d, want 2", got)
	}
	// The owner following their own list changes nothing.
	if _, err := e.svc.FollowList(ctx, feOwner, fk(), id); err != nil {
		t.Fatalf("owner follow: %v", err)
	}
	if got := e.stored(t, id); got != 2 {
		t.Fatalf("owner follow moved the count to %d", got)
	}
	if err := e.svc.UnfollowList(ctx, feViewer, fk(), id); err != nil {
		t.Fatalf("unfollow: %v", err)
	}
	if got := e.stored(t, id); got != 1 {
		t.Fatalf("after unfollow: followerCount %d, want 1", got)
	}
	if got := e.markersFor(t, id); got != 1 {
		t.Fatalf("markers for the list: %d, want 1", got)
	}
	// Unfollowing a list never followed is a success with no effect.
	if err := e.svc.UnfollowList(ctx, "stranger", fk(), id); err != nil {
		t.Fatalf("unfollow without a marker: %v", err)
	}
	if got := e.stored(t, id); got != 1 {
		t.Fatalf("unfollow without a marker moved the count to %d", got)
	}
}

func TestFollowsIntegration_PrivateListHidesFromFollowersAndDiscover(t *testing.T) {
	e := newFollowEnv(t)
	ctx := context.Background()
	id := e.publicList(t)
	e.follow(t, feViewer, id)

	page, err := e.svc.DiscoverLists(ctx, feViewer2, 20, "")
	if err != nil || len(page.Views) != 1 {
		t.Fatalf("discover before private: %d views, err %v", len(page.Views), err)
	}
	if _, err := e.svc.UpdateList(ctx, feOwner, UpdateInput{Key: fk(), ListID: id, IsPrivate: ptr(true)}); err != nil {
		t.Fatalf("make private: %v", err)
	}
	followed, err := e.svc.ListFollowedLists(ctx, feViewer, 20, "")
	if err != nil || len(followed.Views) != 0 {
		t.Fatalf("followed lists after private: %d views, err %v", len(followed.Views), err)
	}
	page, err = e.svc.DiscoverLists(ctx, feViewer2, 20, "")
	if err != nil || len(page.Views) != 0 {
		t.Fatalf("discover after private: %d views, err %v", len(page.Views), err)
	}
	if _, err := e.svc.GetList(ctx, feViewer, id); !isNotFound(err) {
		t.Fatalf("GetList of a private list by a follower: %v, want NOT_FOUND", err)
	}
	// The marker and the count are kept; the list is simply not shown. Public again: the follower sees it again.
	if got := e.stored(t, id); got != 1 {
		t.Fatalf("private list count %d, want 1", got)
	}
	if _, err := e.svc.UpdateList(ctx, feOwner, UpdateInput{Key: fk(), ListID: id, IsPrivate: ptr(false)}); err != nil {
		t.Fatalf("make public: %v", err)
	}
	followed, err = e.svc.ListFollowedLists(ctx, feViewer, 20, "")
	if err != nil || len(followed.Views) != 1 || !followed.Views[0].FollowedByViewer {
		t.Fatalf("followed lists after public again: %+v, err %v", followed, err)
	}
}

func TestFollowsIntegration_DeleteSweepsMarkers(t *testing.T) {
	e := newFollowEnv(t)
	ctx := context.Background()
	id := e.publicList(t)
	e.follow(t, feViewer, id)
	e.follow(t, feViewer2, id)
	if got := e.markersFor(t, id); got != 2 {
		t.Fatalf("markers before delete: %d, want 2", got)
	}
	if err := e.svc.DeleteList(ctx, feOwner, fk(), id); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if got := e.markersFor(t, id); got != 0 {
		t.Fatalf("markers after delete: %d, want 0", got)
	}
	if _, err := e.repo.Get(ctx, id); err != ErrNotFound {
		t.Fatalf("list after delete: %v, want ErrNotFound", err)
	}
}

func TestFollowsIntegration_FollowerErasureDecrementsAndDeletes(t *testing.T) {
	e := newFollowEnv(t)
	ctx := context.Background()
	a, b := e.publicList(t), e.publicList(t)
	e.follow(t, feViewer, a)
	e.follow(t, feViewer, b)
	e.follow(t, feViewer2, a)
	for {
		pg, err := e.repo.PurgeFollowerPage(ctx, feViewer)
		if err != nil {
			t.Fatalf("purge follower page: %v", err)
		}
		if pg.Scanned == 0 {
			break
		}
	}
	if got := e.markersOf(t, feViewer); got != 0 {
		t.Fatalf("erased follower still has %d markers", got)
	}
	if got := e.stored(t, a); got != 1 {
		t.Fatalf("list a count after follower erasure %d, want 1 (viewer2 remains)", got)
	}
	if got := e.stored(t, b); got != 0 {
		t.Fatalf("list b count after follower erasure %d, want 0", got)
	}
	// The erasure is resumable: repeating it on a clean account is a no-op.
	if pg, err := e.repo.PurgeFollowerPage(ctx, feViewer); err != nil || pg.Scanned != 0 {
		t.Fatalf("rerun: scanned %d err %v, want 0 and nil", pg.Scanned, err)
	}
}

func TestFollowsIntegration_OwnerErasureRemovesListAndMarkers(t *testing.T) {
	e := newFollowEnv(t)
	ctx := context.Background()
	id := e.publicList(t)
	e.follow(t, feViewer, id)
	e.follow(t, feViewer2, id)
	if n, err := e.repo.PurgeOwnedPage(ctx, feOwner); err != nil || n != 1 {
		t.Fatalf("purge owned: deleted %d err %v, want 1", n, err)
	}
	if got := e.markersFor(t, id); got != 0 {
		t.Fatalf("markers of an erased owner's list: %d, want 0", got)
	}
	if _, err := e.repo.Get(ctx, id); err != ErrNotFound {
		t.Fatalf("erased owner's list: %v, want ErrNotFound", err)
	}
}

func TestFollowsIntegration_BlockEitherDirection(t *testing.T) {
	tests := []struct {
		name  string
		setup func(g *fakeGraph)
	}{
		{"caller blocks the owner", func(g *fakeGraph) {
			g.snaps[feViewer] = graph.Snapshot{Blocked: set(feOwner)}
		}},
		{"owner blocks the caller", func(g *fakeGraph) {
			g.snaps[feOwner] = graph.Snapshot{Blocked: set(feViewer)}
		}},
		{"caller is blocked by the owner", func(g *fakeGraph) {
			g.snaps[feViewer] = graph.Snapshot{BlockedBy: set(feOwner)}
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newFollowEnv(t)
			id := e.publicList(t)
			tc.setup(e.g)
			_, err := e.svc.FollowList(context.Background(), feViewer, fk(), id)
			if !isNotFound(err) {
				t.Fatalf("follow across a block: %v, want NOT_FOUND", err)
			}
			if got := e.markersFor(t, id); got != 0 {
				t.Fatalf("a refused follow wrote %d markers", got)
			}
			if got := e.stored(t, id); got != 0 {
				t.Fatalf("a refused follow moved the count to %d", got)
			}
		})
	}
}

// The follow cap is a constant (MaxFollowsPerUser) in the service. Here the repository runs with a low cap, so the cap
// check and the refusal are exercised against the emulator without 100 lists; the service maps ErrFollowLimit to
// LIMIT_REACHED list_follows (service unit test).
func TestFollowsIntegration_FollowCapRefuses(t *testing.T) {
	e := newFollowEnv(t)
	ctx := context.Background()
	ids := []string{e.publicList(t), e.publicList(t), e.publicList(t)}
	uidKey := func() string { return idempotency.Key(feViewer, rpcFollowList, fk()) }
	for _, id := range ids[:2] {
		if _, err := e.repo.Follow(ctx, FollowParams{UID: feViewer, ListID: id, IdemKey: uidKey(), RequestHash: followHash(id), MaxFollows: 2}); err != nil {
			t.Fatalf("follow under the cap: %v", err)
		}
	}
	_, err := e.repo.Follow(ctx, FollowParams{UID: feViewer, ListID: ids[2], IdemKey: uidKey(), RequestHash: followHash(ids[2]), MaxFollows: 2})
	if err == nil || !errors.Is(err, ErrFollowLimit) {
		t.Fatalf("follow at the cap: %v, want ErrFollowLimit", err)
	}
	if got := e.markersOf(t, feViewer); got != 2 {
		t.Fatalf("markers after the refused follow: %d, want 2", got)
	}
	if got := e.stored(t, ids[2]); got != 0 {
		t.Fatalf("refused follow moved the count to %d", got)
	}
}

// Discover paging across equal follower counts: DiscoverPage orders by followerCount desc then document id asc, so a
// page boundary inside a tie must neither repeat nor skip a list. Lists are written directly with the counts the test needs.
func TestFollowsIntegration_DiscoverPagingTieBreak(t *testing.T) {
	e := newFollowEnv(t)
	ctx := context.Background()
	type row struct {
		id    string
		count int64
	}
	var public []row
	for i, c := range []int64{2, 2, 2, 5, 2, 0, 0, 5, 2} {
		id := e.node.Generate()
		_ = i
		if _, err := e.client.Collection("lists").Doc(id).Set(ctx, listDoc{
			OwnerID: feOwner, Name: "L", IsPrivate: false, MemberIDs: []string{}, FollowerCount: c,
			CreatedAt: time.Now(), UpdatedAt: time.Now(),
		}); err != nil {
			t.Fatal(err)
		}
		public = append(public, row{id, c})
	}
	// A private list with a high count is never discovered.
	priv := e.node.Generate()
	if _, err := e.client.Collection("lists").Doc(priv).Set(ctx, listDoc{
		OwnerID: feOwner, Name: "P", IsPrivate: true, MemberIDs: []string{}, FollowerCount: 9,
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}

	sort.SliceStable(public, func(i, j int) bool {
		if public[i].count != public[j].count {
			return public[i].count > public[j].count
		}
		return public[i].id < public[j].id
	})
	want := make([]string, len(public))
	for i, r := range public {
		want[i] = r.id
	}

	for _, pageSize := range []int{1, 2, 3, 4} {
		var got []string
		var anchor *DiscoverAnchor
		for {
			rows, err := e.repo.DiscoverPage(ctx, anchor, pageSize)
			if err != nil {
				t.Fatalf("page size %d: %v", pageSize, err)
			}
			for _, l := range rows {
				got = append(got, l.ID)
			}
			if len(rows) < pageSize {
				break
			}
			last := rows[len(rows)-1]
			anchor = &DiscoverAnchor{FollowerCount: int64(last.FollowerCount), ListID: last.ID}
		}
		if !slices.Equal(got, want) {
			t.Fatalf("page size %d: paged order\n got %v\nwant %v", pageSize, got, want)
		}
		if slices.Contains(got, priv) {
			t.Fatalf("page size %d: a private list was discovered", pageSize)
		}
	}
}

// isNotFound reports the service's NOT_FOUND answer (an apierr.Error with code NOT_FOUND) or the repository's ErrNotFound.
func isNotFound(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, ErrNotFound) {
		return true
	}
	var ae *apierr.Error
	return errors.As(err, &ae) && ae.Code == connect.CodeNotFound
}
