package posts

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
)

func TestLongPostTierLimitsAndReplay(t *testing.T) {
	for _, limit := range []int{280, 3000, 15000} {
		e := newCreateEnv()
		e.svc.postTextLimit = func(context.Context, string) (int, error) { return limit, nil }
		in := CreateInput{IdempotencyKey: key1, Text: strings.Repeat("\U0001F600", limit)}
		p, err := e.create(in)
		if err != nil || p.Text != in.Text {
			t.Fatalf("limit %d: %v", limit, err)
		}
		e.svc.postTextLimit = func(context.Context, string) (int, error) { return 280, nil }
		replay, err := e.create(in)
		if err != nil || replay.ID != p.ID {
			t.Fatalf("replay after downgrade: %v", err)
		}
		e.svc.postTextLimit = func(context.Context, string) (int, error) { return limit, nil }
		in.IdempotencyKey = key2
		in.Text += "x"
		if _, err = e.create(in); err == nil {
			t.Fatalf("accepted %d+1", limit)
		}
	}
}
func TestLongPostVerificationFailureWritesNothing(t *testing.T) {
	e := newCreateEnv()
	e.svc.postTextLimit = func(context.Context, string) (int, error) { return 0, errors.New("verification unavailable") }
	if _, err := e.create(CreateInput{IdempotencyKey: key1, Text: strings.Repeat("a", 281)}); err == nil {
		t.Fatal("accepted unavailable access")
	}
	if len(e.repo.docs) != 0 {
		t.Fatal("post written on verification failure")
	}
	// Free-length publishing requires no billing network request.
	if _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "short"}); err != nil {
		t.Fatal(err)
	}
}
func TestPaidTextPreservesGrammar(t *testing.T) {
	for _, value := range []string{strings.Repeat("x\n", 10) + "x", "x\u202E", strings.Repeat("a", 15001)} {
		if _, err := text.ParseWithLimit(value, 15000, false); err == nil {
			t.Fatal("grammar limit bypass")
		}
	}
}
func TestLongScheduledPostReplayAndPublicationPolicy(t *testing.T) {
	e := newSchedSvcEnv()
	e.svc.postTextLimit = func(context.Context, string) (int, error) { return 15000, nil }
	in := e.validIn()
	in.Text = strings.Repeat("a", 15000)
	p, err := e.schedule(in)
	if err != nil {
		t.Fatal(err)
	}
	e.svc.postTextLimit = func(context.Context, string) (int, error) { return 280, nil }
	replay, err := e.schedule(in)
	if err != nil || replay.ID != p.ID {
		t.Fatalf("schedule replay: %v", err)
	}
	if err = e.svc.authorizePostText(context.Background(), schedUID, p.Draft.Text); err == nil {
		t.Fatal("downgraded publication accepted")
	}
}
func TestLongScheduledSweepChecksCurrentAccess(t *testing.T) {
	for _, allowed := range []bool{true, false} {
		e := newSweepEnv(t)
		e.svc.postTextLimit = func(context.Context, string) (int, error) {
			if allowed {
				return 15000, nil
			}
			return 280, nil
		}
		e.dueItem("uid-alice", 1, func(p *ScheduledPost) { p.Draft.Text = strings.Repeat("a", 15000) })
		result, err := e.sweep(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if allowed && result.Published != 1 {
			t.Fatalf("paid draft not published: %+v", result)
		}
		if !allowed && (result.Published != 0 || result.Failed[FailureInvalidContent] != 1) {
			t.Fatal("downgraded draft published")
		}
	}
}
