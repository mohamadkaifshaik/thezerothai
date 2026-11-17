//go:build integration

package identity_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Fixed, well-formed public ids. Every test runs in its own demo-* project (newTestClient), so they never collide.
const (
	pubA = "u0000000000000000000000000a"
	pubB = "u0000000000000000000000000b"
	pubC = "u0000000000000000000000000c"
)

// pubFlagsOn is public_ids on for everyone.
type pubFlagsOn struct{}

func (pubFlagsOn) Enabled(_, name string) bool  { return name == identity.PublicIDsFlag }
func (pubFlagsOn) GloballyOff(name string) bool { return name != identity.PublicIDsFlag }
func docData(t *testing.T, c *firestore.Client, path string) (map[string]any, bool) {
	t.Helper()
	snap, err := c.Doc(path).Get(context.Background())
	if err != nil {
		return nil, false
	}
	return snap.Data(), snap.Exists()
}

// lookupsOf returns the ids of the publicIds documents that name uid.
func lookupsOf(t *testing.T, c *firestore.Client, uid string) []string {
	t.Helper()
	snaps, err := c.Collection("publicIds").Where("uid", "==", uid).Limit(10).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatalf("query publicIds: %v", err)
	}
	var out []string
	for _, s := range snaps {
		out = append(out, s.Ref.ID)
	}
	return out
}

func TestPublicID_Integration_CreateProfileMints(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	p, replay, err := repo.CreateProfile(ctx, "uid-p1", "Alice", "alice", "Alice", pubA, time.Now().UTC(), nil)
	if err != nil || replay || p.PublicID != pubA {
		t.Fatalf("CreateProfile = %+v, %v, %v", p, replay, err)
	}
	if u, ok := docData(t, client, "users/uid-p1"); !ok || u["publicId"] != pubA {
		t.Fatalf("users/uid-p1.publicId = %v", u["publicId"])
	}
	if l, ok := docData(t, client, "publicIds/"+pubA); !ok || l["uid"] != "uid-p1" || l["createdAt"] == nil {
		t.Fatalf("publicIds/%s = %v", pubA, l)
	}
	got, err := repo.ResolvePublicIDs(ctx, []string{pubA, pubB})
	if err != nil || len(got) != 1 || got[pubA] != "uid-p1" {
		t.Fatalf("ResolvePublicIDs = %v, %v", got, err)
	}
	// Without an id nothing extra is written.
	if _, _, err := repo.CreateProfile(ctx, "uid-p2", "Bobby", "bobby", "Bob", "", time.Now().UTC(), nil); err != nil {
		t.Fatal(err)
	}
	if u, _ := docData(t, client, "users/uid-p2"); u["publicId"] != nil {
		t.Errorf("an account created without an id has publicId %v", u["publicId"])
	}
	if l := lookupsOf(t, client, "uid-p2"); len(l) != 0 {
		t.Errorf("lookups for an account created without an id: %v", l)
	}
}

// TestPublicID_Integration_CreateCollisionWritesNothing: a lookup that already exists fails the whole signup
// transaction (users, handle, graph and the lookup), and a rerun with a fresh id succeeds.
func TestPublicID_Integration_CreateCollisionWritesNothing(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	if _, err := client.Doc("publicIds/"+pubA).Set(ctx, map[string]any{"uid": "someone-else", "createdAt": time.Now()}); err != nil {
		t.Fatal(err)
	}
	_, _, err := repo.CreateProfile(ctx, "uid-c1", "Carol", "carol", "Carol", pubA, time.Now().UTC(), nil)
	if !errors.Is(err, identity.ErrCreateConflict) {
		t.Fatalf("err = %v, want ErrCreateConflict", err)
	}
	for _, path := range []string{"users/uid-c1", "handles/carol", "graph/uid-c1"} {
		if _, ok := docData(t, client, path); ok {
			t.Errorf("%s was written by the failed transaction", path)
		}
	}
	if l, _ := docData(t, client, "publicIds/"+pubA); l["uid"] != "someone-else" {
		t.Errorf("the existing lookup changed: %v", l)
	}
	p, _, err := repo.CreateProfile(ctx, "uid-c1", "Carol", "carol", "Carol", pubB, time.Now().UTC(), nil)
	if err != nil || p.PublicID != pubB {
		t.Fatalf("rerun = %+v, %v", p, err)
	}
}

func TestPublicID_Integration_EnsurePublicID(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	seedProfile(t, repo, "uid-e1", "Erin")
	now := time.Now().UTC()

	p, err := repo.EnsurePublicID(ctx, "uid-e1", pubA, now)
	if err != nil || p.PublicID != pubA {
		t.Fatalf("first mint = %q, %v", p.PublicID, err)
	}
	// A second call keeps the first id and writes no second lookup.
	p, err = repo.EnsurePublicID(ctx, "uid-e1", pubB, now)
	if err != nil || p.PublicID != pubA {
		t.Fatalf("second call = %q, %v; want the first id", p.PublicID, err)
	}
	if _, ok := docData(t, client, "publicIds/"+pubB); ok {
		t.Error("a second lookup was created")
	}
	if _, err := repo.EnsurePublicID(ctx, "uid-missing", pubC, now); !errors.Is(err, identity.ErrNotFound) {
		t.Errorf("missing user: err = %v, want ErrNotFound", err)
	}
	if _, ok := docData(t, client, "publicIds/"+pubC); ok {
		t.Error("a lookup was created for a missing user")
	}

	t.Run("a DELETING account is never minted", func(t *testing.T) {
		seedProfile(t, repo, "uid-e2", "Edgar")
		if _, err := repo.BeginDeletion(ctx, "uid-e2", now); err != nil {
			t.Fatal(err)
		}
		p, err := repo.EnsurePublicID(ctx, "uid-e2", pubC, now)
		if err != nil || p.PublicID != "" {
			t.Fatalf("EnsurePublicID on DELETING = %q, %v", p.PublicID, err)
		}
		if _, ok := docData(t, client, "publicIds/"+pubC); ok {
			t.Error("a DELETING account gained a lookup")
		}
	})
	t.Run("a taken lookup is ErrCreateConflict and writes nothing", func(t *testing.T) {
		seedProfile(t, repo, "uid-e3", "Elsa")
		_, err := repo.EnsurePublicID(ctx, "uid-e3", pubA, now) // pubA belongs to uid-e1
		if !errors.Is(err, identity.ErrCreateConflict) {
			t.Fatalf("err = %v, want ErrCreateConflict", err)
		}
		if u, _ := docData(t, client, "users/uid-e3"); u["publicId"] != nil {
			t.Errorf("users/uid-e3.publicId = %v after a failed mint", u["publicId"])
		}
	})
}

// TestPublicID_Integration_LazyMintRace: concurrent lazy mints of one account with different ids leave exactly one id
// and exactly one lookup (no orphan), and every caller sees that id.
func TestPublicID_Integration_LazyMintRace(t *testing.T) {
	repo, client := lifecycleRepo(t)
	seedProfile(t, repo, "uid-r1", "Racer")
	const n = 6
	got := make([]string, n)
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			p, err := repo.EnsurePublicID(context.Background(), "uid-r1", fmt.Sprintf("u000000000000000000000000r%d", i), time.Now().UTC())
			got[i], errs[i] = p.PublicID, err
		}()
	}
	wg.Wait()
	u, _ := docData(t, client, "users/uid-r1")
	stored, _ := u["publicId"].(string)
	if stored == "" {
		t.Fatal("no id was stored")
	}
	if l := lookupsOf(t, client, "uid-r1"); len(l) != 1 || l[0] != stored {
		t.Fatalf("lookups = %v, want exactly [%s]", l, stored)
	}
	for i := range n {
		// A racer whose transaction outlived the SDK's own retries may fail; it must not have written anything.
		if errs[i] == nil && got[i] != stored {
			t.Errorf("racer %d saw %q, want %q", i, got[i], stored)
		}
	}
}

// TestPublicID_Integration_RewritesKeepTheID: every whole-document rewrite of users/{uid} (UpdateProfile, ChangeHandle,
// the privacy toggle) carries publicId through.
func TestPublicID_Integration_RewritesKeepTheID(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	if _, _, err := repo.CreateProfile(ctx, "uid-w1", "Walt", "walt", "Walt", pubA, time.Now().UTC(), nil); err != nil {
		t.Fatal(err)
	}
	check := func(what string) {
		t.Helper()
		if u, _ := docData(t, client, "users/uid-w1"); u["publicId"] != pubA {
			t.Fatalf("after %s users/uid-w1.publicId = %v, want %s", what, u["publicId"], pubA)
		}
	}
	if _, err := repo.UpdateProfile(ctx, "uid-w1", func(p *identity.Profile) { p.Bio = "new bio"; p.UpdatedAt = time.Now().UTC() }); err != nil {
		t.Fatal(err)
	}
	check("UpdateProfile")
	if _, _, err := repo.ChangeHandle(ctx, "uid-w1", "Walter", "walter", time.Now().UTC(), time.Hour); err != nil {
		t.Fatal(err)
	}
	check("ChangeHandle")
	if _, err := repo.UpdateProfileWithPrivacy(ctx, "uid-w1", func(p *identity.Profile) { p.IsPrivate = true; p.UpdatedAt = time.Now().UTC() }, identity.PrivacyLimits{SetMax: 1000}); err != nil {
		t.Fatal(err)
	}
	check("the privacy toggle")
}

func TestPublicID_Integration_DeleteIfOwned(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	if _, _, err := repo.CreateProfile(ctx, "uid-d1", "Dora", "dora", "Dora", pubA, time.Now().UTC(), nil); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Doc("publicIds/"+pubB).Set(ctx, map[string]any{"uid": "someone-else", "createdAt": time.Now()}); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, id string
		want     identity.HandleOutcome
	}{
		{"owned", pubA, identity.HandleDeleted},
		{"re-run is idempotent", pubA, identity.HandleAbsent},
		{"another owner is left alone", pubB, identity.HandleOwnerMismatch},
		{"empty id", "", identity.HandleAbsent},
	} {
		got, err := repo.DeletePublicIDIfOwned(ctx, tc.id, "uid-d1")
		if err != nil || got != tc.want {
			t.Errorf("%s: outcome %v, err %v; want %v", tc.name, got, err, tc.want)
		}
	}
	if _, ok := docData(t, client, "publicIds/"+pubA); ok {
		t.Error("the owned lookup survived")
	}
	if _, ok := docData(t, client, "publicIds/"+pubB); !ok {
		t.Error("another account's lookup was deleted")
	}
}

// TestPublicID_Integration_ServiceGetMeAndLookups: the service over Firestore, public_ids on: GetMe lazily mints for a
// legacy account and shows the id, the lookups resolve both ways, GetProfile serves the public_id target, and an
// unknown id is the handle arm's NOT_FOUND.
func TestPublicID_Integration_ServiceGetMeAndLookups(t *testing.T) {
	repo, client := lifecycleRepo(t)
	ctx := context.Background()
	seedProfile(t, repo, "uid-s1", "Sara")
	seedProfile(t, repo, "uid-s2", "Sven")
	svc := identity.New(repo, identity.NewCache(time.Minute), time.Hour, identity.WithExtrasFlags(pubFlagsOn{}))
	me, err := svc.GetMe(ctx, "uid-s1")
	if err != nil || !identity.ValidPublicID(me.Profile.PublicID) {
		t.Fatalf("GetMe = %q, %v", me.Profile.PublicID, err)
	}
	if l := lookupsOf(t, client, "uid-s1"); len(l) != 1 || l[0] != me.Profile.PublicID {
		t.Fatalf("lookups = %v", l)
	}
	again, err := svc.GetMe(ctx, "uid-s1")
	if err != nil || again.Profile.PublicID != me.Profile.PublicID {
		t.Fatalf("second GetMe = %q, %v", again.Profile.PublicID, err)
	}
	lookups := svc.(identity.PublicIDs)
	byUID, err := lookups.PublicIDsForUIDs(ctx, []string{"uid-s1", "uid-s2", "uid-none"})
	if err != nil || len(byUID) != 1 || byUID["uid-s1"] != me.Profile.PublicID {
		t.Fatalf("PublicIDsForUIDs = %v, %v (uid-s2 has no id yet, uid-none no account)", byUID, err)
	}
	if uid, err := lookups.UIDForPublicID(ctx, me.Profile.PublicID); err != nil || uid != "uid-s1" {
		t.Fatalf("UIDForPublicID = %q, %v", uid, err)
	}
	got, err := svc.GetProfile(ctx, "uid-s2", identity.ProfileTarget{PublicID: me.Profile.PublicID})
	if err != nil || got.UserID != "uid-s1" || got.PublicID != me.Profile.PublicID {
		t.Fatalf("GetProfile by public id = %+v, %v", got, err)
	}
	_, unknown := svc.GetProfile(ctx, "uid-s2", identity.ProfileTarget{PublicID: pubC})
	_, noHandle := svc.GetProfile(ctx, "uid-s2", identity.ProfileTarget{Handle: "nosuchhandle"})
	if unknown == nil || noHandle == nil || unknown.Error() != noHandle.Error() {
		t.Errorf("unknown id = %v, unknown handle = %v; want the same NOT_FOUND", unknown, noHandle)
	}
}
