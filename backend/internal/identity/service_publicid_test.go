package identity

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// pubFlags is the public_ids flag in one of its three states: "off" (globally off, prod), "allow" (an allowlist
// rollout: not globally off, on only for the listed uids) and "on". Every other flag name is off.
type pubFlags struct {
	mode  string
	allow map[string]bool
}

func (f pubFlags) Enabled(uid, name string) bool {
	if name != PublicIDsFlag {
		return false
	}
	return f.mode == "on" || f.mode == "allow" && f.allow[uid]
}

func (f pubFlags) GloballyOff(name string) bool { return name != PublicIDsFlag || f.mode == "off" }

// seqIDs returns a generator that hands out ids in order (then fails), to force collisions.
func seqIDs(ids ...string) func() (string, error) {
	var mu sync.Mutex
	return func() (string, error) {
		mu.Lock()
		defer mu.Unlock()
		if len(ids) == 0 {
			return "", errors.New("generator exhausted")
		}
		id := ids[0]
		ids = ids[1:]
		return id, nil
	}
}

// pid builds a valid public id that differs by its last character.
func pid(c byte) string { return "u000000000000000000000000" + "0" + string(c) }

func newPubService(repo *fakeRepo, flags pubFlags, opts ...Option) *service {
	return New(repo, NewCache(time.Minute), 7*24*time.Hour, append([]Option{WithExtrasFlags(flags)}, opts...)...).(*service)
}

// wireOf is the client-visible form of a service error (code, message, details), so two answers can be compared byte for byte.
func wireOf(t *testing.T, err error) string {
	t.Helper()
	ce := apierr.ToConnect(err)
	if ce == nil {
		t.Fatalf("no wire error for %v", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%v|%s", ce.Code(), ce.Message())
	for _, d := range ce.Details() {
		fmt.Fprintf(&b, "|%s:%x", d.Type(), d.Bytes())
	}
	return b.String()
}

func TestCreateProfile_PublicIDByFlagMode(t *testing.T) {
	for _, tc := range []struct {
		name     string
		flags    pubFlags
		wantMint bool
	}{
		{"globally off: no id, no extra write", pubFlags{mode: "off"}, false},
		{"allowlist without the caller: minted, not shown", pubFlags{mode: "allow", allow: map[string]bool{"someone": true}}, true},
		{"allowlist with the caller: minted, not shown by CreateProfile", pubFlags{mode: "allow", allow: map[string]bool{"uid-1": true}}, true},
		{"on: minted, not shown by CreateProfile", pubFlags{mode: "on"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			svc := newPubService(repo, tc.flags)
			out, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A.")
			if err != nil {
				t.Fatal(err)
			}
			if out.PublicID != "" {
				t.Errorf("CreateProfile response carries public id %q", out.PublicID)
			}
			stored := repo.profiles["uid-1"].PublicID
			if got := stored != ""; got != tc.wantMint {
				t.Fatalf("stored public id %q, want minted=%v", stored, tc.wantMint)
			}
			if !tc.wantMint {
				if len(repo.publicIDs) != 0 || len(repo.createPublicIDs) != 1 || repo.createPublicIDs[0] != "" {
					t.Errorf("globally off wrote lookups %v / passed ids %q", repo.publicIDs, repo.createPublicIDs)
				}
				return
			}
			if !ValidPublicID(stored) || repo.publicIDs[stored] != "uid-1" || len(repo.publicIDs) != 1 {
				t.Errorf("stored %q, lookups %v; want one valid lookup owned by uid-1", stored, repo.publicIDs)
			}
		})
	}
}

func TestCreateProfile_PublicIDCollision(t *testing.T) {
	t.Run("retries with a fresh id", func(t *testing.T) {
		repo := newFakeRepo()
		repo.publicIDs[pid('1')], repo.publicIDs[pid('2')] = "other-1", "other-2"
		svc := newPubService(repo, pubFlags{mode: "on"})
		svc.newPublicID = seqIDs(pid('1'), pid('2'), pid('3'))
		if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
			t.Fatal(err)
		}
		if repo.createCalls != 3 || repo.profiles["uid-1"].PublicID != pid('3') || repo.publicIDs[pid('3')] != "uid-1" {
			t.Errorf("calls %d, stored %q, lookups %v; want 3 runs ending on the third id", repo.createCalls, repo.profiles["uid-1"].PublicID, repo.publicIDs)
		}
	})
	t.Run("three collisions are an internal error and nothing is written", func(t *testing.T) {
		repo := newFakeRepo()
		for _, c := range []byte("123") {
			repo.publicIDs[pid(c)] = "other"
		}
		svc := newPubService(repo, pubFlags{mode: "on"})
		svc.newPublicID = seqIDs(pid('1'), pid('2'), pid('3'), pid('4'))
		_, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A.")
		if err == nil || !errors.Is(err, ErrCreateConflict) {
			t.Fatalf("err = %v, want a wrapped ErrCreateConflict", err)
		}
		var ae *apierr.Error
		if errors.As(err, &ae) {
			t.Errorf("err is a client error %v, want an internal one", ae)
		}
		if repo.createCalls != maxPublicIDAttempts || len(repo.profiles) != 0 || len(repo.publicIDs) != 3 {
			t.Errorf("calls %d profiles %d lookups %d; want %d runs, nothing written", repo.createCalls, len(repo.profiles), len(repo.publicIDs), maxPublicIDAttempts)
		}
	})
	t.Run("a generator failure writes nothing", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newPubService(repo, pubFlags{mode: "on"})
		svc.newPublicID = seqIDs()
		if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err == nil {
			t.Fatal("want an error")
		}
		if repo.createCalls != 0 {
			t.Errorf("CreateProfile reached the repo %d times without an id", repo.createCalls)
		}
	})
	t.Run("globally off never retries a conflict", func(t *testing.T) {
		repo := newFakeRepo()
		repo.createErr = ErrCreateConflict
		svc := newPubService(repo, pubFlags{mode: "off"})
		if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err == nil {
			t.Fatal("want an error")
		}
		if repo.createCalls != 1 {
			t.Errorf("calls = %d, want 1", repo.createCalls)
		}
	})
}

// seedLegacy seeds an account created before public ids (no id).
func seedLegacy(repo *fakeRepo, uid, handle string, status AccountStatus) {
	repo.profiles[uid] = Profile{UserID: uid, Handle: handle, HandleLower: strings.ToLower(handle), DisplayName: handle, Status: status}
	repo.handles[strings.ToLower(handle)] = uid
}

func TestGetMe_LazyPublicIDMint(t *testing.T) {
	for _, tc := range []struct {
		name               string
		flags              pubFlags
		status             AccountStatus
		existing           string
		wantMint, wantShow bool
	}{
		{"globally off: no transaction, no read", pubFlags{mode: "off"}, AccountStatusActive, "", false, false},
		{"allowlist without the caller: minted, not shown", pubFlags{mode: "allow", allow: map[string]bool{"x": true}}, AccountStatusActive, "", true, false},
		{"allowlisted caller: minted and shown", pubFlags{mode: "allow", allow: map[string]bool{"uid-1": true}}, AccountStatusActive, "", true, true},
		{"on: minted and shown", pubFlags{mode: "on"}, AccountStatusActive, "", true, true},
		{"already minted: no transaction, shown", pubFlags{mode: "on"}, AccountStatusActive, pid('9'), false, true},
		{"globally off with a stored id: not shown", pubFlags{mode: "off"}, AccountStatusActive, pid('9'), false, false},
		{"suspended: never minted", pubFlags{mode: "on"}, AccountStatusSuspended, "", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			seedLegacy(repo, "uid-1", "Alice", tc.status)
			if tc.existing != "" {
				p := repo.profiles["uid-1"]
				p.PublicID = tc.existing
				repo.profiles["uid-1"] = p
				repo.publicIDs[tc.existing] = "uid-1"
			}
			svc := newPubService(repo, tc.flags)
			res, err := svc.GetMe(context.Background(), "uid-1")
			if err != nil {
				t.Fatal(err)
			}
			stored := repo.profiles["uid-1"].PublicID
			if minted := tc.existing == "" && stored != ""; minted != tc.wantMint {
				t.Fatalf("minted = %v (stored %q), want %v", minted, stored, tc.wantMint)
			}
			if !tc.wantMint && tc.existing == "" && (repo.ensureCalls != 0 || len(repo.publicIDs) != 0) {
				t.Errorf("no mint expected, but %d EnsurePublicID calls and lookups %v", repo.ensureCalls, repo.publicIDs)
			}
			if tc.existing != "" && repo.ensureCalls != 0 {
				t.Errorf("an account with an id cost %d extra transactions", repo.ensureCalls)
			}
			if repo.getProfileCalls != 1 {
				t.Errorf("GetProfile reads = %d, want 1 (no extra read)", repo.getProfileCalls)
			}
			want := ""
			if tc.wantShow {
				want = stored
			}
			if res.Profile.PublicID != want {
				t.Errorf("GetMe public id = %q, want %q", res.Profile.PublicID, want)
			}
			// A second GetMe is a cache hit: no read and no transaction.
			ensure, reads := repo.ensureCalls, repo.getProfileCalls
			if _, err := svc.GetMe(context.Background(), "uid-1"); err != nil {
				t.Fatal(err)
			}
			if repo.ensureCalls != ensure || repo.getProfileCalls != reads {
				t.Errorf("second GetMe: ensure %d->%d, reads %d->%d; want no change", ensure, repo.ensureCalls, reads, repo.getProfileCalls)
			}
		})
	}
}

// TestGetMe_ConcurrentLazyMint: many instances (separate caches) answering the same user's GetMe at once yield one id
// and one lookup, never an orphan.
func TestGetMe_ConcurrentLazyMint(t *testing.T) {
	repo := newFakeRepo()
	seedLegacy(repo, "uid-1", "Alice", AccountStatusActive)
	const n = 16
	ids := make([]string, n)
	var wg sync.WaitGroup
	for i := range n {
		svc := newPubService(repo, pubFlags{mode: "on"})
		wg.Add(1)
		go func() {
			defer wg.Done()
			res, err := svc.GetMe(context.Background(), "uid-1")
			if err != nil {
				t.Error(err)
				return
			}
			ids[i] = res.Profile.PublicID
		}()
	}
	wg.Wait()
	repo.mu.Lock()
	defer repo.mu.Unlock()
	if len(repo.publicIDs) != 1 || repo.ensureWrites != 1 {
		t.Fatalf("lookups %v, minting writes %d; want exactly one", repo.publicIDs, repo.ensureWrites)
	}
	stored := repo.profiles["uid-1"].PublicID
	if repo.publicIDs[stored] != "uid-1" {
		t.Fatalf("stored id %q has lookup owner %q", stored, repo.publicIDs[stored])
	}
	for i, id := range ids {
		if id != stored {
			t.Errorf("instance %d answered %q, want %q", i, id, stored)
		}
	}
}

func TestGetMe_LazyMintCollisionAndFailure(t *testing.T) {
	t.Run("retries with a fresh id", func(t *testing.T) {
		repo := newFakeRepo()
		seedLegacy(repo, "uid-1", "Alice", AccountStatusActive)
		repo.publicIDs[pid('1')] = "other"
		svc := newPubService(repo, pubFlags{mode: "on"})
		svc.newPublicID = seqIDs(pid('1'), pid('2'))
		res, err := svc.GetMe(context.Background(), "uid-1")
		if err != nil || res.Profile.PublicID != pid('2') || repo.ensureCalls != 2 {
			t.Fatalf("id %q err %v calls %d; want the second id after 2 calls", res.Profile.PublicID, err, repo.ensureCalls)
		}
	})
	t.Run("exhausted collisions answer GetMe without an id and WARN without the id", func(t *testing.T) {
		repo := newFakeRepo()
		seedLegacy(repo, "uid-1", "Alice", AccountStatusActive)
		for _, c := range []byte("123") {
			repo.publicIDs[pid(c)] = "other"
		}
		var logs bytes.Buffer
		svc := newPubService(repo, pubFlags{mode: "on"}, WithFollowRequestCounter(nil, slog.New(slog.NewJSONHandler(&logs, nil))))
		svc.newPublicID = seqIDs(pid('1'), pid('2'), pid('3'))
		res, err := svc.GetMe(context.Background(), "uid-1")
		if err != nil || res.Profile.PublicID != "" {
			t.Fatalf("GetMe = %q, %v; want success without an id", res.Profile.PublicID, err)
		}
		if repo.ensureCalls != maxPublicIDAttempts || repo.profiles["uid-1"].PublicID != "" {
			t.Errorf("calls %d stored %q", repo.ensureCalls, repo.profiles["uid-1"].PublicID)
		}
		line := logs.String()
		if !strings.Contains(line, "public_id_mint_failed") || !strings.Contains(line, "uid_hash") {
			t.Errorf("no WARN public_id_mint_failed with a uid hash: %s", line)
		}
		for _, leak := range []string{"uid-1", pid('1'), pid('2'), pid('3')} {
			if strings.Contains(line, leak) {
				t.Errorf("the WARN carries %q: %s", leak, line)
			}
		}
	})
}

// TestGetMe_FlagOffMakesNoNewCalls: with public_ids globally off, GetMe and GetProfile cost exactly what they did
// before the feature (one profile read each, no transaction, no lookup read).
func TestGetMe_FlagOffMakesNoNewCalls(t *testing.T) {
	repo := newFakeRepo()
	seedLegacy(repo, "uid-1", "Alice", AccountStatusActive)
	seedLegacy(repo, "uid-2", "Bob", AccountStatusActive)
	svc := newPubService(repo, pubFlags{mode: "off"})
	if _, err := svc.GetMe(context.Background(), "uid-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.GetProfile(context.Background(), "uid-1", ProfileTarget{Handle: "bob"}); err != nil {
		t.Fatal(err)
	}
	_, err := svc.GetProfile(context.Background(), "uid-1", ProfileTarget{PublicID: pid('1')})
	wantValidationField(t, err, "target")
	if m, err := svc.PublicIDsForUIDs(context.Background(), []string{"uid-1", "uid-2"}); err != nil || len(m) != 0 {
		t.Fatalf("PublicIDsForUIDs = %v, %v", m, err)
	}
	if m, err := svc.UIDsForPublicIDs(context.Background(), []string{pid('1')}); err != nil || len(m) != 0 {
		t.Fatalf("UIDsForPublicIDs = %v, %v", m, err)
	}
	if repo.ensureCalls != 0 || repo.resolvePubCalls != 0 || repo.getProfilesCalls != 0 || repo.getProfileCalls != 2 || repo.resolveCalls != 1 {
		t.Errorf("ensure %d resolvePub %d getProfiles %d getProfile %d resolveHandle %d; want 0 0 0 2 1",
			repo.ensureCalls, repo.resolvePubCalls, repo.getProfilesCalls, repo.getProfileCalls, repo.resolveCalls)
	}
}

func TestGetProfile_ByPublicID(t *testing.T) {
	on := pubFlags{mode: "allow", allow: map[string]bool{"viewer": true}}
	setup := func(t *testing.T, flags pubFlags) (*fakeRepo, *service) {
		t.Helper()
		repo := newFakeRepo()
		seedLegacy(repo, "viewer", "Viewer", AccountStatusActive)
		seedLegacy(repo, "uid-b", "Bob", AccountStatusActive)
		p := repo.profiles["uid-b"]
		p.PublicID = pid('b')
		repo.profiles["uid-b"] = p
		repo.publicIDs[pid('b')] = "uid-b"
		return repo, newPubService(repo, flags)
	}
	t.Run("caller with the flag gets the profile and its public id", func(t *testing.T) {
		_, svc := setup(t, on)
		got, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{PublicID: pid('b')})
		if err != nil || got.UserID != "uid-b" || got.PublicID != pid('b') {
			t.Fatalf("GetProfile = %+v, %v", got, err)
		}
		byHandle, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{Handle: "bob"})
		if err != nil || byHandle != got {
			t.Errorf("by handle = %+v, %v; want the same profile as by public id", byHandle, err)
		}
	})
	t.Run("caller without the flag: the arm is an empty target, no read", func(t *testing.T) {
		for _, flags := range []pubFlags{{mode: "off"}, {mode: "allow", allow: map[string]bool{"someone": true}}} {
			repo, svc := setup(t, flags)
			_, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{PublicID: pid('b')})
			_, empty := svc.GetProfile(context.Background(), "viewer", ProfileTarget{})
			if wireOf(t, err) != wireOf(t, empty) {
				t.Errorf("%s: public_id arm = %s, want the empty-target answer %s", flags.mode, wireOf(t, err), wireOf(t, empty))
			}
			if repo.resolvePubCalls != 0 || repo.getProfileCalls != 0 {
				t.Errorf("%s: reads lookup %d profile %d, want none", flags.mode, repo.resolvePubCalls, repo.getProfileCalls)
			}
			byHandle, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{Handle: "bob"})
			if err != nil || byHandle.PublicID != "" {
				t.Errorf("%s: by handle public id %q (%v), want none for a caller without the flag", flags.mode, byHandle.PublicID, err)
			}
		}
	})
	t.Run("a malformed id is VALIDATION public_id with no read", func(t *testing.T) {
		repo, svc := setup(t, on)
		_, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{PublicID: "Xk9aQ2mPz7LrT4vB8nC1dE6fGh3J"})
		wantValidationField(t, err, "public_id")
		if repo.resolvePubCalls != 0 {
			t.Errorf("lookup reads = %d", repo.resolvePubCalls)
		}
	})
	t.Run("the lookup is cached", func(t *testing.T) {
		repo, svc := setup(t, on)
		for range 3 {
			if _, err := svc.GetProfile(context.Background(), "viewer", ProfileTarget{PublicID: pid('b')}); err != nil {
				t.Fatal(err)
			}
		}
		if repo.resolvePubCalls != 1 {
			t.Errorf("lookup reads = %d, want 1", repo.resolvePubCalls)
		}
	})
}

// TestGetProfile_PublicIDNotFoundParity: unknown, erased (lookup gone, or stale in cache with the user gone),
// blocked-by, SUSPENDED and DELETING targets all answer the exact bytes of an unknown handle.
func TestGetProfile_PublicIDNotFoundParity(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	seedLegacy(repo, "viewer", "Viewer", AccountStatusActive)
	add := func(uid, handle string, id string, status AccountStatus) {
		seedLegacy(repo, uid, handle, status)
		p := repo.profiles[uid]
		p.PublicID = id
		repo.profiles[uid] = p
		repo.publicIDs[id] = uid
	}
	add("uid-blocker", "Blocker", pid('k'), AccountStatusActive)
	add("uid-susp", "Susp", pid('s'), AccountStatusSuspended)
	add("uid-del", "Deleting", pid('d'), AccountStatusDeleting)
	add("uid-gone", "Gone", pid('g'), AccountStatusActive)
	add("uid-wrong", "Wrong", pid('w'), AccountStatusActive)
	bc := &fakeBlockChecker{blockedBy: map[string]map[string]bool{"viewer": {"uid-blocker": true}}}
	svc := newPubService(repo, pubFlags{mode: "on"}, WithBlockChecker(bc))

	_, want := svc.GetProfile(ctx, "viewer", ProfileTarget{Handle: "nosuchhandle"})
	assertNotFound(t, want)
	// Stale cache on this instance: the account was erased elsewhere after this instance learned its id.
	if _, err := svc.UIDForPublicID(ctx, pid('g')); err != nil {
		t.Fatal(err)
	}
	delete(repo.profiles, "uid-gone")
	delete(repo.publicIDs, pid('g'))
	// Corrupt lookup: names an account that carries another id.
	repo.publicIDs[pid('x')] = "uid-wrong"

	for _, tc := range []struct{ name, id string }{
		{"unknown id", pid('v')},
		{"erased id (stale cache, user gone)", pid('g')},
		{"blocked by the target", pid('k')},
		{"suspended target", pid('s')},
		{"deleting target", pid('d')},
		{"lookup naming an account with another id", pid('x')},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := svc.GetProfile(ctx, "viewer", ProfileTarget{PublicID: tc.id})
			if got := wireOf(t, err); got != wireOf(t, want) {
				t.Errorf("wire = %s, want the unknown-handle bytes %s", got, wireOf(t, want))
			}
		})
	}
	// The same targets by handle answer the same bytes too (the shared path).
	for _, h := range []string{"blocker", "susp", "deleting"} {
		_, err := svc.GetProfile(ctx, "viewer", ProfileTarget{Handle: h})
		if wireOf(t, err) != wireOf(t, want) {
			t.Errorf("by handle %s: %s", h, wireOf(t, err))
		}
	}
}

// TestPublicID_NeverInMutatingResponses: only GetMe and GetProfile carry the id, even with the flag on.
func TestPublicID_NeverInMutatingResponses(t *testing.T) {
	repo := newFakeRepo()
	svc := newPubService(repo, pubFlags{mode: "on"})
	created, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A.")
	if err != nil || created.PublicID != "" {
		t.Fatalf("CreateProfile = %q, %v", created.PublicID, err)
	}
	stored := repo.profiles["uid-1"].PublicID
	bio := "hi"
	updated, err := svc.UpdateProfile(context.Background(), "uid-1", UpdateProfileParams{IdempotencyKey: validKey, Bio: &bio})
	if err != nil || updated.PublicID != "" {
		t.Fatalf("UpdateProfile = %q, %v", updated.PublicID, err)
	}
	renamed, err := svc.ChangeHandle(context.Background(), "uid-1", validKey, "Alice2")
	if err != nil || renamed.PublicID != "" {
		t.Fatalf("ChangeHandle = %q, %v", renamed.PublicID, err)
	}
	// The stored id survived both writes (the fake keeps Profile whole; the Firestore rewrites are covered by
	// TestUserDoc_PublicIDSurvivesRoundTrip and the emulator tests).
	if repo.profiles["uid-1"].PublicID != stored || stored == "" {
		t.Errorf("stored id %q -> %q", stored, repo.profiles["uid-1"].PublicID)
	}
	me, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil || me.Profile.PublicID != stored {
		t.Errorf("GetMe = %q, %v; want %q", me.Profile.PublicID, err, stored)
	}
	if p := toProtoProfile(me.Profile); p.GetPublicId() != stored {
		t.Errorf("proto public_id = %q", p.GetPublicId())
	}
}

func TestUserDoc_PublicIDSurvivesRoundTrip(t *testing.T) {
	p := Profile{UserID: "uid-1", Handle: "Alice", HandleLower: "alice", PublicID: pid('r'), Status: AccountStatusActive}
	if got := profileToDoc(p).toProfile("uid-1"); got.PublicID != p.PublicID {
		t.Fatalf("round trip lost the public id: %q", got.PublicID)
	}
	if got := profileToDoc(Profile{UserID: "uid-1"}).PublicID; got != "" {
		t.Fatalf("an account without an id gained %q", got)
	}
}

func TestPublicIDLookups(t *testing.T) {
	ctx := context.Background()
	t.Run("uids to public ids: cache first, one GetAll per 100 misses, absent when not minted", func(t *testing.T) {
		repo := newFakeRepo()
		var uids []string
		want := map[string]string{}
		for i := range 150 {
			uid := fmt.Sprintf("uid-%03d", i)
			seedLegacy(repo, uid, fmt.Sprintf("h%03d", i), AccountStatusActive)
			uids = append(uids, uid)
			if i%3 == 0 {
				continue // not minted yet
			}
			p := repo.profiles[uid]
			p.PublicID = encodePublicID([16]byte{15: byte(i)})
			repo.profiles[uid] = p
			want[uid] = p.PublicID
		}
		svc := newPubService(repo, pubFlags{mode: "allow"})
		got, err := svc.PublicIDsForUIDs(ctx, append(uids, uids[0], "bad_uid"))
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != len(want) || repo.getProfilesCalls != 2 {
			t.Fatalf("got %d ids in %d GetAlls, want %d in 2", len(got), repo.getProfilesCalls, len(want))
		}
		for uid, id := range want {
			if got[uid] != id {
				t.Errorf("%s -> %q, want %q", uid, got[uid], id)
			}
		}
		if again, _ := svc.PublicIDsForUIDs(ctx, uids); len(again) != len(want) || repo.getProfilesCalls != 2 {
			t.Errorf("second call read again (%d GetAlls) or changed (%d)", repo.getProfilesCalls, len(again))
		}
	})
	t.Run("public ids to uids: malformed skipped, unknown negatively cached, chunked", func(t *testing.T) {
		repo := newFakeRepo()
		var ids []string
		for i := range 120 {
			id := encodePublicID([16]byte{14: 1, 15: byte(i)})
			ids = append(ids, id)
			repo.publicIDs[id] = fmt.Sprintf("uid-%d", i)
		}
		unknown := pid('n')
		svc := newPubService(repo, pubFlags{mode: "allow"})
		got, err := svc.UIDsForPublicIDs(ctx, append(ids, unknown, "not-an-id", "U"+ids[0][1:]))
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 120 || repo.resolvePubCalls != 2 {
			t.Fatalf("got %d in %d GetAlls, want 120 in 2", len(got), repo.resolvePubCalls)
		}
		for _, args := range repo.resolvePubArgs {
			for _, a := range args {
				if !ValidPublicID(a) {
					t.Errorf("a malformed id reached Firestore: %q", a)
				}
			}
		}
		if _, err := svc.UIDForPublicID(ctx, unknown); !errors.Is(err, ErrNotFound) || repo.resolvePubCalls != 2 {
			t.Errorf("unknown id: err %v after %d GetAlls, want ErrNotFound from the negative cache", err, repo.resolvePubCalls)
		}
		if uid, err := svc.UIDForPublicID(ctx, ids[5]); err != nil || uid != "uid-5" || repo.resolvePubCalls != 2 {
			t.Errorf("cached id: %q %v after %d GetAlls", uid, err, repo.resolvePubCalls)
		}
	})
	t.Run("over the limit is an error", func(t *testing.T) {
		svc := newPubService(newFakeRepo(), pubFlags{mode: "on"})
		many := make([]string, MaxPublicIDLookups+1)
		for i := range many {
			many[i] = fmt.Sprintf("uid-%d", i)
		}
		if _, err := svc.PublicIDsForUIDs(ctx, many); err == nil {
			t.Error("PublicIDsForUIDs took more than the limit")
		}
		for i := range many {
			many[i] = encodePublicID([16]byte{13: byte(i >> 8), 15: byte(i)})
		}
		if _, err := svc.UIDsForPublicIDs(ctx, many); err == nil {
			t.Error("UIDsForPublicIDs took more than the limit")
		}
	})
}

// TestServer_GetProfilePublicIDArm_WireParity runs the real service behind the Connect handler: the proto public_id
// arm reaches the service, an unknown id answers the exact wire bytes of an unknown handle, and for a caller without
// the flag the arm answers the exact bytes of an empty target.
func TestServer_GetProfilePublicIDArm_WireParity(t *testing.T) {
	repo := newFakeRepo()
	seedLegacy(repo, "uid-1", "Viewer", AccountStatusActive)
	seedLegacy(repo, "uid-b", "Bob", AccountStatusActive)
	p := repo.profiles["uid-b"]
	p.PublicID = pid('b')
	repo.profiles["uid-b"] = p
	repo.publicIDs[pid('b')] = "uid-b"
	wire := func(err error) string {
		t.Helper()
		var ce *connect.Error
		if !errors.As(err, &ce) {
			t.Fatalf("error is %T (%v), want *connect.Error", err, err)
		}
		var b strings.Builder
		fmt.Fprintf(&b, "%v|%s", ce.Code(), ce.Message())
		for _, d := range ce.Details() {
			fmt.Fprintf(&b, "|%s:%x", d.Type(), d.Bytes())
		}
		return b.String()
	}
	get := func(t *testing.T, client identityv1connect.IdentityServiceClient, req *identityv1.GetProfileRequest) (*identityv1.Profile, error) {
		t.Helper()
		resp, err := client.GetProfile(context.Background(), connect.NewRequest(req))
		if err != nil {
			return nil, err
		}
		return resp.Msg.GetProfile(), nil
	}
	byPub := func(id string) *identityv1.GetProfileRequest {
		return &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_PublicId{PublicId: id}}
	}

	t.Run("flag on for the caller", func(t *testing.T) {
		client, closeFn := newTestServerHTTP(t, newPubService(repo, pubFlags{mode: "allow", allow: map[string]bool{"uid-1": true}}), "uid-1")
		defer closeFn()
		got, err := get(t, client, byPub(pid('b')))
		if err != nil || got.GetUserId() != "uid-b" || got.GetPublicId() != pid('b') {
			t.Fatalf("by public id = %v, %v", got, err)
		}
		_, unknownID := get(t, client, byPub(pid('v')))
		_, unknownHandle := get(t, client, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_Handle{Handle: "nosuchhandle"}})
		if wire(unknownID) != wire(unknownHandle) {
			t.Errorf("unknown id %s != unknown handle %s", wire(unknownID), wire(unknownHandle))
		}
	})
	t.Run("flag off for the caller", func(t *testing.T) {
		client, closeFn := newTestServerHTTP(t, newPubService(repo, pubFlags{mode: "allow", allow: map[string]bool{"someone": true}}), "uid-1")
		defer closeFn()
		_, armErr := get(t, client, byPub(pid('b')))
		_, emptyErr := get(t, client, &identityv1.GetProfileRequest{})
		if wire(armErr) != wire(emptyErr) {
			t.Errorf("public_id arm %s != empty target %s", wire(armErr), wire(emptyErr))
		}
		got, err := get(t, client, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_Handle{Handle: "bob"}})
		if err != nil || got.GetPublicId() != "" {
			t.Errorf("by handle public id %q (%v), want none", got.GetPublicId(), err)
		}
	})
}
