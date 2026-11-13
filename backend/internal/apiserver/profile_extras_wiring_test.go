package apiserver

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// wiring: the avatar adapter over media.Reader, the late-bound pin checker and the post_delete chain's
// identity step. The whole stack over the emulators is covered by profile_extras_integration_test.go.

type fakeMediaReader struct {
	ref   media.Ref
	err   error
	calls []string
}

func (f *fakeMediaReader) ResolveAvatar(_ context.Context, uid, mediaID string) (media.Ref, error) {
	f.calls = append(f.calls, uid+"/"+mediaID)
	return f.ref, f.err
}

func TestAvatarResolver(t *testing.T) {
	mediaOn := flags.NewRegistry(flags.Spec{Name: media.FlagName, Mode: flags.On})
	mediaOff := flags.NewRegistry(flags.Spec{Name: media.FlagName, Mode: flags.Off})
	mediaListed := flags.NewRegistry(flags.Spec{Name: media.FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}})
	boom := errors.New("firestore down")
	tests := []struct {
		name      string
		reg       *flags.Registry
		lib       *fakeMediaReader
		want      identity.AvatarRef
		wantErr   error
		wantCalls int
	}{
		{"ready avatar maps URL and thumbnail", mediaOn, &fakeMediaReader{ref: media.Ref{URL: "https://m/a.webp", ThumbURL: "https://m/a_t.webp", Width: 400, Height: 400}},
			identity.AvatarRef{URL: "https://m/a.webp", ThumbURL: "https://m/a_t.webp"}, nil, 1},
		{"not ready is ErrAvatarNotReady", mediaOn, &fakeMediaReader{err: media.ErrNotReady}, identity.AvatarRef{}, identity.ErrAvatarNotReady, 1},
		{"a wrapped not-ready is ErrAvatarNotReady", mediaOn, &fakeMediaReader{err: fmt.Errorf("resolve: %w", media.ErrNotReady)}, identity.AvatarRef{}, identity.ErrAvatarNotReady, 1},
		{"FEATURE_MEDIA off is the same answer and reads nothing", mediaOff, &fakeMediaReader{ref: media.Ref{URL: "https://m/a.webp"}}, identity.AvatarRef{}, identity.ErrAvatarNotReady, 0},
		{"FEATURE_MEDIA off for this caller reads nothing", mediaListed, &fakeMediaReader{ref: media.Ref{URL: "https://m/a.webp"}}, identity.AvatarRef{}, identity.ErrAvatarNotReady, 0},
		{"a real failure is not collapsed into not ready", mediaOn, &fakeMediaReader{err: boom}, identity.AvatarRef{}, boom, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := avatarResolver{lib: tt.lib, flags: tt.reg}.ResolveAvatar(context.Background(), "uid-1", "0000000000000000202")
			if !errors.Is(err, tt.wantErr) || (tt.wantErr == nil && err != nil) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if errors.Is(err, identity.ErrAvatarNotReady) && tt.wantErr != identity.ErrAvatarNotReady {
				t.Fatalf("err = %v: an infrastructure failure became not-ready", err)
			}
			if got != tt.want {
				t.Fatalf("ref = %+v, want %+v", got, tt.want)
			}
			if len(tt.lib.calls) != tt.wantCalls {
				t.Fatalf("media reads = %v", tt.lib.calls)
			}
			if tt.wantCalls == 1 && tt.lib.calls[0] != "uid-1/0000000000000000202" {
				t.Fatalf("asked %q", tt.lib.calls[0])
			}
		})
	}
}

type fakePinChecker struct {
	can bool
	err error
}

func (f fakePinChecker) CanPin(context.Context, string, string) (bool, error) { return f.can, f.err }

func TestLatePinChecker(t *testing.T) {
	t.Run("unwired fails closed with an error, never a verdict", func(t *testing.T) {
		ok, err := (&latePinChecker{}).CanPin(context.Background(), "uid-1", "0000000000000000301")
		if ok || err == nil {
			t.Fatalf("CanPin = %v, %v", ok, err)
		}
	})
	t.Run("delegates once bound", func(t *testing.T) {
		l := &latePinChecker{}
		l.c = fakePinChecker{can: true}
		if ok, err := l.CanPin(context.Background(), "uid-1", "0000000000000000301"); !ok || err != nil {
			t.Fatalf("CanPin = %v, %v", ok, err)
		}
		l.c = fakePinChecker{err: errors.New("boom")}
		if ok, err := l.CanPin(context.Background(), "uid-1", "0000000000000000301"); ok || err == nil {
			t.Fatalf("CanPin = %v, %v", ok, err)
		}
	})
}

type stepFake struct {
	out string
	err error
	n   int
}

func (s *stepFake) Handle(context.Context, []byte) (string, error) { s.n++; return s.out, s.err }

func TestPostDeleteChain_IdentityPinStep(t *testing.T) {
	tests := []struct {
		name    string
		media   stepFake
		eng     stepFake
		pins    stepFake
		want    string
		wantErr string
	}{
		{"no images, nothing pinned: the engagement outcome alone, as before", stepFake{out: "noop"}, stepFake{out: "done"}, stepFake{out: "noop"}, "done", ""},
		{"images and likes, nothing pinned: media+eng, as before", stepFake{out: "deleted"}, stepFake{out: "done"}, stepFake{out: "noop"}, "deleted+done", ""},
		{"a cleared pin is appended", stepFake{out: "noop"}, stepFake{out: "done"}, stepFake{out: "pin_cleared"}, "done+pin_cleared", ""},
		{"all three report", stepFake{out: "deleted"}, stepFake{out: "done"}, stepFake{out: "pin_cleared"}, "deleted+done+pin_cleared", ""},
		{"a refused pin step repeats the others and adds nothing", stepFake{out: "refused"}, stepFake{out: "refused"}, stepFake{out: "refused"}, "refused+refused", ""},
		{"the pin step failing nacks, the others still ran", stepFake{out: "noop"}, stepFake{out: "done"}, stepFake{err: errors.New("pin step failed")}, "", "pin step failed"},
		{"media failing nacks, the pin step still ran", stepFake{err: errors.New("media failed")}, stepFake{out: "done"}, stepFake{out: "pin_cleared"}, "", "media failed"},
		{"all three failing joins every error", stepFake{err: errors.New("m")}, stepFake{err: errors.New("e")}, stepFake{err: errors.New("p")}, "", "m\ne\np"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			media, eng, pins := tt.media, tt.eng, tt.pins
			out, err := postDeleteChain{media: &media, eng: &eng, pins: &pins}.Handle(context.Background(), []byte(`{}`))
			if media.n != 1 || eng.n != 1 || pins.n != 1 {
				t.Fatalf("every step must run exactly once: media=%d eng=%d pins=%d", media.n, eng.n, pins.n)
			}
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want it to contain %q", err, tt.wantErr)
				}
				return
			}
			if err != nil || out != tt.want {
				t.Fatalf("outcome = %q, %v; want %q", out, err, tt.want)
			}
		})
	}
}

// TestPostDeleteChain_ArticlesStep: the articles step runs on every message; only a deleted article is appended to the
// outcome, and its failure nacks while the other steps still ran.
func TestPostDeleteChain_ArticlesStep(t *testing.T) {
	tests := []struct {
		name     string
		articles stepFake
		want     string
		wantErr  string
	}{
		{"no article rooted at the post adds nothing", stepFake{out: "noop"}, "done", ""},
		{"a refused articles step adds nothing", stepFake{out: "refused"}, "done", ""},
		{"a deleted article is appended", stepFake{out: "article_deleted"}, "done+article_deleted", ""},
		{"the articles step failing nacks", stepFake{err: errors.New("articles failed")}, "", "articles failed"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			media, eng, pins, art := stepFake{out: "noop"}, stepFake{out: "done"}, stepFake{out: "noop"}, tt.articles
			out, err := postDeleteChain{media: &media, eng: &eng, pins: &pins, articles: &art}.Handle(context.Background(), []byte(`{}`))
			if media.n != 1 || eng.n != 1 || pins.n != 1 || art.n != 1 {
				t.Fatalf("every step must run exactly once: media=%d eng=%d pins=%d articles=%d", media.n, eng.n, pins.n, art.n)
			}
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want it to contain %q", err, tt.wantErr)
				}
				return
			}
			if err != nil || out != tt.want {
				t.Fatalf("outcome = %q, %v; want %q", out, err, tt.want)
			}
		})
	}
}
