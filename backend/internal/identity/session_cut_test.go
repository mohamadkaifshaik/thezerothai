package identity

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// EndSessionsBefore mirrors FirestoreRepo: one "transaction" that keeps max(existing, t) and writes only when it moves.
func (f *fakeRepo) EndSessionsBefore(_ context.Context, uid string, t time.Time) (Profile, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cutCalls++
	if f.cutErr != nil {
		return Profile{}, false, f.cutErr
	}
	p, ok := f.profiles[uid]
	if !ok {
		return Profile{}, false, ErrNotFound
	}
	if !t.After(p.SessionsValidAfter) {
		return p, false, nil
	}
	p.SessionsValidAfter = t
	f.profiles[uid] = p
	f.cutWrites++
	return p, true, nil
}

var (
	cutT0 = time.Date(2026, 11, 23, 9, 0, 0, 0, time.UTC)
	cutT1 = cutT0.Add(time.Hour)
	cutT2 = cutT0.Add(2 * time.Hour)
)

// TestEndSessionsBefore_KeepsTheMaximum: the stored cut only moves forward; an earlier or equal time writes nothing
// (idempotent), a later one moves it.
func TestEndSessionsBefore_KeepsTheMaximum(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	repo.profiles["u1"] = Profile{UserID: "u1", Status: AccountStatusActive}
	s := newTestService(repo)

	steps := []struct {
		at        time.Time
		want      time.Time
		wantWrite int
	}{
		{cutT1, cutT1, 1},
		{cutT1, cutT1, 1}, // the same time again: idempotent, no write
		{cutT0, cutT1, 1}, // earlier: kept
		{cutT2, cutT2, 2}, // later: moved
	}
	for i, st := range steps {
		if err := s.EndSessionsBefore(ctx, "u1", st.at); err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
		if got := repo.profiles["u1"].SessionsValidAfter; !got.Equal(st.want) {
			t.Errorf("step %d: stored cut = %v, want %v", i, got, st.want)
		}
		if repo.cutWrites != st.wantWrite {
			t.Errorf("step %d: writes = %d, want %d", i, repo.cutWrites, st.wantWrite)
		}
	}
}

// TestEndSessionsBefore_InvalidatesTheCache: after a cut this instance answers the new cut at once, not the cached
// profile of up to 60 s ago.
func TestEndSessionsBefore_InvalidatesTheCache(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	repo.profiles["u1"] = Profile{UserID: "u1", Status: AccountStatusActive}
	s := newTestService(repo)

	got, err := s.SessionsValidAfter(ctx, "u1")
	if err != nil || !got.IsZero() {
		t.Fatalf("before the cut = %v, %v; want zero, nil", got, err)
	}
	reads := repo.getProfileCalls
	if _, err := s.SessionsValidAfter(ctx, "u1"); err != nil || repo.getProfileCalls != reads {
		t.Fatalf("second lookup read again (%d -> %d), want the cached profile: %v", reads, repo.getProfileCalls, err)
	}
	if err := s.EndSessionsBefore(ctx, "u1", cutT1); err != nil {
		t.Fatal(err)
	}
	got, err = s.SessionsValidAfter(ctx, "u1")
	if err != nil || !got.Equal(cutT1) {
		t.Errorf("after the cut = %v, %v; want %v (the cache entry must be dropped)", got, err, cutT1)
	}
}

// TestSessionsValidAfter_NoProfileIsNoCut: a uid without a profile has no cut (and the negative cache answers the next
// lookup without a read); a repository failure is an error, never "no cut".
func TestSessionsValidAfter_NoProfileIsNoCut(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	s := newTestService(repo)
	for i := range 2 {
		got, err := s.SessionsValidAfter(ctx, "nobody")
		if err != nil || !got.IsZero() {
			t.Fatalf("call %d = %v, %v; want zero, nil", i, got, err)
		}
	}
	if repo.getProfileCalls != 1 {
		t.Errorf("reads = %d, want 1 (the negative cache answers the second)", repo.getProfileCalls)
	}

	failing := &failingProfileRepo{fakeRepo: newFakeRepo()}
	s = newTestService(failing)
	if _, err := s.SessionsValidAfter(ctx, "u-err"); err == nil {
		t.Fatal("a failed read must be an error")
	} else if strings.Contains(err.Error(), "u-err") {
		t.Errorf("the error names the uid: %v", err)
	}
}

type failingProfileRepo struct{ *fakeRepo }

func (failingProfileRepo) GetProfile(context.Context, string) (Profile, error) {
	return Profile{}, errors.New("firestore unavailable")
}

// TestEndSessionsBefore_Errors: a missing profile is success with nothing written (no session can pass account status
// without one); a zero time is refused before any read; a repository failure is returned without the uid.
func TestEndSessionsBefore_Errors(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	s := newTestService(repo)
	if err := s.EndSessionsBefore(ctx, "gone", cutT1); err != nil {
		t.Errorf("missing profile = %v, want nil", err)
	}
	if repo.cutWrites != 0 {
		t.Errorf("writes = %d, want 0", repo.cutWrites)
	}
	calls := repo.cutCalls
	if err := s.EndSessionsBefore(ctx, "u1", time.Time{}); err == nil {
		t.Error("a zero cut must be refused")
	}
	if repo.cutCalls != calls {
		t.Error("a zero cut reached the repository")
	}
	repo.cutErr = errors.New("contention on u-fail")
	err := s.EndSessionsBefore(ctx, "u-fail", cutT1)
	if err == nil {
		t.Fatal("a repository failure must be an error")
	}
	if strings.Contains(err.Error(), "u-fail") {
		t.Errorf("the error names the uid: %v", err)
	}
}

// TestProfileDoc_SessionsValidAfterRoundTrips: the field survives a whole-document rewrite (UpdateProfile, ChangeHandle,
// the privacy toggle all write profileToDoc), and an account without a cut stores no field.
func TestProfileDoc_SessionsValidAfterRoundTrips(t *testing.T) {
	p := Profile{UserID: "u1", Handle: "a", SessionsValidAfter: cutT1}
	d := profileToDoc(p)
	if d.SessionsValidAfter == nil || !d.SessionsValidAfter.Equal(cutT1) {
		t.Fatalf("doc field = %v, want %v", d.SessionsValidAfter, cutT1)
	}
	if back := d.toProfile("u1"); !back.SessionsValidAfter.Equal(cutT1) {
		t.Errorf("round trip = %v, want %v", back.SessionsValidAfter, cutT1)
	}
	if d := profileToDoc(Profile{UserID: "u1"}); d.SessionsValidAfter != nil {
		t.Errorf("no cut must store no field, got %v", d.SessionsValidAfter)
	}
}

// TestProfileSection_SessionsValidAfter: the export's profile section carries the account's cut (the user's own data),
// and omits it when there is none.
func TestProfileSection_SessionsValidAfter(t *testing.T) {
	raw, err := json.Marshal(profileSection(Profile{UserID: "u1", SessionsValidAfter: cutT1.In(time.FixedZone("IST", 19800))}))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"sessionsValidAfter":"2026-11-23T10:00:00Z"`) {
		t.Errorf("section = %s, want sessionsValidAfter in UTC", raw)
	}
	raw, err = json.Marshal(profileSection(Profile{UserID: "u1"}))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "sessionsValidAfter") {
		t.Errorf("section = %s, want no sessionsValidAfter without a cut", raw)
	}
}
