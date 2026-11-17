package identity

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

const lcPublicID = "u0123456789abcdefghjkmnpqrs"

// seedWithPublicID seeds an ACTIVE user that carries lcPublicID and its lookup owned by owner.
func (h *harness) seedWithPublicID(uid, handle, owner string) Profile {
	h.t.Helper()
	p := h.seedActive(uid, handle)
	p.PublicID = lcPublicID
	h.repo.seed(p)
	h.repo.publicIDs[lcPublicID] = owner
	return p
}

// TestJobs_PublicIDErasedBeforeUsersDoc: the chain deletes publicIds/{id} in the identity step, after the handle and
// before users/{uid}, and evicts both cache directions on the erasing instance.
func TestJobs_PublicIDErasedBeforeUsersDoc(t *testing.T) {
	h := newHarness(t)
	h.seedWithPublicID("u1", "Alice", "u1")
	h.cache.SetPublicID("u1", lcPublicID)
	if _, err := h.l.DeleteAccount(context.Background(), "u1", delKey); err != nil {
		t.Fatal(err)
	}
	h.drain(40)
	if _, ok := h.repo.user("u1"); ok {
		t.Fatal("users/u1 survived the chain")
	}
	if len(h.repo.publicIDs) != 0 {
		t.Fatalf("publicIds survived the chain: %v", h.repo.publicIDs)
	}
	last := -1
	for _, op := range []string{"repo.DeleteHandle", "repo.DeletePublicID", "repo.DeleteQuotas", "repo.DeleteUserDoc"} {
		i := h.log.index(op)
		if i < 0 || i < last {
			t.Fatalf("op %q at %d (previous at %d); log = %v", op, i, last, h.log.all())
		}
		last = i
	}
	if _, ok := h.cache.UIDForPublicID(lcPublicID); ok {
		t.Error("the erasing instance still resolves the erased public id")
	}
	if _, ok := h.cache.PublicIDForUID("u1"); ok {
		t.Error("the erasing instance still maps the erased uid to its public id")
	}
	if strings.Contains(h.logs.String(), lcPublicID) {
		t.Errorf("a log line carries the public id: %s", h.logs.String())
	}
}

func TestIdentityStep_PublicID(t *testing.T) {
	t.Run("re-run after the lookup is gone is a no-op success", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedWithPublicID("u1", "Alice", "u1")
		st := &jobStats{}
		for i := range 2 {
			if _, done, err := h.l.identityStep(context.Background(), p, st); err != nil || !done {
				t.Fatalf("run %d: done=%v err=%v", i+1, done, err)
			}
		}
		if len(h.repo.publicIDs) != 0 || h.repo.calls["DeletePublicIDIfOwned"] != 2 || h.log.count("repo.DeletePublicID") != 1 {
			t.Errorf("lookups %v, calls %d, deletes %d; want gone, 2 calls, 1 delete", h.repo.publicIDs, h.repo.calls["DeletePublicIDIfOwned"], h.log.count("repo.DeletePublicID"))
		}
	})
	t.Run("a lookup owned by another uid is left alone", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedWithPublicID("u1", "Alice", "someone-else")
		if _, done, err := h.l.identityStep(context.Background(), p, &jobStats{}); err != nil || !done {
			t.Fatalf("identityStep = %v, %v", done, err)
		}
		if h.repo.publicIDs[lcPublicID] != "someone-else" {
			t.Error("another account's lookup was deleted")
		}
		recs := h.logs.records("public_id_owner_mismatch")
		if len(recs) != 1 {
			t.Fatalf("WARN public_id_owner_mismatch lines = %d: %s", len(recs), h.logs.String())
		}
		if line := h.logs.String(); strings.Contains(line, lcPublicID) || strings.Contains(line, `"u1"`) {
			t.Errorf("the WARN carries the id or the raw uid: %s", line)
		}
	})
	t.Run("a failure stops the step and the retry finishes it", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedWithPublicID("u1", "Alice", "u1")
		h.repo.failOnce["DeletePublicIDIfOwned"] = errors.New("firestore unavailable for publicIds/" + lcPublicID)
		_, done, err := h.l.identityStep(context.Background(), p, &jobStats{})
		if err == nil || done {
			t.Fatalf("done=%v err=%v, want an error", done, err)
		}
		if strings.Contains(err.Error(), lcPublicID) || strings.Contains(err.Error(), "u1") {
			t.Errorf("the step error carries the id or uid: %v", err)
		}
		if h.log.index("repo.DeleteQuotas") >= 0 {
			t.Error("the step went on past the failed public id delete")
		}
		if _, done, err := h.l.identityStep(context.Background(), p, &jobStats{}); err != nil || !done || len(h.repo.publicIDs) != 0 {
			t.Fatalf("retry: done=%v err=%v lookups=%v", done, err, h.repo.publicIDs)
		}
	})
	t.Run("an account that never got an id makes no call", func(t *testing.T) {
		h := newHarness(t)
		p := h.seedActive("u1", "Alice")
		if _, done, err := h.l.identityStep(context.Background(), p, &jobStats{}); err != nil || !done {
			t.Fatalf("identityStep = %v, %v", done, err)
		}
		if n := h.repo.calls["DeletePublicIDIfOwned"]; n != 0 {
			t.Errorf("DeletePublicIDIfOwned calls = %d, want 0 for an account without an id", n)
		}
	})
}

func TestProfileSection_PublicID(t *testing.T) {
	for _, tc := range []struct {
		name, id string
		want     string
	}{
		{"minted", lcPublicID, `"publicId":"` + lcPublicID + `"`},
		{"never minted", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw, err := json.Marshal(profileSection(Profile{UserID: "u1", Handle: "Alice", PublicID: tc.id, CreatedAt: time.Unix(0, 0)}))
			if err != nil {
				t.Fatal(err)
			}
			has := strings.Contains(string(raw), `"publicId"`)
			if tc.want == "" && has || tc.want != "" && !strings.Contains(string(raw), tc.want) {
				t.Errorf("profile section = %s, want publicId %q", raw, tc.id)
			}
		})
	}
}
