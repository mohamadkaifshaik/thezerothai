package identity

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"bytes"
	"log/slog"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// fakePrivacyRepo is the in-memory stand-in for FirestoreRepo.UpdateProfileWithPrivacy: the same decision table over the
// fakeRepo's profiles, a toggle counter and a set (D8). The transaction's reads and writes are asserted against the
// emulator in apiserver/privacy_toggle_integration_test.go.
type fakePrivacyRepo struct {
	*fakeRepo
	set     []string
	toggles int64
	calls   int
	err     error // injected transaction error
}

func (f *fakePrivacyRepo) UpdateProfileWithPrivacy(_ context.Context, uid string, mutate func(*Profile), lim PrivacyLimits) (PrivacyUpdate, error) {
	f.calls++
	if f.err != nil {
		return PrivacyUpdate{Attempts: 1}, f.err
	}
	p, ok := f.profiles[uid]
	if !ok {
		return PrivacyUpdate{Attempts: 1}, ErrNotFound
	}
	before := p
	mutate(&p)
	out := PrivacyUpdate{Profile: p, Attempts: 1}
	if p == before {
		return out, nil
	}
	if p.IsPrivate != before.IsPrivate {
		if f.toggles+1 > lim.TogglesPerDay {
			return PrivacyUpdate{Attempts: 1}, quota.ExceededError(quota.PrivacyToggles, time.Now())
		}
		if p.IsPrivate && !slices.Contains(f.set, uid) && len(f.set) >= lim.SetMax {
			return PrivacyUpdate{Attempts: 1}, ErrProtectedSetFull
		}
		f.toggles++
		if p.IsPrivate {
			if !slices.Contains(f.set, uid) {
				f.set = append(f.set, uid)
			}
			out.Toggle, out.SetUIDs = PrivacyOn, slices.Clone(f.set)
		} else {
			f.set = slices.DeleteFunc(f.set, func(s string) bool { return s == uid })
			out.Toggle = PrivacyOff
		}
	}
	f.profiles[uid] = p
	return out, nil
}

type fakePrivacyListener struct {
	calls []string
	err   error
}

func (f *fakePrivacyListener) BecamePublic(_ context.Context, uid string, _ time.Time) error {
	f.calls = append(f.calls, uid)
	return f.err
}

type privacyHarness struct {
	svc      *service
	repo     *fakePrivacyRepo
	set      *ProtectedSetLoader
	listener *fakePrivacyListener
	logs     *bytes.Buffer
}

func newPrivacyHarness(t *testing.T, reg ExtrasFlags, uid string, lim PrivacyLimits) *privacyHarness {
	t.Helper()
	h := &privacyHarness{repo: &fakePrivacyRepo{fakeRepo: newFakeRepo()}, listener: &fakePrivacyListener{}, logs: &bytes.Buffer{}}
	log := slog.New(slog.NewJSONHandler(h.logs, nil))
	h.set = NewProtectedSetLoader(&fakeSetSource{}, time.Minute, 10*time.Minute, nil, log)
	opts := []Option{WithPrivacy(PrivacyDeps{Repo: h.repo, Set: h.set, Limits: lim}), WithPrivacyListener(h.listener, log)}
	if reg != nil {
		opts = append(opts, WithExtrasFlags(reg))
	}
	h.svc = New(h.repo.fakeRepo, NewCache(time.Minute), 7*24*time.Hour, opts...).(*service)
	if _, err := h.svc.CreateProfile(context.Background(), uid, validKey, "Alice", "Alice A."); err != nil {
		t.Fatal(err)
	}
	return h
}

func (h *privacyHarness) update(uid string, isPrivate bool, name *string) (Profile, error) {
	return h.svc.UpdateProfile(context.Background(), uid, UpdateProfileParams{IdempotencyKey: validKey, IsPrivate: &isPrivate, DisplayName: name})
}

func TestUpdateProfile_PrivacyToggleMatrix(t *testing.T) {
	const uid = "uid-1"
	lim := PrivacyLimits{TogglesPerDay: 4, SetMax: 20000}
	on := privateRegistry(flags.On, 0)

	t.Run("protect then equal value", func(t *testing.T) {
		h := newPrivacyHarness(t, on, uid, lim)
		p, err := h.update(uid, true, nil)
		if err != nil || !p.IsPrivate {
			t.Fatalf("protect = %v, %v", p.IsPrivate, err)
		}
		if !slices.Equal(h.repo.set, []string{uid}) || h.repo.toggles != 1 {
			t.Fatalf("set=%v toggles=%d, want [uid] / 1", h.repo.set, h.repo.toggles)
		}
		// The committing instance sees its own change at once, without a read.
		cur, err := h.set.Current(context.Background())
		if err != nil || !cur.Has(uid) {
			t.Fatalf("loader after protect: %v, %v", cur, err)
		}
		if len(h.listener.calls) != 0 {
			t.Errorf("BecamePublic called on a protect: %v", h.listener.calls)
		}
		// Equal value: no toggle, no listener, cache untouched.
		if _, err := h.update(uid, true, nil); err != nil {
			t.Fatal(err)
		}
		if h.repo.toggles != 1 || len(h.listener.calls) != 0 {
			t.Errorf("equal value: toggles=%d listener=%v, want 1 / none", h.repo.toggles, h.listener.calls)
		}
	})

	t.Run("unprotect calls BecamePublic once and updates the loader", func(t *testing.T) {
		h := newPrivacyHarness(t, on, uid, lim)
		if _, err := h.update(uid, true, nil); err != nil {
			t.Fatal(err)
		}
		p, err := h.update(uid, false, nil)
		if err != nil || p.IsPrivate {
			t.Fatalf("unprotect = %v, %v", p.IsPrivate, err)
		}
		if !slices.Equal(h.listener.calls, []string{uid}) {
			t.Errorf("BecamePublic calls = %v, want [uid]", h.listener.calls)
		}
		cur, _ := h.set.Current(context.Background())
		if cur.Has(uid) || len(h.repo.set) != 0 {
			t.Errorf("after unprotect: loader has=%v set=%v", cur.Has(uid), h.repo.set)
		}
	})

	t.Run("unprotect accepted with the flag off and outside the cohort", func(t *testing.T) {
		for name, reg := range map[string]ExtrasFlags{"off": privateRegistry(flags.Off, 0), "allowlist elsewhere": privateRegistry(flags.Allowlist, 0, "other"), "no flags": nil} {
			h := newPrivacyHarness(t, reg, uid, lim)
			p := h.repo.profiles[uid]
			p.IsPrivate = true // protected earlier, while the flag was on
			h.repo.profiles[uid] = p
			h.repo.set, h.repo.toggles = []string{uid}, 1
			if _, err := h.update(uid, false, nil); err != nil {
				t.Errorf("%s: unprotect refused: %v", name, err)
			}
			if len(h.listener.calls) != 1 {
				t.Errorf("%s: BecamePublic calls = %v", name, h.listener.calls)
			}
		}
	})

	t.Run("protect refused by the flag before any repo call", func(t *testing.T) {
		for name, reg := range map[string]ExtrasFlags{"off": privateRegistry(flags.Off, 0), "allowlist elsewhere": privateRegistry(flags.Allowlist, 0, "other"), "no flags": nil} {
			h := newPrivacyHarness(t, reg, uid, lim)
			_, err := h.update(uid, true, nil)
			_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "private_accounts")
			if h.repo.calls != 0 {
				t.Errorf("%s: the repo was reached (%d calls)", name, h.repo.calls)
			}
		}
		name := "Renamed"
		h := newPrivacyHarness(t, privateRegistry(flags.Off, 0), uid, lim)
		_, err := h.update(uid, true, &name) // the W3-22 M-1 mixed rule: refused whole
		_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "private_accounts")
		if h.repo.profiles[uid].DisplayName == "Renamed" {
			t.Error("the mixed request partly applied")
		}
	})

	t.Run("flag modes that admit the caller", func(t *testing.T) {
		for name, reg := range map[string]ExtrasFlags{
			"allowlist": privateRegistry(flags.Allowlist, 0, uid), "percent 100": privateRegistry(flags.Percent, 100), "on": on,
		} {
			h := newPrivacyHarness(t, reg, uid, lim)
			if p, err := h.update(uid, true, nil); err != nil || !p.IsPrivate {
				t.Errorf("%s: protect = %v, %v", name, p.IsPrivate, err)
			}
		}
	})

	t.Run("fifth toggle of the day is QUOTA_EXCEEDED", func(t *testing.T) {
		h := newPrivacyHarness(t, on, uid, lim)
		for i := 0; i < 4; i++ {
			if _, err := h.update(uid, i%2 == 0, nil); err != nil {
				t.Fatalf("toggle %d: %v", i+1, err)
			}
		}
		_, err := h.update(uid, true, nil)
		_ = wantAPIErr(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED, "quota", "privacy_toggles")
		if h.repo.profiles[uid].IsPrivate {
			t.Error("the refused toggle changed the profile")
		}
	})

	t.Run("cap is LIMIT_REACHED limit=private_accounts", func(t *testing.T) {
		h := newPrivacyHarness(t, on, uid, PrivacyLimits{TogglesPerDay: 4, SetMax: 2})
		h.repo.set = []string{"x", "y"}
		_, err := h.update(uid, true, nil)
		_ = wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit", "private_accounts")
		if h.repo.profiles[uid].IsPrivate || len(h.repo.set) != 2 {
			t.Error("a capped protect changed state")
		}
	})

	t.Run("a failed hand-over is ERROR and never fails the toggle", func(t *testing.T) {
		h := newPrivacyHarness(t, on, uid, lim)
		if _, err := h.update(uid, true, nil); err != nil {
			t.Fatal(err)
		}
		h.listener.err = errors.New("pubsub down")
		if _, err := h.update(uid, false, nil); err != nil {
			t.Fatalf("unprotect failed because the hand-over failed: %v", err)
		}
		if !strings.Contains(h.logs.String(), "privacy_public_enqueue_failed") || strings.Contains(h.logs.String(), uid) {
			t.Errorf("log = %s; want ERROR privacy_public_enqueue_failed without the uid", h.logs.String())
		}
	})

	t.Run("no listener publishes nothing", func(t *testing.T) {
		h := newPrivacyHarness(t, on, uid, lim)
		h.svc.listener = nil
		if _, err := h.update(uid, true, nil); err != nil {
			t.Fatal(err)
		}
		if _, err := h.update(uid, false, nil); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("a toggle bumps no snapshotVersion", func(t *testing.T) {
		h := newPrivacyHarness(t, on, uid, lim)
		before := h.repo.profiles[uid].SnapshotVersion
		if _, err := h.update(uid, true, nil); err != nil {
			t.Fatal(err)
		}
		if got := h.repo.profiles[uid].SnapshotVersion; got != before {
			t.Errorf("snapshotVersion %d -> %d", before, got)
		}
	})

	t.Run("without the privacy wiring protect stays refused", func(t *testing.T) {
		repo := newFakeRepo()
		svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithExtrasFlags(on))
		if _, err := svc.CreateProfile(context.Background(), uid, validKey, "Alice", "Alice A."); err != nil {
			t.Fatal(err)
		}
		yes := true
		_, err := svc.UpdateProfile(context.Background(), uid, UpdateProfileParams{IdempotencyKey: validKey, IsPrivate: &yes})
		_ = wantValidation(t, err, "is_private")
	})
}
