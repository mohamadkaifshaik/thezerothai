package posts

import (
	"context"
	"errors"
	"testing"
)

// The method identity's consumer-side PinChecker needs (ADR-0024 D3, identity/api.go): *PinChecker must satisfy it
// without an adapter, so apiserver can pass it straight to identity.WithPinChecker.
var _ interface {
	CanPin(ctx context.Context, uid, postID string) (bool, error)
} = (*PinChecker)(nil)

func TestPinChecker_CanPin(t *testing.T) {
	t.Parallel()
	const me, other = "uid-me", "uid-other"
	mk := func(id string, author string, kind Kind, mod Moderation) *Post {
		p := post(id, author)
		p.Kind, p.Moderation = kind, mod
		return p
	}
	tests := []struct {
		name   string
		post   *Post // nil: the post does not exist
		postID string
		uid    string
		want   bool
	}{
		{"own POST", mk("0000000000000000001", me, KindPost, ModerationNone), "0000000000000000001", me, true},
		{"own QUOTE", mk("0000000000000000002", me, KindQuote, ModerationNone), "0000000000000000002", me, true},
		{"own REPLY", mk("0000000000000000003", me, KindReply, ModerationNone), "0000000000000000003", me, true},
		{"own REPOST", mk("0000000000000000004", me, KindRepost, ModerationNone), "0000000000000000004", me, false},
		{"unknown kind is refused (allowlist)", mk("0000000000000000005", me, Kind("POLL"), ModerationNone), "0000000000000000005", me, false},
		{"another user's POST", mk("0000000000000000006", other, KindPost, ModerationNone), "0000000000000000006", me, false},
		{"taken down", mk("0000000000000000007", me, KindPost, ModerationTakenDown), "0000000000000000007", me, false},
		{"author suspended (hidden)", mk("0000000000000000008", me, KindPost, ModerationSuspendedAuthor), "0000000000000000008", me, false},
		{"missing or deleted", nil, "0000000000000000009", me, false},
		{"empty post id", nil, "", me, false},
		{"id with a path separator", nil, "a/b", me, false},
		{"empty caller", mk("0000000000000000010", "", KindPost, ModerationNone), "0000000000000000010", "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			if tt.post != nil {
				repo.docs[tt.post.ID] = tt.post
			}
			svc, _ := newSvc(repo)
			got, err := NewPinChecker(svc).CanPin(context.Background(), tt.uid, tt.postID)
			if err != nil {
				t.Fatalf("CanPin returned an error for a plain refusal: %v (every no must be (false, nil))", err)
			}
			if got != tt.want {
				t.Fatalf("CanPin = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestPinChecker_ReadsAndErrors: 1 read cold and 0 warm (the Reader's cache), and an infrastructure failure is an
// error, never the "no" answer.
func TestPinChecker_ReadsAndErrors(t *testing.T) {
	t.Parallel()
	p := post("0000000000000000001", "uid-me")
	repo := newFakeRepo(p)
	svc, _ := newSvc(repo)
	pc := NewPinChecker(svc)
	for i, want := range []int64{1, 0} {
		var ok bool
		var err error
		if r := reads(t, func(ctx context.Context) { ok, err = pc.CanPin(ctx, "uid-me", p.ID) }); err != nil || !ok || r != want {
			t.Fatalf("call %d: ok=%v err=%v reads=%d, want true, nil and %d", i, ok, err, r, want)
		}
	}

	failing := newFakeRepo(p)
	failing.getAllErr = errBoom
	svc2, _ := newSvc(failing)
	ok, err := NewPinChecker(svc2).CanPin(context.Background(), "uid-me", p.ID)
	if ok || !errors.Is(err, errBoom) {
		t.Fatalf("a read failure = (%v, %v), want (false, the wrapped infrastructure error)", ok, err)
	}
}
