//go:build integration

package communities

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

const platCID = "0000000000000000831"

// platformRepo is the repository as opsctl builds it: no idempotency store (the platform methods need only the client).
func (e *env) platformRepo() *FirestoreRepo { return NewFirestoreRepo(e.client, nil) }

func (e *env) seedPlatform(t *testing.T) {
	t.Helper()
	e.seedCommunity(t, Community{ID: platCID, Name: "Plat", Description: "d", OwnerID: "owner", ModeratorIDs: []string{"mod1"}, MemberCount: 3},
		map[string]MemberState{"owner": MemberJoined, "mod1": MemberJoined, "member": MemberJoined})
	e.seedMemberships(t, "owner", Memberships{Joined: []string{platCID}, Owned: []string{platCID}})
}

func (e *env) rawStatus(t *testing.T) (status, owner string) {
	t.Helper()
	d, ok := e.data(t, "communities/"+platCID)
	if !ok {
		t.Fatal("community missing")
	}
	status, _ = d["status"].(string)
	owner, _ = d["ownerId"].(string)
	return status, owner
}

// Suspend and restore (D14): field-level (the other fields stay), no change on a repeat, and the reads honour the
// status within the cache window (here a fresh service: NOT_FOUND to non-owners).
func TestPlatform_SuspendRestoreAndEffects(t *testing.T) {
	e := newEnv(t, 100)
	e.seedPlatform(t)
	repo := e.platformRepo()
	ctx := context.Background()
	at := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	before, _ := e.data(t, "communities/"+platCID)

	changed, was, now, err := repo.SetSuspended(context.Background(), platCID, true, at)
	if err != nil || !changed || was != StatusActive || now != StatusSuspended {
		t.Fatalf("suspend = %v %v %v %v", changed, was, now, err)
	}
	if st, _ := e.rawStatus(t); st != "SUSPENDED" {
		t.Fatalf("status = %s", st)
	}
	d, _ := e.data(t, "communities/"+platCID)
	for k, v := range before {
		if k == "status" || k == "updatedAt" {
			continue
		}
		if fmt.Sprint(d[k]) != fmt.Sprint(v) {
			t.Errorf("field %s changed: %v -> %v (the write must be field-level)", k, v, d[k])
		}
	}
	changed, _, _, err = repo.SetSuspended(context.Background(), platCID, true, at)
	if err != nil || changed {
		t.Fatalf("repeat = %v %v", changed, err)
	}
	if again, _ := e.data(t, "communities/"+platCID); fmt.Sprint(again) != fmt.Sprint(d) {
		t.Errorf("a repeat suspend rewrote the document: %v -> %v", d, again)
	}

	// The service answers the one NOT_FOUND to a stranger and refuses CreatePost's Admit; the owner still reads it.
	fresh := New(Deps{Repo: e.repo, Directory: e.dir, Graph: e.gr, IDs: e.node, Limits: Limits{MaxOwned: 2, MaxJoined: 50, MaxRules: 10, ModlogMax: 100, CacheEntries: 100, MembersCacheEntries: 100}}).(*service)
	if _, err := fresh.GetCommunity(ctx, "member", platCID); err == nil {
		t.Error("GetCommunity of a SUSPENDED community by a member succeeded")
	}
	if v, err := fresh.GetCommunity(ctx, "owner", platCID); err != nil || v.View.Community.Status != StatusSuspended {
		t.Errorf("owner GetCommunity = %+v, %v", v, err)
	}
	gate := NewPostGate(fresh, e.repo)
	if _, err := gate.Admit(ctx, platCID); err == nil {
		t.Error("CreatePost's gate admitted a post into a SUSPENDED community")
	}

	changed, was, now, err = repo.SetSuspended(context.Background(), platCID, false, at)
	if err != nil || !changed || was != StatusSuspended || now != StatusActive {
		t.Fatalf("restore = %v %v %v %v", changed, was, now, err)
	}
	if changed, _, _, err := repo.SetSuspended(context.Background(), platCID, false, at); err != nil || changed {
		t.Fatalf("restore repeat = %v %v", changed, err)
	}
	if _, _, _, err := repo.SetSuspended(ctx, "0000000000000000999", true, at); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing community: %v, want ErrNotFound", err)
	}
	if _, ok := e.data(t, "communities/0000000000000000999"); ok {
		t.Error("a suspend of a missing community created it")
	}
}

// Restore of an ownerless community puts it back to ARCHIVED, never ACTIVE.
func TestPlatform_RestoreOfOwnerlessIsArchived(t *testing.T) {
	e := newEnv(t, 100)
	e.seedPlatform(t)
	repo := e.platformRepo()
	ctx := context.Background()
	at := time.Now().UTC()
	if _, err := e.client.Doc("communities/"+platCID).Update(ctx, []firestore.Update{{Path: "ownerId", Value: ""}, {Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	changed, _, now, err := repo.SetSuspended(ctx, platCID, false, at)
	if err != nil || !changed || now != StatusArchived {
		t.Fatalf("restore = %v %v %v", changed, now, err)
	}
	if st, _ := e.rawStatus(t); st != "ARCHIVED" {
		t.Errorf("status = %s", st)
	}
}

// Archive (D14): the owner goes, the member doc stays, an OWNER_HANDOVER entry names the former owner as the actor with
// no target, owned loses the community and modlogged gains it; a repeat changes nothing; a SUSPENDED community is refused.
func TestPlatform_ArchiveAndRecords(t *testing.T) {
	e := newEnv(t, 100)
	e.seedPlatform(t)
	repo := e.platformRepo()
	ctx := context.Background()
	at := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)

	res, err := repo.Archive(context.Background(), platCID, at, 100)
	if err != nil || !res.Changed || res.OwnerMember != MemberJoined {
		t.Fatalf("archive = %+v %v", res, err)
	}
	c := e.community(t, platCID)
	if c.Status != StatusArchived || c.OwnerID != "" || c.MemberCount != 3 || !slices.Equal(c.ModeratorIDs, []string{"mod1"}) {
		t.Fatalf("community = %+v", c)
	}
	if len(c.Modlog) != 1 || c.Modlog[0].Action != ActionOwnerHandover || c.Modlog[0].Actor != "owner" || c.Modlog[0].Target != "" || c.ModlogSeq != 1 {
		t.Fatalf("modlog = %+v seq %d", c.Modlog, c.ModlogSeq)
	}
	ms, _ := e.memberships(t, "owner")
	if slices.Contains(ms.Owned, platCID) || !slices.Contains(ms.Joined, platCID) || !slices.Contains(ms.Modlogged, platCID) {
		t.Errorf("memberships = %+v, want joined kept, owned dropped, modlogged added (I-M, I-L)", ms)
	}
	if st, err := e.repo.Member(ctx, platCID, "owner"); err != nil || st != MemberJoined {
		t.Errorf("former owner member state = %q, %v, want JOINED", st, err)
	}
	res, err = repo.Archive(context.Background(), platCID, at, 100)
	if err != nil || res.Changed {
		t.Fatalf("repeat = %+v %v", res, err)
	}
	if again := e.community(t, platCID); !reflect.DeepEqual(again, c) {
		t.Errorf("a repeat archive rewrote the community: %+v -> %+v", c, again)
	}

	// A restore never un-archives: an ownerless community that is suspended comes back ARCHIVED.
	if changed, _, now, err := repo.SetSuspended(ctx, platCID, true, at); err != nil || !changed || now != StatusSuspended {
		t.Fatalf("suspend archived = %v %v %v", changed, now, err)
	}
	if _, _, now, err := repo.SetSuspended(ctx, platCID, false, at); err != nil || now != StatusArchived {
		t.Fatalf("restore = %v %v", now, err)
	}
}

func TestPlatform_ArchiveRefusesSuspendedAndMissing(t *testing.T) {
	e := newEnv(t, 100)
	e.seedPlatform(t)
	repo := e.platformRepo()
	ctx := context.Background()
	at := time.Now().UTC()
	if _, _, _, err := repo.SetSuspended(ctx, platCID, true, at); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Archive(context.Background(), platCID, at, 100); !errors.Is(err, ErrSuspendedArchive) {
		t.Fatalf("err = %v, want ErrSuspendedArchive", err)
	}
	if st, owner := e.rawStatus(t); st != "SUSPENDED" || owner != "owner" {
		t.Errorf("a refused archive wrote: status %s owner %q", st, owner)
	}
	if _, err := repo.Archive(ctx, "0000000000000000998", at, 100); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
}

// Append (D14): any number of posts in one call, newest last, a post already listed is not appended again, the cap drops the oldest and
// sets removalsTruncatedAt, a missing community is ErrNotFound and is not created, and a SUSPENDED community still keeps its log.
func TestPlatform_AppendRemovalsAndCap(t *testing.T) {
	e := newEnv(t, 100)
	e.seedPlatform(t)
	repo := e.platformRepo()
	ctx := context.Background()
	t0 := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)

	n, err := repo.Append(context.Background(), platCID, []string{"p1", "p2", "p3"}, t0, 0)
	if err != nil || n != 3 {
		t.Fatalf("append = %d %v", n, err)
	}
	c := e.community(t, platCID)
	if got := removalIDs(c); !slices.Equal(got, []string{"p1", "p2", "p3"}) || !c.RemovalsTruncatedAt.IsZero() {
		t.Fatalf("removals = %v truncated %v", got, c.RemovalsTruncatedAt)
	}
	n, err = repo.Append(context.Background(), platCID, []string{"p2", "p3"}, t0.Add(time.Minute), 0)
	if err != nil || n != 0 {
		t.Fatalf("repeat = %d %v", n, err)
	}
	if got := removalIDs(e.community(t, platCID)); !slices.Equal(got, []string{"p1", "p2", "p3"}) {
		t.Fatalf("removals after a repeat = %v", got)
	}
	if n, err := repo.Append(context.Background(), platCID, []string{"p3", "p4"}, t0.Add(2*time.Minute), 0); err != nil || n != 1 {
		t.Fatalf("append = %d %v", n, err)
	}

	// The cap: limit 3 over [p1 p2 p3 p4] drops p1 and p2 as new ones arrive; removalsTruncatedAt is the `at` of the newest dropped entry.
	t1 := t0.Add(time.Hour)
	if n, err := repo.Append(ctx, platCID, []string{"p5", "p6"}, t1, 3); err != nil || n != 2 {
		t.Fatalf("append = %d %v", n, err)
	}
	c = e.community(t, platCID)
	if got := removalIDs(c); !slices.Equal(got, []string{"p4", "p5", "p6"}) {
		t.Fatalf("removals = %v", got)
	}
	if !c.RemovalsTruncatedAt.Equal(t0) { // p3 (at t0) was the newest entry the cap dropped
		t.Errorf("removalsTruncatedAt = %v, want %v", c.RemovalsTruncatedAt, t0)
	}

	// A SUSPENDED community still keeps its log; a missing one is ErrNotFound and is not created.
	if _, _, _, err := repo.SetSuspended(ctx, platCID, true, t1); err != nil {
		t.Fatal(err)
	}
	if n, err := repo.Append(ctx, platCID, []string{"p7"}, t1, 0); err != nil || n != 1 {
		t.Fatalf("append to suspended = %d %v", n, err)
	}
	if _, err := repo.Append(ctx, "0000000000000000997", []string{"p1"}, t1, 0); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
	if _, ok := e.data(t, "communities/0000000000000000997"); ok {
		t.Error("an append to a missing community created it")
	}
	if n, err := repo.Append(ctx, platCID, nil, t1, 0); err != nil || n != 0 {
		t.Errorf("empty append = %d %v", n, err)
	}
}

func removalIDs(c Community) []string {
	var out []string
	for _, r := range c.RecentRemovals {
		out = append(out, r.PostID)
	}
	return out
}
