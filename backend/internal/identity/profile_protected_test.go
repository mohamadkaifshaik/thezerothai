package identity

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// W3-26b: the pin rule of GetProfile (ADR-0025 D4, AQ6) and GetMe's pending_follow_request_count (D7, AQ3).

type fakeProtectedAuthors struct {
	set   ProtectedSet
	err   error
	calls int
}

func (f *fakeProtectedAuthors) Current(context.Context) (ProtectedSet, error) {
	f.calls++
	return f.set, f.err
}

type fakeCounter struct {
	n     int64
	err   error
	calls int
}

func (f *fakeCounter) PendingFollowRequests(context.Context, string) (int64, error) {
	f.calls++
	return f.n, f.err
}

const pinnedID = "0000000000000000101"

func seedPinned(repo *fakeRepo, uid string, private bool) {
	repo.profiles[uid] = Profile{UserID: uid, Handle: uid, HandleLower: uid, Status: AccountStatusActive, PinnedPostID: pinnedID, IsPrivate: private}
}

func TestGetProfile_PinRule(t *testing.T) {
	t.Parallel()
	protected := newProtectedSet([]string{"p"})
	tests := []struct {
		name      string
		viewer    string
		target    string
		following bool
		followErr error
		setErr    error
		wantPin   bool
		wantSet   int // Current calls
	}{
		{name: "stranger of a protected account has no pin", viewer: "a", target: "p", wantPin: false, wantSet: 1},
		{name: "follower keeps the pin without the set", viewer: "a", target: "p", following: true, wantPin: true, wantSet: 0},
		{name: "owner keeps the pin without the set", viewer: "p", target: "p", wantPin: true, wantSet: 0},
		{name: "stranger of a public account keeps the pin", viewer: "a", target: "q", wantPin: true, wantSet: 1},
		{name: "set unavailable: stranger fails closed", viewer: "a", target: "p", setErr: ErrProtectedSetUnavailable, wantPin: false, wantSet: 1},
		{name: "set unavailable: follower keeps the pin", viewer: "a", target: "p", following: true, setErr: ErrProtectedSetUnavailable, wantPin: true, wantSet: 0},
		{name: "set unavailable: owner keeps the pin", viewer: "p", target: "p", setErr: ErrProtectedSetUnavailable, wantPin: true, wantSet: 0},
		{name: "follow check failure fails closed", viewer: "a", target: "p", followErr: errors.New("boom"), wantPin: false, wantSet: 0},
		{name: "anonymous viewer of a protected account", viewer: "", target: "p", wantPin: false, wantSet: 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			seedPinned(repo, "p", true)
			seedPinned(repo, "q", false)
			bc := &fakeBlockChecker{following: map[string]map[string]bool{"a": {tt.target: tt.following}}, followErr: tt.followErr}
			pa := &fakeProtectedAuthors{set: protected, err: tt.setErr}
			svc := New(repo, NewCache(time.Minute), time.Hour, WithBlockChecker(bc), WithProtectedAuthors(pa, nil), WithExtrasFlags(&flipFlags{})).(*service)
			got, err := svc.GetProfile(context.Background(), tt.viewer, ProfileTarget{UserID: tt.target})
			if err != nil {
				t.Fatalf("GetProfile: %v", err)
			}
			if got.UserID != tt.target || got.Handle != tt.target {
				t.Errorf("header not returned: %+v", got)
			}
			if (got.PinnedPostID != "") != tt.wantPin {
				t.Errorf("pin = %q, want present=%v", got.PinnedPostID, tt.wantPin)
			}
			if pa.calls != tt.wantSet {
				t.Errorf("set loads = %d, want %d", pa.calls, tt.wantSet)
			}
			if repo.profiles[tt.target].PinnedPostID != pinnedID {
				t.Error("the stored profile must keep the pin")
			}
		})
	}
}

// Without the loader wired the pin is returned as before (W3-25b behaviour), and a profile without a pin never asks.
func TestGetProfile_PinRuleUnwiredOrNoPin(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	seedPinned(repo, "p", true)
	repo.profiles["n"] = Profile{UserID: "n", Handle: "n", HandleLower: "n", Status: AccountStatusActive}
	ctx := context.Background()
	svc := New(repo, NewCache(time.Minute), time.Hour, WithExtrasFlags(&flipFlags{})).(*service)
	if got, _ := svc.GetProfile(ctx, "a", ProfileTarget{UserID: "p"}); got.PinnedPostID != pinnedID {
		t.Errorf("unwired: pin = %q", got.PinnedPostID)
	}
	pa := &fakeProtectedAuthors{set: newProtectedSet([]string{"n"})}
	svc = New(repo, NewCache(time.Minute), time.Hour, WithProtectedAuthors(pa, nil), WithExtrasFlags(&flipFlags{})).(*service)
	if got, _ := svc.GetProfile(ctx, "a", ProfileTarget{UserID: "n"}); got.PinnedPostID != "" || pa.calls != 0 {
		t.Errorf("no pin: got %q, set loads %d", got.PinnedPostID, pa.calls)
	}
	// No block checker: nobody is a follower, so a protected account's pin is hidden from a stranger.
	svc = New(repo, NewCache(time.Minute), time.Hour, WithProtectedAuthors(&fakeProtectedAuthors{set: newProtectedSet([]string{"p"})}, nil), WithExtrasFlags(&flipFlags{})).(*service)
	if got, _ := svc.GetProfile(ctx, "a", ProfileTarget{UserID: "p"}); got.PinnedPostID != "" {
		t.Errorf("no checker: pin = %q", got.PinnedPostID)
	}
}

func TestGetMe_PendingFollowRequestCount(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		private   bool
		counter   *fakeCounter
		wired     bool
		want      int64
		wantCalls int
	}{
		{name: "protected caller", private: true, counter: &fakeCounter{n: 3}, wired: true, want: 3, wantCalls: 1},
		{name: "public caller never counts", private: false, counter: &fakeCounter{n: 3}, wired: true, want: 0, wantCalls: 0},
		{name: "count failure leaves the badge at 0", private: true, counter: &fakeCounter{err: errors.New("down")}, wired: true, want: 0, wantCalls: 1},
		{name: "no counter wired", private: true, counter: &fakeCounter{n: 3}, wired: false, want: 0, wantCalls: 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			repo.profiles["p"] = Profile{UserID: "p", Handle: "p", HandleLower: "p", Status: AccountStatusActive, IsPrivate: tt.private}
			opts := []Option{}
			if tt.wired {
				opts = append(opts, WithFollowRequestCounter(tt.counter, nil))
			}
			svc := New(repo, NewCache(time.Minute), time.Hour, opts...).(*service)
			got, err := svc.GetMe(context.Background(), "p")
			if err != nil {
				t.Fatalf("GetMe: %v", err)
			}
			if got.PendingFollowRequestCount != tt.want {
				t.Errorf("count = %d, want %d", got.PendingFollowRequestCount, tt.want)
			}
			if tt.counter.calls != tt.wantCalls {
				t.Errorf("counter calls = %d, want %d", tt.counter.calls, tt.wantCalls)
			}
		})
	}
}

// The count is cached 30 s; Forget and ForgetUnread (an accept, a follow_request notification) evict it; a failure is retried.
func TestGetMe_PendingCountCache(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.profiles["p"] = Profile{UserID: "p", Handle: "p", HandleLower: "p", Status: AccountStatusActive, IsPrivate: true}
	ctr := &fakeCounter{n: 3}
	svc := New(repo, NewCache(time.Minute), time.Hour, WithFollowRequestCounter(ctr, nil)).(*service)
	ctx := context.Background()
	get := func() int64 {
		t.Helper()
		r, err := svc.GetMe(ctx, "p")
		if err != nil {
			t.Fatal(err)
		}
		return r.PendingFollowRequestCount
	}
	first, second := get(), get()
	if first != 3 || second != 3 || ctr.calls != 1 {
		t.Fatalf("second GetMe within 30 s must hit the cache: calls = %d", ctr.calls)
	}
	ctr.n = 2
	if get() != 3 {
		t.Error("stale within the cache window is allowed")
	}
	svc.Forget("p")
	if get() != 2 || ctr.calls != 2 {
		t.Errorf("Forget must evict the count: calls = %d", ctr.calls)
	}
	ctr.n = 5
	svc.ForgetUnread("p")
	if get() != 5 || ctr.calls != 3 {
		t.Errorf("ForgetUnread must evict the count: calls = %d", ctr.calls)
	}
	ctr.err = errors.New("down")
	svc.Forget("p")
	if get() != 0 {
		t.Error("failure must answer 0")
	}
	ctr.err = nil
	if get() != 5 {
		t.Error("a failure is not cached")
	}
}

// The WARN lines carry the reason and a hashed uid, never the uid itself, and go to the injected logger.
func TestPinAndCountWarnLines(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	repo := newFakeRepo()
	seedPinned(repo, "p", true)
	bc := &fakeBlockChecker{followErr: errors.New("boom")}
	svc := New(repo, NewCache(time.Minute), time.Hour, WithBlockChecker(bc), WithExtrasFlags(&flipFlags{}),
		WithProtectedAuthors(&fakeProtectedAuthors{set: newProtectedSet([]string{"p"})}, log),
		WithFollowRequestCounter(&fakeCounter{err: errors.New("down")}, log)).(*service)
	ctx := context.Background()
	if got, err := svc.GetProfile(ctx, "viewer-uid", ProfileTarget{UserID: "p"}); err != nil || got.PinnedPostID != "" {
		t.Fatalf("GetProfile = %+v, %v, want the header without the pin", got, err)
	}
	if me, err := svc.GetMe(ctx, "p"); err != nil || me.PendingFollowRequestCount != 0 {
		t.Fatalf("GetMe = %+v, %v, want 0 and no error", me, err)
	}
	out := buf.String()
	for _, want := range []string{`"msg":"pin_omitted"`, `"pin_omitted":"follow_check_failed"`, `"msg":"pending_count_failed"`, `"level":"WARN"`} {
		if !strings.Contains(out, want) {
			t.Errorf("log lacks %s:\n%s", want, out)
		}
	}
	if strings.Contains(out, "viewer-uid") {
		t.Errorf("a raw uid was logged:\n%s", out)
	}
}
