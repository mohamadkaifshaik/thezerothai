package identity

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// TestCreateProfile_RetriesOnlyOnPublicIDCollision: a commit-time create conflict that is not a public id collision (a
// pre-existing graph/{uid}, say) is deterministic, so it fails after one run instead of three transactions and three Auth
// lookups; a collision (the in-transaction read found publicIds/{id}) is still retried with a fresh id.
func TestCreateProfile_RetriesOnlyOnPublicIDCollision(t *testing.T) {
	for _, tc := range []struct {
		name      string
		createErr error
		wantCalls int
	}{
		{"a generic create conflict is not retried", ErrCreateConflict, 1},
		{"a public id collision is retried up to the bound", ErrPublicIDCollision, maxPublicIDAttempts},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.createErr = tc.createErr
			svc := newPubService(repo, pubFlags{mode: "on"})
			svc.newPublicID = seqIDs(pid('1'), pid('2'), pid('3'))
			_, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A.")
			if !errors.Is(err, ErrCreateConflict) {
				t.Fatalf("err = %v, want a wrapped ErrCreateConflict", err)
			}
			if repo.createCalls != tc.wantCalls {
				t.Errorf("repo runs = %d, want %d", repo.createCalls, tc.wantCalls)
			}
		})
	}
}

// TestCreateProfile_FailureRedactsDrawnPublicID: an error whose text names the drawn public id (Firestore prints document
// paths) never carries it raw out of CreateProfile.
func TestCreateProfile_FailureRedactsDrawnPublicID(t *testing.T) {
	repo := newFakeRepo()
	repo.createErr = errors.New("rpc error: commit failed: documents/publicIds/" + pid('7') + " and users/uid-1")
	svc := newPubService(repo, pubFlags{mode: "on"})
	svc.newPublicID = seqIDs(pid('7'))
	_, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A.")
	if err == nil {
		t.Fatal("want an error")
	}
	chain := logger.CauseChain(err)
	if strings.Contains(chain, pid('7')) || strings.Contains(chain, "uid-1") {
		t.Errorf("error chain carries a raw id: %q", chain)
	}
}

// TestGetProfile_PublicIDCorruptLookupUID: a lookup document whose uid is empty or not a valid uid answers the unknown-id
// NOT_FOUND bytes (never VALIDATION, never INTERNAL, never the document it happens to name).
func TestGetProfile_PublicIDCorruptLookupUID(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	seedLegacy(repo, "viewer", "Viewer", AccountStatusActive)
	// A profile stored under an id the uid validator rejects: the corrupt lookup must not reach it.
	repo.profiles["bad_uid"] = Profile{UserID: "bad_uid", Handle: "Bad", HandleLower: "bad", Status: AccountStatusActive}
	repo.publicIDs[pid('e')] = ""
	repo.publicIDs[pid('m')] = "bad_uid"
	svc := newPubService(repo, pubFlags{mode: "on"})
	_, want := svc.GetProfile(ctx, "viewer", ProfileTarget{PublicID: pid('v')})
	assertNotFound(t, want)
	for _, tc := range []struct{ name, id string }{
		{"empty uid", pid('e')},
		{"malformed uid", pid('m')},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := svc.GetProfile(ctx, "viewer", ProfileTarget{PublicID: tc.id})
			if err == nil {
				t.Fatalf("GetProfile = %+v, want NOT_FOUND", got)
			}
			if wireOf(t, err) != wireOf(t, want) {
				t.Errorf("wire = %s, want the unknown-id bytes %s", wireOf(t, err), wireOf(t, want))
			}
		})
	}
}
